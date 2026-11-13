// ignore_for_file: experimental_member_use

import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gotrue/gotrue.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/main.dart';
import 'package:mini_vault/photos.dart';
import 'package:powersync/attachments/attachments.dart';
import 'package:powersync/powersync.dart' hide Column;

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

  /// Opens the Batch screen on 5 Intercessors at Unassembled, with 2 photos not downloaded yet (no files to load in a test).
  Future<(Vault, Collection, Batch)> openBatch(WidgetTester tester) async {
    final (vault, collection, batch, files) = (await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('app_test');
      final db = PowerSyncDatabase(
        schema: appSchema,
        path: '${dir.path}/vault.db',
      );
      await db.execute(
        "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id) VALUES ('w', 'Starter', 's1', 's2')",
      );
      for (final (i, name) in ['Wishlist', 'Unassembled', 'Primed'].indexed) {
        await db.execute(
          'INSERT INTO stages (id, workflow_id, name, position) VALUES (?, ?, ?, ?)',
          ['s$i', 'w', name, i],
        );
      }
      final vault = Vault(SqliteVaultStore(db));
      final collection = await vault.createCollection('Space Marines');
      final batch = await vault.addBatch(
        collection,
        name: 'Intercessors',
        modelCount: 5,
        stageId: 's1',
      );
      for (final file in ['a', 'b']) {
        await SqliteVaultStore.insertPhoto(
          db,
          Photo(
            id: 'p$file',
            collectionId: collection.id,
            unit: batch.name,
            fileId: file,
          ),
        );
        await db.execute(
          'INSERT INTO ${photoQueueTable.name} (id, filename, local_uri, timestamp, state, has_synced) '
          'VALUES (?, ?, NULL, 1, ?, 1)',
          [file, '$file.jpg', AttachmentState.queuedDownload.toInt()],
        );
      }
      final files = PhotoFiles(
        db,
        GoTrueClient(url: 'http://localhost'),
        Directory('${dir.path}/photos'),
      );
      return (vault, collection, batch, files);
    }))!;
    await tester.pumpWidget(
      MaterialApp(
        home: BatchScreen(
          vault: vault,
          photos: files,
          collection: collection,
          batchId: batch.id,
        ),
      ),
    );
    await settle(tester);
    return (vault, collection, batch);
  }

  testWidgets('Delete in the Edit dialog asks first; Cancel keeps the Batch', (
    tester,
  ) async {
    final (vault, collection, _) = await openBatch(tester);
    Future<int> batches() async =>
        (await tester.runAsync(() => vault.batchesOf(collection)))!.length;

    await tapAndWait(tester, find.byTooltip('Edit Unit'));
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete this Unit?'), findsOneWidget);
    expect(
      find.text(
        'Its 5 models and their history will be deleted on all your devices.',
      ),
      findsOneWidget,
    );
    await tapAndWait(tester, find.text('Cancel').last);
    expect(await batches(), 1);
    // Back in the Edit dialog, which a second Delete, confirmed, closes along with the screen.
    expect(find.text('Edit Unit'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tapAndWait(tester, find.text('Delete').last);
    expect(await batches(), 0);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'tapping a photo opens it full screen without removing it; Remove there asks first',
    (tester) async {
      final (vault, _, batch) = await openBatch(tester);
      Future<int> photos() async => (await tester.runAsync(
        () => vault.photosOf(batch.collectionId, batch.name),
      ))!.length;

      await tester.tap(
        find
            .descendant(
              of: find.byType(UnitPhotos),
              matching: find.byType(InkWell),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Remove this photo?'), findsNothing);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.text('1 of 2'), findsOneWidget);
      expect(await photos(), 2);

      // Swipe to the next photo.
      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
      await tester.pumpAndSettle();
      expect(find.text('2 of 2'), findsOneWidget);

      await tester.tap(find.byTooltip('Remove photo'));
      await tester.pumpAndSettle();
      expect(find.text('Remove this photo?'), findsOneWidget);
      await tapAndWait(tester, find.text('Cancel'));
      expect(await photos(), 2);

      await tester.tap(find.byTooltip('Remove photo'));
      await tester.pumpAndSettle();
      await tapAndWait(tester, find.text('Remove'));
      expect(find.byType(PageView), findsNothing);
      expect(await photos(), 1);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Move opens the Move sheet, which moves the chosen count', (
    tester,
  ) async {
    final (vault, collection, _) = await openBatch(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Move'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Move from Unassembled'), findsOneWidget);
    expect(find.text('5 of 5'), findsOneWidget);
    // Details would reopen this screen.
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Details'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('One fewer'));
    await tester.pump();
    await tapAndWait(tester, find.text('Move 4 models to Primed'));
    final batches = (await tester.runAsync(() => vault.batchesOf(collection)))!;
    expect([
      for (final u in batches) (u.stageId, u.modelCount),
    ], unorderedEquals([('s1', 1), ('s2', 4)]));

    await tester.pumpWidget(const SizedBox());
  });
}
