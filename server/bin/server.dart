import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:server/write_api.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';

/// `server migrate` sets up the database and exits; `server` serves the write API.
/// Reads DATABASE_URL, JWT_SECRET (GoTrue's), PHOTOS_DIR (photo files) and PORT from the environment.
Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final db = Pool<void>.withUrl(env['DATABASE_URL']!);

  if (args case ['migrate']) {
    await db.withConnection(migrate);
    await db.close();
    return;
  }

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addHandler(
        writeApi(
          db,
          Directory(env['PHOTOS_DIR'] ?? '/photos'),
          jwtSecret: env['JWT_SECRET']!,
        ),
      );
  final server = await serve(
    handler,
    InternetAddress.anyIPv4,
    int.parse(env['PORT'] ?? '8000'),
  );
  print('Write API listening on port ${server.port}');
}
