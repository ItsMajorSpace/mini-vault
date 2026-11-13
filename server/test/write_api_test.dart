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

  /// Puts Tag [name] on Unit [unitId], with the id the app gives it.
  Map<String, Object?> putTag(String unitId, String name) => {
    'op': 'PUT',
    'type': 'unit_tags',
    'id': tagId(unitId, name),
    'data': {'unit_id': unitId, 'name': name},
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

  group('Tags', () {
    /// Creates a Unit for [user] through the API and returns its id.
    Future<String> createUnit(({String token, String id}) user) async {
      final id = await newId();
      final response = await upload(user.token, [
        putUnit(
          id,
          collectionId: await createCollection(user),
          stageId: await stageOf(user.id, 'Primed'),
        ),
      ]);
      expect(response.statusCode, 204, reason: response.body);
      return id;
    }

    Future<List<List<Object?>>> tagsOf(String unitId) async => [
      for (final row in await db.execute(
        r'SELECT owner_id::text, name FROM unit_tags WHERE unit_id = $1::uuid ORDER BY name',
        parameters: [unitId],
      ))
        row.toList(),
    ];

    test('are added and removed, and deleted with their Unit', () async {
      final user = await signUp();
      final unitId = await createUnit(user);

      final added = await upload(user.token, [
        putTag(unitId, ' Necrons '),
        putTag(unitId, 'Warhammer 40k'),
      ]);
      expect(added.statusCode, 204, reason: added.body);
      expect(await tagsOf(unitId), [
        [user.id, 'Necrons'],
        [user.id, 'Warhammer 40k'],
      ]);

      final removed = await upload(user.token, [
        {'op': 'DELETE', 'type': 'unit_tags', 'id': tagId(unitId, 'necrons')},
      ]);
      expect(removed.statusCode, 204, reason: removed.body);
      expect(await tagsOf(unitId), [
        [user.id, 'Warhammer 40k'],
      ]);

      // An older app could delete the Unit without its Tags: the server deletes them anyway.
      final deleted = await upload(user.token, [
        {'op': 'DELETE', 'type': 'units', 'id': unitId},
      ]);
      expect(deleted.statusCode, 204, reason: deleted.body);
      expect(await tagsOf(unitId), isEmpty);
    });

    test("cannot be put on another user's Unit", () async {
      final alice = await signUp();
      final bob = await signUp();
      final unitId = await createUnit(alice);

      final response = await upload(bob.token, [putTag(unitId, 'Necrons')]);
      expect(response.statusCode, 403, reason: response.body);
      expect(await tagsOf(unitId), isEmpty);
    });

    test('added again from a second device keeps one row and its first casing, and the batch goes through', () async {
      final user = await signUp();
      final unitId = await createUnit(user);
      expect(
        (await upload(user.token, [putTag(unitId, 'Necrons')])).statusCode,
        204,
      );

      // The second device tagged the same Unit offline, in the same batch as an edit.
      final second = await upload(user.token, [
        putTag(unitId, 'necrons'),
        {
          'op': 'PATCH',
          'type': 'units',
          'id': unitId,
          'data': {'notes': 'Dynasty colours'},
        },
      ]);
      expect(second.statusCode, 204, reason: second.body);
      expect(await tagsOf(unitId), [
        [user.id, 'Necrons'],
      ]);
      expect((await unit(unitId)).single[3], 'Dynasty colours');
    });

    test(
      'must have the id of their Unit and name, and are never edited',
      () async {
        final user = await signUp();
        final unitId = await createUnit(user);
        final wrongId = {...putTag(unitId, 'Necrons'), 'id': await newId()};

        expect((await upload(user.token, [wrongId])).statusCode, 422);
        expect(
          (await upload(user.token, [putTag(unitId, 'Necrons')])).statusCode,
          204,
        );
        final edit = await upload(user.token, [
          {
            'op': 'PATCH',
            'type': 'unit_tags',
            'id': tagId(unitId, 'Necrons'),
            'data': {'name': 'Orks'},
          },
        ]);
        expect(edit.statusCode, 422);
        expect(await tagsOf(unitId), [
          [user.id, 'Necrons'],
        ]);
      },
    );
  });

  test('PowerSync sends each user only their own rows', () async {
    final alice = await signUp();
    final bob = await signUp();
    final id = await createCollection(alice);
    final unitId = await newId();
    final stageChangeId = await newId();
    final wishlist = await stageOf(alice.id, 'Wishlist');
    final tag = putTag(unitId, 'Necrons');
    final photoId = await newId();
    final uploaded = await upload(alice.token, [
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
      tag,
      {
        'op': 'PUT',
        'type': 'photos',
        'id': photoId,
        'data': {'unit_id': unitId, 'file_id': await newId()},
      },
    ]);
    expect(uploaded.statusCode, 204, reason: uploaded.body);

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
    for (
      var i = 0;
      i < 20 && !aliceIds.containsAll([stageChangeId, tag['id']]);
      i++
    ) {
      if (i > 0) await Future<void>.delayed(const Duration(milliseconds: 250));
      aliceIds = await syncedIds(alice.token);
    }
    expect(
      aliceIds,
      containsAll([id, unitId, stageChangeId, tag['id'], photoId]),
    );
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

    /// A Unit created at [stageId] in [collectionId], as the app uploads it.
    Future<String> createUnitAt(
      ({String token, String id}) user,
      String collectionId,
      String stageId,
    ) async {
      final unitId = await newId();
      final created = await upload(user.token, [
        putUnit(unitId, collectionId: collectionId, stageId: stageId),
        putStageChange(
          await newId(),
          unitId: unitId,
          toStageId: stageId,
          happenedAt: '2026-11-13T09:00:00.000Z',
        ),
      ]);
      expect(created.statusCode, 204, reason: created.body);
      return unitId;
    }

    /// One Unit move as the app uploads it: the Unit's stage_id, then the Stage Change.
    Future<List<Map<String, Object?>>> move(
      String unitId,
      String from,
      String to,
    ) async => [
      {
        'op': 'PATCH',
        'type': 'units',
        'id': unitId,
        'data': {'stage_id': to},
      },
      putStageChange(
        await newId(),
        unitId: unitId,
        fromStageId: from,
        toStageId: to,
        happenedAt: '2026-11-13T10:00:00.000Z',
      ),
    ];

    test('deleting a Stage that holds Units: the app\'s batch of moves, new Owned Stage and delete is accepted', () async {
      final user = await signUp();
      final unassembled = await stageOf(user.id, 'Unassembled');
      final assembled = await stageOf(user.id, 'Assembled');
      final units = [
        await createUnitAt(user, await createCollection(user), unassembled),
        await createUnitAt(user, await createCollection(user), unassembled),
      ];

      final response = await upload(user.token, [
        for (final u in units) ...await move(u, unassembled, assembled),
        {
          'op': 'PATCH',
          'type': 'workflows',
          'id': await workflowOf(user.id),
          'data': {'owned_stage_id': assembled},
        },
        {'op': 'DELETE', 'type': 'stages', 'id': unassembled},
      ]);

      expect(response.statusCode, 204, reason: response.body);
      for (final u in units) {
        expect((await unit(u)).single.last, 'Assembled');
        expect(await history(u), [
          'Assembled',
        ]); // The initial Stage Change's Stage is gone, so the join drops it.
        final changes = await db.execute(
          r'SELECT count(*) FROM stage_changes WHERE unit_id = $1::uuid',
          parameters: [u],
        );
        expect(changes.first.first, 2);
      }
      final stages = await db.execute(
        r'SELECT FROM stages WHERE id = $1::uuid',
        parameters: [unassembled],
      );
      expect(stages, isEmpty);
    });

    test('deleting a Stage is still refused (409) when another device moved a Unit into it meanwhile', () async {
      final user = await signUp();
      final collectionId = await createCollection(user);
      final wishlist = await stageOf(user.id, 'Wishlist');
      final primed = await stageOf(user.id, 'Primed');
      final assembled = await stageOf(user.id, 'Assembled');
      final known = await createUnitAt(user, collectionId, primed);
      final other = await createUnitAt(user, collectionId, wishlist);

      // Device B moves the other Unit into Primed while device A is offline, deleting Primed and moving the Unit it knows.
      final moved = await upload(
        user.token,
        await move(other, wishlist, primed),
      );
      expect(moved.statusCode, 204, reason: moved.body);
      final response = await upload(user.token, [
        ...await move(known, primed, assembled),
        {'op': 'DELETE', 'type': 'stages', 'id': primed},
      ]);

      expect(response.statusCode, 409, reason: response.body);
      expect((await unit(known)).single.last, 'Primed');
      expect((await unit(other)).single.last, 'Primed');
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

    group('switching a Collection to another Workflow', () {
      Map<String, Object?> switchTo(String collectionId, String workflowId) => {
        'op': 'PATCH',
        'type': 'collections',
        'id': collectionId,
        'data': {'workflow_id': workflowId},
      };
      Future<String?> workflowOfCollection(String id) async =>
          (await db.execute(
                r'SELECT workflow_id::text FROM collections WHERE id = $1::uuid',
                parameters: [id],
              )).first.first
              as String?;

      /// A user with a Collection holding a Unit at Wishlist and one at Primed, and a second Workflow.
      Future<_Switch> setUpSwitch() async {
        final user = await signUp();
        final collectionId = await createCollection(user);
        final units = [
          await createUnitAt(
            user,
            collectionId,
            await stageOf(user.id, 'Wishlist'),
          ),
          await createUnitAt(
            user,
            collectionId,
            await stageOf(user.id, 'Primed'),
          ),
        ];
        final workflowId = await newId();
        final stages = [await newId(), await newId(), await newId()];
        final created = await upload(
          user.token,
          newWorkflow(workflowId, stages),
        );
        expect(created.statusCode, 204, reason: created.body);
        return (
          user: user,
          collectionId: collectionId,
          units: units,
          workflowId: workflowId,
          stages: stages,
        );
      }

      /// The app's batch: each Unit's move (Unit stage_id, then Stage Change), then the Collection's workflow_id.
      Future<List<Map<String, Object?>>> appBatch(_Switch s) async => [
        ...await move(
          s.units[0],
          await stageOf(s.user.id, 'Wishlist'),
          s.stages[0],
        ),
        ...await move(
          s.units[1],
          await stageOf(s.user.id, 'Primed'),
          s.stages[2],
        ),
        switchTo(s.collectionId, s.workflowId),
      ];

      test("the app's batch is accepted and leaves every Unit at a Stage of the new Workflow", () async {
        final s = await setUpSwitch();

        final response = await upload(s.user.token, await appBatch(s));

        expect(response.statusCode, 204, reason: response.body);
        expect(await workflowOfCollection(s.collectionId), s.workflowId);
        expect((await unit(s.units[0])).single.last, 'Stage 0');
        expect((await unit(s.units[1])).single.last, 'Stage 2');
        expect(await history(s.units[1]), ['Primed', 'Stage 2']);
      });

      test("switching to another user's Workflow is rejected", () async {
        final s = await setUpSwitch();
        final other = await signUp();

        final response = await upload(s.user.token, [
          switchTo(s.collectionId, await workflowOf(other.id)),
        ]);

        expect(response.statusCode, 403, reason: response.body);
        expect(
          await workflowOfCollection(s.collectionId),
          await workflowOf(s.user.id),
        );
      });

      test('switching without moving every Unit is rejected', () async {
        final s = await setUpSwitch();

        final response = await upload(s.user.token, [
          ...(await appBatch(s)).skip(2), // The first Unit's move left out.
        ]);

        expect(response.statusCode, 422, reason: response.body);
        expect(
          await workflowOfCollection(s.collectionId),
          await workflowOf(s.user.id),
        );
        expect((await unit(s.units[1])).single.last, 'Primed');
      });

      test('the batch is rejected as a whole when another device added a Unit to the Collection meanwhile', () async {
        final s = await setUpSwitch();
        final batch = await appBatch(s); // Made offline, before the add.
        final added = await createUnitAt(
          s.user,
          s.collectionId,
          await stageOf(s.user.id, 'Painted'),
        );

        final response = await upload(s.user.token, batch);

        expect(response.statusCode, 422, reason: response.body);
        expect(
          await workflowOfCollection(s.collectionId),
          await workflowOf(s.user.id),
        );
        expect((await unit(s.units[0])).single.last, 'Wishlist');
        expect((await unit(added)).single.last, 'Painted');
        expect(await history(s.units[0]), ['Wishlist']);
      });

      test('the batch is rejected as a whole when another device moved a Unit later than the switch', () async {
        final s = await setUpSwitch();
        final batch = await appBatch(s); // Its moves are stamped 10:00.
        final moved = await upload(s.user.token, [
          putStageChange(
            await newId(),
            unitId: s.units[1],
            fromStageId: await stageOf(s.user.id, 'Primed'),
            toStageId: await stageOf(s.user.id, 'Done'),
            happenedAt: '2026-11-13T11:00:00.000Z',
          ),
        ]);
        expect(moved.statusCode, 204, reason: moved.body);

        final response = await upload(s.user.token, batch);

        expect(response.statusCode, 422, reason: response.body);
        expect(
          await workflowOfCollection(s.collectionId),
          await workflowOf(s.user.id),
        );
        expect((await unit(s.units[1])).single.last, 'Done');
        expect(await history(s.units[1]), ['Primed', 'Done']);
      });

      test(
        "once switched, another device's move to an old Stage is rejected",
        () async {
          final s = await setUpSwitch();
          expect(
            (await upload(s.user.token, await appBatch(s))).statusCode,
            204,
          );

          final response = await upload(
            s.user.token,
            await move(
              s.units[0],
              await stageOf(s.user.id, 'Wishlist'),
              await stageOf(s.user.id, 'Done'),
            ),
          );

          expect(response.statusCode, 422, reason: response.body);
          expect((await unit(s.units[0])).single.last, 'Stage 0');
        },
      );
    });
  });

  group('Photos', () {
    /// A fake JPEG: the write API checks the magic number, not the whole image.
    final jpeg = [0xff, 0xd8, 0xff, 0xe0, ...List.filled(100, 7)];
    const png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0];

    Uri file(String id) => _upload.resolve('/photos/$id');
    Map<String, String> auth(String token, [String type = 'image/jpeg']) => {
      'authorization': 'Bearer $token',
      'content-type': type,
    };

    Future<String> addUnit(({String token, String id}) user) async {
      final id = await newId();
      final response = await upload(user.token, [
        putUnit(
          id,
          collectionId: await createCollection(user),
          stageId: await stageOf(user.id, 'Wishlist'),
        ),
      ]);
      expect(response.statusCode, 204, reason: response.body);
      return id;
    }

    Map<String, Object?> putPhoto(String id, String unitId, String fileId) => {
      'op': 'PUT',
      'type': 'photos',
      'id': id,
      'data': {'unit_id': unitId, 'file_id': fileId},
    };

    /// Adds a Photo row on [unitId] for a new file and uploads [jpeg] as that file; returns the file id.
    Future<String> addPhoto(
      ({String token, String id}) user,
      String unitId,
    ) async {
      final fileId = await newId();
      final row = await upload(user.token, [
        putPhoto(await newId(), unitId, fileId),
      ]);
      expect(row.statusCode, 204, reason: row.body);
      final put = await http.put(
        file(fileId),
        headers: auth(user.token),
        body: jpeg,
      );
      expect(put.statusCode, 204, reason: put.body);
      return fileId;
    }

    test('are uploaded and downloaded by their owner, with a token', () async {
      final user = await signUp();
      final fileId = await addPhoto(user, await addUnit(user));

      final got = await http.get(file(fileId), headers: auth(user.token));
      expect(got.statusCode, 200);
      expect(got.headers['content-type'], 'image/jpeg');
      expect(got.bodyBytes, jpeg);
      expect((await http.get(file(fileId))).statusCode, 401);
    });

    test(
      'are not uploaded before a Photo row of the user points at them',
      () async {
        final user = await signUp();
        final put = await http.put(
          file(await newId()),
          headers: auth(user.token),
          body: jpeg,
        );
        expect(put.statusCode, 409);
      },
    );

    test(
      'are not served to, deleted by or overwritten by another user',
      () async {
        final alice = await signUp();
        final bob = await signUp();
        final unitId = await addUnit(alice);
        final fileId = await addPhoto(alice, unitId);

        expect(
          (await http.get(file(fileId), headers: auth(bob.token))).statusCode,
          404,
        );
        expect(
          (await http.delete(
            file(fileId),
            headers: auth(bob.token),
          )).statusCode,
          404,
        );
        // Bob's own row can't point at Alice's Unit, and without one he can't upload.
        expect(
          (await upload(bob.token, [
            putPhoto(await newId(), unitId, fileId),
          ])).statusCode,
          403,
        );
        expect(
          (await http.put(
            file(fileId),
            headers: auth(bob.token),
            body: [0xff, 0xd8, 0xff, 0],
          )).statusCode,
          409,
        );
        final got = await http.get(file(fileId), headers: auth(alice.token));
        expect(got.bodyBytes, jpeg);
      },
    );

    test('reject files that are not images, too large, or not of their declared type', () async {
      final user = await signUp();
      final unitId = await addUnit(user);
      final fileId = await newId();
      expect(
        (await upload(user.token, [
          putPhoto(await newId(), unitId, fileId),
        ])).statusCode,
        204,
      );

      for (final (reason, type, body, status) in [
        ('a script', 'image/jpeg', utf8.encode('#!/bin/sh\necho hi'), 415),
        ('PNG bytes declared JPEG', 'image/jpeg', png, 415),
        ('JPEG bytes declared HTML', 'text/html', jpeg, 415),
        (
          'over 10 MiB',
          'image/jpeg',
          [...jpeg, ...List.filled(10 << 20, 0)],
          413,
        ),
      ]) {
        final put = await http.put(
          file(fileId),
          headers: auth(user.token, type),
          body: body,
        );
        expect(put.statusCode, status, reason: reason);
      }
      expect(
        (await http.get(file(fileId), headers: auth(user.token))).statusCode,
        404,
      );
      final pngPut = await http.put(
        file(fileId),
        headers: auth(user.token, 'image/png'),
        body: png,
      );
      expect(pngPut.statusCode, 204);
    });

    test(
      'reject ids that are not UUIDs, so no path leaves the photo directory',
      () async {
        final user = await signUp();
        for (final id in [
          '..%2F..%2Fetc%2Fpasswd',
          '..%2F${user.id}',
          '%2E%2E',
          'ABCDEF00-0000-4000-8000-000000000000',
          '${await newId()}.jpg',
        ]) {
          final url = Uri.parse('http://localhost:8000/photos/$id');
          final get = await http.get(url, headers: auth(user.token));
          final put = await http.put(
            url,
            headers: auth(user.token),
            body: jpeg,
          );
          final delete = await http.delete(url, headers: auth(user.token));
          expect(
            [get.statusCode, put.statusCode, delete.statusCode],
            everyElement(anyOf(400, 404)),
            reason: id,
          );
        }
        // A Photo row's file id must be a UUID too.
        final row = await upload(user.token, [
          putPhoto(await newId(), await addUnit(user), '../../etc/passwd'),
        ]);
        expect(row.statusCode, 422, reason: row.body);
      },
    );

    test('a file shared by two Photos survives deleting one, and is deleted with the last', () async {
      final user = await signUp();
      final unitId = await addUnit(user);
      final splitId = await addUnit(user);
      final fileId = await addPhoto(user, unitId);
      // A Split copies the Photo: a second row pointing at the same file.
      final copyId = await newId();
      expect(
        (await upload(user.token, [
          putPhoto(copyId, splitId, fileId),
        ])).statusCode,
        204,
      );
      Future<int> download() async =>
          (await http.get(file(fileId), headers: auth(user.token))).statusCode;

      final original =
          (await db.execute(
                r'SELECT id::text FROM photos WHERE unit_id = $1::uuid',
                parameters: [unitId],
              )).single.single
              as String;
      expect(
        (await upload(user.token, [
          {'op': 'DELETE', 'type': 'photos', 'id': original},
        ])).statusCode,
        204,
      );
      expect(await download(), 200);
      expect(
        (await http.delete(file(fileId), headers: auth(user.token))).statusCode,
        409,
        reason: 'a Photo still points at the file',
      );

      // As the app deletes a Unit: its Photos, then the Unit.
      expect(
        (await upload(user.token, [
          {'op': 'DELETE', 'type': 'photos', 'id': copyId},
          {'op': 'DELETE', 'type': 'units', 'id': splitId},
        ])).statusCode,
        204,
      );
      expect(await download(), 404);
    });

    test(
      'are deleted with their Unit, even if only the Unit delete arrives',
      () async {
        final user = await signUp();
        final unitId = await addUnit(user);
        final fileId = await addPhoto(user, unitId);
        expect(
          (await upload(user.token, [
            {'op': 'DELETE', 'type': 'units', 'id': unitId},
          ])).statusCode,
          204,
        );
        expect(
          (await http.get(file(fileId), headers: auth(user.token))).statusCode,
          404,
        );
      },
    );

    test('are at most ten per Unit, and never edited', () async {
      final user = await signUp();
      final unitId = await addUnit(user);
      final ops = [
        for (var i = 0; i < 10; i++)
          putPhoto(await newId(), unitId, await newId()),
      ];
      expect((await upload(user.token, ops)).statusCode, 204);

      final eleventh = await upload(user.token, [
        putPhoto(await newId(), unitId, await newId()),
      ]);
      expect(eleventh.statusCode, 422, reason: eleventh.body);
      final edit = await upload(user.token, [
        {
          'op': 'PATCH',
          'type': 'photos',
          'id': ops.first['id'],
          'data': {'file_id': await newId()},
        },
      ]);
      expect(edit.statusCode, 422, reason: edit.body);
      final count = await db.execute(
        r'SELECT count(*) FROM photos WHERE unit_id = $1::uuid',
        parameters: [unitId],
      );
      expect(count.single.single, 10);
    });
  });
}

/// A user with a Collection holding two Units, and a second Workflow with three Stages.
typedef _Switch = ({
  ({String token, String id}) user,
  String collectionId,
  List<String> units,
  String workflowId,
  List<String> stages,
});
