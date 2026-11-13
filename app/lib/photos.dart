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

import 'sync.dart';
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

/// The photo files of the signed-in user: kept in [dir] on the device, uploaded and downloaded in the background.
class PhotoFiles {
  PhotoFiles(this._db, GoTrueClient auth, this.dir)
    : queue = AttachmentQueue(
        db: _db,
        remoteStorage: _WriteApiStorage(auth),
        localStorage: IOLocalStorage(dir),
        // Every photo file any Unit points at; a Split's copies share one.
        watchAttachments: () => _db
            .watch('SELECT DISTINCT file_id FROM photos')
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
              (await _db.getOptional('SELECT 1 FROM photos WHERE file_id = ?', [
                    attachment.id,
                  ])) !=
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
  Stream<List<(Photo, File?)>> watch(String unitId) => _db
      .watch(
        'SELECT p.id, p.file_id, a.local_uri FROM photos p '
        'LEFT JOIN ${photoQueueTable.name} a ON a.id = p.file_id AND a.state <> ? '
        'WHERE p.unit_id = ? ORDER BY p.id',
        parameters: [AttachmentState.archived.toInt(), unitId],
        triggerOnTables: ['photos', photoQueueTable.name],
      )
      .map(
        (rows) => [
          for (final r in rows)
            (
              Photo(
                id: r['id'] as String,
                unitId: unitId,
                fileId: r['file_id'] as String,
              ),
              switch (r['local_uri']) {
                final String uri => File('${dir.path}/$uri'),
                _ => null,
              },
            ),
        ],
      );

  /// Picks a photo from [source], resizes it and adds it to the Unit; its file uploads once online.
  /// Throws a [StateError] if the Unit has no room, before anything is picked.
  Future<void> add(Vault vault, String unitId, ImageSource source) async {
    final photo = await vault.newPhoto(unitId);
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

/// A Unit's photos in a row, with buttons to add one from the camera or gallery. Tapping a photo offers to remove it.
class UnitPhotos extends StatefulWidget {
  const UnitPhotos({
    super.key,
    required this.vault,
    required this.files,
    required this.unitId,
  });

  final Vault vault;
  final PhotoFiles files;
  final String unitId;

  @override
  State<UnitPhotos> createState() => _UnitPhotosState();
}

class _UnitPhotosState extends State<UnitPhotos> {
  late final _photos = widget.files.watch(widget.unitId);

  Future<void> _add(ImageSource source) async {
    try {
      await attempt(
        context,
        () => widget.files.add(widget.vault, widget.unitId, source),
      );
    } on FormatException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read that image')),
        );
      }
    }
  }

  Future<void> _remove(Photo photo, File? file) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: file == null ? null : Image.file(file),
        title: const Text('Remove this photo?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove ?? false) await widget.vault.removePhoto(photo.id);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: _photos,
      builder: (context, snapshot) {
        final photos = snapshot.data ?? const [];
        final full = photos.length >= Vault.maxPhotos;
        return SizedBox(
          height: 112,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            children: [
              for (final (photo, file) in photos)
                Padding(
                  key: ValueKey(photo.id),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: InkWell(
                    onTap: () => _remove(photo, file),
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
              IconButton(
                icon: const Icon(Icons.photo_camera),
                tooltip: 'Take a photo',
                onPressed: full ? null : () => _add(ImageSource.camera),
              ),
              IconButton(
                icon: const Icon(Icons.photo_library),
                tooltip: 'Add a photo from the gallery',
                onPressed: full ? null : () => _add(ImageSource.gallery),
              ),
            ],
          ),
        );
      },
    );
  }
}
