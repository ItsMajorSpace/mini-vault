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

  Future<String> stageOf(String userId, String name) async =>
      (await db.execute(
            r'SELECT id::text FROM stages WHERE owner_id = $1::uuid AND name = $2',
            parameters: [userId, name],
          )).first.first
          as String;

  /// Creates a Collection for [user] through the API and returns its id.
  Future<String> createCollection(({String token, String id}) user) async {
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
    ]);
    expect(response.statusCode, 204, reason: response.body);
    return id;
  }

  Map<String, Object?> putUnit(
    String id, {
    required String collectionId,
    required String stageId,
    int modelCount = 10,
  }) => {
    'op': 'PUT',
    'type': 'units',
    'id': id,
    'data': {
      'name': 'Intercessors',
      'model_count': modelCount,
      'notes': '',
      'collection_id': collectionId,
      'stage_id': stageId,
    },
  };

  Future<List<List<Object?>>> unit(String id) async => [
    for (final row in await db.execute(
      r'''SELECT u.owner_id::text, u.name, u.model_count, u.notes, s.name
        FROM units u JOIN stages s ON s.id = u.stage_id WHERE u.id = $1::uuid''',
      parameters: [id],
    ))
      row.toList(),
  ];

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

  test('a Unit is created at a Stage, edited per field and deleted', () async {
    final user = await signUp();
    final collectionId = await createCollection(user);
    final id = await newId();

    final created = await upload(user.token, [
      putUnit(
        id,
        collectionId: collectionId,
        stageId: await stageOf(user.id, 'Primed'),
      ),
    ]);
    expect(created.statusCode, 204, reason: created.body);
    expect(await unit(id), [
      [user.id, 'Intercessors', 10, '', 'Primed'],
    ]);

    final edited = await upload(user.token, [
      {
        'op': 'PATCH',
        'type': 'units',
        'id': id,
        'data': {'model_count': 5, 'notes': 'Jump packs'},
      },
    ]);
    expect(edited.statusCode, 204, reason: edited.body);
    expect(await unit(id), [
      [user.id, 'Intercessors', 5, 'Jump packs', 'Primed'],
    ]);

    final deleted = await upload(user.token, [
      {'op': 'DELETE', 'type': 'units', 'id': id},
    ]);
    expect(deleted.statusCode, 204, reason: deleted.body);
    expect(await unit(id), isEmpty);
  });

  test('a Unit must have at least one model', () async {
    final user = await signUp();
    final collectionId = await createCollection(user);
    final stageId = await stageOf(user.id, 'Wishlist');
    final id = await newId();
    await upload(user.token, [
      putUnit(id, collectionId: collectionId, stageId: stageId),
    ]);

    final created = await upload(user.token, [
      putUnit(
        await newId(),
        collectionId: collectionId,
        stageId: stageId,
        modelCount: 0,
      ),
    ]);
    final edited = await upload(user.token, [
      {
        'op': 'PATCH',
        'type': 'units',
        'id': id,
        'data': {'model_count': 0},
      },
    ]);

    expect(created.statusCode, 422);
    expect(edited.statusCode, 422);
    expect((await unit(id)).single[2], 10);
  });

  test(
    "rows cannot point at another user's rows, or at rows that do not exist",
    () async {
      final alice = await signUp();
      final bob = await signUp();
      final aliceCollection = await createCollection(alice);
      final bobCollection = await createCollection(bob);
      final aliceStage = await stageOf(alice.id, 'Wishlist');
      final bobStage = await stageOf(bob.id, 'Wishlist');

      final cases = {
        "a Unit in another user's Collection": (
          403,
          putUnit(
            await newId(),
            collectionId: aliceCollection,
            stageId: bobStage,
          ),
        ),
        "a Unit at another user's Stage": (
          403,
          putUnit(
            await newId(),
            collectionId: bobCollection,
            stageId: aliceStage,
          ),
        ),
        "a Collection with another user's Workflow": (
          403,
          {
            'op': 'PUT',
            'type': 'collections',
            'id': await newId(),
            'data': {
              'name': 'Planted',
              'workflow_id': await workflowOf(alice.id),
            },
          },
        ),
        'a Unit in a missing Collection': (
          422,
          putUnit(
            await newId(),
            collectionId: await newId(),
            stageId: bobStage,
          ),
        ),
        'a Collection with a missing Workflow': (
          422,
          {
            'op': 'PUT',
            'type': 'collections',
            'id': await newId(),
            'data': {'name': 'Planted', 'workflow_id': await newId()},
          },
        ),
      };
      for (final MapEntry(key: reason, value: (status, op)) in cases.entries) {
        final response = await upload(bob.token, [op]);
        expect(response.statusCode, status, reason: reason);
      }

      final units = await db.execute(
        r'SELECT count(*) FROM units WHERE owner_id IN ($1::uuid, $2::uuid)',
        parameters: [alice.id, bob.id],
      );
      expect(units.single.first, 0);
    },
  );

  test("a Unit's Stage must be in its Collection's Workflow", () async {
    final user = await signUp();
    final collectionId = await createCollection(user);
    // A second Workflow of the same user, with one Stage.
    final otherWorkflow = await newId();
    final otherStage = await newId();
    await db.execute(
      r'''INSERT INTO workflows (id, owner_id, name, owned_stage_id, finished_stage_id)
        VALUES ($1::uuid, $3::uuid, 'Other', $2::uuid, $2::uuid)''',
      parameters: [otherWorkflow, otherStage, user.id],
    );
    await db.execute(
      r'''INSERT INTO stages (id, owner_id, workflow_id, name, position)
        VALUES ($2::uuid, $3::uuid, $1::uuid, 'Elsewhere', 0)''',
      parameters: [otherWorkflow, otherStage, user.id],
    );
    final id = await newId();

    final created = await upload(user.token, [
      putUnit(await newId(), collectionId: collectionId, stageId: otherStage),
    ]);
    await upload(user.token, [
      putUnit(
        id,
        collectionId: collectionId,
        stageId: await stageOf(user.id, 'Wishlist'),
      ),
    ]);
    final moved = await upload(user.token, [
      {
        'op': 'PATCH',
        'type': 'units',
        'id': id,
        'data': {'stage_id': otherStage},
      },
    ]);

    expect(created.statusCode, 422);
    expect(moved.statusCode, 422);
    expect((await unit(id)).single.last, 'Wishlist');
  });

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
    final id = await createCollection(alice);
    final unitId = await newId();
    await upload(alice.token, [
      putUnit(
        unitId,
        collectionId: id,
        stageId: await stageOf(alice.id, 'Wishlist'),
      ),
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
    for (var i = 0; i < 20 && !aliceIds.contains(unitId); i++) {
      if (i > 0) await Future<void>.delayed(const Duration(milliseconds: 250));
      aliceIds = await syncedIds(alice.token);
    }
    expect(aliceIds, containsAll([id, unitId]));
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
