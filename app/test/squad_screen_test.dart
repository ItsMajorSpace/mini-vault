import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/main.dart';
import 'package:mini_vault/squad.dart';
import 'package:mini_vault/theme.dart';
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

  /// Opens the Squad screen on 'Intercessors', a Unit of it per (models, Stage index), in a Workflow of [stages].
  Future<(Vault, Collection)> openSquad(
    WidgetTester tester,
    List<String> stages,
    List<(int, int)> units,
  ) async {
    final (vault, collection) = (await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('app_test');
      final db = PowerSyncDatabase(
        schema: SqliteVaultStore.schema,
        path: '${dir.path}/vault.db',
      );
      await db.execute(
        "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id) VALUES ('w', 'Starter', 's1', 's1')",
      );
      for (final (i, name) in stages.indexed) {
        await db.execute(
          'INSERT INTO stages (id, workflow_id, name, position) VALUES (?, ?, ?, ?)',
          ['s$i', 'w', name, i],
        );
      }
      final vault = Vault(SqliteVaultStore(db));
      final collection = await vault.createCollection('Space Marines');
      for (final (count, stage) in units) {
        await vault.addUnit(
          collection,
          name: 'Intercessors',
          modelCount: count,
          stageId: 's$stage',
        );
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
    return (vault, collection);
  }

  /// Each Stage row's model count, in Workflow order.
  List<String?> counts(WidgetTester tester) => [
    for (final t in tester.widgetList<Text>(find.byType(Text)))
      if (RegExp(r'^\d+ models?$').hasMatch(t.data ?? '')) t.data,
  ];

  const stages = ['Wishlist', 'Unassembled', 'Primed'];

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

      // Every Stage in Workflow order, the empty one too, each with the Squad's count, and a dot in its colour.
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
      // Each row's dot in its Stage's colour.
      expect(
        [
          for (final i in tester.widgetList<Icon>(find.byIcon(Icons.circle)))
            i.color,
        ],
        [for (final c in Vault.stageColours.take(3)) stageColour(c)],
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

  testWidgets(
    'lists the Squad\'s Paints with notes, marking wanted ones; adds from the library, a new one wanted, and removes',
    (tester) async {
      final (vault, collection) = await openSquad(tester, stages, [(5, 0)]);
      await tester.runAsync(() async {
        final blue = await vault.addPaint(
          brand: 'Citadel',
          range: 'Base',
          name: 'Macragge Blue',
        );
        await vault.addPaint(
          brand: 'Citadel',
          range: 'Shade',
          name: 'Nuln Oil',
          owned: false,
        );
        await vault.addPaint(
          brand: 'Vallejo',
          range: 'Model Color',
          name: 'Flat Blue',
        );
        await vault.addSquadPaint(
          collection.id,
          'Intercessors',
          blue.id,
          note: 'armour',
        );
      });
      await settle(tester);
      expect(find.text('Macragge Blue'), findsOneWidget);
      expect(find.text('Citadel / Base · armour'), findsOneWidget);

      // The picker offers only Paints the Squad does not use yet, searched on brand, range or name.
      await tester.tap(find.byTooltip('Add Paint'));
      await tester.pumpAndSettle();
      expect(find.text('Citadel / Base / Macragge Blue'), findsNothing);
      expect(find.text('Vallejo / Model Color / Flat Blue'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'BLUE');
      await tester.pump();
      expect(find.text('Citadel / Base / Macragge Blue'), findsNothing);
      expect(find.text('Citadel / Shade / Nuln Oil'), findsNothing);
      expect(find.text('Vallejo / Model Color / Flat Blue'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'model');
      await tester.pump();
      expect(find.text('Vallejo / Model Color / Flat Blue'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'citadel');
      await tester.pump();
      expect(find.text('Vallejo / Model Color / Flat Blue'), findsNothing);
      await tapAndWait(tester, find.text('Citadel / Shade / Nuln Oil'));
      expect(find.text('Citadel / Shade · Wanted'), findsOneWidget);

      // A Paint created here starts as wanted, named as searched.
      await tester.tap(find.byTooltip('Add Paint'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Agrax Earthshade');
      await tester.pump();
      await tester.tap(find.text('New Paint…'));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(
        find.widgetWithText(TextField, 'Agrax Earthshade'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tapAndWait(tester, find.byTooltip('Remove Paint').first);
      expect(find.text('Macragge Blue'), findsNothing);
      expect(find.text('Nuln Oil'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the Paints section shows again after it is scrolled out of view and back',
    (tester) async {
      // Tall enough at first that the section is built (and listening) when the screen opens.
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (vault, collection) = await openSquad(
        tester,
        [for (var i = 0; i < 40; i++) 'Stage $i'],
        [(5, 0)],
      );
      await tester.runAsync(() async {
        final blue = await vault.addPaint(
          brand: 'Citadel',
          range: 'Base',
          name: 'Macragge Blue',
        );
        await vault.addSquadPaint(collection.id, 'Intercessors', blue.id);
      });
      await settle(tester);
      expect(find.text('Macragge Blue'), findsOneWidget);

      // A short screen drops the section from the list; scrolling to it builds it again.
      tester.view.physicalSize = const Size(800, 400);
      await settle(tester);
      expect(find.text('Macragge Blue'), findsNothing);
      await tester.scrollUntilVisible(find.text('Macragge Blue'), 500);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Macragge Blue'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'tapping a Stage opens the Move sheet, next Stage preselected, all models counted; Move moves the chosen count',
    (tester) async {
      await openSquad(tester, stages, [(5, 0)]);
      Finder chip(String stage) => find.widgetWithText(ChoiceChip, stage);
      bool selected(String stage) =>
          tester.widget<ChoiceChip>(chip(stage)).selected;
      bool enabled(IconData icon) =>
          tester
              .widget<IconButton>(find.widgetWithIcon(IconButton, icon))
              .onPressed !=
          null;

      await tester.tap(find.text('Wishlist'));
      await tester.pumpAndSettle();
      // The other Stages as chips, the next one preselected; the count starts at all of them.
      expect(chip('Wishlist'), findsNothing);
      expect(selected('Unassembled'), isTrue);
      expect(selected('Primed'), isFalse);
      expect(find.text('5 of 5'), findsOneWidget);
      expect(enabled(Icons.add), isFalse);
      await tester.tap(find.byTooltip('One fewer'));
      await tester.pump();
      await tester.tap(find.byTooltip('One fewer'));
      await tester.pump();
      expect(find.text('3 of 5'), findsOneWidget);
      await tapAndWait(tester, find.byType(FilledButton));
      expect(find.byType(BottomSheet), findsNothing);
      expect(counts(tester), ['2 models', '3 models', '0 models']);

      // All again, after one fewer, and back to an earlier Stage.
      await tester.tap(find.text('Unassembled'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('One fewer'));
      await tester.pump();
      expect(find.text('2 of 3'), findsOneWidget);
      await tester.tap(find.text('All'));
      await tester.tap(chip('Wishlist'));
      await tester.pump();
      expect(find.text('3 of 3'), findsOneWidget);
      expect(enabled(Icons.add), isFalse);
      await tapAndWait(tester, find.text('Move 3 models to Wishlist'));
      expect(counts(tester), ['5 models', '0 models', '0 models']);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Edit count recounts a Stage\'s Unit, deleting it at 0 once confirmed; not with several Units there',
    (tester) async {
      final (vault, collection) = await openSquad(tester, stages, [
        (6, 0),
        (4, 0),
        (3, 2),
      ]);
      Future<List<(String, int)>> units() async => [
        for (final u in (await tester.runAsync(
          () => vault.unitsOf(collection),
        ))!)
          (u.stageId, u.modelCount),
      ]..sort((a, b) => '$a'.compareTo('$b'));
      Future<void> recount(String stage, String to) async {
        await tester.tap(find.text(stage));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Edit count'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), to);
        await tester.pump();
      }

      // Two Units at Wishlist: their count cannot be edited until Merged.
      await tester.tap(find.text('Wishlist'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Edit count'))
            .onPressed,
        isNull,
      );
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // A recount: the Unit at Primed now has 5, no Unit moved.
      await recount('Primed', '5');
      await tapAndWait(tester, find.text('Save'));
      expect(counts(tester), ['10 models', '0 models', '5 models']);
      expect(await units(), [('s0', 4), ('s0', 6), ('s2', 5)]);

      // Non-numeric and negative input is rejected as typed.
      await recount('Primed', '-x');
      expect(find.text('-x'), findsNothing);
      await tapAndWait(tester, find.text('Cancel'));

      // 0 asks first; cancelling keeps the Unit.
      await recount('Primed', '0');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Delete the Unit at Primed?'), findsOneWidget);
      await tapAndWait(tester, find.text('Cancel'));
      expect(await units(), [('s0', 4), ('s0', 6), ('s2', 5)]);

      // Confirmed, it deletes the Unit.
      await recount('Primed', '0');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tapAndWait(tester, find.text('Delete'));
      expect(await units(), [('s0', 4), ('s0', 6)]);
      expect(counts(tester), ['10 models', '0 models', '0 models']);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'empty Stages are dimmed and open nothing; Details asks which of several Units to open',
    (tester) async {
      final (vault, collection) = await openSquad(tester, stages, [
        (6, 0),
        (4, 0),
        (2, 1),
      ]);
      double opacity(String stage) => tester
          .widget<Opacity>(
            find.ancestor(of: find.text(stage), matching: find.byType(Opacity)),
          )
          .opacity;

      expect([for (final s in stages) opacity(s)], [1, 1, 0.38]);
      await tester.tap(find.text('Primed'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);

      await tester.tap(find.text('Wishlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.text('Which Unit?'), findsOneWidget);
      expect(find.widgetWithText(ListTile, '6 models'), findsOneWidget);
      await tapAndWait(tester, find.widgetWithText(ListTile, '4 models'));
      final opened = tester.widget<UnitScreen>(find.byType(UnitScreen)).unitId;
      final units = (await tester.runAsync(() => vault.unitsOf(collection)))!;
      expect(units.firstWhere((u) => u.id == opened).modelCount, 4);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    '+ opens New Unit named after the Squad, at the Owned Stage, suggesting Squad names as the Name is typed',
    (tester) async {
      final (vault, collection) = await openSquad(tester, stages, [(5, 0)]);
      await tester.runAsync(
        () => vault.addUnit(
          collection,
          name: 'Assault Intercessors',
          modelCount: 3,
          stageId: 's0',
        ),
      );
      await settle(tester);

      await tapAndWait(tester, find.byTooltip('New Unit'));
      expect(find.text('New Unit'), findsOneWidget);
      final name = find.widgetWithText(TextFormField, 'Name');
      expect(
        tester.widget<TextFormField>(name).controller!.text,
        'Intercessors',
      );
      // The Owned Stage, not the first one (Wishlist), is preselected.
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byType(DropdownButtonFormField<String>),
            )
            .initialValue,
        's1',
      );

      // Part of a name, in any case, offers every Squad containing it; picking one fills it in.
      await tester.enterText(name, 'CESS');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(InkWell, 'Intercessors'), findsOneWidget);
      expect(find.text('Assault Intercessors'), findsOneWidget);
      await tester.tap(find.text('Assault Intercessors'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(name).controller!.text,
        'Assault Intercessors',
      );

      await tapAndWait(tester, find.text('Save'));
      final units = (await tester.runAsync(() => vault.unitsOf(collection)))!;
      expect([
        for (final u in units)
          if (u.name == 'Assault Intercessors') (u.modelCount, u.stageId),
      ], unorderedEquals([(3, 's0'), (1, 's1')]));

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a 7-Stage Squad fits a 1080×2340 phone screen without scrolling',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      await openSquad(
        tester,
        [
          'Wishlist',
          'Unassembled',
          'Assembled',
          'Primed',
          'Based',
          'Painted',
          'Varnished',
        ],
        [(3, 0), (2, 3), (1, 6)],
      );

      expect(
        tester
            .state<ScrollableState>(find.byType(Scrollable))
            .position
            .maxScrollExtent,
        0,
      );
      expect(find.text('Varnished').hitTestable(), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );
}
