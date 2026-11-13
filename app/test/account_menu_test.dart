// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/main.dart';
import 'package:mini_vault/photos.dart';
import 'package:powersync/attachments/attachments.dart';
import 'package:powersync/powersync.dart';

// The account menu, the sign-out warning and Sync now on the Collections screen, against real SQLite.
// The database is never connected; a connected status is set by hand.
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

/// A database holding the starter Workflow with [waiting] row changes left in its upload queue (0 or 2).
Future<PowerSyncDatabase> openDb(
  WidgetTester tester, {
  required int waiting,
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
  if (waiting == 0) await (await db.getCrudBatch())!.complete();
  return db;
}))!;

Future<void> pumpCollections(
  WidgetTester tester,
  PowerSyncDatabase db, {
  VoidCallback? onSignOut,
  VoidCallback? onDeleteAccount,
  Future<void> Function()? onSyncNow,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CollectionsScreen(
        vault: Vault(SqliteVaultStore(db)),
        db: db,
        email: 'collector@example.com',
        onSignOut: onSignOut ?? () {},
        onDeleteAccount: onDeleteAccount ?? () {},
        onSyncNow: onSyncNow,
      ),
    ),
  );
  await settle(tester);
}

Future<void> openMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Account'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the account menu shows the email, Sign out and Delete account', (
    tester,
  ) async {
    final db = await openDb(tester, waiting: 0);
    var deletes = 0;
    await pumpCollections(tester, db, onDeleteAccount: () => deletes++);

    expect(find.byTooltip('Workflows'), findsOneWidget);
    expect(find.byTooltip('Sign out'), findsNothing);
    expect(find.byTooltip('Delete account'), findsNothing);
    expect(find.byIcon(Icons.logout), findsNothing);
    expect(find.byIcon(Icons.person_remove), findsNothing);

    await openMenu(tester);
    expect(find.text('collector@example.com'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);
    expect(find.byType(PopupMenuDivider), findsOneWidget);

    await tester.tap(find.text('collector@example.com'));
    await tester.pumpAndSettle();
    expect(
      find.text('Sign out'),
      findsOneWidget,
    ); // Not tappable: the menu stays.

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    expect(deletes, 1);
  });

  testWidgets('signing out with everything synced asks nothing', (
    tester,
  ) async {
    final db = await openDb(tester, waiting: 0);
    var signOuts = 0;
    await pumpCollections(tester, db, onSignOut: () => signOuts++);

    await openMenu(tester);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(signOuts, 1);
  });

  testWidgets('signing out with unsynced changes warns first', (tester) async {
    final db = await openDb(tester, waiting: 2);
    var signOuts = 0;
    await pumpCollections(tester, db, onSignOut: () => signOuts++);

    await openMenu(tester);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Sign out with unsynced changes?'), findsOneWidget);
    expect(
      find.text(
        "2 changes haven't synced yet and will be lost. "
        'Connect to the internet and wait for them to sync to keep them.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(signOuts, 0);

    await openMenu(tester);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out anyway'));
    await tester.pumpAndSettle();
    expect(signOuts, 1);
  });

  testWidgets('the unsynced count includes photos waiting to upload', (
    tester,
  ) async {
    final db = await openDb(tester, waiting: 0);
    await tester.runAsync(() async {
      for (final (id, state) in [
        ('waiting', AttachmentState.queuedUpload),
        ('uploaded', AttachmentState.synced),
        ('incoming', AttachmentState.queuedDownload),
      ]) {
        await db.execute(
          'INSERT INTO ${photoQueueTable.name} (id, filename, timestamp, state, has_synced) VALUES (?, ?, 0, ?, 0)',
          [id, '$id.jpg', state.toInt()],
        );
      }
    });
    var signOuts = 0;
    await pumpCollections(tester, db, onSignOut: () => signOuts++);

    expect(find.text('1 change waiting to sync'), findsOneWidget);

    await openMenu(tester);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining("1 change hasn't synced yet and will be lost."),
      findsOneWidget,
    );
    expect(signOuts, 0);
  });

  testWidgets(
    'Sync now shows only when connected with changes waiting, and syncs',
    (tester) async {
      final db = await openDb(tester, waiting: 2);
      var syncs = 0;
      var sync = Completer<void>();
      await pumpCollections(
        tester,
        db,
        onSyncNow: () {
          syncs++;
          return sync.future;
        },
      );

      expect(find.text('2 changes waiting to sync'), findsOneWidget);
      expect(find.text('Sync now'), findsNothing); // Offline.

      // ignore: invalid_use_of_protected_member, deprecated_member_use, no server to connect to here.
      db.setStatus(db.currentStatus.copyWith(connected: true));
      await settle(tester);
      await tester.tap(find.text('Sync now'));
      await tester.pump();
      expect(syncs, 1);
      expect(find.text('Sync now'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // A failed sync: no popup, the count and button stay.
      sync.completeError(Exception('offline'));
      await tester.pump();
      expect(find.text('Sync now'), findsOneWidget);
      expect(find.text('2 changes waiting to sync'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);

      sync = Completer<void>()..complete();
      await tester.tap(find.text('Sync now'));
      await tester.pump();
      expect(syncs, 2);
    },
  );

  testWidgets('Sync now is hidden when connected with nothing waiting', (
    tester,
  ) async {
    final db = await openDb(tester, waiting: 0);
    await pumpCollections(tester, db, onSyncNow: () async {});
    // ignore: invalid_use_of_protected_member, deprecated_member_use, no server to connect to here.
    db.setStatus(db.currentStatus.copyWith(connected: true));
    await settle(tester);

    expect(find.text('All changes synced'), findsOneWidget);
    expect(find.text('Sync now'), findsNothing);
  });

  testWidgets('Sync now also shows on a Collection\'s own screen', (
    tester,
  ) async {
    final db = await openDb(tester, waiting: 0);
    await tester.runAsync(
      () => db.execute(
        "INSERT INTO collections (id, name, workflow_id) VALUES ('c', 'Crimson Fists', 'w')",
      ),
    );
    var syncs = 0;
    await pumpCollections(tester, db, onSyncNow: () async => syncs++);
    // ignore: invalid_use_of_protected_member, deprecated_member_use, no server to connect to here.
    db.setStatus(db.currentStatus.copyWith(connected: true));
    await tester.tap(find.text('Crimson Fists'));
    await settle(tester);

    expect(find.text('Sync now'), findsOneWidget);
    await tester.tap(find.text('Sync now'));
    await tester.pump();
    expect(syncs, 1);
  });
}
