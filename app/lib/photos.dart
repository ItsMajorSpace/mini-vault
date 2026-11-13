/// A Unit's photos: picked from the camera or gallery, resized on the device, and synced as files through
/// PowerSync's attachment queue, whose remote storage is the write API (`/photos/<file id>`).
library;

// PowerSync marks its attachment queue experimental; it is still the SDK's official mechanism (ADR 0003).
// ignore_for_file: experimental_member_use

import 'dart:io';
import 'dart:typed_data';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:flutter/foundation.dart';
import 'package:gotrue/gotrue.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:powersync/attachments/attachments.dart';
import 'package:powersync/attachments/io.dart';
import 'package:powersync/powersync.dart' hide Column;

import 'section.dart';
import 'sync.dart';
import 'theme.dart';
import 'workflows.dart';

/// The longest edge, in pixels, of an uploaded photo.
const maxPhotoEdge = 2048;

/// [bytes] (any image the `image` package reads) as a JPEG of at most [maxPhotoEdge] px on the long edge,
/// upright and with its aspect ratio kept. Throws a [FormatException] if it isn't a readable image.
Uint8List resizeForUpload(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('Not a readable image');
  var image = img.bakeOrientation(decoded);
  if (image.width > maxPhotoEdge || image.height > maxPhotoEdge) {
    image = image.width >= image.height
        ? img.copyResize(image, width: maxPhotoEdge)
        : img.copyResize(image, height: maxPhotoEdge);
  }
  return img.encodeJpg(image, quality: 85);
}

/// The attachments table PowerSync's queue keeps its state in; part of the app's database schema.
final photoQueueTable = AttachmentsQueueTable();

/// The app's database schema: the Vault's tables and the photo queue's.
final appSchema = Schema([...SqliteVaultStore.schema.tables, photoQueueTable]);

/// Local changes not on the server yet: row changes in PowerSync's upload queue (`ps_crud`, emptied as uploads
/// finish) plus photo files waiting to upload. Lost on sign-out.
Stream<int> watchUnsynced(PowerSyncDatabase db) => db
    .watch(
      'SELECT (SELECT count(*) FROM ps_crud) + '
      '(SELECT count(*) FROM ${photoQueueTable.name} WHERE state = ?) AS n',
      parameters: [AttachmentState.queuedUpload.toInt()],
      triggerOnTables: ['ps_crud', photoQueueTable.name],
    )
    .map((rows) => rows.first['n'] as int);

/// The photo files of the signed-in user: kept in [dir] on the device, uploaded and downloaded in the background.
class PhotoFiles {
  PhotoFiles(this._db, GoTrueClient auth, this.dir)
    : queue = AttachmentQueue(
        db: _db,
        remoteStorage: _WriteApiStorage(auth),
        localStorage: IOLocalStorage(dir),
        // Every photo file any Unit points at; Units may share one.
        watchAttachments: () => _db
            .watch('SELECT DISTINCT file_id FROM squad_photos')
            .map(
              (rows) => [
                for (final r in rows)
                  WatchedAttachmentItem(
                    id: r['file_id'] as String,
                    fileExtension: 'jpg',
                  ),
              ],
            ),
        errorHandler: AttachmentErrorHandler(
          // 409: the server has no Photo pointing at the file yet. Retry while one exists here (it is still
          // uploading); otherwise it was removed or rejected, and the file is dropped.
          onUploadError: (attachment, e, _) async => switch (e) {
            _HttpStatus(status: 409) =>
              (await _db.getOptional(
                    'SELECT 1 FROM squad_photos WHERE file_id = ?',
                    [attachment.id],
                  )) !=
                  null,
            _HttpStatus(:final status) => status >= 500 || status == 401,
            _ => true, // Offline, or the server is down.
          },
          // A file another device has not uploaded yet answers 404 for now.
          onDownloadError: (_, _, _) async => true,
          onDeleteError: (_, _, _) async => false,
        ),
      );

  final PowerSyncDatabase _db;
  final Directory dir;
  final AttachmentQueue queue;

  /// The Unit's Photos, each with its file on this device (null until downloaded), again whenever they change.
  Stream<List<(Photo, File?)>> watch(String collectionId, String unit) => _db
      .watch(
        'SELECT p.id, p.file_id, a.local_uri FROM squad_photos p '
        'LEFT JOIN ${photoQueueTable.name} a ON a.id = p.file_id AND a.state <> ? '
        'WHERE p.collection_id = ? AND p.squad_name = ? ORDER BY p.id',
        parameters: [AttachmentState.archived.toInt(), collectionId, unit],
        triggerOnTables: ['squad_photos', photoQueueTable.name],
      )
      .map(
        (rows) => [
          for (final r in rows)
            (
              Photo(
                id: r['id'] as String,
                collectionId: collectionId,
                unit: unit,
                fileId: r['file_id'] as String,
              ),
              switch (r['local_uri']) {
                final String uri => File('${dir.path}/$uri'),
                _ => null,
              },
            ),
        ],
      );

  /// The file on this device of the Unit's newest Photo (null if it has none, or the newest is not downloaded yet),
  /// again whenever it changes. Nothing is downloaded for it.
  // shortcut: Photos have no creation time, so "newest" is the latest attachment queue timestamp (set when the
  // file is saved here, or queued or downloaded on another device); add a created_at to photos if that misleads.
  Stream<File?> watchNewest(String collectionId, String unitName) => _db
      .watch(
        'SELECT a.local_uri FROM squad_photos p '
        'LEFT JOIN ${photoQueueTable.name} a ON a.id = p.file_id AND a.state <> ? '
        'WHERE p.collection_id = ? AND p.squad_name = ? '
        'ORDER BY a.timestamp DESC, p.id DESC LIMIT 1',
        parameters: [AttachmentState.archived.toInt(), collectionId, unitName],
        triggerOnTables: ['squad_photos', photoQueueTable.name],
      )
      .map(
        (rows) => switch (rows.firstOrNull?['local_uri']) {
          final String uri => File('${dir.path}/$uri'),
          _ => null,
        },
      );

  /// Picks a photo from [source], resizes it and adds it to the Unit; its file uploads once online.
  /// Throws a [StateError] if the Unit has no room, before anything is picked.
  Future<void> add(
    Vault vault,
    String collectionId,
    String unit,
    ImageSource source,
  ) async {
    final photo = await vault.newPhoto(collectionId, unit);
    // The picker's own resize is fast and native; resizeForUpload still guarantees the size and JPEG.
    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: maxPhotoEdge.toDouble(),
      maxHeight: maxPhotoEdge.toDouble(),
    );
    if (picked == null) return;
    final jpeg = await compute(resizeForUpload, await picked.readAsBytes());
    await queue.saveFile(
      id: photo.fileId,
      data: Stream.value(jpeg),
      mediaType: 'image/jpeg',
      fileExtension: 'jpg',
      updateHook: (tx, _) => SqliteVaultStore.insertPhoto(tx, photo),
    );
  }
}

class _HttpStatus implements Exception {
  _HttpStatus(this.status);
  final int status;

  @override
  String toString() => 'HTTP $status';
}

class _WriteApiStorage implements RemoteStorage {
  _WriteApiStorage(this._auth);

  final GoTrueClient _auth;

  Future<Map<String, String>> _headers() async {
    final session = await _auth.getSession();
    if (session == null) throw StateError('Signed out');
    return {'authorization': 'Bearer ${session.accessToken}'};
  }

  Uri _url(Attachment a) => Uri.parse('$apiUrl/photos/${a.id}');

  static void _check(http.Response response, Set<int> ok) {
    if (!ok.contains(response.statusCode)) {
      throw _HttpStatus(response.statusCode);
    }
  }

  @override
  Future<void> uploadFile(Stream<Uint8List> data, Attachment a) async {
    final bytes = await data.fold(
      BytesBuilder(copy: false),
      (b, c) => b..add(c),
    );
    _check(
      await http.put(
        _url(a),
        headers: {
          ...await _headers(),
          'content-type': a.mediaType ?? 'image/jpeg',
        },
        body: bytes.takeBytes(),
      ),
      {204},
    );
  }

  @override
  Future<Stream<List<int>>> downloadFile(Attachment a) async {
    final response = await http.get(_url(a), headers: await _headers());
    _check(response, {200});
    return Stream.value(response.bodyBytes);
  }

  // Unused: the app never queues a delete. The server deletes a file once no Photo row points at it.
  @override
  Future<void> deleteFile(Attachment a) async =>
      _check(await http.delete(_url(a), headers: await _headers()), {204, 404});
}

/// A Unit's Photos section: its photos in a row, with header buttons to add one from the camera or gallery. Tapping a
/// photo opens the viewer.
class UnitPhotos extends StatefulWidget {
  const UnitPhotos({
    super.key,
    required this.vault,
    required this.files,
    required this.collectionId,
    required this.unit,
  });

  final Vault vault;
  final PhotoFiles files;
  final String collectionId;

  /// The Unit's name.
  final String unit;

  @override
  State<UnitPhotos> createState() => _UnitPhotosState();
}

class _UnitPhotosState extends State<UnitPhotos> {
  late var _photos = widget.files.watch(widget.collectionId, widget.unit);

  @override
  void didUpdateWidget(UnitPhotos old) {
    super.didUpdateWidget(old);
    if (old.unit != widget.unit) {
      _photos = widget.files.watch(widget.collectionId, widget.unit);
    }
  }

  Future<void> _add(ImageSource source) async {
    try {
      await attempt(
        context,
        () => widget.files.add(
          widget.vault,
          widget.collectionId,
          widget.unit,
          source,
        ),
      );
    } on FormatException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read that image')),
        );
      }
    }
  }

  Future<void> _view(List<(Photo, File?)> photos, int index) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) =>
          _PhotoViewer(photos: photos, index: index, vault: widget.vault),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: _photos,
      builder: (context, snapshot) {
        final photos = snapshot.data ?? const [];
        final full = photos.length >= Vault.maxPhotos;
        return Section(
          title: 'Photos',
          count: photos.length,
          actions: [
            IconButton(
              icon: const Icon(Icons.photo_camera),
              tooltip: 'Take a photo',
              onPressed: full ? null : () => _add(ImageSource.camera),
            ),
            IconButton(
              icon: const Icon(Icons.add_photo_alternate),
              tooltip: 'Add a photo from the gallery',
              onPressed: full ? null : () => _add(ImageSource.gallery),
            ),
          ],
          child: photos.isEmpty
              ? const SectionHint('No photos yet')
              : SizedBox(
                  height: 112,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(8),
                    children: [
                      for (final (i, (photo, file)) in photos.indexed)
                        Padding(
                          key: ValueKey(photo.id),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: InkWell(
                            onTap: () => _view(photos, i),
                            child: SizedBox.square(
                              dimension: 96,
                              child: file == null
                                  ? const Icon(
                                      Icons.cloud_download,
                                      semanticLabel: 'Photo not downloaded yet',
                                    )
                                  : Image.file(
                                      file,
                                      fit: BoxFit.cover,
                                      cacheWidth: 192,
                                      semanticLabel: 'Photo',
                                    ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
        );
      },
    );
  }
}

/// [photos] full screen from [index]: swipe between them, pinch to zoom, and remove one once confirmed.
class _PhotoViewer extends StatefulWidget {
  const _PhotoViewer({
    required this.photos,
    required this.index,
    required this.vault,
  });

  final List<(Photo, File?)> photos;
  final int index;
  final Vault vault;

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final _pages = PageController(initialPage: widget.index);
  late int _index = widget.index;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _remove() async {
    final (photo, _) = widget.photos[_index];
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this photo?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: destructive(context),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (!(remove ?? false) || !mounted) return;
    await attempt(context, () => widget.vault.removePhoto(photo.id));
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_index + 1} of ${widget.photos.length}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove photo',
            onPressed: _remove,
          ),
        ],
      ),
      body: PageView(
        controller: _pages,
        onPageChanged: (i) => setState(() => _index = i),
        children: [
          for (final (photo, file) in widget.photos)
            InteractiveViewer(
              key: ValueKey(photo.id),
              maxScale: 5,
              child: Center(
                child: file == null
                    ? const Icon(
                        Icons.cloud_download,
                        color: Colors.white,
                        semanticLabel: 'Photo not downloaded yet',
                      )
                    : Image.file(file, semanticLabel: 'Photo'),
              ),
            ),
        ],
      ),
    );
  }
}

/// A Unit row's leading square: the Unit's newest photo on this device, or a placeholder.
class UnitThumbnail extends StatefulWidget {
  const UnitThumbnail({
    super.key,
    required this.files,
    required this.collectionId,
    required this.unitName,
  });

  final PhotoFiles? files;
  final String collectionId;
  final String unitName;

  @override
  State<UnitThumbnail> createState() => _UnitThumbnailState();
}

class _UnitThumbnailState extends State<UnitThumbnail> {
  late final _newest = widget.files?.watchNewest(
    widget.collectionId,
    widget.unitName,
  );

  @override
  Widget build(BuildContext context) {
    final placeholder = Icon(
      Icons.image_outlined,
      color: Theme.of(context).colorScheme.outline,
      semanticLabel: 'No photo',
    );
    return SizedBox.square(
      dimension: 48,
      child: StreamBuilder(
        stream: _newest,
        builder: (context, snapshot) => switch (snapshot.data) {
          final file? => ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.file(
              file,
              fit: BoxFit.cover,
              cacheWidth: 96,
              semanticLabel: 'Photo',
              errorBuilder: (_, _, _) => placeholder,
            ),
          ),
          null => placeholder,
        },
      ),
    );
  }
}
