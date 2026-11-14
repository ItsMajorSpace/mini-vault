// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gotrue/gotrue.dart';
import 'package:mini_vault/account.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/main.dart';
import 'package:mini_vault/photos.dart';
import 'package:mini_vault/theme.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:powersync/attachments/attachments.dart';
import 'package:powersync/powersync.dart';

// The account menu, the sign-out warning, and the sync icon and banner, against real SQLite.
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

/// The heading font and AppBar colour as shown on screen.
(String?, Color?) looks(WidgetTester tester, String title) {
  final text = tester.widget<RichText>(
    find.descendant(of: find.text(title), matching: find.byType(RichText)),
  );
  final bar = tester.widget<Material>(
    find
        .descendant(of: find.byType(AppBar), matching: find.byType(Material))
        .first,
  );
  return (text.text.style!.fontFamily, bar.color);
}

void main() {
  testWidgets(
    'Theme switches colours and heading font at once and survives a restart',
    (tester) async {
      final db = await openDb(tester, waiting: 0);
      final file = (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('theme_test');
        addTearDown(() => dir.delete(recursive: true));
        return File('${dir.path}/theme.txt');
      }))!;
      final setting = (await tester.runAsync(() => ThemeSetting.load(file)))!;
      expect(setting.value, AppTheme.grimdark);
      // Rebuilt on change the way MiniVaultApp is.
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: setting,
          builder: (_, _) => MaterialApp(
            theme: setting.value.data,
            home: CollectionsScreen(
              vault: Vault(SqliteVaultStore(db)),
              db: db,
              theme: setting,
            ),
          ),
        ),
      );
      await settle(tester);
      expect(looks(tester, 'Collections'), (
        stencilFont,
        AppTheme.grimdark.data.colorScheme.surface,
      ));

      await openMenu(tester);
      await tester.tap(find.text('Theme'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fantasy'));
      await settle(tester);
      final fantasy = AppTheme.fantasy.data.colorScheme;
      expect(looks(tester, 'Collections'), (cinzelFont, fantasy.surface));
      expect(
        fantasy.surface,
        isNot(AppTheme.grimdark.data.colorScheme.surface),
      );

      // Restart: a fresh setting from the same file, in the real app (signed out, so on Sign in).
      final reloaded = (await tester.runAsync(() => ThemeSetting.load(file)))!;
      final auth = GoTrueClient(
        url: 'http://localhost',
        autoRefreshToken: false,
      );
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('photos_test'),
      ))!;
      addTearDown(() => dir.delete(recursive: true));
      await tester.pumpWidget(
        MiniVaultApp(
          auth: auth,
          db: db,
          photos: PhotoFiles(db, auth, dir),
          theme: reloaded,
        ),
      );
      await settle(tester);
      expect(looks(tester, 'Mini Vault'), (cinzelFont, fantasy.surface));
    },
  );

  testWidgets('the account menu shows the email, Sign out and Delete account', (
    tester,
  ) async {
    final db = await openDb(tester, waiting: 0);
    var deletes = 0;
    await pumpCollections(tester, db, onDeleteAccount: () => deletes++);

    expect(find.byTooltip('Workflows'), findsNothing);
    expect(find.byIcon(Icons.account_tree), findsNothing);
    expect(find.byTooltip('Sign out'), findsNothing);
    expect(find.byTooltip('Delete account'), findsNothing);
    expect(find.byIcon(Icons.logout), findsNothing);
    expect(find.byIcon(Icons.person_remove), findsNothing);

    await openMenu(tester);
    expect(find.text('collector@example.com'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('Workflows'), findsNothing); // A bottom tab now.
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

  testWidgets('About shows the app version and build, and the font license', (
    tester,
  ) async {
    PackageInfo.setMockInitialValues(
      appName: 'mini_vault',
      packageName: 'mini_vault',
      version: '0.0.0-dev',
      buildNumber: '0',
      buildSignature: '',
    );
    final db = await openDb(tester, waiting: 0);
    await pumpCollections(tester, db);

    await openMenu(tester);
    await tester.tap(find.text('About'));
    await settle(tester);
    expect(find.text('0.0.0-dev (0)'), findsOneWidget);

    registerFontLicense();
    final fonts = await tester.runAsync(
      () => LicenseRegistry.licenses
          .where((l) => l.packages.contains('Black Ops One'))
          .toList(),
    );
    final text = fonts!.single.paragraphs.map((p) => p.text).join('\n');
    expect(text, contains('Copyright 2022 The Black-Ops Project Authors'));
    expect(text, contains('SIL OPEN FONT LICENSE Version 1.1'));
    final cinzel = await tester.runAsync(
      () => LicenseRegistry.licenses
          .where((l) => l.packages.contains('Cinzel'))
          .toList(),
    );
    expect(
      cinzel!.single.paragraphs.map((p) => p.text).join('\n'),
      contains('Copyright 2020 The Cinzel Project Authors'),
    );
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

    expect(find.byTooltip('1 change waiting to sync'), findsOneWidget);

    await openMenu(tester);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining("1 change hasn't synced yet and will be lost."),
      findsOneWidget,
    );
    expect(signOuts, 0);
  });

  group('the sync icon', () {
    Finder badge(String count) =>
        find.descendant(of: find.byType(Badge), matching: find.text(count));

    testWidgets('is a plain cloud when everything is synced', (tester) async {
      final db = await openDb(tester, waiting: 0);
      await pumpCollections(tester, db);
      connect(db);
      await settle(tester);

      expect(find.byTooltip('All changes synced'), findsOneWidget);
      expect(find.byIcon(Icons.cloud), findsOneWidget);
      expect(find.text('0'), findsNothing); // No badge.
      expect(find.byType(SyncBanner), findsOneWidget);
      expect(find.textContaining('sync'), findsNothing); // No bar, no banner.
    });

    testWidgets('counts the changes waiting in a badge', (tester) async {
      final db = await openDb(tester, waiting: 2);
      await pumpCollections(tester, db);
      connect(db);
      await settle(tester);

      expect(find.byTooltip('2 changes waiting to sync'), findsOneWidget);
      expect(find.byIcon(Icons.cloud), findsOneWidget);
      expect(badge('2'), findsOneWidget);
      expect(find.textContaining('sync'), findsNothing); // No banner.
    });

    testWidgets('is crossed out offline, still counting', (tester) async {
      final db = await openDb(tester, waiting: 2);
      await pumpCollections(tester, db);

      expect(find.byTooltip('2 changes waiting to sync'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);
      expect(badge('2'), findsOneWidget);
      expect(find.textContaining('sync'), findsNothing); // No banner.

      await tester.runAsync(() async => (await db.getCrudBatch())!.complete());
      await settle(tester);
      expect(find.byTooltip('Offline'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);
      expect(find.byType(Badge), findsOneWidget);
      expect(find.text('2'), findsNothing);
    });

    testWidgets('syncs now on a tap when connected, with a spinner', (
      tester,
    ) async {
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
      const tooltip = '2 changes waiting to sync';

      await tester.tap(find.byTooltip(tooltip)); // Offline: nothing.
      await tester.pump();
      expect(syncs, 0);

      connect(db);
      await settle(tester);
      await tester.tap(find.byTooltip(tooltip));
      await tester.pump();
      expect(syncs, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.cloud), findsNothing);
      await tester.tap(find.byTooltip(tooltip)); // Already syncing.
      await tester.pump();
      expect(syncs, 1);

      // A failed sync: no popup, the count stays.
      sync.completeError(Exception('offline'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(badge('2'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);

      sync = Completer<void>()..complete();
      await tester.tap(find.byTooltip(tooltip));
      await tester.pump();
      expect(syncs, 2);
    });

    testWidgets('also syncs from a Collection\'s own screen', (tester) async {
      final db = await openDb(tester, waiting: 0);
      await tester.runAsync(
        () => db.execute(
          "INSERT INTO collections (id, name, workflow_id) VALUES ('c', 'Crimson Fists', 'w')",
        ),
      );
      var syncs = 0;
      await pumpCollections(tester, db, onSyncNow: () async => syncs++);
      connect(db);
      await tester.tap(find.text('Crimson Fists'));
      await settle(tester);

      expect(find.byType(CollectionScreen), findsOneWidget);
      await tester.tap(
        find.byTooltip('1 change waiting to sync'),
      ); // The new Collection.
      await tester.pump();
      expect(syncs, 1);
    });
  });

  group('the sync banner', () {
    testWidgets('shows a sync error, on both screens', (tester) async {
      final db = await openDb(tester, waiting: 0);
      await tester.runAsync(
        () => db.execute(
          "INSERT INTO collections (id, name, workflow_id) VALUES ('c', 'Crimson Fists', 'w')",
        ),
      );
      await pumpCollections(tester, db);
      // ignore: invalid_use_of_protected_member, deprecated_member_use, no server to fail here.
      db.setStatus(db.currentStatus.copyWith(uploadError: Exception('boom')));
      await settle(tester);
      expect(find.text('Sync failed: Exception: boom'), findsOneWidget);

      await tester.tap(find.text('Crimson Fists'));
      await settle(tester);
      expect(find.byType(CollectionScreen), findsOneWidget);
      expect(find.text('Sync failed: Exception: boom'), findsOneWidget);
    });

    testWidgets('shows once changes have waited for over a day', (
      tester,
    ) async {
      final db = await openDb(tester, waiting: 2);
      var now = DateTime(2026, 11, 13, 9);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SyncBanner(db: db, now: () => now),
          ),
        ),
      );
      await settle(tester);
      const stale =
          "Changes haven't synced for over a day. Connect to the internet to keep them.";
      expect(find.text(stale), findsNothing);

      now = now.add(const Duration(hours: 23));
      await tester.pump(const Duration(hours: 23));
      expect(find.text(stale), findsNothing);

      now = now.add(const Duration(hours: 1));
      await tester.pump(const Duration(hours: 1)); // Nothing else changes.
      expect(find.text(stale), findsOneWidget);

      // Synced: the banner goes.
      await tester.runAsync(() async => (await db.getCrudBatch())!.complete());
      await settle(tester);
      expect(find.text(stale), findsNothing);
    });
  });
}

void connect(PowerSyncDatabase db) =>
    // ignore: invalid_use_of_protected_member, deprecated_member_use, no server to connect to here.
    db.setStatus(db.currentStatus.copyWith(connected: true));
