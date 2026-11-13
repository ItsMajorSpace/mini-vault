import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/main.dart';
import 'package:mini_vault/photos.dart';
import 'package:powersync/powersync.dart';

// shortcut: the database is never closed once the screen has been mounted (see collections_screen_test.dart).
void main() {
  /// Lets SQLite reads and writes (isolate round trips) finish, then the UI catch up.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Taps outside the fake-async zone: SQLite I/O started from a tap inside it never completes.
  Future<void> tapAndWait(WidgetTester tester, Finder finder) async {
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await settle(tester);
  }

  const necrons = '''
cano (2000 points)

Necrons
Strike Force (2000 points)
Canoptek Court

CHARACTERS

Illuminor Szeras (165 points)
  • 1x Eldritch Lance
    1x Impaling legs

Technomancer (100 points)
  • 1x Staff of light
  • Enhancement: Dimensional Sanctum

BATTLELINE

Necron Warriors (200 points)
  • 20x Necron Warrior
    • 20x Close combat weapon
      20x Gauss reaper
''';

  testWidgets(
    'from a Collection: paste, preview (untick, rename, count), import at the first Stage with the Tag, Merging',
    (tester) async {
      final (db, vault, collection) = (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('app_test');
        final db = PowerSyncDatabase(
          schema: appSchema,
          path: '${dir.path}/vault.db',
        );
        await db.execute(
          "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id) VALUES ('w', 'Starter', 's1', 's1')",
        );
        for (final (i, name) in ['Wishlist', 'Unassembled'].indexed) {
          await db.execute(
            'INSERT INTO stages (id, workflow_id, name, position) VALUES (?, ?, ?, ?)',
            ['s$i', 'w', name, i],
          );
        }
        final vault = Vault(SqliteVaultStore(db));
        final collection = await vault.createCollection('Dynasty');
        await vault.addBatch(
          collection,
          name: 'Necron Warriors',
          modelCount: 3,
          stageId: 's0',
        );
        return (db, vault, collection);
      }))!;
      await tester.pumpWidget(
        MaterialApp(
          home: CollectionScreen(vault: vault, db: db, collection: collection),
        ),
      );
      await settle(tester);

      await tapAndWait(tester, find.byTooltip('Collection'));
      await tapAndWait(tester, find.text('Import army list'));
      await tester.enterText(find.byType(TextField), 'Intercessors x10');
      await tapAndWait(tester, find.text('Preview'));
      expect(find.textContaining('Unrecognised list'), findsOneWidget);

      await tester.enterText(find.byType(TextField), necrons);
      await tapAndWait(tester, find.text('Preview'));
      expect(find.text('Dynasty'), findsOneWidget); // Preselected.
      expect(find.text('Wishlist'), findsOneWidget); // The first Stage.
      expect(find.text('Already 3 models'), findsOneWidget);

      await tester.tap(find.byType(Checkbox).at(1)); // Technomancer.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Illuminor Szeras'),
        'Szeras',
      );
      await tester.enterText(find.widgetWithText(TextFormField, '20'), '10');
      await tester.pump();
      await tapAndWait(tester, find.text('Import'));

      // Back in the Collection.
      expect(find.text('Import army list'), findsNothing);
      final batches = (await tester.runAsync(
        () => vault.batchesOf(collection),
      ))!;
      expect([
        for (final u in batches) (u.name, u.stageId, u.modelCount),
      ], unorderedEquals([('Szeras', 's0', 1), ('Necron Warriors', 's0', 13)]));
      for (final u in batches) {
        expect(
          await tester.runAsync(() => vault.tagsOf(u.collectionId, u.name)),
          ['Necrons'],
        );
      }
    },
  );
}
