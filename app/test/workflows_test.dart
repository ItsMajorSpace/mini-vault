import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
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
}
