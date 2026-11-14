import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/photos.dart';
import 'package:mini_vault/stage_strip.dart';
import 'package:mini_vault/theme.dart';
import 'package:mini_vault/workflows.dart';
import 'package:powersync/powersync.dart';

const standard = [
  'Wishlist',
  'Unassembled',
  'Assembled',
  'Primed',
  'Painted',
  'Based',
  'Done',
];

/// The keys of [strip]'s segments (Stage ids) and ticks (`tick:<Stage id>`), left to right.
List<String> parts(WidgetTester tester, Finder strip) => [
  for (final w
      in tester
          .widget<Row>(find.descendant(of: strip, matching: find.byType(Row)))
          .children)
    (w.key! as ValueKey<String>).value,
];

// shortcut: the database is never closed once the screen has been mounted (see collections_screen_test.dart).
void main() {
  testWidgets(
    'StageStrip: a segment per Stage, ticks where Owned and Finished begin',
    (tester) async {
      Workflow workflow(List<String> names, int owned, int finished) =>
          Workflow(
            id: 'w',
            name: 'W',
            stages: [
              for (final (i, n) in names.indexed)
                Stage(id: 's$i', name: n, colour: Vault.stageColours[i]),
            ],
            ownedStageId: 's$owned',
            finishedStageId: 's$finished',
          );
      Future<void> show(Workflow w) => tester.pumpWidget(
        MaterialApp(
          theme: grimdarkTheme,
          home: Scaffold(body: StageStrip(w)),
        ),
      );

      await show(workflow(standard, 1, 6));
      final strip = find.byType(StageStrip);
      expect(parts(tester, strip), [
        's0',
        'tick:s1',
        's1',
        's2',
        's3',
        's4',
        's5',
        'tick:s6',
        's6',
      ]);
      final tick = tester.widget<Container>(
        find.byKey(const ValueKey('tick:s1')),
      );
      expect(
        (tick.decoration! as BoxDecoration).color,
        grimdarkTheme.colorScheme.primary,
      );
      final first = tester.widget<Container>(
        find.descendant(
          of: find.byKey(const ValueKey('s0')),
          matching: find.byType(Container),
        ),
      );
      expect(
        (first.decoration! as BoxDecoration).color,
        stageColour(Vault.stageColours[0]),
      );
      expect(
        find.bySemanticsLabel(
          '7 Stages, owned from Unassembled, finished from Done',
        ),
        findsOneWidget,
      );

      // No wanted Stages: the Owned tick sits at the start.
      await show(workflow(['Primed', 'Painted', 'Based'], 0, 2));
      expect(parts(tester, strip), ['tick:s0', 's0', 's1', 'tick:s2', 's2']);

      // Owned and Finished at one Stage: one tick.
      await show(workflow(['Wishlist', 'Done'], 1, 1));
      expect(parts(tester, strip), ['s0', 'tick:s1', 's1']);
      expect(
        find.bySemanticsLabel('2 Stages, owned from Done, finished from Done'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Workflows list: Stages, who uses each Workflow, Delete disabled while in use',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final vault = (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('app_test');
        final db = PowerSyncDatabase(
          schema: appSchema,
          path: '${dir.path}/vault.db',
        );
        await db.execute(
          "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id, starter) VALUES ('w', 'Standard', 's1', 's6', 1)",
        );
        for (final (i, name) in standard.indexed) {
          await db.execute(
            'INSERT INTO stages (id, workflow_id, name, position) VALUES (?, ?, ?, ?)',
            ['s$i', 'w', name, i],
          );
        }
        await db.execute(
          "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id) VALUES ('p', 'Speed paint', 'p0', 'p2')",
        );
        for (final (i, name) in ['Primed', 'Painted', 'Based'].indexed) {
          await db.execute(
            'INSERT INTO stages (id, workflow_id, name, position) VALUES (?, ?, ?, ?)',
            ['p$i', 'p', name, i],
          );
        }
        for (final name in ['Ultramarines', 'Death Guard']) {
          await db.execute(
            "INSERT INTO collections (id, name, workflow_id) VALUES (?, ?, 'w')",
            [name, name],
          );
        }
        return Vault(SqliteVaultStore(db));
      }))!;
      Future<void> settle() async {
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await tester.pumpWidget(
        MaterialApp(
          theme: grimdarkTheme,
          home: WorkflowsScreen(vault: vault),
        ),
      );
      await settle();

      Finder card(String name) =>
          find.ancestor(of: find.text(name), matching: find.byType(Card));
      final standardCard = card('Standard');
      final speedCard = card('Speed paint');
      expect(
        find.descendant(of: standardCard, matching: find.text('Starter')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: speedCard, matching: find.text('Starter')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: standardCard,
          matching: find.text('7 Stages · Wishlist → Done'),
        ),
        findsOneWidget,
      );
      expect(
        parts(
          tester,
          find.descendant(of: speedCard, matching: find.byType(StageStrip)),
        ),
        ['tick:p0', 'p0', 'p1', 'tick:p2', 'p2'],
      );
      for (final name in ['Ultramarines', 'Death Guard']) {
        expect(
          find.descendant(
            of: standardCard,
            matching: find.widgetWithText(Chip, name),
          ),
          findsOneWidget,
        );
      }
      expect(
        find.descendant(
          of: standardCard,
          matching: find.text('Not used by any Collection'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: speedCard,
          matching: find.text('Not used by any Collection'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: speedCard, matching: find.byType(Chip)),
        findsNothing,
      );
      expect(find.text('New Workflow'), findsOneWidget);

      PopupMenuItem<Object?> deleteItem() =>
          tester.widget<PopupMenuItem<Object?>>(
            find.ancestor(
              of: find.text('Delete'),
              matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
            ),
          );

      await tester.tap(find.byTooltip('Workflow actions for Standard'));
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Used by 2 Collections'), findsOneWidget);
      expect(deleteItem().enabled, isFalse);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Workflow actions for Speed paint'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Used by'), findsNothing);
      expect(deleteItem().enabled, isTrue);
      await tester.runAsync(() async {
        await tester.tap(find.text('Delete'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await settle();
      expect(find.text('Speed paint'), findsNothing);
      expect(find.text('Standard'), findsOneWidget);
    },
  );

  testWidgets(
    'Stage editor: colours, zones, moving the Owned and Finished markers',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final vault = (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('app_test');
        final db = PowerSyncDatabase(
          schema: appSchema,
          path: '${dir.path}/vault.db',
        );
        await db.execute(
          "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id, starter) VALUES ('w', 'Standard', 's1', 's6', 1)",
        );
        for (final (i, name) in standard.indexed) {
          await db.execute(
            'INSERT INTO stages (id, workflow_id, name, position, colour) VALUES (?, ?, ?, ?, ?)',
            ['s$i', 'w', name, i, Vault.stageColours[i]],
          );
        }
        await db.execute(
          "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id) VALUES ('p', 'Speed paint', 'p0', 'p1')",
        );
        for (final (i, name) in ['Primed', 'Painted', 'Based'].indexed) {
          await db.execute(
            'INSERT INTO stages (id, workflow_id, name, position, colour) VALUES (?, ?, ?, ?, ?)',
            ['p$i', 'p', name, i, Vault.stageColours[i]],
          );
        }
        for (final name in ['Ultramarines', 'Death Guard']) {
          await db.execute(
            "INSERT INTO collections (id, name, workflow_id) VALUES (?, ?, 'w')",
            [name, name],
          );
        }
        await db.execute(
          "INSERT INTO collections (id, name, workflow_id) VALUES ('c', 'Curse of Strahd', 'p')",
        );
        return Vault(SqliteVaultStore(db));
      }))!;
      Future<void> settle() async {
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      Future<void> open(String id) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: grimdarkTheme,
            home: WorkflowScreen(vault: vault, workflowId: id),
          ),
        );
        await settle();
      }

      Future<(String, String)> boundaries(String id) async {
        final w = (await tester.runAsync(vault.workflows))!
            .firstWhere((w) => w.id == id);
        return (w.ownedStage.id, w.finishedStage.id);
      }

      /// The editor's rows top to bottom: Stage ids, and `owned`/`finished` for the markers.
      List<String> rows() {
        final keys = {
          for (final w in tester.widgetList<Widget>(
            find.descendant(
              of: find.byType(ReorderableListView),
              matching: find.byWidgetPredicate(
                (w) =>
                    w.key is ValueKey<String> &&
                    !(w.key! as ValueKey<String>).value.contains(':'),
              ),
            ),
          ))
            (w.key! as ValueKey<String>).value,
        }.toList();
        double top(String k) => tester.getTopLeft(find.byKey(ValueKey(k))).dy;
        return keys..sort((a, b) => top(a).compareTo(top(b)));
      }

      Future<void> reorder(int from, int to) async {
        final list = tester.widget<ReorderableListView>(
          find.byType(ReorderableListView),
        );
        await tester.runAsync(() async {
          list.onReorderItem!(from, to);
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await settle();
      }

      Future<void> semanticsAction(String marker, String label) async {
        final node = tester.getSemantics(find.byKey(ValueKey(marker)));
        await tester.runAsync(() async {
          node.owner!.performAction(
            node.id,
            SemanticsAction.customAction,
            CustomSemanticsAction.getIdentifier(
              CustomSemanticsAction(label: label),
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await settle();
      }

      Future<void> clearSnackBars() async {
        ScaffoldMessenger.of(tester.element(find.byType(ReorderableListView)))
            .clearSnackBars();
        await settle();
      }

      Future<void> undo() async {
        await tester.runAsync(() async {
          await tester.tap(find.text('Undo'));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await settle();
        await clearSnackBars();
      }

      final semantics = tester.ensureSemantics();
      await open('w');

      // Used-by strip and the three zones.
      expect(
        find.text(
          'Used by Death Guard and Ultramarines. Changes apply to both.',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.text('WANTED'), findsOneWidget);
      expect(find.text('No Wanted Stages'), findsNothing);
      expect(rows(), [
        's0',
        'owned',
        's1',
        's2',
        's3',
        's4',
        's5',
        'finished',
        's6',
      ]);

      // Each Stage shows its colour.
      for (final (i, _) in standard.indexed) {
        final swatch = tester.widget<Container>(
          find.byKey(ValueKey('swatch:s$i')),
        );
        expect(
          (swatch.decoration! as BoxDecoration).color,
          stageColour(Vault.stageColours[i]),
        );
        // Outlined, so the light Stage colours show on any background.
        expect(
          (swatch.decoration! as BoxDecoration).border,
          Border.all(color: grimdarkTheme.colorScheme.outline, width: 0.5),
        );
      }

      // Semantics actions move a marker by one Stage; Undo restores it.
      await semanticsAction('owned', 'Move down a Stage');
      expect(await boundaries('w'), ('s2', 's6'));
      expect(find.text('Owned from Assembled'), findsOneWidget);
      expect(rows().take(4), ['s0', 's1', 'owned', 's2']);
      await undo();
      expect(await boundaries('w'), ('s1', 's6'));

      await semanticsAction('finished', 'Move up a Stage');
      expect(await boundaries('w'), ('s1', 's5'));
      expect(find.text('Finished from Based'), findsOneWidget);
      await undo();
      expect(await boundaries('w'), ('s1', 's6'));

      // Dropping a marker sets the Stage right below it: Finished above Primed.
      await reorder(7, 4);
      expect(await boundaries('w'), ('s1', 's3'));
      await undo();
      // Owned dropped right above Finished: both start at Done, markers stacked.
      await reorder(1, 6);
      expect(await boundaries('w'), ('s6', 's6'));
      expect(rows().skip(6), ['owned', 'finished', 's6']);
      await undo();
      expect(await boundaries('w'), ('s1', 's6'));

      // Refused: Finished above Owned, and either marker below the last Stage.
      for (final (from, to) in [(7, 0), (1, 8), (7, 8)]) {
        await reorder(from, to);
        expect(await boundaries('w'), ('s1', 's6'));
        expect(find.text('Undo'), findsNothing);
        await clearSnackBars();
      }
      await semanticsAction('finished', 'Move down a Stage');
      expect(await boundaries('w'), ('s1', 's6'));

      // Dragging a Stage still moves it; Owned and Finished stay with their Stages.
      await reorder(4, 2);
      expect(rows().take(4), ['s0', 's3', 'owned', 's1']);

      // Owned at the first Stage: the empty Wanted zone keeps its hint.
      await open('p');
      expect(find.text('WANTED'), findsOneWidget);
      expect(find.text('No Wanted Stages'), findsOneWidget);
      expect(
        find.text(
          'Used by Curse of Strahd. Changes apply to it.',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(rows(), ['owned', 'p0', 'finished', 'p1', 'p2']);
      semantics.dispose();
    },
  );

  testWidgets(
    'Stage sheet: rename and recolour on Save, Owned/Finished switches, add above/below, delete',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final vault = (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('app_test');
        final db = PowerSyncDatabase(
          schema: appSchema,
          path: '${dir.path}/vault.db',
        );
        await db.execute(
          "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id, starter) VALUES ('w', 'Standard', 's1', 's6', 1)",
        );
        for (final (i, name) in standard.indexed) {
          await db.execute(
            'INSERT INTO stages (id, workflow_id, name, position, colour) VALUES (?, ?, ?, ?, ?)',
            ['s$i', 'w', name, i, Vault.stageColours[i]],
          );
        }
        return Vault(SqliteVaultStore(db));
      }))!;
      Future<void> settle() async {
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      Future<void> tapAndWait(Finder f) async {
        await tester.runAsync(() async {
          await tester.tap(f);
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await settle();
      }

      Future<Workflow> workflow() async =>
          (await tester.runAsync(vault.workflows))!.single;

      SwitchListTile toggle(String title) => tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, title),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: grimdarkTheme,
          home: WorkflowScreen(vault: vault, workflowId: 'w'),
        ),
      );
      await settle();
      expect(find.byTooltip('Stage actions for Primed'), findsNothing);

      // Tapping a Stage opens its sheet: name, the preset colours, and both switches off but allowed.
      await tapAndWait(find.text('Primed'));
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Primed'), findsOneWidget);
      for (final c in Vault.stageColours) {
        expect(find.byTooltip(c), findsOneWidget);
      }
      expect(toggle('Owned from here').value, isFalse);
      expect(toggle('Owned from here').onChanged, isNotNull);
      expect(find.text('Now from Unassembled'), findsOneWidget);
      expect(toggle('Finished from here').value, isFalse);
      expect(find.text('Now from Done'), findsOneWidget);

      // Cancel changes nothing.
      await tester.enterText(find.byType(TextField), 'Ignored');
      await tapAndWait(find.text('Cancel'));
      expect(find.byType(BottomSheet), findsNothing);
      expect((await workflow()).stages[3].name, 'Primed');

      // Save commits name, colour and the Owned Stage together.
      await tapAndWait(find.text('Primed'));
      await tester.enterText(find.byType(TextField), 'Undercoated');
      await tester.tap(find.byTooltip(Vault.stageColours[9]));
      await tester.tap(find.text('Owned from here'));
      await tester.pump();
      expect(toggle('Owned from here').value, isTrue);
      await tapAndWait(find.text('Save'));
      var w = await workflow();
      expect(w.stages[3].name, 'Undercoated');
      expect(w.stages[3].colour, Vault.stageColours[9]);
      expect(w.ownedStage.id, 's3');
      expect(find.text('Owned from Undercoated'), findsOneWidget);
      ScaffoldMessenger.of(tester.element(find.byType(ReorderableListView)))
          .clearSnackBars();
      await settle();

      // The Owned Stage's own switch is on and can't be turned off.
      await tapAndWait(find.text('Undercoated'));
      expect(toggle('Owned from here').value, isTrue);
      expect(toggle('Owned from here').onChanged, isNull);
      await tapAndWait(find.text('Cancel'));

      // Setting the Finished Stage via its switch.
      await tapAndWait(find.text('Based'));
      await tester.tap(find.text('Finished from here'));
      await tester.pump();
      await tapAndWait(find.text('Save'));
      expect((await workflow()).finishedStage.id, 's5');

      // Forbidden switches are disabled, with the reason.
      await tapAndWait(find.text('Done'));
      expect(toggle('Owned from here').onChanged, isNull);
      expect(find.text('Comes after the Finished Stage'), findsOneWidget);
      await tapAndWait(find.text('Cancel'));
      await tapAndWait(find.text('Wishlist'));
      expect(toggle('Finished from here').onChanged, isNull);
      expect(find.text('Comes before the Owned Stage'), findsOneWidget);
      await tapAndWait(find.text('Cancel'));

      // Add above and below.
      await tapAndWait(find.text('Assembled'));
      await tapAndWait(find.text('Add above'));
      await tester.enterText(find.byType(TextField), 'Built');
      await tapAndWait(find.text('Save'));
      await tapAndWait(find.text('Assembled'));
      await tapAndWait(find.text('Add below'));
      await tester.enterText(find.byType(TextField), 'Washed');
      await tapAndWait(find.text('Save'));
      expect(
        [for (final s in (await workflow()).stages) s.name],
        [
          'Wishlist',
          'Unassembled',
          'Built',
          'Assembled',
          'Washed',
          'Undercoated',
          'Painted',
          'Based',
          'Done',
        ],
      );

      // Delete opens the Delete Stage dialog.
      await tapAndWait(find.text('Undercoated'));
      await tapAndWait(find.text('Delete'));
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Delete Undercoated?'), findsOneWidget);
      expect(find.text('Owned from'), findsOneWidget);
    },
  );

  testWidgets(
    'Delete Stage dialog: next Stage by default, only allowed Owned/Finished, names the Collections, previews',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final vault = (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('app_test');
        final db = PowerSyncDatabase(
          schema: appSchema,
          path: '${dir.path}/vault.db',
        );
        // Owned from Unassembled, Finished from Painted.
        await db.execute(
          "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id, starter) VALUES ('w', 'Standard', 's1', 's4', 1)",
        );
        for (final (i, name) in standard.indexed) {
          await db.execute(
            'INSERT INTO stages (id, workflow_id, name, position, colour) VALUES (?, ?, ?, ?, ?)',
            ['s$i', 'w', name, i, Vault.stageColours[i]],
          );
        }
        final vault = Vault(SqliteVaultStore(db));
        for (final (c, stage) in [
          ('Ultramarines', 's1'),
          ('Death Guard', 's1'),
          ('Kill Team', 's6'),
        ]) {
          final collection = await vault.createCollection(c, workflowId: 'w');
          await vault.addBatch(
            collection,
            name: 'Squad',
            modelCount: 5,
            stageId: stage,
          );
        }
        return vault;
      }))!;
      Future<void> settle() async {
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      Future<void> tapAndWait(Finder f) async {
        await tester.runAsync(() async {
          await tester.tap(f);
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await settle();
      }

      Future<Workflow> workflow() async =>
          (await tester.runAsync(vault.workflows))!.single;
      DropdownMenu<Stage> picker(String label) =>
          tester.widget<DropdownMenu<Stage>>(
            find.widgetWithText(DropdownMenu<Stage>, label),
          );
      List<String> choices(String label) => [
        for (final e in picker(label).dropdownMenuEntries) e.label,
      ];
      Future<void> delete(String stage) async {
        await tapAndWait(find.text(stage));
        await tapAndWait(find.text('Delete'));
      }

      final preview = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(StageStrip),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: grimdarkTheme,
          home: WorkflowScreen(vault: vault, workflowId: 'w'),
        ),
      );
      await settle();

      // The Owned Stage holding Units: names their Collections, moves them to the next Stage by default, and offers
      // only Owned Stages at or before Painted (the Finished Stage).
      await delete('Unassembled');
      expect(find.text('Delete Unassembled?'), findsOneWidget);
      expect(
        find.text(
          '2 Units across Death Guard and Ultramarines are at this Stage. '
          'It is also the Owned Stage.',
        ),
        findsOneWidget,
      );
      expect(
        picker('Move their models to').initialSelection?.name,
        'Assembled',
      );
      expect(choices('Move their models to'), [
        'Wishlist',
        'Assembled',
        'Primed',
        'Painted',
        'Based',
        'Done',
      ]);
      expect(picker('Owned from').initialSelection?.name, 'Assembled');
      expect(choices('Owned from'), [
        'Wishlist',
        'Assembled',
        'Primed',
        'Painted',
      ]);
      expect(find.text('Finished from'), findsNothing);
      expect(parts(tester, preview), [
        's0',
        'tick:s2',
        's2',
        's3',
        'tick:s4',
        's4',
        's5',
        's6',
      ]);

      // Picking another Owned Stage updates the preview; Delete applies it.
      await tapAndWait(find.text('Owned from'));
      await tapAndWait(find.widgetWithText(MenuItemButton, 'Primed').last);
      expect(picker('Owned from').initialSelection?.name, 'Primed');
      expect(parts(tester, preview), [
        's0',
        's2',
        'tick:s3',
        's3',
        'tick:s4',
        's4',
        's5',
        's6',
      ]);
      await tapAndWait(find.widgetWithText(TextButton, 'Delete'));
      var w = await workflow();
      expect(w.stages.map((s) => s.id), ['s0', 's2', 's3', 's4', 's5', 's6']);
      expect(w.ownedStage.id, 's3');
      expect(
        [
          for (final b in (await tester.runAsync(() => vault.batchesAt('s2')))!)
            b.name,
        ],
        ['Squad', 'Squad'],
      );

      // The Finished Stage: only Stages at or after Primed (the Owned Stage), defaulting to the next.
      await delete('Painted');
      expect(find.text('It is the Finished Stage.'), findsOneWidget);
      expect(find.text('Move their models to'), findsNothing);
      expect(picker('Finished from').initialSelection?.name, 'Based');
      expect(choices('Finished from'), ['Primed', 'Based', 'Done']);
      await tapAndWait(find.text('Cancel'));
      expect((await workflow()).stages.length, 6);

      // The last Stage moves its Units to the previous one by default.
      await delete('Done');
      expect(
        find.text('1 Unit in Kill Team is at this Stage.'),
        findsOneWidget,
      );
      expect(picker('Move their models to').initialSelection?.name, 'Based');
      await tapAndWait(find.widgetWithText(TextButton, 'Delete'));
      w = await workflow();
      expect(w.stages.last.id, 's5');
      expect((await tester.runAsync(() => vault.batchesAt('s5')))!.length, 1);
    },
  );

  testWidgets(
    'Switch Workflow: pick by strip, map Stages by zone, warn on a zone change',
    (tester) async {
      // Phone width: the mapping rows must fit 320dp.
      tester.view.physicalSize = const Size(320, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (vault, ultramarines) = (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('app_test');
        final db = PowerSyncDatabase(
          schema: appSchema,
          path: '${dir.path}/vault.db',
        );
        // Standard: owned from Unassembled, finished from Done. Kitbash: owned from Ordered, finished from Painted.
        // Speed paint: owned from Primed, finished from Based.
        for (final (id, name, stages, owned, finished) in [
          ('w', 'Standard', standard, 1, 6),
          (
            'k',
            'Kitbash',
            ['Wishlist', 'Ordered', 'Built', 'Sprayed', 'Painted', 'Varnished'],
            1,
            4,
          ),
          ('p', 'Speed paint', ['Primed', 'Pink', 'Based'], 0, 2),
        ]) {
          await db.execute(
            'INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id, starter) VALUES (?, ?, ?, ?, ?)',
            [id, name, '$id$owned', '$id$finished', id == 'w' ? 1 : 0],
          );
          for (final (i, s) in stages.indexed) {
            await db.execute(
              'INSERT INTO stages (id, workflow_id, name, position, colour) VALUES (?, ?, ?, ?, ?)',
              ['$id$i', id, s, i, Vault.stageColours[i]],
            );
          }
        }
        final vault = Vault(SqliteVaultStore(db));
        await vault.createCollection('Kill Team', workflowId: 'k');
        final c = await vault.createCollection('Ultramarines', workflowId: 'w');
        for (final (name, stage) in [
          ('Captain', 'w0'),
          ('Intercessors', 'w1'),
          ('Hellblasters', 'w1'),
          ('Terminators', 'w3'),
          ('Dreadnought', 'w4'),
          ('Librarian', 'w6'),
        ]) {
          await vault.addBatch(c, name: name, modelCount: 1, stageId: stage);
        }
        return (vault, c);
      }))!;
      Future<void> settle() async {
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      Future<void> tapAndWait(Finder f) async {
        await tester.runAsync(() async {
          await tester.tap(f);
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await settle();
      }

      DropdownMenu<Stage> target(String fromId) => tester
          .widget<DropdownMenu<Stage>>(find.byKey(ValueKey('to:$fromId')));
      final dialog = find.byType(AlertDialog);

      await tester.pumpWidget(
        MaterialApp(
          theme: grimdarkTheme,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => switchWorkflow(context, vault, ultramarines),
                child: const Text('switch'),
              ),
            ),
          ),
        ),
      );
      await tapAndWait(find.text('switch'));

      // Pick: radio rows with each other Workflow's strip, range and users.
      expect(find.text('Switch Ultramarines to'), findsOneWidget);
      expect(find.text('Now on Standard.'), findsOneWidget);
      expect(find.byType(RadioListTile<Workflow>), findsNWidgets(2));
      expect(
        find.descendant(of: dialog, matching: find.byType(StageStrip)),
        findsNWidgets(2),
      );
      expect(
        find.text('Wishlist → Varnished · used by Kill Team'),
        findsOneWidget,
      );
      expect(find.text('Primed → Based · not used'), findsOneWidget);
      await tapAndWait(find.text('Kitbash'));
      await tapAndWait(find.text('Next'));

      // Map: same name first, else the target's Stage in the same zone; Unit counts per source Stage.
      expect(find.text('Switch to Kitbash?'), findsOneWidget);
      expect(target('w0').initialSelection?.name, 'Wishlist');
      expect(target('w1').initialSelection?.name, 'Ordered');
      expect(target('w3').initialSelection?.name, 'Ordered');
      expect(target('w4').initialSelection?.name, 'Painted');
      expect(target('w6').initialSelection?.name, 'Painted');
      expect(find.text('2 Units'), findsOneWidget);
      expect(find.text('1 Unit'), findsNWidgets(4));
      // Painted keeps its name but moves from the Owned to the Finished zone.
      expect(find.text('Owned models would count as finished'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber), findsOneWidget);

      // Moving the finished models back to Wishlist warns too, but stays allowed.
      await tapAndWait(find.byKey(const ValueKey('to:w6')));
      await tapAndWait(find.widgetWithText(MenuItemButton, 'Wishlist').last);
      expect(
        find.text('Finished models would count as wanted'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.warning_amber), findsNWidgets(2));
      await tapAndWait(find.text('Switch'));

      final moved = (await tester.runAsync(
        () async => [
          for (final c in await vault.collections())
            if (c.id == ultramarines.id)
              for (final b in await vault.batchesOf(c))
                '${b.name}:${b.stageId}',
        ],
      ))!;
      expect(moved..sort(), [
        'Captain:k0',
        'Dreadnought:k4',
        'Hellblasters:k1',
        'Intercessors:k1',
        'Librarian:k0',
        'Terminators:k1',
      ]);
    },
  );
}
