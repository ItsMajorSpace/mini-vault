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
  testWidgets('no screen on the main flows says Squad, Batch, Split or Merge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (db, vault) = (await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('app_test');
      final db = PowerSyncDatabase(
        schema: appSchema,
        path: '${dir.path}/vault.db',
      );
      await db.execute(
        "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id) VALUES ('w', 'Starter', 's1', 's2')",
      );
      for (final (i, name) in ['Wishlist', 'Unassembled', 'Primed'].indexed) {
        await db.execute(
          'INSERT INTO stages (id, workflow_id, name, position) VALUES (?, ?, ?, ?)',
          ['s$i', 'w', name, i],
        );
      }
      final vault = Vault(SqliteVaultStore(db));
      final c = await vault.createCollection('Space Marines');
      await vault.createCollection('Orks');
      await vault.addBatch(
        c,
        name: 'Intercessors',
        modelCount: 5,
        stageId: 's0',
      );
      await vault.addBatch(
        c,
        name: 'Intercessors',
        modelCount: 2,
        stageId: 's1',
      );
      // A Split, then a move that Merges.
      await vault.moveModels(c, 'Intercessors', 's0', 's1', 3);
      await vault.moveModels(c, 'Intercessors', 's0', 's1', 2);
      return (db, vault);
    }))!;
    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> tapAndWait(Finder finder) async {
      await tester.runAsync(() async {
        await tester.tap(finder);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await settle();
    }

    /// Every text and tooltip on screen.
    void expectPlainWords(String where) {
      final words = RegExp('Squad|Batch|Split|Merge');
      final shown = [
        for (final w in tester.allWidgets)
          if (w is RichText)
            w.text.toPlainText()
          else if (w is Tooltip)
            w.message ?? '',
      ];
      expect(shown, isNotEmpty);
      expect(shown.where(words.hasMatch), isEmpty, reason: where);
    }

    Future<void> look(String where, Finder open) async {
      await tapAndWait(open);
      expectPlainWords(where);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(
      MaterialApp(
        home: CollectionsScreen(vault: vault, db: db),
      ),
    );
    await settle();
    expect(find.text('RECENTLY PAINTED'), findsOneWidget);
    expectPlainWords('Collections');

    await tapAndWait(find.text('Orks'));
    expectPlainWords('empty Collection');
    await look('Add models', find.byTooltip('Add models'));
    await tester.pageBack();
    await settle();

    await tapAndWait(
      find.text('Space Marines').last,
    ); // The first is under Recently painted.
    expect(find.text('Intercessors'), findsOneWidget);
    expectPlainWords('Collection');
    await tapAndWait(find.byTooltip('Collection'));
    expectPlainWords('Collection menu');
    await tapAndWait(find.text('Delete Collection'));
    expectPlainWords('Delete Collection');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tapAndWait(find.text('Intercessors'));
    expect(find.text('HISTORY'), findsOneWidget);
    expectPlainWords('Unit');
    await tapAndWait(find.text('Unassembled'));
    expectPlainWords('Move sheet');
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await look('Edit Unit', find.byTooltip('Edit Unit'));
    await look('Delete Unit', find.byTooltip('Delete Unit'));
    await look('Add models', find.byTooltip('Add models'));

    await tester.pumpWidget(const SizedBox());
  });
}
