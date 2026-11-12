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
        r'''SELECT w.name, owned.name, finished.name, w.starter
          FROM workflows w
          JOIN stages owned ON owned.id = w.owned_stage_id
          JOIN stages finished ON finished.id = w.finished_stage_id
          WHERE w.owner_id = $1::uuid''',
        parameters: [user.id],
      );
      expect(workflows.map((r) => r.toList()), [
        ['Starter', 'Unassembled', 'Done', true],
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

  test('a Stage holding Units cannot be deleted until they are gone', () async {
    final user = await signUp();
    final collectionId = await createCollection(user);
    final primed = await stageOf(user.id, 'Primed');
    final id = await newId();
    expect(
      (await upload(user.token, [
        putUnit(id, collectionId: collectionId, stageId: primed),
      ])).statusCode,
      204,
    );

    final blocked = await upload(user.token, [
      {'op': 'DELETE', 'type': 'stages', 'id': primed},
    ]);
    expect(blocked.statusCode, 409, reason: blocked.body);
    expect(await unit(id), isNotEmpty);

    final deleted = await upload(user.token, [
      {'op': 'DELETE', 'type': 'units', 'id': id},
      {'op': 'DELETE', 'type': 'stages', 'id': primed},
    ]);
    expect(deleted.statusCode, 204, reason: deleted.body);
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
    final stageChangeId = await newId();
    final wishlist = await stageOf(alice.id, 'Wishlist');
    await upload(alice.token, [
      putUnit(unitId, collectionId: id, stageId: wishlist),
      {
        'op': 'PUT',
        'type': 'stage_changes',
        'id': stageChangeId,
        'data': {
          'unit_id': unitId,
          'to_stage_id': wishlist,
          'model_count': 10,
          'happened_at': '2026-11-13T09:00:00.000Z',
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
    for (var i = 0; i < 20 && !aliceIds.contains(stageChangeId); i++) {
      if (i > 0) await Future<void>.delayed(const Duration(milliseconds: 250));
      aliceIds = await syncedIds(alice.token);
    }
    expect(aliceIds, containsAll([id, unitId, stageChangeId]));
    expect(aliceIds, contains(await workflowOf(alice.id)));

    final bobIds = await syncedIds(bob.token);
    expect(bobIds, contains(await workflowOf(bob.id)));
    expect(bobIds.intersection(aliceIds), isEmpty);
  });

  /// The operations that create a Workflow with Stages [stageIds] at positions 0, 1, 2..., the second Owned and the last Finished.
  List<Map<String, Object?>> newWorkflow(String id, List<String> stageIds) => [
    {
      'op': 'PUT',
      'type': 'workflows',
      'id': id,
      'data': {
        'name': 'Speed painting',
        'owned_stage_id': stageIds[1],
        'finished_stage_id': stageIds.last,
      },
    },
    for (final (i, stageId) in stageIds.indexed)
      {
        'op': 'PUT',
        'type': 'stages',
        'id': stageId,
        'data': {'workflow_id': id, 'name': 'Stage $i', 'position': i},
      },
  ];

  Future<List<String>> stagesOf(String workflowId) async => [
    for (final row in await db.execute(
      r'SELECT name FROM stages WHERE workflow_id = $1::uuid ORDER BY position, id',
      parameters: [workflowId],
    ))
      row.first as String,
  ];

  test('a Workflow is created with its Stages, and edited', () async {
    final user = await signUp();
    final id = await newId();
    final stages = [await newId(), await newId(), await newId()];

    final created = await upload(user.token, newWorkflow(id, stages));
    expect(created.statusCode, 204, reason: created.body);
    expect(await stagesOf(id), ['Stage 0', 'Stage 1', 'Stage 2']);

    // Move Stage 2 to the top as the new Owned Stage, make Stage 1 the Finished Stage, and delete Stage 0.
    final edited = await upload(user.token, [
      {
        'op': 'PATCH',
        'type': 'stages',
        'id': stages[2],
        'data': {'position': 0},
      },
      {
        'op': 'PATCH',
        'type': 'stages',
        'id': stages[0],
        'data': {'position': 1},
      },
      {
        'op': 'PATCH',
        'type': 'stages',
        'id': stages[1],
        'data': {'position': 2},
      },
      {
        'op': 'PATCH',
        'type': 'workflows',
        'id': id,
        'data': {'owned_stage_id': stages[2], 'finished_stage_id': stages[1]},
      },
      {'op': 'DELETE', 'type': 'stages', 'id': stages[0]},
    ]);
    expect(edited.statusCode, 204, reason: edited.body);
    expect(await stagesOf(id), ['Stage 2', 'Stage 1']);
  });

  test(
    'a batch that leaves a Workflow invalid is rejected as a whole',
    () async {
      final user = await signUp();
      final id = await newId();
      final stages = [await newId(), await newId(), await newId()];
      await upload(user.token, newWorkflow(id, stages));
      final otherId = await newId();
      final otherStages = [await newId(), await newId()];
      await upload(user.token, newWorkflow(otherId, otherStages));

      for (final (reason, ops) in [
        (
          'Owned after Finished',
          [
            {
              'op': 'PATCH',
              'type': 'stages',
              'id': stages[1],
              'data': {'position': 5},
            },
          ],
        ),
        (
          'Owned Stage deleted',
          [
            {'op': 'DELETE', 'type': 'stages', 'id': stages[1]},
          ],
        ),
        (
          'Finished Stage of another Workflow',
          [
            {
              'op': 'PATCH',
              'type': 'workflows',
              'id': id,
              'data': {'finished_stage_id': otherStages.last},
            },
          ],
        ),
        (
          'Finished Stage moved to another Workflow',
          [
            {
              'op': 'PATCH',
              'type': 'stages',
              'id': stages.last,
              'data': {'workflow_id': otherId},
            },
          ],
        ),
        (
          'all Stages deleted',
          [
            for (final s in stages) {'op': 'DELETE', 'type': 'stages', 'id': s},
          ],
        ),
      ]) {
        final response = await upload(user.token, ops);
        expect(response.statusCode, 422, reason: reason);
      }
      expect(await stagesOf(id), ['Stage 0', 'Stage 1', 'Stage 2']);
    },
  );

  test(
    "Stages and Collections cannot point at another user's Workflow",
    () async {
      final alice = await signUp();
      final bob = await signUp();
      final aliceWorkflow = await workflowOf(alice.id);

      for (final op in [
        {
          'op': 'PUT',
          'type': 'collections',
          'id': await newId(),
          'data': {'name': 'Planted', 'workflow_id': aliceWorkflow},
        },
        {
          'op': 'PUT',
          'type': 'stages',
          'id': await newId(),
          'data': {
            'name': 'Planted',
            'workflow_id': aliceWorkflow,
            'position': 0,
          },
        },
        {
          'op': 'PUT',
          'type': 'collections',
          'id': await newId(),
          'data': {'name': 'Dangling', 'workflow_id': await newId()},
        },
      ]) {
        final response = await upload(bob.token, [op]);
        // Another user's Workflow is forbidden (403); one that doesn't exist is invalid (422).
        expect(
          response.statusCode,
          (op['data'] as Map)['name'] == 'Dangling' ? 422 : 403,
          reason: '${op['type']}: ${response.body}',
        );
      }

      expect(
        (await db.execute(
          r'SELECT count(*) FROM stages WHERE workflow_id = $1::uuid',
          parameters: [aliceWorkflow],
        )).single.first,
        Vault.starterStageNames.length,
      );
      expect(
        (await db.execute(
          r"SELECT count(*) FROM collections WHERE name IN ('Planted', 'Dangling')",
        )).single.first,
        0,
      );
    },
  );

  test(
    'a Workflow a Collection uses cannot be deleted; an unused one can',
    () async {
      final user = await signUp();
      final used = await workflowOf(user.id);
      await upload(user.token, [
        {
          'op': 'PUT',
          'type': 'collections',
          'id': await newId(),
          'data': {'name': 'Space Marines', 'workflow_id': used},
        },
      ]);
      final unused = await newId();
      final unusedStages = [await newId(), await newId()];
      await upload(user.token, newWorkflow(unused, unusedStages));

      final blocked = await upload(user.token, [
        {'op': 'DELETE', 'type': 'workflows', 'id': used},
      ]);
      expect(blocked.statusCode, 409, reason: blocked.body);

      final deleted = await upload(user.token, [
        for (final s in unusedStages)
          {'op': 'DELETE', 'type': 'stages', 'id': s},
        {'op': 'DELETE', 'type': 'workflows', 'id': unused},
      ]);
      expect(deleted.statusCode, 204, reason: deleted.body);

      expect(
        (await db.execute(
          r'SELECT id::text FROM workflows WHERE owner_id = $1::uuid',
          parameters: [user.id],
        )).map((r) => r.first),
        [used],
      );
    },
  );

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

  group('Stage Changes', () {
    Map<String, Object?> putStageChange(
      String id, {
      required String unitId,
      String? fromStageId,
      required String toStageId,
      required String happenedAt,
    }) => {
      'op': 'PUT',
      'type': 'stage_changes',
      'id': id,
      'data': {
        'unit_id': unitId,
        'from_stage_id': fromStageId,
        'to_stage_id': toStageId,
        'model_count': 10,
        'happened_at': happenedAt,
      },
    };

    /// The Unit's history as to-Stage names, oldest first.
    Future<List<Object?>> history(String unitId) async => [
      for (final row in await db.execute(
        r'''SELECT s.name FROM stage_changes sc JOIN stages s ON s.id = sc.to_stage_id
          WHERE sc.unit_id = $1::uuid ORDER BY sc.happened_at, sc.id''',
        parameters: [unitId],
      ))
        row.first,
    ];

    /// A user with a Unit created at Wishlist, as the app uploads it: the Unit, then its initial Stage Change.
    Future<({String token, String id, String unitId})> userWithUnit() async {
      final user = await signUp();
      final collectionId = await createCollection(user);
      final wishlist = await stageOf(user.id, 'Wishlist');
      final unitId = await newId();
      final created = await upload(user.token, [
        putUnit(unitId, collectionId: collectionId, stageId: wishlist),
        putStageChange(
          await newId(),
          unitId: unitId,
          toStageId: wishlist,
          happenedAt: '2026-11-13T09:00:00.000Z',
        ),
      ]);
      expect(created.statusCode, 204, reason: created.body);
      return (token: user.token, id: user.id, unitId: unitId);
    }

    test('two offline moves uploaded out of order are both kept, and the later one by device timestamp is current', () async {
      final user = await userWithUnit();
      final wishlist = await stageOf(user.id, 'Wishlist');
      final primed = await stageOf(user.id, 'Primed');
      final painted = await stageOf(user.id, 'Painted');

      // Device B moved to Painted at 11:00 and uploads first; device A moved to Primed at 10:00 and uploads second.
      for (final (stageId, at) in [
        (painted, '2026-11-13T11:00:00.000Z'),
        (primed, '2026-11-13T10:00:00.000Z'),
      ]) {
        final response = await upload(user.token, [
          {
            'op': 'PATCH',
            'type': 'units',
            'id': user.unitId,
            'data': {'stage_id': stageId},
          },
          putStageChange(
            await newId(),
            unitId: user.unitId,
            fromStageId: wishlist,
            toStageId: stageId,
            happenedAt: at,
          ),
        ]);
        expect(response.statusCode, 204, reason: response.body);
      }

      expect(await history(user.unitId), ['Wishlist', 'Primed', 'Painted']);
      expect((await unit(user.unitId)).single.last, 'Painted');
    });

    test(
      'cannot be edited or deleted; deleting the Unit removes them',
      () async {
        final user = await userWithUnit();
        final id = await newId();
        final primed = await stageOf(user.id, 'Primed');
        final move = putStageChange(
          id,
          unitId: user.unitId,
          toStageId: primed,
          happenedAt: '2026-11-13T10:00:00.000Z',
        );
        expect((await upload(user.token, [move])).statusCode, 204);

        for (final op in [
          {
            'op': 'PATCH',
            'type': 'stage_changes',
            'id': id,
            'data': {'to_stage_id': await stageOf(user.id, 'Done')},
          },
          {'op': 'DELETE', 'type': 'stage_changes', 'id': id},
        ]) {
          final response = await upload(user.token, [op]);
          expect(response.statusCode, 422, reason: '${op['op']}');
        }
        // A retried upload of the same insert, even with other data, changes nothing.
        final retried = await upload(user.token, [
          putStageChange(
            id,
            unitId: user.unitId,
            toStageId: await stageOf(user.id, 'Done'),
            happenedAt: '2026-11-14T10:00:00.000Z',
          ),
        ]);
        expect(retried.statusCode, 204, reason: retried.body);
        expect(await history(user.unitId), ['Wishlist', 'Primed']);
        expect((await unit(user.unitId)).single.last, 'Primed');

        final deleted = await upload(user.token, [
          {'op': 'DELETE', 'type': 'units', 'id': user.unitId},
        ]);
        expect(deleted.statusCode, 204, reason: deleted.body);
        expect(await history(user.unitId), isEmpty);
      },
    );

    test("cannot point at another user's Unit or Stage", () async {
      final alice = await userWithUnit();
      final bob = await userWithUnit();
      final aliceStage = await stageOf(alice.id, 'Primed');
      final bobStage = await stageOf(bob.id, 'Primed');

      for (final (reason, op) in [
        (
          "another user's Unit",
          putStageChange(
            await newId(),
            unitId: alice.unitId,
            toStageId: bobStage,
            happenedAt: '2026-11-13T10:00:00.000Z',
          ),
        ),
        (
          "another user's to-Stage",
          putStageChange(
            await newId(),
            unitId: bob.unitId,
            toStageId: aliceStage,
            happenedAt: '2026-11-13T10:00:00.000Z',
          ),
        ),
        (
          "another user's from-Stage",
          putStageChange(
            await newId(),
            unitId: bob.unitId,
            fromStageId: aliceStage,
            toStageId: bobStage,
            happenedAt: '2026-11-13T10:00:00.000Z',
          ),
        ),
      ]) {
        final response = await upload(bob.token, [op]);
        expect(response.statusCode, 403, reason: reason);
      }

      expect(await history(alice.unitId), ['Wishlist']);
      expect(await history(bob.unitId), ['Wishlist']);
      expect((await unit(alice.unitId)).single.last, 'Wishlist');
    });

    test(
      "a move to a Stage outside the Collection's Workflow is rejected",
      () async {
        final user = await userWithUnit();
        final otherWorkflow = await newId();
        final otherStages = [await newId(), await newId()];
        expect(
          (await upload(
            user.token,
            newWorkflow(otherWorkflow, otherStages),
          )).statusCode,
          204,
        );

        final response = await upload(user.token, [
          putStageChange(
            await newId(),
            unitId: user.unitId,
            toStageId: otherStages.first,
            happenedAt: '2026-11-13T10:00:00.000Z',
          ),
        ]);

        expect(response.statusCode, 422, reason: response.body);
        expect(await history(user.unitId), ['Wishlist']);
        expect((await unit(user.unitId)).single.last, 'Wishlist');
      },
    );
  });
}
