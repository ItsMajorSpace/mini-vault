/// Photo files on the server's disk: one file per owner and file id, `<photos>/<owner id>/<file id>`.
/// The app's PowerSync attachment queue uploads, downloads and deletes them; Photo rows (the `photos` table)
/// point at them, and a file is deleted once no row points at it.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';

/// The largest photo file accepted. The app uploads JPEGs of at most 2048 px on the long edge, well under this.
const maxPhotoBytes = 10 << 20;

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// Serves `/photos/<id>` for [owner], the authenticated user:
/// - `PUT` stores the request body as the file, once a Photo row of the owner points at it (else 409, so the
///   app retries after its row has synced). 413 if over [maxPhotoBytes], 415 unless the bytes are a JPEG, PNG
///   or WebP image of the declared content type.
/// - `GET` answers the file, 404 if the owner has none with that id (another user's file included).
/// - `DELETE` deletes the file unless a Photo row still points at it (409); 404 if the owner has no such file.
///
/// The id must be a lowercase UUID (400 otherwise), so it never names a path outside the owner's directory.
Future<Response> photoRequest(
  Pool<void> db,
  Directory photos,
  String owner,
  String id,
  Request request,
) async {
  if (!_uuid.hasMatch(owner) || !_uuid.hasMatch(id)) {
    return Response(400, body: 'Expected a lowercase UUID');
  }
  final file = File('${photos.path}/$owner/$id');
  switch (request.method) {
    case 'GET':
      if (!await file.exists()) return Response.notFound(null);
      final head = await file.openRead(0, 12).expand((b) => b).toList();
      return Response.ok(
        file.openRead(),
        headers: {
          'content-type': _imageType(head) ?? 'application/octet-stream',
          'content-length': '${await file.length()}',
          'cache-control': 'private',
        },
      );
    case 'PUT':
      if (!await _referenced(db, owner, id)) {
        return Response(409, body: 'No Photo points at this file yet');
      }
      if ((request.contentLength ?? 0) > maxPhotoBytes) return Response(413);
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in request.read()) {
        bytes.add(chunk);
        if (bytes.length > maxPhotoBytes) return Response(413);
      }
      final body = bytes.takeBytes();
      final type = _imageType(body);
      if (type == null || type != request.mimeType) {
        return Response(415, body: 'Expected a JPEG, PNG or WebP image');
      }
      await file.parent.create(recursive: true);
      // Written aside and renamed, so a download never sees half a file.
      final partial = File('${file.path}.partial');
      await partial.writeAsBytes(body, flush: true);
      await partial.rename(file.path);
      // The last row may have been deleted while this uploaded.
      await deleteUnreferencedPhotos(db, photos, owner, {id});
      return Response(204);
    case 'DELETE':
      if (await _referenced(db, owner, id)) {
        return Response(409, body: 'A Photo still points at this file');
      }
      if (!await file.exists()) return Response.notFound(null);
      await file.delete();
      return Response(204);
    default:
      return Response(405);
  }
}

/// Deletes those of [owner]'s photo files [fileIds] that no Photo row points at any more.
// shortcut: checked after the rows' transaction commits, so a Split copy uploaded in the same instant as the last
// row's delete can lose its file. Lock per file id (pg_advisory_lock) if that ever happens.
Future<void> deleteUnreferencedPhotos(
  Pool<void> db,
  Directory photos,
  String owner,
  Set<String> fileIds,
) async {
  for (final id in fileIds) {
    if (!_uuid.hasMatch(owner) || !_uuid.hasMatch(id)) continue;
    if (await _referenced(db, owner, id)) continue;
    final file = File('${photos.path}/$owner/$id');
    if (await file.exists()) await file.delete();
  }
}

Future<bool> _referenced(Pool<void> db, String owner, String fileId) async =>
    (await db.execute(
      r'SELECT FROM photos WHERE owner_id = $1::uuid AND file_id = $2::uuid LIMIT 1',
      parameters: [owner, fileId],
    )).isNotEmpty;

/// The image type that [bytes] start with (their magic number), or null if they are not a JPEG, PNG or WebP.
String? _imageType(List<int> bytes) {
  bool startsWith(List<int> magic, [int offset = 0]) =>
      bytes.length >= offset + magic.length &&
      [for (final (i, b) in magic.indexed) bytes[offset + i] == b]
          .every((same) => same);
  if (startsWith([0xff, 0xd8, 0xff])) return 'image/jpeg';
  if (startsWith([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
    return 'image/png';
  }
  if (startsWith('RIFF'.codeUnits) && startsWith('WEBP'.codeUnits, 8)) {
    return 'image/webp';
  }
  return null;
}
