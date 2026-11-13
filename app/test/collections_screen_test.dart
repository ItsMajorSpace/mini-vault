// ignore_for_file: experimental_member_use

import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gotrue/gotrue.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/main.dart';
import 'package:mini_vault/photos.dart';
import 'package:mini_vault/progress.dart';
import 'package:mini_vault/theme.dart';
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
        find.text('Other'),
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
      'Warhammer',
      'Orks',
      'Ultramarines',
      'Other',
      'Terrain',
    ];
    final tops = [for (final t in order) tester.getTopLeft(find.text(t)).dy];
    expect(tops, [...tops]..sort(), reason: 'in the order $order');
    // Models, but no move yet.
    expect(find.text('Recently painted'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => dir.delete(recursive: true));
  });

  testWidgets(
    'the Collection dialog suggests Game Systems in use and returns the fields',
    (tester) async {
      (String, String?, String)? result;
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

      expect(result, ('Orks', null, 'Warhammer 40k'));
    },
  );

  testWidgets('shows a Collection\'s Units by name, with model counts', (
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
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    // One row per Unit, by name, counting the models of all its Batches.
    final rows = [
      'Captain',
      '1 model',
      'Intercessors',
      '15 models',
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
                  find.descendant(
                    of: find.descendant(
                      of: find.ancestor(
                        of: find.text('Terminators'),
                        matching: find.byType(ListTile),
                      ),
                      matching: find.byType(StageBar),
                    ),
                    matching: find.byType(DecoratedBox),
                  ),
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
      for (var i = 0; i < 20; i++) {
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
        expect(inRow(unit, find.byIcon(Icons.image_outlined)), findsOneWidget);
      }
      // Every row's leading square is the same size.
      for (final unit in ['Intercessors', 'Captain', 'Terminators']) {
        expect(
          tester.getSize(inRow(unit, find.byType(UnitThumbnail))),
          const Size.square(48),
        );
      }

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Recently painted lists the last 3 moved Units, newest first; tapping one opens its Move sheet',
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
      expect(find.text('Recently painted'), findsOneWidget);
      final order = ['Recently painted', 'Boyz', 'Captain', 'Nobz'];
      final tops = [for (final t in order) tester.getTopLeft(find.text(t)).dy];
      expect(tops, [...tops]..sort(), reason: 'in the order $order');
      expect(find.text('Intercessors'), findsNothing);
      // Each with its Collection and Stage bar.
      final boyz = find.ancestor(
        of: find.text('Boyz'),
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(of: boyz, matching: find.text('Orks')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: boyz, matching: find.byType(StageBar)),
        findsOneWidget,
      );

      // Primed, its latest move's from-Stage, still has 3 models: the sheet starts there.
      await tester.tap(find.text('Captain'));
      await settle();
      expect(find.text('Move from Primed'), findsOneWidget);
      expect(find.text('3 of 3'), findsOneWidget);
      expect(find.text('Move 3 models to Painted'), findsOneWidget);

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
        matching: find.byType(ListTile),
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
