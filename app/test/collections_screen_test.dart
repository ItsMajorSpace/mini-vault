import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/main.dart';
import 'package:sqlite_async/sqlite_async.dart';

// Smoke test: the Collections list renders what is stored in real SQLite, across an app restart.
// shortcut: Collections are created through the Vault, not the dialogs: SQLite I/O started from a tap
// never completes inside the widget tester's fake-async zone. Drive the dialogs in an integration test on a device.
void main() {
  testWidgets('shows the stored Collections after a restart', (tester) async {
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('app_test'),
    ))!;
    late SqliteDatabase db;
    late Vault vault;

    Future<void> launch() async {
      await tester.runAsync(() async {
        db = SqliteDatabase(path: '${dir.path}/mini_vault.db');
        await SqliteVaultStore.createTables(db);
        vault = Vault(SqliteVaultStore(db));
      });
      await tester.pumpWidget(MiniVaultApp(key: UniqueKey(), vault: vault));
      // Lets the list's SQLite read (several isolate round trips) finish, then the UI catch up.
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await launch();
    expect(find.text('No Collections yet'), findsOneWidget);

    await tester.runAsync(() async {
      final created = await vault.createCollection('Space Marines');
      await vault.renameCollection(created.id, 'Ultramarines');
      await db.close();
    });
    await launch();

    expect(find.text('Ultramarines'), findsOneWidget);
    expect(find.byTooltip('New Collection'), findsOneWidget);

    await tester.runAsync(() async {
      await db.close();
      await dir.delete(recursive: true);
    });
  });
}
