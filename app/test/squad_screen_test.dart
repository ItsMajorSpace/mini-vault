import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/squad.dart';
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

  testWidgets(
    'shows every Stage with the Squad\'s counts and Tags; renames and Merges',
    (tester) async {
      final (vault, collection) = (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('app_test');
        final db = PowerSyncDatabase(
          schema: SqliteVaultStore.schema,
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
        for (final (name, count, stage, tag) in [
          ('Intercessors', 6, 's0', '40k'),
          ('Intercessors', 4, 's0', 'Ultramarines'),
          ('Intercessors', 2, 's2', '40k'),
          ('Captain', 1, 's2', 'HQ'),
        ]) {
          final unit = await vault.addUnit(
            collection,
            name: name,
            modelCount: count,
            stageId: stage,
          );
          await vault.addTags(unit.id, [tag]);
        }
        return (vault, collection);
      }))!;

      await tester.pumpWidget(
        MaterialApp(
          home: SquadScreen(
            vault: vault,
            collection: collection,
            name: 'Intercessors',
          ),
        ),
      );
      await settle(tester);

      // Every Stage in Workflow order, the empty one too, each with the Squad's count and a share bar.
      final rows = [
        'Wishlist',
        '10 models',
        'Unassembled',
        '0 models',
        'Primed',
        '2 models',
      ];
      final ys = [
        for (final text in rows) tester.getTopLeft(find.text(text)).dy,
      ];
      expect(ys, orderedEquals([...ys]..sort()));
      expect(
        [
          for (final p in tester.widgetList<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          ))
            p.value,
        ],
        [10 / 12, 0, 2 / 12],
      );
      // The union of its Units' Tags, read-only; not the Captain's.
      expect(find.widgetWithText(Chip, '40k'), findsOneWidget);
      expect(find.widgetWithText(Chip, 'Ultramarines'), findsOneWidget);
      expect(find.text('HQ'), findsNothing);
      expect(find.byType(InputChip), findsNothing);

      // Two Units at Wishlist: one Merge chip, which Merges them.
      expect(find.text('Merge'), findsOneWidget);
      await tapAndWait(tester, find.text('Merge'));
      expect(find.text('Merge'), findsNothing);
      expect(find.text('10 models'), findsOneWidget);

      await tester.tap(find.byTooltip('Rename Squad'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Assault Intercessors');
      await tapAndWait(tester, find.text('Save'));

      expect(find.text('Assault Intercessors'), findsOneWidget);
      expect(find.text('10 models'), findsOneWidget);
      final squads = (await tester.runAsync(
        () => vault.watchSquads(collection).first,
      ))!;
      expect(
        [for (final s in squads) (s.name, s.units.length)],
        [('Assault Intercessors', 2), ('Captain', 1)],
      );

      await tester.pumpWidget(const SizedBox());
    },
  );
}
