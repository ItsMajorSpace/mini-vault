import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/main.dart';
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
      PowerSyncDatabase open() => PowerSyncDatabase(
        schema: SqliteVaultStore.schema,
        path: '${dir.path}/vault.db',
      );

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
      expect(find.text('2 changes waiting to sync'), findsOneWidget);
      expect(find.byTooltip('New Collection'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => dir.delete(recursive: true));
    },
  );
}
