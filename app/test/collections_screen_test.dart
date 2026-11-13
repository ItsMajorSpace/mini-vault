import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/main.dart';
import 'package:mini_vault/photos.dart';
import 'package:mini_vault/progress.dart';
import 'package:mini_vault/workflows.dart';
import 'package:powersync/powersync.dart';

// Smoke test: the Collections screen renders what is stored in real SQLite after an app restart,
// and shows the local changes still waiting to sync (the database is never connected here).
// shortcut: Collections are created through the Vault, not the dialogs: SQLite I/O started from a tap
// never completes inside the widget tester's fake-async zone. Drive the dialogs in an integration test on a device.
// shortcut: the database is never closed once the screen has been mounted: closing it then hangs inside the
// fake-async zone. Its isolate ends with the test process.
void main() {
  testWidgets(
    'shows the stored Collections and pending changes after a restart',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('app_test'),
      ))!;
      PowerSyncDatabase open() =>
          PowerSyncDatabase(schema: appSchema, path: '${dir.path}/vault.db');

      await tester.runAsync(() async {
        final db = open();
        // Stands in for the first sync: the server's starter Workflow, already uploaded.
        await db.execute(
          "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id) VALUES ('w', 'Starter', 's', 's')",
        );
        await db.execute(
          "INSERT INTO stages (id, workflow_id, name, position) VALUES ('s', 'w', 'Wishlist', 0)",
        );
        await (await db.getCrudBatch())!.complete();

        final vault = Vault(SqliteVaultStore(db));
        final created = await vault.createCollection('Space Marines');
        await vault.renameCollection(created.id, 'Ultramarines');
        await db.close();
      });

      final db = (await tester.runAsync(() async {
        final db = open();
        await db.initialize();
        return db;
      }))!;
      await tester.pumpWidget(
        MaterialApp(
          home: CollectionsScreen(vault: Vault(SqliteVaultStore(db)), db: db),
        ),
      );
      // Lets the screen's SQLite reads (several isolate round trips) finish, then the UI catch up.
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.text('Ultramarines'), findsOneWidget);
      expect(find.text('0 / 0 finished'), findsOneWidget);
      expect(
        find.text('1 Collection · 0 owned · 0 finished · 0 wanted'),
        findsOneWidget,
      );
      expect(find.text('2 changes waiting to sync'), findsOneWidget);
      expect(find.byTooltip('New Collection'), findsOneWidget);
      expect(
        find.text('Other'),
        findsNothing,
      ); // No Game System yet: no headers.

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => dir.delete(recursive: true));
    },
  );

  testWidgets('groups Collections under their Game System, A–Z, then Other', (
    tester,
  ) async {
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('app_test'),
    ))!;
    final db = (await tester.runAsync(() async {
      final db = PowerSyncDatabase(
        schema: appSchema,
        path: '${dir.path}/vault.db',
      );
      await db.execute(
        "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id) VALUES ('w', 'Starter', 's', 's')",
      );
      await db.execute(
        "INSERT INTO stages (id, workflow_id, name, position) VALUES ('s', 'w', 'Wishlist', 0)",
      );
      final vault = Vault(SqliteVaultStore(db));
      await vault.createCollection('Terrain');
      await vault.createCollection('Ultramarines', gameSystem: 'Warhammer');
      await vault.createCollection('Party', gameSystem: 'D&D');
      await vault.createCollection('Orks', gameSystem: 'warhammer');
      return db;
    }))!;
    await tester.pumpWidget(
      MaterialApp(
        home: CollectionsScreen(vault: Vault(SqliteVaultStore(db)), db: db),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    final order = [
      'D&D',
      'Party',
      'Warhammer',
      'Orks',
      'Ultramarines',
      'Other',
      'Terrain',
    ];
    final tops = [for (final t in order) tester.getTopLeft(find.text(t)).dy];
    expect(tops, [...tops]..sort(), reason: 'in the order $order');

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => dir.delete(recursive: true));
  });

  testWidgets(
    'the Collection dialog suggests Game Systems in use and returns the fields',
    (tester) async {
      (String, String?, String)? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showDialog(
                context: context,
                builder: (_) => const NewCollectionDialog(
                  gameSystems: ['D&D', 'Warhammer 40k'],
                  collection: Collection(
                    id: 'c',
                    name: 'Orks',
                    workflowId: 'w',
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Edit Collection'), findsOneWidget);
      expect(find.text('Workflow'), findsNothing);

      await tester.enterText(
        find.widgetWithText(TextField, 'Game System'),
        'war',
      );
      await tester.pumpAndSettle();
      expect(find.text('D&D'), findsNothing);
      await tester.tap(find.text('Warhammer 40k'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(result, ('Orks', null, 'Warhammer 40k'));
    },
  );

  testWidgets('shows a Collection\'s Squads by name, with model counts', (
    tester,
  ) async {
    final (db, vault, collection) = (await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('app_test');
      final db = PowerSyncDatabase(
        schema: appSchema,
        path: '${dir.path}/vault.db',
      );
      await db.execute(
        "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id) VALUES ('w', 'Starter', 's1', 's1')",
      );
      for (final (i, name) in ['Wishlist', 'Unassembled', 'Primed'].indexed) {
        await db.execute(
          'INSERT INTO stages (id, workflow_id, name, position) VALUES (?, ?, ?, ?)',
          ['s$i', 'w', name, i],
        );
      }
      final vault = Vault(SqliteVaultStore(db));
      final collection = await vault.createCollection('Space Marines');
      for (final (name, count, stage) in [
        ('Intercessors', 10, 's2'),
        ('Captain', 1, 's2'),
        ('Terminators', 5, 's0'),
        ('Intercessors', 5, 's0'),
      ]) {
        await vault.addUnit(
          collection,
          name: name,
          modelCount: count,
          stageId: stage,
        );
      }
      return (db, vault, collection);
    }))!;

    await tester.pumpWidget(
      MaterialApp(
        home: CollectionScreen(vault: vault, db: db, collection: collection),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    // One row per Squad, by name, counting the models of all its Units.
    final rows = [
      'Captain',
      '1 model',
      'Intercessors',
      '15 models',
      'Terminators',
      '5 models',
    ];
    final ys = [for (final text in rows) tester.getTopLeft(find.text(text)).dy];
    expect(ys, orderedEquals([...ys]..sort()));
    // One per Squad, and the Progress drawer's.
    expect(find.byType(StageBar), findsNWidgets(4));
    // Owned and Finished Stage are both Unassembled: Primed counts as finished, Wishlist as wanted.
    expect(
      find.text('3 Squads · 11 owned · 11 finished · 10 wanted'),
      findsOneWidget,
    );
    expect(find.byTooltip('New Unit'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
