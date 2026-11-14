// ignore_for_file: experimental_member_use

import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gotrue/gotrue.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/main.dart';
import 'package:mini_vault/photos.dart';
import 'package:mini_vault/progress.dart';
import 'package:mini_vault/section.dart';
import 'package:mini_vault/stage_strip.dart';
import 'package:mini_vault/theme.dart';
import 'package:mini_vault/unit.dart';
import 'package:mini_vault/workflows.dart';
import 'package:powersync/attachments/attachments.dart';
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
      expect(find.byTooltip('2 changes waiting to sync'), findsOneWidget);
      expect(find.byTooltip('New Collection'), findsOneWidget);
      expect(
        find.text('OTHER'),
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
      final terrain = await vault.createCollection('Terrain');
      await vault.addBatch(terrain, name: 'Ruins', modelCount: 2, stageId: 's');
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
      'WARHAMMER',
      'Orks',
      'Ultramarines',
      'OTHER',
      'Terrain',
    ];
    final tops = [for (final t in order) tester.getTopLeft(find.text(t)).dy];
    expect(tops, [...tops]..sort(), reason: 'in the order $order');
    // Models, but no move yet.
    expect(find.text('RECENTLY PAINTED'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => dir.delete(recursive: true));
  });

  testWidgets(
    'a Game System group collapses to a summary line, remembered per device',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('app_test'),
      ))!;
      final file = File('${dir.path}/collapsed.txt');
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
        final ultramarines = await vault.createCollection(
          'Ultramarines',
          gameSystem: 'Warhammer',
        );
        await vault.addBatch(
          ultramarines,
          name: 'Intercessors',
          modelCount: 2,
          stageId: 's',
        );
        final orks = await vault.createCollection(
          'Orks',
          gameSystem: 'warhammer',
        );
        await vault.addBatch(orks, name: 'Boyz', modelCount: 3, stageId: 's');
        return db;
      }))!;

      Future<void> open() async {
        final collapsed = (await tester.runAsync(
          () => CollapsedGroups.load(file),
        ))!;
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            home: CollectionsScreen(
              vault: Vault(SqliteVaultStore(db)),
              db: db,
              collapsed: collapsed,
            ),
          ),
        );
        for (var i = 0; i < 60; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      Finder header(bool expanded) => find.byWidgetPredicate(
        (w) => w is SectionHeader && w.expanded == expanded,
      );

      await open();
      expect(find.text('Orks'), findsOneWidget);
      expect(find.text('Ultramarines'), findsOneWidget);
      expect(header(true), findsNWidgets(2)); // Warhammer and Other.
      expect(find.text('2 Collections · 5 / 5 finished'), findsNothing);

      await tester.tap(find.text('WARHAMMER'));
      await tester.pump();
      expect(find.text('Orks'), findsNothing);
      expect(find.text('Ultramarines'), findsNothing);
      expect(find.text('2 Collections · 5 / 5 finished'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
      expect(header(false), findsOneWidget);
      expect(
        find.ancestor(
          of: find.text('WARHAMMER'),
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.expanded == false,
          ),
        ),
        findsOneWidget,
      );
      expect(find.text('Terrain'), findsOneWidget); // Other stays open.

      await open(); // The screen again, from the same file.
      expect(find.text('Orks'), findsNothing);
      expect(find.text('2 Collections · 5 / 5 finished'), findsOneWidget);

      await tester.tap(find.text('WARHAMMER'));
      await tester.pump();
      expect(find.text('Orks'), findsOneWidget);
      expect(find.text('Ultramarines'), findsOneWidget);
      expect(find.text('2 Collections · 5 / 5 finished'), findsNothing);

      await tester.tap(find.text('OTHER'));
      await tester.pump();
      expect(find.text('Terrain'), findsNothing);
      expect(find.text('1 Collection · 0 / 0 finished'), findsOneWidget);

      await tester.runAsync(() => file.delete()); // A fresh file: all open.
      await open();
      expect(find.text('Terrain'), findsOneWidget);
      expect(find.text('Orks'), findsOneWidget);
      expect(header(false), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => dir.delete(recursive: true));
    },
  );

  testWidgets(
    'search filters by Collection or Game System name, opens collapsed groups and ends with back',
    (tester) async {
      // Tall enough to build every row of the lazy list.
      tester.view.physicalSize = const Size(2400, 4800);
      addTearDown(tester.view.resetPhysicalSize);
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('app_test'),
      ))!;
      final file = File('${dir.path}/collapsed.txt');
      final (db, collapsed) = (await tester.runAsync(() async {
        await file.writeAsString('game-system:warhammer\n');
        final db = PowerSyncDatabase(
          schema: appSchema,
          path: '${dir.path}/vault.db',
        );
        await db.execute(
          "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id) VALUES ('w', 'Starter', 's0', 's1')",
        );
        for (final (i, name) in ['Wishlist', 'Painted'].indexed) {
          await db.execute(
            'INSERT INTO stages (id, workflow_id, name, position) VALUES (?, ?, ?, ?)',
            ['s$i', 'w', name, i],
          );
        }
        final vault = Vault(SqliteVaultStore(db));
        final terrain = await vault.createCollection('Terrain');
        await vault.addBatch(
          terrain,
          name: 'Ruins',
          modelCount: 2,
          stageId: 's0',
        );
        await vault.moveModels(terrain, 'Ruins', 's0', 's1', 1);
        await vault.createCollection('Space Marines', gameSystem: 'Warhammer');
        await vault.createCollection('Orks', gameSystem: 'Warhammer');
        await vault.createCollection('Necrons', gameSystem: 'Grimdark Future');
        await vault.createCollection(
          'Death Guard',
          gameSystem: 'Grimdark Future',
        );
        return (db, await CollapsedGroups.load(file));
      }))!;
      await tester.pumpWidget(
        MaterialApp(
          home: CollectionsScreen(
            vault: Vault(SqliteVaultStore(db)),
            db: db,
            collapsed: collapsed,
          ),
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 60; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      Future<void> search(String query) async {
        await tester.enterText(find.byType(TextField), query);
        await settle();
      }

      await settle();
      expect(find.text('Orks'), findsNothing); // Warhammer is collapsed.
      expect(find.text('RECENTLY PAINTED'), findsOneWidget);

      await tester.tap(find.byTooltip('Search'));
      await tester.pump();
      expect(find.text('Search Collections'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).autofocus,
        isTrue,
      );

      // A Game System match keeps all its Collections.
      await search('grim');
      expect(find.text('GRIMDARK FUTURE'), findsOneWidget);
      expect(find.text('Necrons'), findsOneWidget);
      expect(find.text('Death Guard'), findsOneWidget);
      expect(find.text('WARHAMMER'), findsNothing);
      expect(find.text('Terrain'), findsNothing);
      expect(find.text('RECENTLY PAINTED'), findsNothing);
      expect(find.byTooltip('New Collection'), findsNothing);

      // Otherwise only the matching Collections, collapsed groups open, no chevrons.
      await search('ORK');
      expect(find.text('WARHAMMER'), findsOneWidget);
      expect(find.text('Orks'), findsOneWidget);
      expect(find.text('Space Marines'), findsNothing);
      expect(find.text('Necrons'), findsNothing);
      expect(
        find.byWidgetPredicate((w) => w is SectionHeader && w.expanded != null),
        findsNothing,
      );
      final orks = tester.widget<Text>(find.text('Orks')).textSpan!;
      final bold = <String>[];
      orks.visitChildren((span) {
        if (span is TextSpan && span.style?.fontWeight == FontWeight.bold) {
          bold.add(span.text!);
        }
        return true;
      });
      expect(bold, ['Ork']);

      // No matches: Clear search empties the field and keeps search open.
      await search('tyranids');
      expect(find.text('No Collections match "tyranids"'), findsOneWidget);
      expect(
        find.text('Search looks at Collection names and Game Systems.'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Clear search'));
      await settle();
      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
      );
      expect(find.text('No Collections match "tyranids"'), findsNothing);

      // Back ends search: the full list as before, Warhammer collapsed again.
      await search('ork');
      await tester.tap(find.byTooltip('End search'));
      await settle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Collections'), findsOneWidget);
      expect(find.text('Orks'), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
      expect(
        find.text('Terrain'),
        findsNWidgets(2),
      ); // Its row and under Ruins.
      expect(find.text('RECENTLY PAINTED'), findsOneWidget);
      expect(find.byTooltip('New Collection'), findsOneWidget);
      expect(collapsed.isCollapsed('game-system:warhammer'), isTrue);

      // So does system back.
      await tester.tap(find.byTooltip('Search'));
      await tester.pump();
      await search('ork');
      await tester.binding.handlePopRoute();
      await settle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Necrons'), findsOneWidget);
      expect(find.text('Orks'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => dir.delete(recursive: true));
    },
  );

  testWidgets(
    'Collection rows show a Progress ring and line in one card per group, open the Collection, and stay in search',
    (tester) async {
      final db = (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('app_test');
        final db = PowerSyncDatabase(
          schema: appSchema,
          path: '${dir.path}/vault.db',
        );
        await db.execute(
          "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id) VALUES ('w', 'Starter', 's1', 's2')",
        );
        for (final (i, name) in ['Wishlist', 'Built', 'Painted'].indexed) {
          await db.execute(
            'INSERT INTO stages (id, workflow_id, name, position) VALUES (?, ?, ?, ?)',
            ['s$i', 'w', name, i],
          );
        }
        final vault = Vault(SqliteVaultStore(db));
        final marines = await vault.createCollection(
          'Space Marines',
          gameSystem: 'Warhammer',
        );
        for (final (name, count, stage) in [
          ('Intercessors', 2, 's2'),
          ('Scouts', 1, 's1'),
          ('Terminators', 4, 's0'),
        ]) {
          await vault.addBatch(
            marines,
            name: name,
            modelCount: count,
            stageId: stage,
          );
        }
        await vault.createCollection('Orks', gameSystem: 'Warhammer');
        return db;
      }))!;
      await tester.pumpWidget(
        MaterialApp(
          home: CollectionsScreen(vault: Vault(SqliteVaultStore(db)), db: db),
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 60; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      Finder row(String name) =>
          find.ancestor(of: find.text(name), matching: find.byType(InkWell));
      void expectRow(String name, String percent, String words) {
        final r = row(name);
        expect(
          find.descendant(of: r, matching: find.byType(ProgressRing)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: r, matching: find.text(percent)),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: r,
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Semantics && w.properties.label == '$percent finished',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: r, matching: find.text(words)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: r, matching: find.byIcon(Icons.chevron_right)),
          findsOneWidget,
        );
        expect(tester.getSize(r).height, greaterThanOrEqualTo(76));
      }

      await settle();
      // Owned from Built: 2 of 3 painted, Terminators still wanted.
      expectRow('Space Marines', '67%', '2 / 3 finished · 4 wanted');
      expectRow('Orks', '0%', '0 / 0 finished');
      // Both rows in the group's one card.
      final card = find.ancestor(
        of: find.text('Orks'),
        matching: find.byType(Card),
      );
      expect(
        find.descendant(of: card, matching: find.text('Space Marines')),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Search'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'mar');
      await settle();
      expect(find.text('Orks'), findsNothing);
      expectRow('Space Marines', '67%', '2 / 3 finished · 4 wanted');
      final bold = <String>[];
      tester.widget<Text>(find.text('Space Marines')).textSpan!.visitChildren((
        span,
      ) {
        if (span is TextSpan && span.style?.fontWeight == FontWeight.bold) {
          bold.add(span.text!);
        }
        return true;
      });
      expect(bold, ['Mar']);

      await tester.tap(find.text('Space Marines'));
      await settle();
      expect(find.byType(CollectionScreen), findsOneWidget);
      expect(find.text('Intercessors'), findsOneWidget);
    },
  );

  testWidgets(
    'the Collection dialog suggests Game Systems in use and returns the fields',
    (tester) async {
      (String, String?, String, String)? result;
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

      expect(result, ('Orks', null, 'Warhammer 40k', ''));
    },
  );

  testWidgets(
    'the New Collection Workflow picker shows each Workflow\'s Stage strip',
    (tester) async {
      Workflow workflow(String id, String name, List<String> stages) =>
          Workflow(
            id: id,
            name: name,
            stages: [
              for (final (i, s) in stages.indexed)
                Stage(id: '$id$i', name: s, colour: Vault.stageColours[i]),
            ],
            ownedStageId: '${id}0',
            finishedStageId: '$id${stages.length - 1}',
          );
      (String, String?, String, String)? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showDialog(
                context: context,
                builder: (_) => NewCollectionDialog(
                  workflows: [
                    workflow('w', 'Standard', ['Wishlist', 'Done']),
                    workflow('k', 'Kitbash', ['Ordered', 'Built', 'Painted']),
                  ],
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      StageStrip selected() => tester.widget<StageStrip>(
        find.descendant(of: dialog, matching: find.byType(StageStrip)).first,
      );
      // The starter is preselected, its strip under the field.
      expect(selected().workflow.name, 'Standard');

      await tester.tap(find.widgetWithText(DropdownMenu<Workflow>, 'Workflow'));
      await tester.pumpAndSettle();
      for (final name in ['Standard', 'Kitbash']) {
        expect(
          find.descendant(
            of: find.widgetWithText(MenuItemButton, name).last,
            matching: find.byType(StageStrip),
          ),
          findsOneWidget,
        );
      }
      await tester.tap(find.widgetWithText(MenuItemButton, 'Kitbash').last);
      await tester.pumpAndSettle();
      expect(selected().workflow.name, 'Kitbash');

      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Orks');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(result?.$2, 'k');
    },
  );

  testWidgets('shows a Collection\'s Units in order, with model counts', (
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
        await vault.addBatch(
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
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    // One row per Unit, a new one last, counting the models of all its Batches.
    final rows = [
      'Intercessors',
      '15 models',
      'Captain',
      '1 model',
      'Terminators',
      '5 models',
    ];
    final ys = [for (final text in rows) tester.getTopLeft(find.text(text)).dy];
    expect(ys, orderedEquals([...ys]..sort()));
    // One per Unit, and the Progress drawer's.
    expect(find.byType(StageBar), findsNWidgets(4));
    // Owned and Finished Stage are both Unassembled: Primed counts as finished, Wishlist as wanted.
    expect(
      find.text('3 Units · 11 owned · 11 finished · 10 wanted'),
      findsOneWidget,
    );
    // Each Unit's bar: solid owned segments, then wanted ones outlined; together they fill the bar.
    List<(String, double)> segments(String unit) {
      final bar = find.descendant(
        of: find.ancestor(of: find.text(unit), matching: find.byType(ListTile)),
        matching: find.byType(StageBar),
      );
      final width = tester.getSize(bar).width;
      return [
        for (final e in tester.elementList(
          find.descendant(
            of: find.descendant(of: bar, matching: find.byType(Expanded)),
            matching: find.byWidgetPredicate(
              (w) => w is ColoredBox || w is DecoratedBox,
            ),
          ),
        ))
          (
            e.widget is ColoredBox ? 'owned' : 'wanted outlined',
            (tester.getSize(find.byElementPredicate((x) => x == e)).width /
                    width *
                    100)
                .roundToDouble(),
          ),
      ];
    }

    // Percent of the bar.
    expect(segments('Terminators'), [('wanted outlined', 100.0)]);
    expect(segments('Intercessors'), [
      ('owned', 67.0),
      ('wanted outlined', 33.0),
    ]);
    final outline =
        tester
                .widget<DecoratedBox>(
                  find
                      .descendant(
                        of: find.descendant(
                          of: find.ancestor(
                            of: find.text('Terminators'),
                            matching: find.byType(ListTile),
                          ),
                          matching: find.byType(StageBar),
                        ),
                        matching: find.byType(DecoratedBox),
                      )
                      .last,
                )
                .decoration
            as BoxDecoration;
    expect(outline.color, isNull);
    expect(
      outline.border,
      Border.all(color: stageColour(Vault.stageColours.first)),
    );
    expect(find.byTooltip('Add models'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Unit rows lead with the newest photo on this device, else a placeholder',
    (tester) async {
      final (db, vault, collection, files) = (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('app_test');
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
        final collection = await vault.createCollection('Space Marines');
        final other = await vault.createCollection('Dark Angels');
        Future<(String, String)> batch(Collection c, String name) async {
          await vault.addBatch(c, name: name, modelCount: 1, stageId: 's');
          return (c.id, name);
        }

        // (Unit, file, queue timestamp, downloaded): the newest file is the one with the latest timestamp.
        final photos = [
          (await batch(collection, 'Intercessors'), 'old', 1, true),
          (await batch(collection, 'Intercessors'), 'new', 2, true),
          (await batch(other, 'Intercessors'), 'other', 9, true),
          (await batch(collection, 'Captain'), 'here', 1, true),
          (await batch(collection, 'Captain'), 'incoming', 2, false),
        ];
        await batch(collection, 'Terminators');
        for (final (i, ((collectionId, unit), file, ts, downloaded))
            in photos.indexed) {
          await SqliteVaultStore.insertPhoto(
            db,
            Photo(
              id: 'p$i',
              collectionId: collectionId,
              unit: unit,
              fileId: file,
            ),
          );
          await db.execute(
            'INSERT INTO ${photoQueueTable.name} (id, filename, local_uri, timestamp, state, has_synced) '
            'VALUES (?, ?, ?, ?, ?, 1)',
            [
              file,
              '$file.jpg',
              downloaded ? '$file.jpg' : null,
              ts,
              (downloaded
                      ? AttachmentState.synced
                      : AttachmentState.queuedDownload)
                  .toInt(),
            ],
          );
        }
        final files = PhotoFiles(
          db,
          GoTrueClient(url: 'http://localhost'),
          Directory('${dir.path}/photos'),
        );
        return (db, vault, collection, files);
      }))!;

      await tester.pumpWidget(
        MaterialApp(
          home: CollectionScreen(
            vault: vault,
            db: db,
            collection: collection,
            photos: files,
          ),
        ),
      );
      for (var i = 0; i < 60; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }

      Finder inRow(String unit, Finder matching) => find.descendant(
        of: find.ancestor(of: find.text(unit), matching: find.byType(ListTile)),
        matching: matching,
      );
      final image = tester.widget<Image>(
        inRow('Intercessors', find.byType(Image)),
      );
      expect((image.image as ResizeImage).imageProvider, isA<FileImage>());
      expect(
        ((image.image as ResizeImage).imageProvider as FileImage).file.path,
        '${files.dir.path}/new.jpg',
      );
      // The newest is not downloaded yet: placeholder, not an older photo.
      for (final unit in ['Captain', 'Terminators']) {
        expect(inRow(unit, find.byType(Image)), findsNothing);
        expect(
          tester
              .widget<Icon>(inRow(unit, find.byIcon(Icons.add_a_photo)))
              .semanticLabel,
          'Add photo',
        );
      }
      // Every row's leading square is the same size, its own tap target.
      for (final unit in ['Intercessors', 'Captain', 'Terminators']) {
        expect(
          tester.getSize(inRow(unit, find.byType(UnitThumbnail))),
          const Size.square(56),
        );
      }

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'tapping a thumbnail opens its photos at the newest, a placeholder offers Take/Choose; the row opens the Unit',
    (tester) async {
      final (db, vault, collection, files) = (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('app_test');
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
        final collection = await vault.createCollection('Space Marines');
        for (final name in ['Intercessors', 'Captain']) {
          await vault.addBatch(
            collection,
            name: name,
            modelCount: 1,
            stageId: 's',
          );
        }
        final photosDir = await Directory('${dir.path}/photos').create();
        // (id, file, queue timestamp): 'new' is the newest, though second by id.
        for (final (id, file, ts) in [('p0', 'old', 1), ('p1', 'new', 2)]) {
          await File('${photosDir.path}/$file.jpg')
              .writeAsBytes(img.encodePng(img.Image(width: 2, height: 2)));
          await SqliteVaultStore.insertPhoto(
            db,
            Photo(
              id: id,
              collectionId: collection.id,
              unit: 'Intercessors',
              fileId: file,
            ),
          );
          await db.execute(
            'INSERT INTO ${photoQueueTable.name} (id, filename, local_uri, timestamp, state, has_synced) '
            'VALUES (?, ?, ?, ?, ?, 1)',
            [
              file,
              '$file.jpg',
              '$file.jpg',
              ts,
              AttachmentState.synced.toInt(),
            ],
          );
        }
        final files = PhotoFiles(
          db,
          GoTrueClient(url: 'http://localhost'),
          photosDir,
        );
        return (db, vault, collection, files);
      }))!;

      Future<void> settle() async {
        for (var i = 0; i < 60; i++) {
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

      await tester.pumpWidget(
        MaterialApp(
          home: CollectionScreen(
            vault: vault,
            db: db,
            collection: collection,
            photos: files,
          ),
        ),
      );
      await settle();
      Finder thumbnail(String unit) => find.descendant(
        of: find.ancestor(of: find.text(unit), matching: find.byType(ListTile)),
        matching: find.byType(UnitThumbnail),
      );

      // A photo opens the viewer at the newest, swiping through all the Unit's photos.
      await tapAndWait(thumbnail('Intercessors'));
      expect(find.text('2 of 2'), findsOneWidget);
      expect(find.byTooltip('Remove photo'), findsOneWidget);
      await tester.tap(find.byType(CloseButton));
      await settle();

      // The placeholder offers the Unit screen's Take/Choose; cancelling adds nothing.
      await tapAndWait(thumbnail('Captain'));
      expect(find.text('Take a photo'), findsOneWidget);
      expect(find.text('Add a photo from the gallery'), findsOneWidget);
      expect(find.byType(UnitScreen), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await settle();
      expect(find.text('Take a photo'), findsNothing);
      final photos = (await tester.runAsync(
        () => files.watch(collection.id, 'Captain').first,
      ))!;
      expect(photos, isEmpty);

      // The rest of the row still opens the Unit screen.
      await tapAndWait(find.text('Captain'));
      expect(find.byType(UnitScreen), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Recently painted lists the last 3 moved Units, newest first; tapping one opens its Move sheet, its chevron the Unit',
    (tester) async {
      final (db, vault) = (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('app_test');
        final db = PowerSyncDatabase(
          schema: appSchema,
          path: '${dir.path}/vault.db',
        );
        await db.execute(
          "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id) VALUES ('w', 'Starter', 's1', 's2')",
        );
        for (final (i, name) in ['Wishlist', 'Primed', 'Painted'].indexed) {
          await db.execute(
            'INSERT INTO stages (id, workflow_id, name, position) VALUES (?, ?, ?, ?)',
            ['s$i', 'w', name, i],
          );
        }
        final vault = Vault(SqliteVaultStore(db));
        final marines = await vault.createCollection('Space Marines');
        final orks = await vault.createCollection('Orks');
        for (final (c, name) in [
          (marines, 'Intercessors'),
          (marines, 'Captain'),
          (orks, 'Boyz'),
          (orks, 'Nobz'),
        ]) {
          await vault.addBatch(c, name: name, modelCount: 5, stageId: 's1');
        }
        for (final (c, name) in [
          (marines, 'Intercessors'),
          (orks, 'Nobz'),
          (marines, 'Captain'),
          (orks, 'Boyz'),
        ]) {
          await vault.moveModels(c, name, 's1', 's2', 2);
        }
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

      await tester.pumpWidget(
        MaterialApp(
          home: CollectionsScreen(vault: vault, db: db),
        ),
      );
      await settle();
      expect(find.text('RECENTLY PAINTED'), findsOneWidget);
      // Cards side by side, newest first.
      final order = ['Boyz', 'Captain', 'Nobz'];
      final lefts = [for (final t in order) tester.getTopLeft(find.text(t)).dx];
      expect(lefts, [...lefts]..sort(), reason: 'in the order $order');
      expect(find.text('Intercessors'), findsNothing);
      // Each card with its Collection, Stage bar and the Stage a tap moves from.
      Finder inCard(String name, Finder f) => find.descendant(
        of: find.ancestor(
          of: find.text(name),
          matching: find.byType(RecentUnitCard),
        ),
        matching: f,
      );
      expect(inCard('Boyz', find.text('Orks')), findsOneWidget);
      expect(inCard('Boyz', find.byType(StageBar)), findsOneWidget);
      expect(inCard('Boyz', find.text('Move from Primed')), findsOneWidget);
      expect(inCard('Boyz', find.byIcon(Icons.swap_vert)), findsOneWidget);
      expect(tester.getSize(find.byType(RecentUnitCard).first).width, 164);

      // Primed, its latest move's from-Stage, still has 3 models: the sheet starts there.
      await tester.tap(find.text('Captain'));
      await settle();
      final sheet = find.byType(BottomSheet);
      expect(
        find.descendant(of: sheet, matching: find.text('Move from Primed')),
        findsOneWidget,
      );
      expect(find.text('3 of 3'), findsOneWidget);
      expect(find.text('Move 3 models to Painted'), findsOneWidget);

      // Its chevron opens the Unit screen instead.
      Navigator.pop(tester.element(find.text('3 of 3')));
      await settle();
      await tester.tap(find.byTooltip('Open Captain'));
      await settle();
      expect(find.byTooltip('Edit Unit'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Collection actions live in the Collection screen menu, not on the rows',
    (tester) async {
      final (db, vault) = (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('app_test');
        final db = PowerSyncDatabase(
          schema: appSchema,
          path: '${dir.path}/vault.db',
        );
        for (final w in ['w', 'w2']) {
          await db.execute(
            "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id) VALUES (?, ?, 's$w', 's$w')",
            [w, w == 'w' ? 'Starter' : 'Speed Paint'],
          );
          await db.execute(
            "INSERT INTO stages (id, workflow_id, name, position) VALUES ('s$w', ?, 'Wishlist', 0)",
            [w],
          );
        }
        final vault = Vault(SqliteVaultStore(db));
        final c = await vault.createCollection(
          'Space Marines',
          workflowId: 'w',
        );
        await vault.addBatch(c, name: 'Captain', modelCount: 1, stageId: 'sw');
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

      // Taps outside the fake-async zone: SQLite I/O started from a tap inside it never completes.
      Future<void> tapAndWait(Finder finder) async {
        await tester.runAsync(() async {
          await tester.tap(finder);
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await settle();
      }

      Future<void> openMenu() async {
        await tester.tap(find.byTooltip('Collection'));
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(
        MaterialApp(
          home: CollectionsScreen(vault: vault, db: db),
        ),
      );
      await settle();

      // The row shows only its name and Progress.
      final row = find.ancestor(
        of: find.text('Space Marines'),
        matching: find.byType(CollectionRow),
      );
      expect(
        find.descendant(of: row, matching: find.byType(IconButton)),
        findsNothing,
      );
      for (final tip in [
        'Switch Workflow',
        'Edit Collection',
        'Delete Collection',
      ]) {
        expect(find.byTooltip(tip), findsNothing);
      }

      await tester.tap(row);
      await settle();
      await openMenu();
      final order = ['Edit Collection', 'Switch Workflow', 'Delete Collection'];
      final tops = [for (final t in order) tester.getTopLeft(find.text(t)).dy];
      expect(tops, [...tops]..sort(), reason: 'in the order $order');
      expect(find.byType(PopupMenuDivider), findsOneWidget);
      expect(
        tester.getTopLeft(find.byType(PopupMenuDivider)).dy,
        inExclusiveRange(tops[1], tops[2]),
      );

      // Edit: a rename shows in the title.
      await tapAndWait(find.text('Edit Collection'));
      expect(find.byType(NewCollectionDialog), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Name'),
        'Ultramarines',
      );
      await tapAndWait(find.text('Save'));
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Ultramarines'),
        ),
        findsOneWidget,
      );

      // Edit shows the current Workflow with its strip; Switch… closes it, discarding the edits, and runs the switch.
      await openMenu();
      await tapAndWait(find.text('Edit Collection'));
      final edit = find.byType(NewCollectionDialog);
      expect(
        find.descendant(of: edit, matching: find.text('Starter')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: edit, matching: find.byType(StageStrip)),
        findsOneWidget,
      );
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Orks');
      await tapAndWait(find.text('Switch…'));
      expect(edit, findsNothing);
      expect(find.text('Switch Ultramarines to'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5)); // Dismisses it.
      await tester.pumpAndSettle();

      // Switch Workflow offers the other Workflow.
      await openMenu();
      await tapAndWait(find.text('Switch Workflow'));
      expect(find.text('Switch Ultramarines to'), findsOneWidget);
      expect(find.text('Speed Paint'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5)); // Dismisses it.
      await tester.pumpAndSettle();

      // Delete asks, then goes back to the Collections screen.
      await openMenu();
      await tapAndWait(find.text('Delete Collection'));
      expect(find.text('Delete Ultramarines?'), findsOneWidget);
      await tapAndWait(find.text('Delete'));
      expect(find.byType(CollectionScreen), findsNothing);
      expect(find.text('New Collection'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a Collection description is set in Edit Collection, shown clipped under the app bar, tapped to edit, and cleared',
    (tester) async {
      final (db, vault, collection) = (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('app_test');
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
        return (db, vault, await vault.createCollection('Ultramarines'));
      }))!;
      Future<void> settle() async {
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      // Taps outside the fake-async zone: SQLite I/O started from a tap inside it never completes.
      Future<void> tapAndWait(Finder finder) async {
        await tester.runAsync(() async {
          await tester.tap(finder);
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await settle();
      }

      final description = find.widgetWithText(TextField, 'Description');
      const text =
          '2nd Company strike force,\nblue with gold trim.\nLeague in spring.';
      Finder shown() => find.textContaining('2nd Company');

      await tester.pumpWidget(
        MaterialApp(
          home: CollectionScreen(vault: vault, db: db, collection: collection),
        ),
      );
      await settle();
      expect(shown(), findsNothing);

      await tester.tap(find.byTooltip('Collection'));
      await tester.pumpAndSettle();
      await tapAndWait(find.text('Edit Collection'));
      await tester.enterText(description, '  $text  ');
      await tapAndWait(find.text('Save'));
      expect(shown(), findsOneWidget);
      final shownText = tester.widget<Text>(shown());
      expect(shownText.data, text);
      expect(shownText.maxLines, 2);
      expect(shownText.overflow, TextOverflow.ellipsis);

      await tapAndWait(shown());
      expect(find.text('Edit Collection'), findsOneWidget);
      expect(tester.widget<TextField>(description).controller!.text, text);
      await tester.enterText(description, '   ');
      await tapAndWait(find.text('Save'));
      expect(shown(), findsNothing);
      expect(
        (await tester.runAsync(vault.collections))!.single.description,
        '',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'empty screens explain what goes there and offer a button that adds the first one',
    (tester) async {
      final (db, vault) = (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('app_test');
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
        return (db, Vault(SqliteVaultStore(db)));
      }))!;
      Future<void> settle() async {
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      // Taps outside the fake-async zone: SQLite I/O started from a tap inside it never completes.
      Future<void> tapAndWait(Finder finder) async {
        await tester.runAsync(() async {
          await tester.tap(finder);
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await settle();
      }

      Finder bigButton(String label) => find.ancestor(
        of: find.text(label),
        matching: find.bySubtype<FilledButton>(),
      );
      Finder dialogTitled(String title) => find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(title),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: CollectionsScreen(vault: vault, db: db),
        ),
      );
      await settle();

      // No Collections: what a Collection is, a New Collection button, and the FAB still there.
      expect(
        find.text(
          'A Collection is a named set of Units that progress through the same Workflow.',
        ),
        findsOneWidget,
      );
      expect(bigButton('New Collection'), findsOneWidget);
      expect(find.byTooltip('New Collection'), findsOneWidget);
      await tapAndWait(bigButton('New Collection'));
      expect(find.byType(NewCollectionDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // An empty Collection: what a Unit is, an Add models button, and the FAB still there.
      await tester.runAsync(() => vault.createCollection('Space Marines'));
      await settle();
      expect(bigButton('New Collection'), findsNothing);
      await tester.tap(find.text('Space Marines'));
      await settle();
      expect(
        find.text(
          'A Unit is all the models you track under one name, like "Intercessors", wherever they are in your Workflow.',
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('Add models'), findsOneWidget);
      await tapAndWait(bigButton('Add models'));
      expect(dialogTitled('Add models'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );
}
