// ignore_for_file: experimental_member_use

import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/main.dart';
import 'package:mini_vault/paints.dart';
import 'package:mini_vault/photos.dart';
import 'package:mini_vault/unit.dart';
import 'package:powersync/powersync.dart';

// The paint library against real SQLite. Paints are added through the Vault, not the dialog, and toggling owned is
// tested in domain_core: SQLite I/O started from a tap never completes inside the widget tester's fake-async zone.
// shortcut: the database is never closed once the screen has been mounted, as in collections_screen_test.dart.
void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets(
    'the home screen opens the Paints, grouped by brand, with a search and a Wanted filter',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('app_test'),
      ))!;
      final db = (await tester.runAsync(() async {
        final db = PowerSyncDatabase(
          schema: appSchema,
          path: '${dir.path}/vault.db',
        );
        await db.initialize();
        final vault = Vault(SqliteVaultStore(db));
        for (final (brand, range, name, owned) in [
          ('Vallejo', 'Model Color', 'Flat Blue', false),
          ('Citadel', 'Layer', 'Calgar Blue', true),
          ('citadel', 'Base', 'Macragge Blue', false),
          ('Army Painter', 'Warpaints', 'Matt Black', true),
        ]) {
          await vault.addPaint(
            brand: brand,
            range: range,
            name: name,
            owned: owned,
          );
        }
        return db;
      }))!;
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            vault: Vault(SqliteVaultStore(db)),
            collections: CollectionsScreen(
              vault: Vault(SqliteVaultStore(db)),
              db: db,
            ),
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.widgetWithText(NavigationDestination, 'Paints'));
      await settle(tester);

      final order = [
        'Army Painter',
        'Matt Black',
        'Citadel',
        'Macragge Blue',
        'Calgar Blue',
        'Vallejo',
        'Flat Blue',
      ];
      final tops = [for (final t in order) tester.getTopLeft(find.text(t)).dy];
      expect(tops, [...tops]..sort(), reason: 'in the order $order');
      expect(
        find.text('citadel'),
        findsNothing,
      ); // One brand, spelled as first added.
      expect(find.widgetWithText(ChoiceChip, 'Wanted'), findsNWidgets(2));
      expect(find.widgetWithText(ChoiceChip, 'Owned'), findsNWidgets(2));
      expect(find.byIcon(Icons.delete), findsNothing);
      expect(find.byTooltip('Delete Paint'), findsNothing);

      await tester.tap(find.widgetWithText(FilterChip, 'Wanted'));
      await tester.pump();
      expect(find.text('Matt Black'), findsNothing);
      expect(find.text('Calgar Blue'), findsNothing);
      expect(find.text('Army Painter'), findsNothing);
      expect(find.text('Macragge Blue'), findsOneWidget);
      expect(find.text('Flat Blue'), findsOneWidget);

      // Search narrows on brand, range or name, ignoring case, and combines with Wanted.
      await tester.enterText(find.byType(TextField), 'BLUE');
      await tester.pump();
      expect(find.text('Macragge Blue'), findsOneWidget);
      expect(find.text('Flat Blue'), findsOneWidget);
      expect(find.text('Calgar Blue'), findsNothing);
      await tester.enterText(find.byType(TextField), 'base');
      await tester.pump();
      expect(find.text('Macragge Blue'), findsOneWidget);
      expect(find.text('Flat Blue'), findsNothing);
      await tester.enterText(find.byType(TextField), 'warpaints');
      await tester.pump();
      expect(find.text('Matt Black'), findsNothing);
      expect(find.text('No Paints match.'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilterChip, 'Wanted'));
      await tester.pump();
      expect(find.text('Matt Black'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'citadel');
      await tester.pump();
      expect(find.text('Calgar Blue'), findsOneWidget);
      expect(find.text('Macragge Blue'), findsOneWidget);
      expect(find.text('Matt Black'), findsNothing);
      expect(find.text('Flat Blue'), findsNothing);

      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      // The tap runs in the real async zone so its SQLite write completes.
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(ChoiceChip, 'Wanted').first);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await settle(tester);
      expect(find.widgetWithText(ChoiceChip, 'Wanted'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Owned'), findsNWidgets(3));

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => dir.delete(recursive: true));
    },
  );

  testWidgets(
    'Paints that fail to load say so plainly, with Retry and no exception text',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('app_test'),
      ))!;
      // No tables, so every query fails.
      final db = (await tester.runAsync(() async {
        final db = PowerSyncDatabase(
          schema: const Schema([]),
          path: '${dir.path}/vault.db',
        );
        await db.initialize();
        return db;
      }))!;
      await tester.pumpWidget(
        MaterialApp(home: PaintsScreen(vault: Vault(SqliteVaultStore(db)))),
      );
      await settle(tester);

      expect(find.text('Could not load your Paints.'), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);
      expect(find.textContaining('no such table'), findsNothing);
      await tester.tap(find.text('Retry'));
      await settle(tester);
      expect(find.text('Retry'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => dir.delete(recursive: true));
    },
  );

  testWidgets(
    'a Paint lists the Units that use it and opens one; deleting it from its dialog says how many Units use it',
    (tester) async {
      final (vault, dir) = (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('app_test');
        final db = PowerSyncDatabase(
          schema: appSchema,
          path: '${dir.path}/vault.db',
        );
        await db.execute(
          "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id) VALUES ('w', 'Starter', 's0', 's0')",
        );
        await db.execute(
          "INSERT INTO stages (id, workflow_id, name, position) VALUES ('s0', 'w', 'Wishlist', 0)",
        );
        final vault = Vault(SqliteVaultStore(db));
        final blue = await vault.addPaint(
          brand: 'Citadel',
          range: 'Base',
          name: 'Macragge Blue',
        );
        for (final (collection, unit) in [
          ('Space Marines', 'Intercessors'),
          ('Dark Angels', 'Deathwing'),
        ]) {
          final c = await vault.createCollection(collection);
          await vault.addBatch(c, name: unit, modelCount: 5, stageId: 's0');
          await vault.addUnitPaint(c.id, unit, blue.id);
        }
        return (vault, dir);
      }))!;
      await tester.pumpWidget(MaterialApp(home: PaintsScreen(vault: vault)));
      await settle(tester);

      // Delete is in the Paint dialog, and confirmed.
      await tester.tap(find.text('Macragge Blue'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 Units use it'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Macragge Blue'));
      await tester.pumpAndSettle();
      final units = ['Deathwing', 'Intercessors'];
      final tops = [for (final s in units) tester.getTopLeft(find.text(s)).dy];
      expect(tops, [...tops]..sort(), reason: 'by Collection: $units');
      expect(find.text('Dark Angels'), findsOneWidget);
      await tester.tap(find.text('Intercessors'));
      await settle(tester);
      expect(find.byType(UnitScreen), findsOneWidget);
      expect(find.text('Citadel / Base'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => dir.delete(recursive: true));
    },
  );

  testWidgets(
    'the Paint dialog suggests brands in use and that brand\'s ranges, and returns the fields',
    (tester) async {
      PaintFields? result;
      const paints = [
        Paint(
          id: '1',
          brand: 'Citadel',
          range: 'Base',
          name: 'Macragge Blue',
          owned: true,
        ),
        Paint(
          id: '2',
          brand: 'Citadel',
          range: 'Shade',
          name: 'Nuln Oil',
          owned: true,
        ),
        Paint(
          id: '3',
          brand: 'Vallejo',
          range: 'Model Color',
          name: 'Flat Blue',
          owned: true,
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showDialog(
                context: context,
                builder: (_) => const PaintDialog(paints: paints),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('New Paint'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Brand'), 'cit');
      await tester.pumpAndSettle();
      expect(find.text('Vallejo'), findsNothing);
      await tester.tap(find.text('Citadel'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Range'), 's');
      await tester.pumpAndSettle();
      expect(find.text('Base'), findsNothing);
      await tester.tap(find.text('Shade'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Name'),
        'Agrax Earthshade',
      );
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(result, (
        brand: 'Citadel',
        range: 'Shade',
        name: 'Agrax Earthshade',
        owned: false,
      ));
    },
  );
}
