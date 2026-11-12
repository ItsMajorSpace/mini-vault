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
}
