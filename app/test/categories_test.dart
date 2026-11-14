// ignore_for_file: experimental_member_use

import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/main.dart';
import 'package:mini_vault/photos.dart';
import 'package:mini_vault/section.dart';
import 'package:powersync/powersync.dart';

// Categories on the Collection screen and in Add models, against real SQLite.
// shortcut: the database is never closed once the screen has been mounted, as in collections_screen_test.dart.
void main() {
  late Directory dir;
  late PowerSyncDatabase db;
  late Vault vault;
  late Collection collection;
  late Category heroes;
  late Category core;

  /// Necrons with Categories Heroes (Overlord), Core (Warriors) and Support (empty), and Scarabs Uncategorised; the
  /// only Stage is both Owned and Finished.
  Future<void> seed(WidgetTester tester, {bool categories = true}) async {
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('app_test');
      db = PowerSyncDatabase(schema: appSchema, path: '${dir.path}/vault.db');
      await db.execute(
        "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id) VALUES ('w', 'Starter', 's', 's')",
      );
      await db.execute(
        "INSERT INTO stages (id, workflow_id, name, position) VALUES ('s', 'w', 'Wishlist', 0)",
      );
      vault = Vault(SqliteVaultStore(db));
      collection = await vault.createCollection('Necrons');
      if (categories) {
        heroes = await vault.addCategory(collection.id, 'Heroes');
        core = await vault.addCategory(collection.id, 'Core');
        await vault.addCategory(collection.id, 'Support');
      }
      for (final (name, count, category) in [
        ('Overlord', 1, categories ? heroes.id : null),
        ('Warriors', 10, categories ? core.id : null),
        ('Scarabs', 3, null),
      ]) {
        await vault.addBatch(
          collection,
          name: name,
          modelCount: count,
          stageId: 's',
          categoryId: category,
        );
      }
    });
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  // Taps outside the fake-async zone: SQLite I/O started from a tap inside it never completes.
  Future<void> tapAndWait(WidgetTester tester, Finder finder) async {
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await settle(tester);
  }

  /// The Collection screen, on a view tall enough to build every row unless [size] is given.
  Future<void> open(
    WidgetTester tester, {
    CollapsedGroups? collapsed,
    Size size = const Size(800, 2400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        home: CollectionScreen(
          vault: vault,
          db: db,
          collection: collection,
          collapsed: collapsed,
        ),
      ),
    );
    await settle(tester);
  }

  /// Whether [texts] are on screen, top to bottom in that order.
  void expectInOrder(WidgetTester tester, List<String> texts) {
    final tops = [
      for (final t in texts) tester.getTopLeft(find.text(t).first).dy,
    ];
    expect(tops, [...tops]..sort(), reason: 'in the order $texts');
  }

  Finder categoryShows(String text) => find.descendant(
    of: find.byType(CategoryField),
    matching: find.text(text),
  );

  testWidgets(
    'Units appear under their Category headers in order, Uncategorised last and muted, only when it has Units',
    (tester) async {
      await seed(tester);
      await open(tester);
      expectInOrder(tester, [
        'HEROES',
        'Overlord',
        'CORE',
        'Warriors',
        'SUPPORT',
        'UNCATEGORISED',
        'Scarabs',
      ]);
      final uncategorised = tester.widget<SectionHeader>(
        find.ancestor(
          of: find.text('UNCATEGORISED'),
          matching: find.byType(SectionHeader),
        ),
      );
      expect(uncategorised.muted, isTrue);
      expect(uncategorised.count, 1);

      await tester.runAsync(
        () => vault.setUnitCategory(collection.id, 'Scarabs', core.id),
      );
      await settle(tester);
      expect(find.text('UNCATEGORISED'), findsNothing);
      expectInOrder(tester, ['CORE', 'Scarabs', 'Warriors', 'SUPPORT']);
    },
  );

  testWidgets('without Categories the Units show without headers', (
    tester,
  ) async {
    await seed(tester, categories: false);
    await open(tester);
    expect(find.text('Overlord'), findsOneWidget);
    expect(find.byType(SectionHeader), findsOneWidget); // Paint Schemes only.
    expect(find.text('UNCATEGORISED'), findsNothing);
  });

  testWidgets(
    'a Category header collapses to a summary line, remembered per device',
    (tester) async {
      await seed(tester);
      final file = File('${dir.path}/collapsed.txt');
      Future<void> reopen() async => open(
        tester,
        collapsed: (await tester.runAsync(() => CollapsedGroups.load(file)))!,
      );

      await reopen();
      await tester.tap(find.text('CORE'));
      await tester.pump();
      expect(find.text('Warriors'), findsNothing);
      expect(find.text('1 Unit · 10 / 10 finished'), findsOneWidget);
      await tester.tap(find.text('UNCATEGORISED'));
      await tester.pump();
      expect(find.text('Scarabs'), findsNothing);
      expect(find.text('1 Unit · 3 / 3 finished'), findsOneWidget);
      expect((await tester.runAsync(file.readAsLines))!.toSet(), {
        'category:${core.id}',
        'uncategorised:${collection.id}',
      });

      await reopen();
      expect(find.text('Warriors'), findsNothing);
      expect(find.text('Scarabs'), findsNothing);
      expect(find.text('Overlord'), findsOneWidget);

      await tester.tap(find.text('CORE'));
      await tester.pump();
      expect(find.text('Warriors'), findsOneWidget);
    },
  );

  testWidgets(
    "a header's add action preselects its Category; the FAB preselects Uncategorised",
    (tester) async {
      await seed(tester);
      await open(tester);

      await tapAndWait(tester, find.byTooltip('Add models to Core'));
      expect(categoryShows('Core'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Immortals',
      );
      await tapAndWait(tester, find.text('Save'));
      expectInOrder(tester, ['CORE', 'Immortals', 'Warriors', 'SUPPORT']);

      await tapAndWait(tester, find.byTooltip('Add models'));
      expect(categoryShows('Uncategorised'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Wraiths',
      );
      await tapAndWait(tester, find.text('Save'));
      expectInOrder(tester, ['UNCATEGORISED', 'Scarabs', 'Wraiths']);
    },
  );

  testWidgets(
    "'New Category…' creates the Category on Save, last, with the Unit in it; an existing name reuses that one",
    (tester) async {
      await seed(tester);
      await open(tester);

      Future<void> addNew(String unit, String category) async {
        await tapAndWait(tester, find.byTooltip('Add models'));
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Name'),
          unit,
        );
        await tester.tap(find.byType(CategoryField));
        await tester.pumpAndSettle();
        await tester.tap(find.text('New Category…').last);
        await tester.pumpAndSettle();
        expect(find.text('Created when you save'), findsOneWidget);
        await tester.enterText(
          find.widgetWithText(TextFormField, 'New Category'),
          category,
        );
        await tapAndWait(tester, find.text('Save'));
      }

      await addNew('Lychguard', ' Elites ');
      expectInOrder(tester, [
        'SUPPORT',
        'ELITES',
        'Lychguard',
        'UNCATEGORISED',
      ]);
      expect(
        [
          for (final c in (await tester.runAsync(
            () => vault.watchCategories(collection.id).first,
          ))!)
            c.name,
        ],
        ['Heroes', 'Core', 'Support', 'Elites'],
      );

      await addNew('Lord', 'heroes');
      expect(find.text('HEROES'), findsOneWidget);
      expectInOrder(tester, ['HEROES', 'Lord', 'Overlord', 'CORE']);
      expect(
        (await tester.runAsync(
          () => vault.watchCategories(collection.id).first,
        ))!.length,
        4,
      );

      // The close button goes back to the dropdown.
      await tapAndWait(tester, find.byTooltip('Add models'));
      await tester.tap(find.byType(CategoryField));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New Category…').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Pick a Category'));
      await tester.pumpAndSettle();
      expect(find.text('Created when you save'), findsNothing);
      expect(categoryShows('Uncategorised'), findsOneWidget);
    },
  );

  testWidgets(
    "Category is disabled and shows the existing Unit's when Name is one",
    (tester) async {
      await seed(tester);
      await open(tester);

      await tapAndWait(tester, find.byTooltip('Add models'));
      final name = find.widgetWithText(TextFormField, 'Name');
      await tester.enterText(name, 'Warriors');
      await tester.pump();
      expect(categoryShows('Core'), findsOneWidget);
      expect(find.text('Change it on the Unit screen'), findsOneWidget);
      final dropdown = tester.widget<DropdownButton<String?>>(
        find.byType(DropdownButton<String?>),
      );
      expect(dropdown.onChanged, isNull);

      await tester.enterText(name, 'Warriors II');
      await tester.pump();
      expect(categoryShows('Uncategorised'), findsOneWidget);
      expect(find.text('Change it on the Unit screen'), findsNothing);

      // Saving more Warriors into the existing Unit keeps it in Core.
      await tester.enterText(name, 'Warriors');
      await tapAndWait(tester, find.text('Save'));
      expectInOrder(tester, ['CORE', 'Warriors', 'SUPPORT']);
      expect(find.text('11 models'), findsOneWidget);
    },
  );

  testWidgets('Add models scrolls above the keyboard with Save reachable', (
    tester,
  ) async {
    await seed(tester);
    await open(tester, size: const Size(800, 760));

    await tapAndWait(tester, find.byTooltip('Add models'));
    tester.view.viewInsets = const FakeViewPadding(bottom: 480);
    await tester.pumpAndSettle();

    expect(find.text('Save').hitTestable(), findsOneWidget);
    expect(find.text('Cancel').hitTestable(), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Stage'),
      50,
      scrollable: find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Stage').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// From the Collection screen to [unit]'s Unit screen, then its Edit Unit dialog.
  Future<void> editUnit(WidgetTester tester, String unit) async {
    await tapAndWait(tester, find.text(unit));
    await tapAndWait(tester, find.byTooltip('Edit Unit'));
  }

  Future<void> back(WidgetTester tester) async {
    await tapAndWait(tester, find.byTooltip('Back'));
  }

  testWidgets(
    'the Unit screen leads its Tags with the Category chip; Uncategorised shows none',
    (tester) async {
      await seed(tester);
      await tester.runAsync(
        () => vault.addTags(collection.id, 'Overlord', ['Character']),
      );
      await open(tester);

      await tapAndWait(tester, find.text('Overlord'));
      final chip = find.ancestor(
        of: find.text('Heroes'),
        matching: find.byType(Chip),
      );
      expect(chip, findsOneWidget);
      expect(
        find.descendant(of: chip, matching: find.byIcon(Icons.category)),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Category Heroes'), findsOneWidget);
      expect(
        tester.getTopLeft(chip).dx,
        lessThan(tester.getTopLeft(find.text('Character')).dx),
      );

      await back(tester);
      await tapAndWait(tester, find.text('Scarabs'));
      expect(find.byIcon(Icons.category), findsNothing);
    },
  );

  testWidgets(
    'changing the Category in Edit Unit moves the Unit on the Collection screen',
    (tester) async {
      await seed(tester);
      await open(tester);

      await editUnit(tester, 'Scarabs');
      expect(categoryShows('Uncategorised'), findsOneWidget);
      await tester.tap(find.byType(CategoryField));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Support').last);
      await tester.pumpAndSettle();
      await tapAndWait(tester, find.text('Save'));
      expect(find.bySemanticsLabel('Category Support'), findsOneWidget);

      await back(tester);
      expect(find.text('UNCATEGORISED'), findsNothing);
      expectInOrder(tester, ['CORE', 'Warriors', 'SUPPORT', 'Scarabs']);

      // Renamed and moved in one save: the Unit keeps the new Category.
      await editUnit(tester, 'Scarabs');
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Canoptek Scarabs',
      );
      await tester.tap(find.byType(CategoryField));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Heroes').last);
      await tester.pumpAndSettle();
      await tapAndWait(tester, find.text('Save'));
      await back(tester);
      expectInOrder(tester, ['HEROES', 'Canoptek Scarabs', 'CORE']);
    },
  );

  testWidgets("'New Category…' in Edit Unit creates and assigns the Category", (
    tester,
  ) async {
    await seed(tester);
    await open(tester);

    await editUnit(tester, 'Overlord');
    await tester.tap(find.byType(CategoryField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New Category…').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'New Category'),
      'Lords',
    );
    await tapAndWait(tester, find.text('Save'));
    expect(find.bySemanticsLabel('Category Lords'), findsOneWidget);

    await back(tester);
    expectInOrder(tester, ['CORE', 'SUPPORT', 'LORDS', 'Overlord']);
    expect(
      [
        for (final c in (await tester.runAsync(
          () => vault.watchCategories(collection.id).first,
        ))!)
          c.name,
      ],
      ['Heroes', 'Core', 'Support', 'Lords'],
    );
  });
}
