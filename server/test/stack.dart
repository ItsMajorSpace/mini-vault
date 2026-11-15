import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

// The Docker stack the server tests run against: Postgres, GoTrue and the write API.
// Start it first: `docker compose up -d --build` in server/ (with a .env, see .env.example).
final env = {
  for (final line in File('.env').readAsLinesSync())
    if (line.split('=') case [final key, ...final value]
        when !key.startsWith('#') && value.isNotEmpty)
      key.trim(): value.join('='),
};
final authUrl = Uri.parse('http://localhost:9999');
final uploadUrl = Uri.parse('http://localhost:8000/upload');

/// Connects to the stack's Postgres as its superuser.
Future<Connection> openPostgres() => Connection.open(
  Endpoint(
    host: 'localhost',
    database: 'postgres',
    username: 'postgres',
    password: env['POSTGRES_PASSWORD'],
  ),
  settings: ConnectionSettings(sslMode: SslMode.disable),
);

/// Signs up a new account through GoTrue and returns its access token and user id.
Future<({String token, String id})> signUp() async {
  final email = 'test-${DateTime.now().microsecondsSinceEpoch}@example.com';
  final response = await http.post(
    authUrl.resolve('/signup'),
    headers: {'content-type': 'application/json'},
    body: jsonEncode({'email': email, 'password': 'correct horse battery'}),
  );
  expect(response.statusCode, 200, reason: response.body);
  final body = jsonDecode(response.body) as Map<String, Object?>;
  return (
    token: body['access_token'] as String,
    id: (body['user'] as Map)['id'] as String,
  );
}

/// Uploads operations shaped like PowerSync's `CrudEntry.toJson()`.
Future<http.Response> upload(String token, List<Map<String, Object?>> ops) =>
    http.post(
      uploadUrl,
      headers: {'authorization': 'Bearer $token'},
      body: jsonEncode({'operations': ops}),
    );
