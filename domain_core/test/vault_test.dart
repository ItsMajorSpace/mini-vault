import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:powersync/powersync.dart';
import 'package:test/test.dart';

// Seam 1: the domain core over real local SQLite (a PowerSync database file in a temp dir), no mocks.
// The starter Workflow's shape is tested on the server, which creates it (server/test).
void main() {
  late Directory dir;
  late PowerSyncDatabase db;
  late Vault vault;

  /// Opens the database file the way the app does on launch.
  Future<void> launch() async {
    db = PowerSyncDatabase(
      schema: SqliteVaultStore.schema,
      path: '${dir.path}/vault.db',
    );
    await db.initialize();
    vault = Vault(SqliteVaultStore(db));
  }

  /// Closes and reopens the database, like an app restart.
  Future<void> restart() async {
    await db.close();
    await launch();
  }

  /// Stands in for the first sync delivering the starter Workflow the server created.
  Future<String> syncStarterWorkflow() async {
    const workflowId = '00000000-0000-4000-8000-000000000001';
    await db.execute(
      "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id) VALUES (?, 'Starter', 's1', 's6')",
      [workflowId],
    );
    for (final (position, name) in Vault.starterStageNames.indexed) {
      await db.execute(
        'INSERT INTO stages (id, workflow_id, name, position) VALUES (?, ?, ?, ?)',
        ['s$position', workflowId, name, position],
      );
    }
    return workflowId;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('domain_core_test');
    await launch();
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  group('starter Workflow', () {
    test('is read back in Stage order once synced', () async {
      expect(await vault.starterWorkflow(), isNull);
      await syncStarterWorkflow();

      final workflow = (await vault.starterWorkflow())!;

      expect(workflow.stages.map((s) => s.name), Vault.starterStageNames);
      expect(workflow.ownedStage.name, 'Unassembled');
      expect(workflow.finishedStage.name, 'Done');
    });
  });

  group('Collection', () {
    test('cannot be created before the starter Workflow has synced', () async {
      await expectLater(
        vault.createCollection('Space Marines'),
        throwsStateError,
      );
      expect(await vault.collections(), isEmpty);
    });

    test('is created with the starter Workflow and a UUID id, and persists across restarts', () async {
      final workflowId = await syncStarterWorkflow();
      final created = await vault.createCollection('  Space Marines ');
      await restart();

      final [collection] = await vault.collections();
      expect(collection.id, created.id);
      expect(
        collection.id,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(collection.name, 'Space Marines');
      expect(collection.workflowId, workflowId);
    });

    test('is renamed, and the new name persists across restarts', () async {
      await syncStarterWorkflow();
      final created = await vault.createCollection('Space Marines');
      await vault.createCollection('Kill Team');

      await vault.renameCollection(created.id, 'Ultramarines');
      await restart();

      expect((await vault.collections()).map((c) => c.name), [
        'Kill Team',
        'Ultramarines',
      ]);
    });

    test('cannot be created or renamed with a blank name', () async {
      await syncStarterWorkflow();
      final created = await vault.createCollection('Space Marines');

      await expectLater(vault.createCollection('  '), throwsArgumentError);
      expect(() => vault.renameCollection(created.id, ''), throwsArgumentError);
      expect((await vault.collections()).map((c) => c.name), ['Space Marines']);
    });

    test(
      'changes are queued for upload: an insert, then a per-field update',
      () async {
        await syncStarterWorkflow();
        final created = await vault.createCollection('Space Marines');
        await vault.renameCollection(created.id, 'Ultramarines');

        final batch = (await db.getCrudBatch())!;
        final ops = batch.crud.where((e) => e.table == 'collections').toList();
        expect(ops.map((e) => e.op), [UpdateType.put, UpdateType.patch]);
        expect(ops.last.opData, {'name': 'Ultramarines'});
      },
    );

    test('are watched: the stream emits again after a change', () async {
      await syncStarterWorkflow();
      final names = vault.watchCollections().map(
        (cs) => cs.map((c) => c.name).toList(),
      );
      final expectation = expectLater(names, emitsThrough(['Space Marines']));
      await vault.createCollection('Space Marines');
      await expectation;
    });
  });

  group('Unit', () {
    late Collection collection;
    setUp(() async {
      await syncStarterWorkflow();
      collection = await vault.createCollection('Space Marines');
    });

    /// The Collection's groups as "Stage (model count): Unit names", for compact expectations.
    Future<List<String>> groups() async => [
      for (final g in await vault.watchStageGroups(collection).first)
        '${g.stage.name} (${g.modelCount}): ${g.units.map((u) => u.name).join(', ')}',
    ];

    test(
      'is added at a Stage with its fields, and persists across restarts',
      () async {
        final added = await vault.addUnit(
          collection,
          name: ' Intercessors ',
          modelCount: 10,
          notes: ' Magnetised arms ',
          stageId: 's2',
        );
        await restart();

        final [group] = (await vault.watchStageGroups(collection).first)
            .where((g) => g.units.isNotEmpty)
            .toList();
        final [unit] = group.units;
        expect(group.stage.name, 'Assembled');
        expect(unit.id, added.id);
        expect(unit.collectionId, collection.id);
        expect(
          (unit.name, unit.modelCount, unit.notes),
          ('Intercessors', 10, 'Magnetised arms'),
        );
      },
    );

    test('cannot be added with a blank name, no models, or a Stage outside the Workflow', () async {
      Future<Unit> add({
        String name = 'Intercessors',
        int count = 1,
        String stage = 's0',
      }) => vault.addUnit(
        collection,
        name: name,
        modelCount: count,
        stageId: stage,
      );

      await expectLater(add(name: ' '), throwsArgumentError);
      await expectLater(add(count: 0), throwsArgumentError);
      await expectLater(add(stage: 'elsewhere'), throwsArgumentError);
      expect(await groups(), everyElement(endsWith('(0): ')));
    });

    test('is edited per field, rejecting a blank name or no models', () async {
      final unit = await vault.addUnit(
        collection,
        name: 'Intercessors',
        modelCount: 10,
        notes: 'Magnetised',
        stageId: 's0',
      );
      await db.execute('DELETE FROM ps_crud');

      await vault.editUnit(
        unit.id,
        name: 'Assault Intercessors',
        modelCount: 5,
      );
      await vault.editUnit(unit.id, notes: 'Jump packs');
      expect(() => vault.editUnit(unit.id, name: ''), throwsArgumentError);
      expect(() => vault.editUnit(unit.id, modelCount: 0), throwsArgumentError);

      final [unitNow] =
          (await vault.watchStageGroups(collection).first).first.units;
      expect(
        (unitNow.name, unitNow.modelCount, unitNow.notes),
        ('Assault Intercessors', 5, 'Jump packs'),
      );
      final ops = (await db.getCrudBatch())!.crud;
      expect(ops.map((e) => [e.op, e.opData]), [
        [
          UpdateType.patch,
          {'name': 'Assault Intercessors', 'model_count': 5},
        ],
        [
          UpdateType.patch,
          {'notes': 'Jump packs'},
        ],
      ]);
    });

    test('is deleted', () async {
      final unit = await vault.addUnit(
        collection,
        name: 'Intercessors',
        modelCount: 10,
        stageId: 's0',
      );
      await vault.addUnit(
        collection,
        name: 'Hellblasters',
        modelCount: 5,
        stageId: 's0',
      );

      await vault.deleteUnit(unit.id);

      expect((await groups()).first, 'Wishlist (5): Hellblasters');
    });

    test(
      'are grouped by Stage in Workflow order, with a model count per Stage',
      () async {
        final other = await vault.createCollection('Kill Team');
        await vault.addUnit(
          other,
          name: 'Elsewhere',
          modelCount: 3,
          stageId: 's0',
        );
        await vault.addUnit(
          collection,
          name: 'Terminators',
          modelCount: 5,
          stageId: 's4',
        );
        await vault.addUnit(
          collection,
          name: 'Intercessors',
          modelCount: 10,
          stageId: 's0',
        );
        await vault.addUnit(
          collection,
          name: 'Captain',
          modelCount: 1,
          stageId: 's4',
        );
        await vault.addUnit(
          collection,
          name: 'hellblasters',
          modelCount: 5,
          stageId: 's0',
        );

        expect(await groups(), [
          'Wishlist (15): hellblasters, Intercessors',
          'Unassembled (0): ',
          'Assembled (0): ',
          'Primed (0): ',
          'Painted (6): Captain, Terminators',
          'Based (0): ',
          'Done (0): ',
        ]);
      },
    );

    test('groups are watched: the stream emits again after a change', () async {
      final counts = vault
          .watchStageGroups(collection)
          .map((gs) => gs.first.modelCount);
      final expectation = expectLater(counts, emitsThrough(10));
      await vault.addUnit(
        collection,
        name: 'Intercessors',
        modelCount: 10,
        stageId: 's0',
      );
      await expectation;
    });
  });
}
