import 'dart:convert';
import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:http/http.dart' as http;
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

// Seam 2: the write API over HTTP, against real Postgres, GoTrue and the API in Docker.
// Start the stack first: `docker compose up -d --build` in server/ (with a .env, see .env.example).
final _env = {
  for (final line in File('.env').readAsLinesSync())
    if (line.split('=') case [final key, ...final value]
        when !key.startsWith('#') && value.isNotEmpty)
      key.trim(): value.join('='),
};
final _auth = Uri.parse('http://localhost:9999');
final _upload = Uri.parse('http://localhost:8000/upload');

void main() {
  late Connection db;

  setUpAll(() async {
    db = await Connection.open(
      Endpoint(
        host: 'localhost',
        database: 'postgres',
        username: 'postgres',
        password: _env['POSTGRES_PASSWORD'],
      ),
      settings: ConnectionSettings(sslMode: SslMode.disable),
    );
  });
  tearDownAll(() => db.close());

  /// Signs up a new account through GoTrue and returns its access token and user id.
  Future<({String token, String id})> signUp() async {
    final email = 'test-${DateTime.now().microsecondsSinceEpoch}@example.com';
    final response = await http.post(
      _auth.resolve('/signup'),
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
        _upload,
        headers: {'authorization': 'Bearer $token'},
        body: jsonEncode({'operations': ops}),
      );

  Future<String> newId() async =>
      (await db.execute('SELECT gen_random_uuid()::text')).first.first
          as String;

  Future<String> workflowOf(String userId) async =>
      (await db.execute(
            r'SELECT id::text FROM workflows WHERE owner_id = $1::uuid',
            parameters: [userId],
          )).first.first
          as String;

  Future<List<List<Object?>>> collection(String id) async => [
    for (final row in await db.execute(
      r'SELECT owner_id::text, name FROM collections WHERE id = $1::uuid',
      parameters: [id],
    ))
      row.toList(),
  ];

  test(
    'sign-up creates exactly one starter Workflow for the new account',
    () async {
      final user = await signUp();

      final workflows = await db.execute(
        r'''SELECT w.name, owned.name, finished.name
          FROM workflows w
          JOIN stages owned ON owned.id = w.owned_stage_id
          JOIN stages finished ON finished.id = w.finished_stage_id
          WHERE w.owner_id = $1::uuid''',
        parameters: [user.id],
      );
      expect(workflows.map((r) => r.toList()), [
        ['Starter', 'Unassembled', 'Done'],
      ]);
      final stages = await db.execute(
        r'SELECT name FROM stages WHERE owner_id = $1::uuid ORDER BY position',
        parameters: [user.id],
      );
      expect(stages.map((r) => r.first), Vault.starterStageNames);
    },
  );

  test('a created Collection is owned by the signed-in user, and renamed per field', () async {
    final user = await signUp();
    final id = await newId();
    final workflowId = await workflowOf(user.id);

    final created = await upload(user.token, [
      {
        'op': 'PUT',
        'type': 'collections',
        'id': id,
        'data': {'name': ' Space Marines ', 'workflow_id': workflowId},
      },
    ]);
    expect(created.statusCode, 204, reason: created.body);
    expect(await collection(id), [
      [user.id, 'Space Marines'],
    ]);

    final renamed = await upload(user.token, [
      {
        'op': 'PATCH',
        'type': 'collections',
        'id': id,
        'data': {'name': 'Ultramarines'},
      },
    ]);
    expect(renamed.statusCode, 204, reason: renamed.body);
    expect(await collection(id), [
      [user.id, 'Ultramarines'],
    ]);
  });

  test(
    "writes to another user's rows are rejected and change nothing",
    () async {
      final alice = await signUp();
      final bob = await signUp();
      final id = await newId();
      final aliceWorkflow = await workflowOf(alice.id);
      await upload(alice.token, [
        {
          'op': 'PUT',
          'type': 'collections',
          'id': id,
          'data': {'name': 'Space Marines', 'workflow_id': aliceWorkflow},
        },
      ]);

      for (final op in [
        {
          'op': 'PATCH',
          'type': 'collections',
          'id': id,
          'data': {'name': 'Mine now'},
        },
        {
          'op': 'PUT',
          'type': 'collections',
          'id': id,
          'data': {'name': 'Mine now', 'workflow_id': aliceWorkflow},
        },
        {'op': 'DELETE', 'type': 'collections', 'id': id},
        {
          'op': 'PATCH',
          'type': 'workflows',
          'id': aliceWorkflow,
          'data': {'name': 'Mine now'},
        },
      ]) {
        final response = await upload(bob.token, [op]);
        expect(response.statusCode, 403, reason: '${op['op']} ${op['type']}');
      }

      expect(await collection(id), [
        [alice.id, 'Space Marines'],
      ]);
      expect(
        (await db.execute(
          r'SELECT name FROM workflows WHERE id = $1::uuid',
          parameters: [aliceWorkflow],
        )).single.first,
        'Starter',
      );
    },
  );

  test('the owner cannot be set from the payload', () async {
    final alice = await signUp();
    final bob = await signUp();

    final response = await upload(bob.token, [
      {
        'op': 'PUT',
        'type': 'collections',
        'id': await newId(),
        'data': {
          'name': 'Planted',
          'workflow_id': await workflowOf(bob.id),
          'owner_id': alice.id,
        },
      },
    ]);

    expect(response.statusCode, 422);
  });

  test('a delete wins over a later rename from another device', () async {
    final user = await signUp();
    final id = await newId();
    await upload(user.token, [
      {
        'op': 'PUT',
        'type': 'collections',
        'id': id,
        'data': {
          'name': 'Space Marines',
          'workflow_id': await workflowOf(user.id),
        },
      },
      {'op': 'DELETE', 'type': 'collections', 'id': id},
    ]);

    final renamed = await upload(user.token, [
      {
        'op': 'PATCH',
        'type': 'collections',
        'id': id,
        'data': {'name': 'Ultramarines'},
      },
    ]);

    expect(renamed.statusCode, 204);
    expect(await collection(id), isEmpty);
  });

  test('an invalid batch is rejected as a whole', () async {
    final user = await signUp();
    final id = await newId();

    final response = await upload(user.token, [
      {
        'op': 'PUT',
        'type': 'collections',
        'id': id,
        'data': {
          'name': 'Space Marines',
          'workflow_id': await workflowOf(user.id),
        },
      },
      {
        'op': 'PATCH',
        'type': 'collections',
        'id': id,
        'data': {'name': '   '},
      },
    ]);

    expect(response.statusCode, 422);
    expect(await collection(id), isEmpty);
  });

  test('PowerSync sends each user only their own rows', () async {
    final alice = await signUp();
    final bob = await signUp();
    final id = await newId();
    await upload(alice.token, [
      {
        'op': 'PUT',
        'type': 'collections',
        'id': id,
        'data': {
          'name': 'Space Marines',
          'workflow_id': await workflowOf(alice.id),
        },
      },
    ]);

    /// The ids in one full sync of [token]'s rows, read from PowerSync's sync stream.
    Future<Set<String>> syncedIds(String token) async {
      final request =
          http.Request('POST', Uri.parse('http://localhost:8080/sync/stream'))
            ..headers.addAll({
              'authorization': 'Token $token',
              'content-type': 'application/json',
            })
            ..body = '{"raw_data": true}';
      final client = http.Client();
      final ids = <String>{};
      try {
        final lines = (await client.send(request)).stream
            .transform(utf8.decoder)
            .transform(const LineSplitter());
        await for (final line in lines.timeout(const Duration(seconds: 10))) {
          final message = jsonDecode(line) as Map<String, Object?>;
          if (message['data'] case {'data': final List ops}) {
            ids.addAll([
              for (final op in ops) (op as Map)['object_id'] as String,
            ]);
          }
          if (message.containsKey('checkpoint_complete')) break;
        }
      } finally {
        client.close();
      }
      return ids;
    }

    // Replication from Postgres is asynchronous: wait until Alice's Collection reaches her stream.
    var aliceIds = <String>{};
    for (var i = 0; i < 20 && !aliceIds.contains(id); i++) {
      if (i > 0) await Future<void>.delayed(const Duration(milliseconds: 250));
      aliceIds = await syncedIds(alice.token);
    }
    expect(aliceIds, contains(id));
    expect(aliceIds, contains(await workflowOf(alice.id)));

    final bobIds = await syncedIds(bob.token);
    expect(bobIds, contains(await workflowOf(bob.id)));
    expect(bobIds.intersection(aliceIds), isEmpty);
  });

  test('uploads without a valid access token are rejected', () async {
    final op = {'op': 'DELETE', 'type': 'collections', 'id': await newId()};
    final forged =
        'eyJhbGciOiJub25lIn0.${base64Url.encode(utf8.encode('{"sub":"x","aud":"authenticated"}'))}.';

    expect(
      (await http.post(_upload, body: '{"operations":[]}')).statusCode,
      401,
    );
    expect((await upload(forged, [op])).statusCode, 401);
  });
}
