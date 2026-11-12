import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:sqlite_async/sqlite_async.dart';
import 'package:test/test.dart';

// Seam 1: the domain core over real local SQLite (a file in a temp dir), no mocks.
void main() {
  late Directory dir;
  late SqliteDatabase db;
  late Vault vault;

  /// Opens the database file the way the app does on launch.
  Future<void> launch() async {
    db = SqliteDatabase(path: '${dir.path}/vault.db');
    await SqliteVaultStore.createTables(db);
    vault = Vault(SqliteVaultStore(db));
  }

  /// Closes and reopens the database, like an app restart.
  Future<void> restart() async {
    await db.close();
    await launch();
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
    test('has the starter Stages in order, Owned Stage Unassembled and Finished Stage Done', () async {
      await vault.ensureStarterWorkflow();
      await restart();

      final workflow = await vault.ensureStarterWorkflow();

      expect(workflow.stages.map((s) => s.name), [
        'Wishlist',
        'Unassembled',
        'Assembled',
        'Primed',
        'Painted',
        'Based',
        'Done',
      ]);
      expect(workflow.ownedStage.name, 'Unassembled');
      expect(workflow.finishedStage.name, 'Done');
    });

    test('is created only once', () async {
      final first = await vault.ensureStarterWorkflow();
      await restart();
      final second = await vault.ensureStarterWorkflow();

      expect(second.id, first.id);
    });
  });

  group('Collection', () {
    test('is created with the starter Workflow and a UUID id, and persists across restarts', () async {
      final workflow = await vault.ensureStarterWorkflow();
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
      expect(collection.workflowId, workflow.id);
    });

    test('is renamed, and the new name persists across restarts', () async {
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
      final created = await vault.createCollection('Space Marines');

      await expectLater(vault.createCollection('  '), throwsArgumentError);
      expect(() => vault.renameCollection(created.id, ''), throwsArgumentError);
      expect((await vault.collections()).map((c) => c.name), ['Space Marines']);
    });
  });
}
