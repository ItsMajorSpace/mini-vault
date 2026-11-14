// ignore_for_file: experimental_member_use

import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/main.dart';
import 'package:mini_vault/paint_schemes.dart';
import 'package:mini_vault/paints.dart';
import 'package:mini_vault/photos.dart';
import 'package:powersync/powersync.dart';

// Paint Schemes on the Collection, Paint Scheme and Paints screens, against real SQLite.
// shortcut: the database is never closed once a screen has been mounted, as in collections_screen_test.dart.
void main() {
  late PowerSyncDatabase db;
  late Vault vault;
  late Collection collection;
  late Paint blue;
  late Paint white;
  late Paint black;
  late PaintScheme armour;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
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

  /// A Collection with the Unit Intercessors, three Paints (White Scar wanted) and the Paint Scheme Armour:
  /// 1. Prime [Abaddon Black], 2. Drybrush [Macragge Blue, White Scar] "2:1", 3. only the note "Matt varnish".
  Future<void> seed(WidgetTester tester) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('app_test');
      db = PowerSyncDatabase(schema: appSchema, path: '${dir.path}/vault.db');
      await db.execute(
        "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id) VALUES ('w', 'Starter', 's', 's')",
      );
      await db.execute(
        "INSERT INTO stages (id, workflow_id, name, position) VALUES ('s', 'w', 'Wishlist', 0)",
      );
      vault = Vault(SqliteVaultStore(db));
      collection = await vault.createCollection('Ultramarines');
      await vault.addBatch(
        collection,
        name: 'Intercessors',
        modelCount: 10,
        stageId: 's',
      );
      blue = await vault.addPaint(
        brand: 'Citadel',
        range: 'Base',
        name: 'Macragge Blue',
      );
      white = await vault.addPaint(
        brand: 'Citadel',
        range: 'Layer',
        name: 'White Scar',
        owned: false,
      );
      black = await vault.addPaint(
        brand: 'Citadel',
        range: 'Base',
        name: 'Abaddon Black',
      );
      armour = await vault.addPaintScheme(collection.id, 'Armour');
      await vault.addSchemeStep(
        armour.id,
        paintIds: [black.id],
        technique: 'Prime',
      );
      await vault.addSchemeStep(
        armour.id,
        paintIds: [blue.id, white.id],
        technique: 'Drybrush',
        note: '2:1',
      );
      await vault.addSchemeStep(armour.id, note: 'Matt varnish');
    });
  }

  double top(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

  testWidgets(
    'the Collection screen shows its Paint Schemes above the Units, adds one, says they go with the Collection, and opens one',
    (tester) async {
      await seed(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: CollectionScreen(vault: vault, db: db, collection: collection),
        ),
      );
      await settle(tester);

      expect(find.text('PAINT SCHEMES'), findsOneWidget);
      expect(find.text('Armour'), findsOneWidget);
      expect(find.text('3 Scheme Steps'), findsOneWidget);
      // No other Collection has a Paint Scheme to copy.
      expect(find.byTooltip('Copy a Paint Scheme'), findsNothing);
      expect(
        top(tester, find.text('Armour')),
        lessThan(top(tester, find.text('Intercessors'))),
      );

      await tester.tap(find.byTooltip('New Paint Scheme'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Bases');
      await tapAndWait(tester, find.text('Save'));
      expect(find.text('Bases'), findsOneWidget);
      expect(find.text('0 Scheme Steps'), findsOneWidget);

      await tester.tap(find.byTooltip('Collection'));
      await tester.pumpAndSettle();
      await tapAndWait(tester, find.text('Delete Collection'));
      expect(
        find.text(
          'Its 1 Unit (10 models) and their history, Tags and photos, and its 2 Paint Schemes, '
          'will be deleted on all your devices.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tapAndWait(tester, find.text('Armour'));
      expect(find.byType(PaintSchemeScreen), findsOneWidget);
      expect(find.text('Ultramarines · Paint Scheme'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a Paint Scheme is started as a copy of one from another Collection, offered only from other Collections',
    (tester) async {
      await seed(tester);
      await tester.runAsync(() async {
        final other = await vault.createCollection('Dark Angels');
        final robes = await vault.addPaintScheme(other.id, 'Robes');
        await vault.addSchemeStep(
          robes.id,
          paintIds: [white.id, black.id],
          technique: 'Basecoat',
          note: 'Bone',
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: CollectionScreen(vault: vault, db: db, collection: collection),
        ),
      );
      await settle(tester);

      await tester.tap(find.byTooltip('Copy a Paint Scheme'));
      await tester.pumpAndSettle();
      expect(find.text('Copy a Paint Scheme from'), findsOneWidget);
      expect(find.text('Robes · Dark Angels'), findsOneWidget);
      expect(find.text('Armour · Ultramarines'), findsNothing);
      await tapAndWait(tester, find.text('Robes · Dark Angels'));

      expect(find.text('Robes'), findsOneWidget);
      expect(find.text('1 Scheme Step'), findsOneWidget);
      final copied = await tester.runAsync(() async {
        final copy = (await vault.watchPaintSchemes(collection.id).first)
            .firstWhere((s) => s.name == 'Robes');
        return [
          for (final s in await vault.watchSchemeSteps(copy.id).first)
            '${s.technique} ${s.paints.map((p) => p.name)} ${s.note}',
        ];
      });
      expect(copied, ['Basecoat (White Scar, Abaddon Black) Bone']);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a Paint Scheme shows numbered Steps, adds, edits, deletes and reorders them, and is renamed and deleted',
    (tester) async {
      await seed(tester);
      // A phone-sized screen, so the whole Scheme Step sheet fits.
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.6;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .push(
            MaterialPageRoute<void>(
              builder: (_) => PaintSchemeScreen(
                vault: vault,
                collection: collection,
                scheme: armour,
              ),
            ),
          );
      await settle(tester);
      List<String> titles() =>
          [
            for (final t in ['Prime', 'Drybrush', 'No Technique', 'Wash'])
              if (find.text(t).evaluate().isNotEmpty) t,
          ]..sort(
            (a, b) =>
                top(tester, find.text(a)).compareTo(top(tester, find.text(b))),
          );

      // Numbered, Technique as title, Paints as chips, MIX for several, wanted noted, "No Technique" in italics.
      expect(titles(), ['Prime', 'Drybrush', 'No Technique']);
      for (final n in ['1', '2', '3']) {
        expect(find.text(n), findsOneWidget);
      }
      expect(find.byIcon(Icons.drag_handle), findsNWidgets(3));
      expect(find.text('MIX'), findsOneWidget);
      expect(find.widgetWithText(Chip, 'White Scar'), findsOneWidget);
      expect(find.text('Wanted · 2:1'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('No Technique')).style?.fontStyle,
        FontStyle.italic,
      );

      // A new Step: Save waits for a Paint, Technique or note; suggestions are the defaults and those used before.
      await tapAndWait(tester, find.byTooltip('Add Scheme Step'));
      expect(find.text('New Scheme Step'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Delete'), findsNothing);
      FilledButton save() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(save().onPressed, isNull);
      expect(find.text('Add a Paint, a Technique or a note'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Basecoat'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Prime'), findsNothing);
      await tester.tap(find.widgetWithText(ActionChip, '+4'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, 'Prime'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Technique'), 'wa');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, 'Basecoat'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Wash'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Technique'))
            .controller!
            .text,
        'Wash',
      );
      expect(save().onPressed, isNotNull);
      await tester.tap(find.text('Add Paint'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Citadel / Base / Macragge Blue'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove Macragge Blue'), findsOneWidget);
      await tapAndWait(tester, find.widgetWithText(FilledButton, 'Save'));
      expect(titles(), ['Prime', 'Drybrush', 'No Technique', 'Wash']);
      expect(find.text('4'), findsOneWidget);
      expect(find.widgetWithText(Chip, 'Macragge Blue'), findsNWidgets(2));

      // Dragging Step 3 to the top.
      await tester.runAsync(() async {
        tester
            .widget<ReorderableListView>(find.byType(ReorderableListView))
            .onReorderItem!(2, 0);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await settle(tester);
      expect(titles(), ['No Technique', 'Prime', 'Drybrush', 'Wash']);

      // Editing a Step offers Delete.
      await tapAndWait(tester, find.text('Prime'));
      expect(find.text('Scheme Step 2'), findsOneWidget);
      expect(find.byTooltip('Remove Abaddon Black'), findsOneWidget);
      await tapAndWait(tester, find.widgetWithText(TextButton, 'Delete'));
      expect(titles(), ['No Technique', 'Drybrush', 'Wash']);

      // Renamed and deleted from the app bar; deleting asks first.
      await tester.tap(find.byTooltip('Rename Paint Scheme'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Power armour');
      await tapAndWait(tester, find.text('Save'));
      expect(find.text('Power armour'), findsOneWidget);
      await tester.tap(find.byTooltip('Delete Paint Scheme'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Its 3 Scheme Steps will be deleted on all your devices. Its Paints stay in your paints.',
        ),
        findsOneWidget,
      );
      await tapAndWait(tester, find.text('Delete'));
      expect(find.byType(PaintSchemeScreen), findsNothing);
      expect(
        await tester.runAsync(
          () => vault.watchPaintSchemes(collection.id).first,
        ),
        isEmpty,
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'deleting a Paint says how many Units and Paint Schemes use it, and keeps their Scheme Steps',
    (tester) async {
      await seed(tester);
      await tester.runAsync(() async {
        await vault.addUnitPaint(collection.id, 'Intercessors', blue.id);
        final trim = await vault.addPaintScheme(collection.id, 'Trim');
        await vault.addSchemeStep(trim.id, paintIds: [blue.id]);
      });
      await tester.pumpWidget(MaterialApp(home: PaintsScreen(vault: vault)));
      await settle(tester);

      await tester.tap(find.text('Macragge Blue'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Citadel / Base / Macragge Blue will be removed from your paints on all your devices. '
          '1 Unit and 2 Paint Schemes use it; it will be removed from them, keeping their Scheme Steps.',
        ),
        findsOneWidget,
      );
      await tapAndWait(tester, find.widgetWithText(TextButton, 'Delete'));

      final steps = (await tester.runAsync(
        () => vault.watchSchemeSteps(armour.id).first,
      ))!;
      expect(
        [for (final s in steps) s.paints.map((p) => p.name).join('+')],
        ['Abaddon Black', 'White Scar', ''],
      );

      await tester.pumpWidget(const SizedBox());
    },
  );
}
