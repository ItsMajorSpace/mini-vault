// ignore_for_file: experimental_member_use

import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/army_list.dart';
import 'package:mini_vault/main.dart';
import 'package:mini_vault/paints.dart';
import 'package:mini_vault/photos.dart';
import 'package:mini_vault/progress.dart';
import 'package:mini_vault/workflows.dart';
import 'package:powersync/powersync.dart';

// The bottom tabs and the Collections empty state, against real SQLite.
// shortcut: the database is never closed once the screen has been mounted, as in collections_screen_test.dart.

/// Lets SQLite reads (isolate round trips) finish, then the UI catch up.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// A database holding the starter Workflow and, unless [empty], one Collection.
Future<PowerSyncDatabase> openDb(
  WidgetTester tester, {
  bool empty = false,
}) async => (await tester.runAsync(() async {
  final dir = await Directory.systemTemp.createTemp('app_test');
  addTearDown(() => dir.delete(recursive: true));
  final db = PowerSyncDatabase(schema: appSchema, path: '${dir.path}/vault.db');
  await db.execute(
    "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id) VALUES ('w', 'Starter', 's', 's')",
  );
  await db.execute(
    "INSERT INTO stages (id, workflow_id, name, position) VALUES ('s', 'w', 'Wishlist', 0)",
  );
  if (!empty) {
    await db.execute(
      "INSERT INTO collections (id, name, workflow_id) VALUES ('c', 'Crimson Fists', 'w')",
    );
  }
  return db;
}))!;

Future<void> tab(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(NavigationDestination, label));
  await settle(tester);
}

void main() {
  testWidgets('each tab opens its screen and keeps its back stack', (
    tester,
  ) async {
    final db = await openDb(tester);
    final vault = Vault(SqliteVaultStore(db));
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          vault: vault,
          collections: CollectionsScreen(vault: vault, db: db),
        ),
      ),
    );
    await settle(tester);

    expect(find.byType(CollectionsScreen), findsOneWidget);
    // Collections show their totals in the list, not in a Progress drawer.
    expect(find.byType(ProgressDrawer), findsNothing);
    await tester.tap(find.text('Crimson Fists'));
    await settle(tester);
    expect(find.byType(CollectionScreen), findsOneWidget);
    // A Collection keeps its drawer, above the tabs.
    expect(
      tester.getTopLeft(find.byType(NavigationBar)).dy,
      greaterThanOrEqualTo(
        tester.getBottomLeft(find.byType(ProgressDrawer)).dy,
      ),
    );

    await tab(tester, 'Paints');
    expect(find.byType(PaintsScreen), findsOneWidget);
    expect(find.byType(CollectionScreen), findsNothing);

    await tab(tester, 'Workflows');
    expect(find.byType(WorkflowsScreen), findsOneWidget);
    await tester.tap(
      find.text('Starter').first,
    ); // The name, not its Starter badge.
    await settle(tester);
    expect(find.byType(WorkflowScreen), findsOneWidget);

    await tab(tester, 'Collections');
    expect(find.byType(CollectionScreen), findsOneWidget);
    expect(find.byType(WorkflowScreen), findsNothing);

    await tab(tester, 'Workflows');
    expect(find.byType(WorkflowScreen), findsOneWidget);

    // Back pops within the open tab only.
    await tester.pageBack();
    await settle(tester);
    expect(find.byType(WorkflowScreen), findsNothing);
    expect(find.byType(WorkflowsScreen), findsOneWidget);
    await tab(tester, 'Collections');
    expect(find.byType(CollectionScreen), findsOneWidget);
  });

  testWidgets('the Collections app bar has only sync and the Account menu', (
    tester,
  ) async {
    final db = await openDb(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: CollectionsScreen(vault: Vault(SqliteVaultStore(db)), db: db),
      ),
    );
    await settle(tester);

    expect(find.byTooltip('Paints'), findsNothing);
    expect(find.byTooltip('Import army list'), findsNothing);
    expect(find.byTooltip('Account'), findsOneWidget);
  });

  testWidgets('the empty Collections import an army list', (tester) async {
    final db = await openDb(tester, empty: true);
    await tester.pumpWidget(
      MaterialApp(
        home: CollectionsScreen(vault: Vault(SqliteVaultStore(db)), db: db),
      ),
    );
    await settle(tester);

    expect(find.byIcon(Icons.collections_bookmark), findsOneWidget);
    expect(find.text('No Collections yet'), findsOneWidget);
    expect(find.byType(ProgressOverview), findsNothing);

    expect(
      find.text('New Collection'),
      findsWidgets,
    ); // Button and FAB tooltip.
    await tester.tap(find.text('Import army list'));
    await settle(tester);
    expect(find.byType(ArmyListScreen), findsOneWidget);
  });

  /// A database holding the Standard Workflow's Necrons (6 wanted; 9, 11 and 18 owned) and the Starter's Crimson Fists.
  Future<(PowerSyncDatabase, Vault)> seeded(WidgetTester tester) async {
    tester.view.physicalSize = const Size(2400, 4800);
    addTearDown(tester.view.reset);
    final db = await openDb(tester);
    final vault = Vault(SqliteVaultStore(db));
    await tester.runAsync(() async {
      final w = await vault.createWorkflow('Standard');
      final c = await vault.createCollection('Necrons', workflowId: w.id);
      for (final (stage, n) in [(0, 6), (1, 9), (3, 11), (6, 18)]) {
        await vault.addBatch(
          c,
          name: 'Warriors',
          modelCount: n,
          stageId: w.stages[stage].id,
        );
      }
    });
    return (db, vault);
  }

  const standard = [
    'Standard', '18 / 38 finished · 47%', //
    'Wanted', 'Wishlist', '6', //
    'Owned', 'Unassembled', '9', '24%', 'Assembled', '0', //
    'Primed', '11', '29%', 'Painted', '0', 'Based', '0', //
    'Finished', 'Done', '18', '47%',
  ];
  List<String?> texts(WidgetTester tester, Finder of) => [
    for (final t in tester.widgetList<Text>(
      find.descendant(of: of, matching: find.byType(Text)),
    ))
      t.data,
  ];
  final overviewButton = find.descendant(
    of: find.byType(ProgressOverview),
    matching: find.byType(TextButton),
  );

  testWidgets(
    'the Progress overview leads the Collections with all their totals',
    (tester) async {
      final (db, vault) = await seeded(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: CollectionsScreen(vault: vault, db: db),
        ),
      );
      await settle(tester);

      final overview = find.byType(ProgressOverview);
      expect(
        tester.getTopLeft(overview).dy,
        lessThan(tester.getTopLeft(find.text('Necrons')).dy),
      );
      expect(texts(tester, overview), [
        '47%',
        '18 / 38 finished',
        '2 Collections · 2 Workflows',
        '38', 'owned', '18', 'finished', '6', 'wanted', //
        'Show Stages',
      ]);
      expect(
        find.descendant(
          of: overview,
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.label == '47% finished',
          ),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSize(
          find.descendant(of: overview, matching: find.byType(ProgressRing)),
        ),
        const Size(72, 72),
      );
      expect(
        tester
            .widget<StageBar>(
              find.descendant(of: overview, matching: find.byType(StageBar)),
            )
            .height,
        8,
      );

      // Searching hides it with the FAB; clearing brings it back, closed.
      await tester.tap(find.byTooltip('Search'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'nec');
      await settle(tester);
      expect(find.text('Necrons'), findsOneWidget);
      expect(overview, findsNothing);
      expect(find.byTooltip('New Collection'), findsNothing);
      await tester.tap(find.byTooltip('End search'));
      await settle(tester);
      expect(overview, findsOneWidget);
    },
  );

  testWidgets('the overview stays readable at a large text size', (
    tester,
  ) async {
    final (db, vault) = await seeded(tester);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: MaterialApp(
          home: CollectionsScreen(vault: vault, db: db),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(overviewButton);
    await settle(tester);

    expect(find.byType(StageBreakdown), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Show Stages breaks down each Workflow in the overview and in a Collection\'s drawer',
    (tester) async {
      final (db, vault) = await seeded(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            vault: vault,
            collections: CollectionsScreen(vault: vault, db: db),
          ),
        ),
      );
      await settle(tester);

      expect(find.byType(StageBreakdown), findsNothing);
      await tester.tap(overviewButton);
      await settle(tester);
      expect(texts(tester, find.byType(StageBreakdown).first), standard);
      expect(texts(tester, find.byType(StageBreakdown).at(1)).take(2), [
        'Starter',
        '0 / 0 finished · 0%',
      ]);
      expect(find.text('Hide Stages'), findsOneWidget);

      await tester.tap(overviewButton);
      await settle(tester);
      expect(find.byType(StageBreakdown), findsNothing);
      expect(find.text('Show Stages'), findsOneWidget);

      await tester.tap(find.text('Necrons'));
      await settle(tester);
      expect(find.byType(CollectionScreen), findsOneWidget);
      await tester.tap(find.byTooltip('Show Stages'));
      await settle(tester);
      expect(texts(tester, find.byType(StageBreakdown)), standard);
    },
  );
}
