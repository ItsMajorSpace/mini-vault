import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

  Map<String, Object?> putBatch(
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

  /// Puts Tag [name] on Batch [batchId], with the id the app gives it.
  Map<String, Object?> putTag(String batchId, String name) => {
    'op': 'PUT',
    'type': 'unit_tags',
    'id': tagId(batchId, name),
    'data': {'unit_id': batchId, 'name': name},
  };

  Future<List<List<Object?>>> batch(String id) async => [
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

  test('/health answers 200 while Postgres is up', () async {
    final response = await http.get(_upload.resolve('/health'));
    expect(response.statusCode, 200);
  });

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
        r'SELECT name, colour FROM stages WHERE owner_id = $1::uuid ORDER BY position',
        parameters: [user.id],
      );
      expect(stages.map((r) => r.first), Vault.starterStageNames);
      expect(stages.map((r) => r.last), Vault.stageColours.take(7));
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
    'a Collection\'s Game System is stored trimmed, and blank clears it',
    () async {
      final user = await signUp();
      final id = await newId();
      Future<Object?> gameSystem() async => (await db.execute(
        r'SELECT game_system FROM collections WHERE id = $1::uuid',
        parameters: [id],
      )).single.single;

      final created = await upload(user.token, [
        {
          'op': 'PUT',
          'type': 'collections',
          'id': id,
          'data': {
            'name': 'Space Marines',
            'workflow_id': await workflowOf(user.id),
            'game_system': ' Warhammer 40k ',
          },
        },
      ]);
      expect(created.statusCode, 204, reason: created.body);
      expect(await gameSystem(), 'Warhammer 40k');

      for (final cleared in ['  ', null]) {
        await upload(user.token, [
          {
            'op': 'PATCH',
            'type': 'collections',
            'id': id,
            'data': {'game_system': 'D&D'},
          },
        ]);
        expect(await gameSystem(), 'D&D');
        final patched = await upload(user.token, [
          {
            'op': 'PATCH',
            'type': 'collections',
            'id': id,
            'data': {'game_system': cleared},
          },
        ]);
        expect(patched.statusCode, 204, reason: patched.body);
        expect(await gameSystem(), isNull);
      }
    },
  );

  test('a Paint is stored trimmed, toggled owned per field, never blank, and deleted', () async {
    final user = await signUp();
    final id = await newId();
    Future<List<List<Object?>>> paint() async => [
      for (final row in await db.execute(
        r'SELECT owner_id::text, brand, range, name, owned FROM paints WHERE id = $1::uuid',
        parameters: [id],
      ))
        row.toList(),
    ];

    final created = await upload(user.token, [
      {
        'op': 'PUT',
        'type': 'paints',
        'id': id,
        'data': {
          'brand': ' Citadel ',
          'range': 'Base ',
          'name': ' Macragge Blue',
          'owned': 1,
        },
      },
    ]);
    expect(created.statusCode, 204, reason: created.body);
    final toggled = await upload(user.token, [
      {
        'op': 'PATCH',
        'type': 'paints',
        'id': id,
        'data': {'owned': 0},
      },
    ]);
    expect(toggled.statusCode, 204, reason: toggled.body);
    expect(await paint(), [
      [user.id, 'Citadel', 'Base', 'Macragge Blue', 0],
    ]);

    for (final column in ['brand', 'range', 'name']) {
      final blank = await upload(user.token, [
        {
          'op': 'PATCH',
          'type': 'paints',
          'id': id,
          'data': {column: '  '},
        },
      ]);
      expect(blank.statusCode, 422, reason: column);
    }
    final notABool = await upload(user.token, [
      {
        'op': 'PATCH',
        'type': 'paints',
        'id': id,
        'data': {'owned': 2},
      },
    ]);
    expect(notABool.statusCode, 422, reason: notABool.body);

    await upload(user.token, [
      {'op': 'DELETE', 'type': 'paints', 'id': id},
    ]);
    expect(await paint(), isEmpty);
  });

  test("a Unit's Paint is stored by Collection and name, only on the user's own rows, and goes with its Collection or Paint", () async {
    final alice = await signUp();
    final bob = await signUp();
    Future<String> putPaint(({String token, String id}) user) async {
      final id = await newId();
      final response = await upload(user.token, [
        {
          'op': 'PUT',
          'type': 'paints',
          'id': id,
          'data': {
            'brand': 'Citadel',
            'range': 'Base',
            'name': 'Macragge Blue',
            'owned': 1,
          },
        },
      ]);
      expect(response.statusCode, 204, reason: response.body);
      return id;
    }

    Map<String, Object?> putLink(
      String id,
      String collectionId,
      String paintId,
    ) => {
      'op': 'PUT',
      'type': 'squad_paints',
      'id': id,
      'data': {
        'collection_id': collectionId,
        'squad_name': ' Intercessors ',
        'paint_id': paintId,
        'note': 'armour',
      },
    };
    Future<List<List<Object?>>> links() async => [
      for (final row in await db.execute(
        r'SELECT owner_id::text, squad_name, note FROM squad_paints WHERE owner_id = ANY($1::uuid[]) ORDER BY note',
        parameters: [
          TypedValue(Type.textArray, [alice.id, bob.id]),
        ],
      ))
        row.toList(),
    ];

    final collectionId = await createCollection(alice);
    final paintId = await putPaint(alice);
    final otherPaintId = await putPaint(alice);
    final id = await newId();
    final created = await upload(alice.token, [
      putLink(id, collectionId, paintId),
      putLink(await newId(), collectionId, otherPaintId),
    ]);
    expect(created.statusCode, 204, reason: created.body);
    final renamed = await upload(alice.token, [
      {
        'op': 'PATCH',
        'type': 'squad_paints',
        'id': id,
        'data': {'squad_name': 'Hellblasters', 'note': 'base'},
      },
    ]);
    expect(renamed.statusCode, 204, reason: renamed.body);
    expect(await links(), [
      [alice.id, 'Intercessors', 'armour'],
      [alice.id, 'Hellblasters', 'base'],
    ]);

    final blank = await upload(alice.token, [
      {
        'op': 'PATCH',
        'type': 'squad_paints',
        'id': id,
        'data': {'squad_name': ' '},
      },
    ]);
    expect(blank.statusCode, 422, reason: blank.body);

    // Bob can't link to Alice's Collection or Paint, nor touch her link.
    final bobCollection = await createCollection(bob);
    final bobPaint = await putPaint(bob);
    for (final op in [
      putLink(await newId(), collectionId, bobPaint),
      putLink(await newId(), bobCollection, paintId),
      {'op': 'DELETE', 'type': 'squad_paints', 'id': id},
    ]) {
      final response = await upload(bob.token, [op]);
      expect(response.statusCode, 403, reason: response.body);
    }

    await upload(alice.token, [
      {'op': 'DELETE', 'type': 'paints', 'id': otherPaintId},
    ]);
    expect(await links(), [
      [alice.id, 'Hellblasters', 'base'],
    ]);
    await upload(alice.token, [
      {'op': 'DELETE', 'type': 'collections', 'id': collectionId},
    ]);
    expect(await links(), isEmpty);
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

  test('a Batch is created at a Stage, edited per field and deleted', () async {
    final user = await signUp();
    final collectionId = await createCollection(user);
    final id = await newId();

    final created = await upload(user.token, [
      putBatch(
        id,
        collectionId: collectionId,
        stageId: await stageOf(user.id, 'Primed'),
      ),
    ]);
    expect(created.statusCode, 204, reason: created.body);
    expect(await batch(id), [
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
    expect(await batch(id), [
      [user.id, 'Intercessors', 5, 'Jump packs', 'Primed'],
    ]);

    final deleted = await upload(user.token, [
      {'op': 'DELETE', 'type': 'units', 'id': id},
    ]);
    expect(deleted.statusCode, 204, reason: deleted.body);
    expect(await batch(id), isEmpty);
  });

  test(
    'a Stage holding Batches cannot be deleted until they are gone',
    () async {
      final user = await signUp();
      final collectionId = await createCollection(user);
      final primed = await stageOf(user.id, 'Primed');
      final id = await newId();
      expect(
        (await upload(user.token, [
          putBatch(id, collectionId: collectionId, stageId: primed),
        ])).statusCode,
        204,
      );

      final blocked = await upload(user.token, [
        {'op': 'DELETE', 'type': 'stages', 'id': primed},
      ]);
      expect(blocked.statusCode, 409, reason: blocked.body);
      expect(await batch(id), isNotEmpty);

      final deleted = await upload(user.token, [
        {'op': 'DELETE', 'type': 'units', 'id': id},
        {'op': 'DELETE', 'type': 'stages', 'id': primed},
      ]);
      expect(deleted.statusCode, 204, reason: deleted.body);
    },
  );

  test('a Batch must have at least one model', () async {
    final user = await signUp();
    final collectionId = await createCollection(user);
    final stageId = await stageOf(user.id, 'Wishlist');
    final id = await newId();
    await upload(user.token, [
      putBatch(id, collectionId: collectionId, stageId: stageId),
    ]);

    final created = await upload(user.token, [
      putBatch(
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
    expect((await batch(id)).single[2], 10);
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
          putBatch(
            await newId(),
            collectionId: aliceCollection,
            stageId: bobStage,
          ),
        ),
        "a Unit at another user's Stage": (
          403,
          putBatch(
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
          putBatch(
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

      final batches = await db.execute(
        r'SELECT count(*) FROM units WHERE owner_id IN ($1::uuid, $2::uuid)',
        parameters: [alice.id, bob.id],
      );
      expect(batches.single.first, 0);
    },
  );

  test("a Batch's Stage must be in its Collection's Workflow", () async {
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
      r'''INSERT INTO stages (id, owner_id, workflow_id, name, position, colour)
        VALUES ($2::uuid, $3::uuid, $1::uuid, 'Elsewhere', 0, '#FF7B7B')''',
      parameters: [otherWorkflow, otherStage, user.id],
    );
    final id = await newId();

    final created = await upload(user.token, [
      putBatch(await newId(), collectionId: collectionId, stageId: otherStage),
    ]);
    await upload(user.token, [
      putBatch(
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
    expect((await batch(id)).single.last, 'Wishlist');
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
    /// Creates a Batch for [user] through the API and returns its id.
    Future<String> createBatch(({String token, String id}) user) async {
      final id = await newId();
      final response = await upload(user.token, [
        putBatch(
          id,
          collectionId: await createCollection(user),
          stageId: await stageOf(user.id, 'Primed'),
        ),
      ]);
      expect(response.statusCode, 204, reason: response.body);
      return id;
    }

    Future<List<List<Object?>>> tagsOf(String batchId) async => [
      for (final row in await db.execute(
        r'SELECT owner_id::text, name FROM unit_tags WHERE unit_id = $1::uuid ORDER BY name',
        parameters: [batchId],
      ))
        row.toList(),
    ];

    test('are added and removed, and deleted with their Batch', () async {
      final user = await signUp();
      final batchId = await createBatch(user);

      final added = await upload(user.token, [
        putTag(batchId, ' Necrons '),
        putTag(batchId, 'Warhammer 40k'),
      ]);
      expect(added.statusCode, 204, reason: added.body);
      expect(await tagsOf(batchId), [
        [user.id, 'Necrons'],
        [user.id, 'Warhammer 40k'],
      ]);

      final removed = await upload(user.token, [
        {'op': 'DELETE', 'type': 'unit_tags', 'id': tagId(batchId, 'necrons')},
      ]);
      expect(removed.statusCode, 204, reason: removed.body);
      expect(await tagsOf(batchId), [
        [user.id, 'Warhammer 40k'],
      ]);

      // An older app could delete the Batch without its Tags: the server deletes them anyway.
      final deleted = await upload(user.token, [
        {'op': 'DELETE', 'type': 'units', 'id': batchId},
      ]);
      expect(deleted.statusCode, 204, reason: deleted.body);
      expect(await tagsOf(batchId), isEmpty);
    });

    test("cannot be put on another user's Batch", () async {
      final alice = await signUp();
      final bob = await signUp();
      final batchId = await createBatch(alice);

      final response = await upload(bob.token, [putTag(batchId, 'Necrons')]);
      expect(response.statusCode, 403, reason: response.body);
      expect(await tagsOf(batchId), isEmpty);
    });

    test('added again from a second device keeps one row and its first casing, and the batch goes through', () async {
      final user = await signUp();
      final batchId = await createBatch(user);
      expect(
        (await upload(user.token, [putTag(batchId, 'Necrons')])).statusCode,
        204,
      );

      // The second device tagged the same Batch offline, in the same batch as an edit.
      final second = await upload(user.token, [
        putTag(batchId, 'necrons'),
        {
          'op': 'PATCH',
          'type': 'units',
          'id': batchId,
          'data': {'notes': 'Dynasty colours'},
        },
      ]);
      expect(second.statusCode, 204, reason: second.body);
      expect(await tagsOf(batchId), [
        [user.id, 'Necrons'],
      ]);
      expect((await batch(batchId)).single[3], 'Dynasty colours');
    });

    test(
      'must have the id of their Batch and name, and are never edited',
      () async {
        final user = await signUp();
        final batchId = await createBatch(user);
        final wrongId = {...putTag(batchId, 'Necrons'), 'id': await newId()};

        expect((await upload(user.token, [wrongId])).statusCode, 422);
        expect(
          (await upload(user.token, [putTag(batchId, 'Necrons')])).statusCode,
          204,
        );
        final edit = await upload(user.token, [
          {
            'op': 'PATCH',
            'type': 'unit_tags',
            'id': tagId(batchId, 'Necrons'),
            'data': {'name': 'Orks'},
          },
        ]);
        expect(edit.statusCode, 422);
        expect(await tagsOf(batchId), [
          [user.id, 'Necrons'],
        ]);
      },
    );
  });

  test('PowerSync sends each user only their own rows', () async {
    final alice = await signUp();
    final bob = await signUp();
    final id = await createCollection(alice);
    final batchId = await newId();
    final stageChangeId = await newId();
    final wishlist = await stageOf(alice.id, 'Wishlist');
    final tag = putTag(batchId, 'Necrons');
    final photoId = await newId();
    final paintId = await newId();
    final unitPaintId = await newId();
    final uploaded = await upload(alice.token, [
      putBatch(batchId, collectionId: id, stageId: wishlist),
      {
        'op': 'PUT',
        'type': 'stage_changes',
        'id': stageChangeId,
        'data': {
          'unit_id': batchId,
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
        'data': {'unit_id': batchId, 'file_id': await newId()},
      },
      {
        'op': 'PUT',
        'type': 'paints',
        'id': paintId,
        'data': {
          'brand': 'Citadel',
          'range': 'Base',
          'name': 'Macragge Blue',
          'owned': 1,
        },
      },
      {
        'op': 'PUT',
        'type': 'squad_paints',
        'id': unitPaintId,
        'data': {
          'collection_id': id,
          'squad_name': 'Intercessors',
          'paint_id': paintId,
          'note': '',
        },
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
      containsAll([
        id,
        batchId,
        stageChangeId,
        tag['id'],
        photoId,
        paintId,
        unitPaintId,
      ]),
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
        'data': {
          'workflow_id': id,
          'name': 'Stage $i',
          'position': i,
          'colour': Vault.stageColours[i],
        },
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
    'a Stage colour is set per field; one not #RRGGBB is rejected',
    () async {
      final user = await signUp();
      final primed = await stageOf(user.id, 'Primed');
      Future<Object?> colour() async => (await db.execute(
        r'SELECT colour FROM stages WHERE id = $1::uuid',
        parameters: [primed],
      )).single.first;
      Map<String, Object?> patch(Object? colour) => {
        'op': 'PATCH',
        'type': 'stages',
        'id': primed,
        'data': {'colour': colour},
      };

      final set = await upload(user.token, [patch('#12AB9F')]);
      expect(set.statusCode, 204, reason: set.body);
      expect(await colour(), '#12AB9F');

      for (final bad in [
        '#12ab9f',
        '12AB9F',
        '#12AB9',
        '#12AB9F00',
        'red',
        '',
        null,
        42,
      ]) {
        final response = await upload(user.token, [patch(bad)]);
        expect(response.statusCode, 422, reason: '$bad: ${response.body}');
      }
      final missing = await upload(user.token, [
        {
          'op': 'PUT',
          'type': 'stages',
          'id': await newId(),
          'data': {
            'workflow_id': await workflowOf(user.id),
            'name': 'Uncoloured',
            'position': 9,
          },
        },
      ]);
      expect(missing.statusCode, 422, reason: missing.body);
      expect(await colour(), '#12AB9F');
    },
  );

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
      required String batchId,
      String? fromStageId,
      required String toStageId,
      required String happenedAt,
    }) => {
      'op': 'PUT',
      'type': 'stage_changes',
      'id': id,
      'data': {
        'unit_id': batchId,
        'from_stage_id': fromStageId,
        'to_stage_id': toStageId,
        'model_count': 10,
        'happened_at': happenedAt,
      },
    };

    /// The Batch's history as to-Stage names, oldest first.
    Future<List<Object?>> history(String batchId) async => [
      for (final row in await db.execute(
        r'''SELECT s.name FROM stage_changes sc JOIN stages s ON s.id = sc.to_stage_id
          WHERE sc.unit_id = $1::uuid ORDER BY sc.happened_at, sc.id''',
        parameters: [batchId],
      ))
        row.first,
    ];

    /// A user with a Batch created at Wishlist, as the app uploads it: the Batch, then its initial Stage Change.
    Future<({String token, String id, String batchId})> userWithBatch() async {
      final user = await signUp();
      final collectionId = await createCollection(user);
      final wishlist = await stageOf(user.id, 'Wishlist');
      final batchId = await newId();
      final created = await upload(user.token, [
        putBatch(batchId, collectionId: collectionId, stageId: wishlist),
        putStageChange(
          await newId(),
          batchId: batchId,
          toStageId: wishlist,
          happenedAt: '2026-11-13T09:00:00.000Z',
        ),
      ]);
      expect(created.statusCode, 204, reason: created.body);
      return (token: user.token, id: user.id, batchId: batchId);
    }

    test('two offline moves uploaded out of order are both kept, and the later one by device timestamp is current', () async {
      final user = await userWithBatch();
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
            'id': user.batchId,
            'data': {'stage_id': stageId},
          },
          putStageChange(
            await newId(),
            batchId: user.batchId,
            fromStageId: wishlist,
            toStageId: stageId,
            happenedAt: at,
          ),
        ]);
        expect(response.statusCode, 204, reason: response.body);
      }

      expect(await history(user.batchId), ['Wishlist', 'Primed', 'Painted']);
      expect((await batch(user.batchId)).single.last, 'Painted');
    });

    test(
      'cannot be edited or deleted; deleting the Batch removes them',
      () async {
        final user = await userWithBatch();
        final id = await newId();
        final primed = await stageOf(user.id, 'Primed');
        final move = putStageChange(
          id,
          batchId: user.batchId,
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
            batchId: user.batchId,
            toStageId: await stageOf(user.id, 'Done'),
            happenedAt: '2026-11-14T10:00:00.000Z',
          ),
        ]);
        expect(retried.statusCode, 204, reason: retried.body);
        expect(await history(user.batchId), ['Wishlist', 'Primed']);
        expect((await batch(user.batchId)).single.last, 'Primed');

        final deleted = await upload(user.token, [
          {'op': 'DELETE', 'type': 'units', 'id': user.batchId},
        ]);
        expect(deleted.statusCode, 204, reason: deleted.body);
        expect(await history(user.batchId), isEmpty);
      },
    );

    test("cannot point at another user's Batch or Stage", () async {
      final alice = await userWithBatch();
      final bob = await userWithBatch();
      final aliceStage = await stageOf(alice.id, 'Primed');
      final bobStage = await stageOf(bob.id, 'Primed');

      for (final (reason, op) in [
        (
          "another user's Unit",
          putStageChange(
            await newId(),
            batchId: alice.batchId,
            toStageId: bobStage,
            happenedAt: '2026-11-13T10:00:00.000Z',
          ),
        ),
        (
          "another user's to-Stage",
          putStageChange(
            await newId(),
            batchId: bob.batchId,
            toStageId: aliceStage,
            happenedAt: '2026-11-13T10:00:00.000Z',
          ),
        ),
        (
          "another user's from-Stage",
          putStageChange(
            await newId(),
            batchId: bob.batchId,
            fromStageId: aliceStage,
            toStageId: bobStage,
            happenedAt: '2026-11-13T10:00:00.000Z',
          ),
        ),
      ]) {
        final response = await upload(bob.token, [op]);
        expect(response.statusCode, 403, reason: reason);
      }

      expect(await history(alice.batchId), ['Wishlist']);
      expect(await history(bob.batchId), ['Wishlist']);
      expect((await batch(alice.batchId)).single.last, 'Wishlist');
    });

    /// A Batch created at [stageId] in [collectionId], as the app uploads it.
    Future<String> createBatchAt(
      ({String token, String id}) user,
      String collectionId,
      String stageId,
    ) async {
      final batchId = await newId();
      final created = await upload(user.token, [
        putBatch(batchId, collectionId: collectionId, stageId: stageId),
        putStageChange(
          await newId(),
          batchId: batchId,
          toStageId: stageId,
          happenedAt: '2026-11-13T09:00:00.000Z',
        ),
      ]);
      expect(created.statusCode, 204, reason: created.body);
      return batchId;
    }

    /// One Batch move as the app uploads it: the Batch's stage_id, then the Stage Change.
    Future<List<Map<String, Object?>>> move(
      String batchId,
      String from,
      String to,
    ) async => [
      {
        'op': 'PATCH',
        'type': 'units',
        'id': batchId,
        'data': {'stage_id': to},
      },
      putStageChange(
        await newId(),
        batchId: batchId,
        fromStageId: from,
        toStageId: to,
        happenedAt: '2026-11-13T10:00:00.000Z',
      ),
    ];

    test('deleting a Stage that holds Batches: the app\'s batch of moves, new Owned Stage and delete is accepted', () async {
      final user = await signUp();
      final unassembled = await stageOf(user.id, 'Unassembled');
      final assembled = await stageOf(user.id, 'Assembled');
      final batches = [
        await createBatchAt(user, await createCollection(user), unassembled),
        await createBatchAt(user, await createCollection(user), unassembled),
      ];

      final response = await upload(user.token, [
        for (final u in batches) ...await move(u, unassembled, assembled),
        {
          'op': 'PATCH',
          'type': 'workflows',
          'id': await workflowOf(user.id),
          'data': {'owned_stage_id': assembled},
        },
        {'op': 'DELETE', 'type': 'stages', 'id': unassembled},
      ]);

      expect(response.statusCode, 204, reason: response.body);
      for (final u in batches) {
        expect((await batch(u)).single.last, 'Assembled');
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

    test('deleting a Stage is still refused (409) when another device moved a Batch into it meanwhile', () async {
      final user = await signUp();
      final collectionId = await createCollection(user);
      final wishlist = await stageOf(user.id, 'Wishlist');
      final primed = await stageOf(user.id, 'Primed');
      final assembled = await stageOf(user.id, 'Assembled');
      final known = await createBatchAt(user, collectionId, primed);
      final other = await createBatchAt(user, collectionId, wishlist);

      // Device B moves the other Batch into Primed while device A is offline, deleting Primed and moving the Batch it knows.
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
      expect((await batch(known)).single.last, 'Primed');
      expect((await batch(other)).single.last, 'Primed');
    });

    test(
      "a move to a Stage outside the Collection's Workflow is rejected",
      () async {
        final user = await userWithBatch();
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
            batchId: user.batchId,
            toStageId: otherStages.first,
            happenedAt: '2026-11-13T10:00:00.000Z',
          ),
        ]);

        expect(response.statusCode, 422, reason: response.body);
        expect(await history(user.batchId), ['Wishlist']);
        expect((await batch(user.batchId)).single.last, 'Wishlist');
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

      /// A user with a Collection holding a Batch at Wishlist and one at Primed, and a second Workflow.
      Future<_Switch> setUpSwitch() async {
        final user = await signUp();
        final collectionId = await createCollection(user);
        final batches = [
          await createBatchAt(
            user,
            collectionId,
            await stageOf(user.id, 'Wishlist'),
          ),
          await createBatchAt(
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
          batches: batches,
          workflowId: workflowId,
          stages: stages,
        );
      }

      /// The app's batch: each Batch's move (Batch stage_id, then Stage Change), then the Collection's workflow_id.
      Future<List<Map<String, Object?>>> appBatch(_Switch s) async => [
        ...await move(
          s.batches[0],
          await stageOf(s.user.id, 'Wishlist'),
          s.stages[0],
        ),
        ...await move(
          s.batches[1],
          await stageOf(s.user.id, 'Primed'),
          s.stages[2],
        ),
        switchTo(s.collectionId, s.workflowId),
      ];

      test("the app's batch is accepted and leaves every Batch at a Stage of the new Workflow", () async {
        final s = await setUpSwitch();

        final response = await upload(s.user.token, await appBatch(s));

        expect(response.statusCode, 204, reason: response.body);
        expect(await workflowOfCollection(s.collectionId), s.workflowId);
        expect((await batch(s.batches[0])).single.last, 'Stage 0');
        expect((await batch(s.batches[1])).single.last, 'Stage 2');
        expect(await history(s.batches[1]), ['Primed', 'Stage 2']);
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

      test('switching without moving every Batch is rejected', () async {
        final s = await setUpSwitch();

        final response = await upload(s.user.token, [
          ...(await appBatch(s)).skip(2), // The first Batch's move left out.
        ]);

        expect(response.statusCode, 422, reason: response.body);
        expect(
          await workflowOfCollection(s.collectionId),
          await workflowOf(s.user.id),
        );
        expect((await batch(s.batches[1])).single.last, 'Primed');
      });

      test('the batch is rejected as a whole when another device added a Batch to the Collection meanwhile', () async {
        final s = await setUpSwitch();
        final ops = await appBatch(s); // Made offline, before the add.
        final added = await createBatchAt(
          s.user,
          s.collectionId,
          await stageOf(s.user.id, 'Painted'),
        );

        final response = await upload(s.user.token, ops);

        expect(response.statusCode, 422, reason: response.body);
        expect(
          await workflowOfCollection(s.collectionId),
          await workflowOf(s.user.id),
        );
        expect((await batch(s.batches[0])).single.last, 'Wishlist');
        expect((await batch(added)).single.last, 'Painted');
        expect(await history(s.batches[0]), ['Wishlist']);
      });

      test('the batch is rejected as a whole when another device moved a Batch later than the switch', () async {
        final s = await setUpSwitch();
        final ops = await appBatch(s); // Its moves are stamped 10:00.
        final moved = await upload(s.user.token, [
          putStageChange(
            await newId(),
            batchId: s.batches[1],
            fromStageId: await stageOf(s.user.id, 'Primed'),
            toStageId: await stageOf(s.user.id, 'Done'),
            happenedAt: '2026-11-13T11:00:00.000Z',
          ),
        ]);
        expect(moved.statusCode, 204, reason: moved.body);

        final response = await upload(s.user.token, ops);

        expect(response.statusCode, 422, reason: response.body);
        expect(
          await workflowOfCollection(s.collectionId),
          await workflowOf(s.user.id),
        );
        expect((await batch(s.batches[1])).single.last, 'Done');
        expect(await history(s.batches[1]), ['Primed', 'Done']);
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
              s.batches[0],
              await stageOf(s.user.id, 'Wishlist'),
              await stageOf(s.user.id, 'Done'),
            ),
          );

          expect(response.statusCode, 422, reason: response.body);
          expect((await batch(s.batches[0])).single.last, 'Stage 0');
        },
      );
    });
  });

  /// A fake JPEG: the write API checks the magic number, not the whole image.
  final jpeg = [0xff, 0xd8, 0xff, 0xe0, ...List.filled(100, 7)];
  const png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0];

  Uri file(String id) => _upload.resolve('/photos/$id');
  Map<String, String> auth(String token, [String type = 'image/jpeg']) => {
    'authorization': 'Bearer $token',
    'content-type': type,
  };

  Future<String> addBatch(({String token, String id}) user) async {
    final id = await newId();
    final response = await upload(user.token, [
      putBatch(
        id,
        collectionId: await createCollection(user),
        stageId: await stageOf(user.id, 'Wishlist'),
      ),
    ]);
    expect(response.statusCode, 204, reason: response.body);
    return id;
  }

  Map<String, Object?> putPhoto(String id, String batchId, String fileId) => {
    'op': 'PUT',
    'type': 'photos',
    'id': id,
    'data': {'unit_id': batchId, 'file_id': fileId},
  };

  /// Adds a Photo row on [batchId] for a new file and uploads [jpeg] as that file; returns the file id.
  Future<String> addPhoto(
    ({String token, String id}) user,
    String batchId,
  ) async {
    final fileId = await newId();
    final row = await upload(user.token, [
      putPhoto(await newId(), batchId, fileId),
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

  group('Photos', () {
    test('are uploaded and downloaded by their owner, with a token', () async {
      final user = await signUp();
      final fileId = await addPhoto(user, await addBatch(user));

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
        final batchId = await addBatch(alice);
        final fileId = await addPhoto(alice, batchId);

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
        // Bob's own row can't point at Alice's Batch, and without one he can't upload.
        expect(
          (await upload(bob.token, [
            putPhoto(await newId(), batchId, fileId),
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
      final batchId = await addBatch(user);
      final fileId = await newId();
      expect(
        (await upload(user.token, [
          putPhoto(await newId(), batchId, fileId),
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
          putPhoto(await newId(), await addBatch(user), '../../etc/passwd'),
        ]);
        expect(row.statusCode, 422, reason: row.body);
      },
    );

    test('a file shared by two Photos survives deleting one, and is deleted with the last', () async {
      final user = await signUp();
      final batchId = await addBatch(user);
      final splitId = await addBatch(user);
      final fileId = await addPhoto(user, batchId);
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
                parameters: [batchId],
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

      // As the app deletes a Batch: its Photos, then the Batch.
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
      'are deleted with their Batch, even if only the Batch delete arrives',
      () async {
        final user = await signUp();
        final batchId = await addBatch(user);
        final fileId = await addPhoto(user, batchId);
        expect(
          (await upload(user.token, [
            {'op': 'DELETE', 'type': 'units', 'id': batchId},
          ])).statusCode,
          204,
        );
        expect(
          (await http.get(file(fileId), headers: auth(user.token))).statusCode,
          404,
        );
      },
    );

    test('are at most ten per Batch, and never edited', () async {
      final user = await signUp();
      final batchId = await addBatch(user);
      final ops = [
        for (var i = 0; i < 10; i++)
          putPhoto(await newId(), batchId, await newId()),
      ];
      expect((await upload(user.token, ops)).statusCode, 204);

      final eleventh = await upload(user.token, [
        putPhoto(await newId(), batchId, await newId()),
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
        parameters: [batchId],
      );
      expect(count.single.single, 10);
    });

    group('and a deleted Collection', () {
      /// Adds a Batch to [collectionId] with its starting Stage Change, a Tag and a Photo of a new file;
      /// returns the Batch id and the file id.
      Future<(String, String)> addFull(
        ({String token, String id}) user,
        String collectionId,
      ) async {
        final batchId = await newId();
        final stageId = await stageOf(user.id, 'Wishlist');
        final response = await upload(user.token, [
          putBatch(batchId, collectionId: collectionId, stageId: stageId),
          {
            'op': 'PUT',
            'type': 'stage_changes',
            'id': await newId(),
            'data': {
              'unit_id': batchId,
              'from_stage_id': null,
              'to_stage_id': stageId,
              'model_count': 10,
              'happened_at': DateTime.now().toUtc().toIso8601String(),
            },
          },
          putTag(batchId, 'Imperium'),
        ]);
        expect(response.statusCode, 204, reason: response.body);
        return (batchId, await addPhoto(user, batchId));
      }

      /// What the app uploads for deleting [collectionId] while it knows of [batches]: their Tags and Photos, the
      /// Batches, then the Collection.
      Future<List<Map<String, Object?>>> appDelete(
        String collectionId,
        List<String> batches,
      ) async => [
        for (final table in ['unit_tags', 'photos'])
          for (final row in await db.execute(
            'SELECT id::text FROM $table WHERE unit_id::text = ANY(\$1)',
            parameters: [TypedValue(Type.textArray, batches)],
          ))
            {'op': 'DELETE', 'type': table, 'id': row.first},
        for (final u in batches) {'op': 'DELETE', 'type': 'units', 'id': u},
        {'op': 'DELETE', 'type': 'collections', 'id': collectionId},
      ];

      /// The user's rows left of each synced table under a Collection, and Batches whose Collection is gone.
      Future<List<Object?>> leftUnder(
        String userId,
        String collectionId,
      ) async => (await db.execute(
        r'''SELECT
              (SELECT count(*) FROM collections WHERE id = $2::uuid),
              (SELECT count(*) FROM units WHERE collection_id = $2::uuid),
              (SELECT count(*) FROM stage_changes sc JOIN units u ON u.id = sc.unit_id WHERE u.collection_id = $2::uuid),
              (SELECT count(*) FROM unit_tags t JOIN units u ON u.id = t.unit_id WHERE u.collection_id = $2::uuid),
              (SELECT count(*) FROM photos p JOIN units u ON u.id = p.unit_id WHERE u.collection_id = $2::uuid),
              (SELECT count(*) FROM units u WHERE u.owner_id = $1::uuid
                AND NOT EXISTS (SELECT FROM collections c WHERE c.id = u.collection_id))''',
        parameters: [userId, collectionId],
      )).single.toList();

      Future<int> download(({String token, String id}) user, String id) async =>
          (await http.get(file(id), headers: auth(user.token))).statusCode;

      test('deletes its Batches with their rows and unreferenced files; a file shared with another Collection survives', () async {
        final user = await signUp();
        final doomed = await createCollection(user);
        final kept = await createCollection(user);
        final (a, fileA) = await addFull(user, doomed);
        final (b, fileB) = await addFull(user, doomed);
        final (c, fileC) = await addFull(user, kept);
        // A Split-style copy: a Batch in the kept Collection shares fileB.
        expect(
          (await upload(user.token, [
            putPhoto(await newId(), c, fileB),
          ])).statusCode,
          204,
        );

        final response = await upload(
          user.token,
          await appDelete(doomed, [a, b]),
        );
        expect(response.statusCode, 204, reason: response.body);

        expect(await leftUnder(user.id, doomed), [0, 0, 0, 0, 0, 0]);
        expect(await download(user, fileA), 404);
        expect(await download(user, fileB), 200);
        expect(await download(user, fileC), 200);
        expect(await leftUnder(user.id, kept), [1, 1, 1, 1, 2, 0]);
      });

      test('a Batch another device added meanwhile is deleted with it, or rejected if it arrives later', () async {
        final user = await signUp();
        final collectionId = await createCollection(user);
        final (known, _) = await addFull(user, collectionId);
        // This device deletes offline, knowing only [known]; the other device's Batch lands first.
        final deleteOps = await appDelete(collectionId, [known]);
        final (added, addedFile) = await addFull(user, collectionId);

        final response = await upload(user.token, deleteOps);
        expect(response.statusCode, 204, reason: response.body);
        expect(await leftUnder(user.id, collectionId), [0, 0, 0, 0, 0, 0]);
        expect(await batch(added), isEmpty);
        expect(await download(user, addedFile), 404);

        // The other device's Batch arriving after the delete is rejected: no orphan.
        final late = await upload(user.token, [
          putBatch(
            await newId(),
            collectionId: collectionId,
            stageId: await stageOf(user.id, 'Wishlist'),
          ),
        ]);
        expect(late.statusCode, 422, reason: late.body);
        expect(await leftUnder(user.id, collectionId), [0, 0, 0, 0, 0, 0]);
      });

      test('racing a Batch add at the same instant leaves no orphan, whichever commits first', () async {
        final user = await signUp();
        final stageId = await stageOf(user.id, 'Wishlist');
        for (var i = 0; i < 10; i++) {
          final collectionId = await createCollection(user);
          final (known, _) = await addFull(user, collectionId);
          final deleteOps = await appDelete(collectionId, [known]);
          final [deleted, added] = await Future.wait([
            upload(user.token, deleteOps),
            upload(user.token, [
              putBatch(
                await newId(),
                collectionId: collectionId,
                stageId: stageId,
              ),
            ]),
          ]);
          expect(deleted.statusCode, 204, reason: deleted.body);
          expect(added.statusCode, anyOf(204, 422), reason: added.body);
          expect(await leftUnder(user.id, collectionId), [0, 0, 0, 0, 0, 0]);
        }
      });

      test("of another user can't be deleted", () async {
        final alice = await signUp();
        final bob = await signUp();
        final collectionId = await createCollection(alice);
        final (batchId, fileId) = await addFull(alice, collectionId);

        final response = await upload(bob.token, [
          {'op': 'DELETE', 'type': 'collections', 'id': collectionId},
        ]);
        expect(response.statusCode, 403, reason: response.body);
        expect(await leftUnder(alice.id, collectionId), [1, 1, 1, 1, 1, 0]);
        expect(await batch(batchId), isNotEmpty);
        expect(await download(alice, fileId), 200);
      });
    });
  });

  group('Splits and Merges', () {
    late ({String token, String id}) user;
    late String collectionId;
    late String wishlist;
    late String primed;
    late String a;

    /// A random v4 UUID, for helpers that can't await [newId].
    String uuid() {
      final r = Random();
      String hex(int n) =>
          [for (var i = 0; i < n; i++) r.nextInt(16).toRadixString(16)].join();
      return '${hex(8)}-${hex(4)}-4${hex(3)}-a${hex(3)}-${hex(12)}';
    }

    Map<String, Object?> putStageChange(
      String batchId,
      String? from,
      String to,
      int count,
      String at,
    ) => {
      'op': 'PUT',
      'type': 'stage_changes',
      'id': uuid(),
      'data': {
        'unit_id': batchId,
        'from_stage_id': from,
        'to_stage_id': to,
        'model_count': count,
        'happened_at': at,
      },
    };

    /// The count PATCH the app uploads after a Split or Merge: its local view, which the server ignores.
    Map<String, Object?> patchCount(String batchId, int count) => {
      'op': 'PATCH',
      'type': 'units',
      'id': batchId,
      'data': {'model_count': count},
    };

    /// The app's Split batch: a new Batch at Primed with its Stage Change, the Split, then [source]'s new count.
    List<Map<String, Object?>> split(
      String source,
      String created,
      int count, {
      required int localCount,
      String? collection,
    }) => [
      putBatch(
        created,
        collectionId: collection ?? collectionId,
        stageId: primed,
        modelCount: count,
      ),
      putStageChange(created, wishlist, primed, count, '2026-11-13T10:00:00Z'),
      {
        'op': 'PUT',
        'type': 'splits',
        'id': uuid(),
        'data': {
          'unit_id': source,
          'new_unit_id': created,
          'model_count': count,
        },
      },
      patchCount(source, localCount),
    ];

    /// The app's Merge batch: the Merge, then [batchId]'s new count and the delete of [other].
    List<Map<String, Object?>> merge(
      String batchId,
      String other, {
      required int localCount,
    }) => [
      {
        'op': 'PUT',
        'type': 'merges',
        'id': uuid(),
        'data': {'unit_id': batchId, 'merged_unit_id': other},
      },
      patchCount(batchId, localCount),
      {'op': 'DELETE', 'type': 'units', 'id': other},
    ];

    Future<int?> count(String batchId) async =>
        (await batch(batchId)).map((u) => u[2] as int).firstOrNull;

    setUp(() async {
      user = await signUp();
      collectionId = await createCollection(user);
      wishlist = await stageOf(user.id, 'Wishlist');
      primed = await stageOf(user.id, 'Primed');
      a = await newId();
      final created = await upload(user.token, [
        putBatch(a, collectionId: collectionId, stageId: wishlist),
        putStageChange(a, null, wishlist, 10, '2026-11-13T09:00:00Z'),
      ]);
      expect(created.statusCode, 204, reason: created.body);
    });

    test('two concurrent offline Splits compose: 10 − 4 − 3 leaves 3, and a retry changes nothing', () async {
      final (b, c) = (await newId(), await newId());
      // Both devices saw 10 models, so each uploads its own stale count.
      final first = split(a, b, 4, localCount: 6);
      final responses = await Future.wait([
        upload(user.token, first),
        upload(user.token, split(a, c, 3, localCount: 7)),
      ]);
      for (final r in responses) {
        expect(r.statusCode, 204, reason: r.body);
      }

      expect([await count(a), await count(b), await count(c)], [3, 4, 3]);
      expect((await batch(b)).single[4], 'Primed');
      expect((await upload(user.token, first)).statusCode, 204);
      expect([await count(a), await count(b)], [3, 4]);
    });

    test('deleting a Collection takes its split and merged Batches and their records with it', () async {
      final (b, c) = (await newId(), await newId());
      for (final ops in [
        split(a, b, 4, localCount: 6),
        split(a, c, 2, localCount: 4),
        merge(b, c, localCount: 6),
      ]) {
        final r = await upload(user.token, ops);
        expect(r.statusCode, 204, reason: r.body);
      }

      final deleted = await upload(user.token, [
        {'op': 'DELETE', 'type': 'collections', 'id': collectionId},
      ]);
      expect(deleted.statusCode, 204, reason: deleted.body);
      for (final table in ['units', 'splits', 'merges', 'stage_changes']) {
        expect(
          (await db.execute(
            'SELECT count(*) FROM $table WHERE owner_id = \$1::uuid',
            parameters: [user.id],
          )).single.first,
          0,
          reason: table,
        );
      }
    });

    test('a Split that would leave fewer than 1 model is rejected, with nothing written', () async {
      final (b, c, d) = (await newId(), await newId(), await newId());
      expect(
        (await upload(user.token, split(a, b, 4, localCount: 6))).statusCode,
        204,
      );

      // Another device, still seeing 10, splits 6 off: that would leave 0.
      final below = await upload(user.token, split(a, c, 6, localCount: 4));
      expect(below.statusCode, 409, reason: below.body);
      final all = await upload(user.token, split(a, d, 10, localCount: 1));
      expect(all.statusCode, 409, reason: all.body);

      expect([await count(a), await count(c), await count(d)], [6, null, null]);
      final splits = await db.execute(
        r'SELECT count(*) FROM splits WHERE unit_id = $1::uuid',
        parameters: [a],
      );
      expect(splits.single.single, 1);
    });

    test(
      "a Split of another user's Batch is rejected, with nothing written",
      () async {
        final bob = await signUp();
        final bobsCollection = await createCollection(bob);
        final b = await newId();

        final response = await upload(
          bob.token,
          split(a, b, 4, localCount: 6, collection: bobsCollection),
        );
        expect(response.statusCode, 403, reason: response.body);
        expect([await count(a), await count(b)], [10, null]);
      },
    );

    test('a Merge adds the counts and deletes the merged Batch; a second Merge of it is rejected', () async {
      final b = await newId();
      expect(
        (await upload(user.token, split(a, b, 4, localCount: 6))).statusCode,
        204,
      );
      final moved = await upload(user.token, [
        putStageChange(a, wishlist, primed, 6, '2026-11-13T11:00:00Z'),
      ]);
      expect(moved.statusCode, 204, reason: moved.body);

      // Two devices Merge the same pair automatically, the same way (into the lowest id); a third the other way.
      final merged = await upload(user.token, merge(a, b, localCount: 10));
      expect(merged.statusCode, 204, reason: merged.body);
      final same = await upload(user.token, merge(a, b, localCount: 14));
      expect(same.statusCode, 422, reason: same.body);
      final again = await upload(user.token, merge(b, a, localCount: 10));
      expect(again.statusCode, 422, reason: again.body);

      expect([await count(a), await count(b)], [10, null]);
      expect((await batch(a)).single[4], 'Primed');
    });

    test('a Merge racing a Split of the merged Batch counts it as the server has it', () async {
      final (b, c) = (await newId(), await newId());
      final atPrimed = await upload(user.token, [
        ...split(a, b, 4, localCount: 6),
        putStageChange(a, wishlist, primed, 6, '2026-11-13T11:00:00Z'),
      ]);
      expect(atPrimed.statusCode, 204, reason: atPrimed.body);

      // Device X splits 1 of B's 4 back to Wishlist; device Y, offline, Merges B (it still sees 4) into A.
      final splitOfB = await upload(user.token, [
        putBatch(
          c,
          collectionId: collectionId,
          stageId: wishlist,
          modelCount: 1,
        ),
        putStageChange(c, primed, wishlist, 1, '2026-11-13T12:00:00Z'),
        {
          'op': 'PUT',
          'type': 'splits',
          'id': await newId(),
          'data': {'unit_id': b, 'new_unit_id': c, 'model_count': 1},
        },
        patchCount(b, 3),
      ]);
      expect(splitOfB.statusCode, 204, reason: splitOfB.body);
      final merged = await upload(user.token, merge(a, b, localCount: 10));
      expect(merged.statusCode, 204, reason: merged.body);

      expect([await count(a), await count(b), await count(c)], [9, null, 1]);
    });

    test(
      'a Merge is rejected once the Batches are no longer at the same Stage',
      () async {
        final b = await newId();
        expect(
          (await upload(user.token, split(a, b, 4, localCount: 6))).statusCode,
          204,
        );

        final response = await upload(user.token, merge(a, b, localCount: 10));
        expect(response.statusCode, 409, reason: response.body);
        expect([await count(a), await count(b)], [6, 4]);
      },
    );
  });

  group('Accounts', () {
    const syncedTables = [
      'workflows',
      'stages',
      'collections',
      'units',
      'stage_changes',
      'unit_tags',
      'photos',
      'splits',
      'merges',
    ];

    /// How many rows [userId] owns, per synced table.
    Future<Map<String, int>> rowsOf(String userId) async => {
      for (final table in syncedTables)
        table:
            (await db.execute(
                  'SELECT count(*) FROM $table WHERE owner_id = \$1::uuid',
                  parameters: [userId],
                )).single.single
                as int,
    };

    /// Whether [userId]'s photo directory exists inside the API container.
    Future<bool> hasPhotoDirectory(String userId) async {
      final out = await Directory.systemTemp.createTemp('photos');
      try {
        final copy = await Process.run('docker', [
          'compose',
          'cp',
          'api:/photos/$userId',
          out.path,
        ]);
        return copy.exitCode == 0;
      } finally {
        await out.delete(recursive: true);
      }
    }

    /// Gives [user] a row in every synced table and a photo file; returns the file id.
    Future<String> fillAccount(({String token, String id}) user) async {
      final collectionId = await createCollection(user);
      final wishlist = await stageOf(user.id, 'Wishlist');
      final [a, b, c] = [for (var i = 0; i < 3; i++) await newId()];
      Future<Map<String, Object?>> putStageChange(String batchId) async => {
        'op': 'PUT',
        'type': 'stage_changes',
        'id': await newId(),
        'data': {
          'unit_id': batchId,
          'from_stage_id': null,
          'to_stage_id': wishlist,
          'model_count': 5,
          'happened_at': '2026-11-13T09:00:00Z',
        },
      };
      final response = await upload(user.token, [
        for (final id in [a, b, c])
          putBatch(
            id,
            collectionId: collectionId,
            stageId: wishlist,
            modelCount: 5,
          ),
        for (final id in [a, b, c]) await putStageChange(id),
        putTag(a, 'Necrons'),
        {
          'op': 'PUT',
          'type': 'merges',
          'id': await newId(),
          'data': {'unit_id': a, 'merged_unit_id': b},
        },
        {'op': 'DELETE', 'type': 'units', 'id': b},
        {
          'op': 'PUT',
          'type': 'splits',
          'id': await newId(),
          'data': {'unit_id': a, 'new_unit_id': c, 'model_count': 2},
        },
      ]);
      expect(response.statusCode, 204, reason: response.body);
      final fileId = await addPhoto(user, a);
      expect((await rowsOf(user.id)).values, everyElement(isPositive));
      expect(await hasPhotoDirectory(user.id), isTrue);
      return fileId;
    }

    Future<http.Response> deleteAccount(String token) => http.delete(
      _upload.resolve('/account'),
      headers: {'authorization': 'Bearer $token'},
    );

    test("deleting an account removes all its rows, its user and its photos, and nobody else's", () async {
      final alice = await signUp();
      final bob = await signUp();
      await fillAccount(alice);
      final bobsFile = await fillAccount(bob);
      final bobsRows = await rowsOf(bob.id);

      final response = await deleteAccount(alice.token);
      expect(response.statusCode, 204, reason: response.body);

      expect((await rowsOf(alice.id)).values, everyElement(0));
      expect(
        await db.execute(
          r'SELECT FROM auth.users WHERE id = $1::uuid',
          parameters: [alice.id],
        ),
        isEmpty,
      );
      expect(await hasPhotoDirectory(alice.id), isFalse);

      expect(await rowsOf(bob.id), bobsRows);
      final bobsPhoto = await http.get(
        file(bobsFile),
        headers: auth(bob.token),
      );
      expect(bobsPhoto.statusCode, 200);
      expect(bobsPhoto.bodyBytes, jpeg);
    });

    test(
      "a deleted account's token, though unexpired, can no longer write",
      () async {
        final user = await signUp();
        final batchId = await addBatch(user);
        expect((await deleteAccount(user.token)).statusCode, 204);

        final write = await upload(user.token, [
          {
            'op': 'PUT',
            'type': 'collections',
            'id': await newId(),
            'data': {'name': 'Orks', 'workflow_id': await newId()},
          },
        ]);
        expect(write.statusCode, 401, reason: write.body);
        final photo = await http.put(
          file(await newId()),
          headers: auth(user.token),
          body: jpeg,
        );
        expect(photo.statusCode, 401);
        expect((await deleteAccount(user.token)).statusCode, 401);
        expect(await batch(batchId), isEmpty);
      },
    );

    test('a password is reset with the code from the reset email', () async {
      final email =
          'reset-${DateTime.now().microsecondsSinceEpoch}@example.com';
      Future<http.Response> post(String path, Object body) => http.post(
        _auth.resolve(path),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(body),
      );
      Future<int> signIn(String password) async => (await post(
        '/token?grant_type=password',
        {'email': email, 'password': password},
      )).statusCode;
      expect(
        (await post('/signup', {
          'email': email,
          'password': 'forgotten password',
        })).statusCode,
        200,
      );

      final recover = await post('/recover', {'email': email});
      expect(recover.statusCode, 200, reason: recover.body);

      // Mailpit's API: https://mailpit.axllent.org/docs/api-v1/
      final mailpit = Uri.parse('http://localhost:8025/api/v1/');
      var messages = <Object?>[];
      for (var i = 0; i < 50 && messages.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final search = await http.get(
          mailpit
              .resolve('search')
              .replace(queryParameters: {'query': 'to:"$email"'}),
        );
        messages = (jsonDecode(search.body) as Map)['messages'] as List;
      }
      expect(messages, hasLength(1), reason: 'the reset email arrived');
      final message = jsonDecode(
        (await http.get(
          mailpit.resolve('message/${(messages.single as Map)['ID']}'),
        )).body,
      ) as Map;
      final text = message['Text'] as String;
      final code = RegExp(r'\b\d{6}\b').firstMatch(text)?[0];
      expect(code, isNotNull, reason: text);

      final verified = await post('/verify', {
        'type': 'recovery',
        'email': email,
        'token': code,
      });
      expect(verified.statusCode, 200, reason: verified.body);
      final token =
          (jsonDecode(verified.body) as Map)['access_token'] as String;
      final updated = await http.put(
        _auth.resolve('/user'),
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer $token',
        },
        body: jsonEncode({'password': 'remembered password'}),
      );
      expect(updated.statusCode, 200, reason: updated.body);

      expect(await signIn('remembered password'), 200);
      expect(await signIn('forgotten password'), 400);
    });
  });
}

/// A user with a Collection holding two Batches, and a second Workflow with three Stages.
typedef _Switch = ({
  ({String token, String id}) user,
  String collectionId,
  List<String> batches,
  String workflowId,
  List<String> stages,
});
