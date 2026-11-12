/// [VaultStore] over local SQLite, used by the app. Kept out of `domain_core.dart` so the server never needs it.
library;

import 'package:sqlite_async/sqlite_async.dart';

import 'domain_core.dart';

class SqliteVaultStore implements VaultStore {
  /// Takes any sqlite_async connection, so a `PowerSyncDatabase` can be passed in later.
  SqliteVaultStore(this._db);

  final SqliteConnection _db;

  /// Tables are shaped like PowerSync's synced views: a text UUID `id`, plain columns, no constraints.
  // shortcut: hand-written tables with no migrations; replaced by a PowerSync Schema when sync lands (#5).
  static Future<void> createTables(SqliteConnection db) =>
      db.writeTransaction((tx) async {
        await tx.execute(
          'CREATE TABLE IF NOT EXISTS workflows '
          '(id TEXT PRIMARY KEY NOT NULL, name TEXT, owned_stage_id TEXT, finished_stage_id TEXT)',
        );
        await tx.execute(
          'CREATE TABLE IF NOT EXISTS stages '
          '(id TEXT PRIMARY KEY NOT NULL, workflow_id TEXT, name TEXT, position INTEGER)',
        );
        await tx.execute(
          'CREATE TABLE IF NOT EXISTS collections '
          '(id TEXT PRIMARY KEY NOT NULL, name TEXT, workflow_id TEXT)',
        );
      });

  @override
  Future<List<Workflow>> workflows() => _db.readTransaction((tx) async {
    final stages = await tx.getAll(
      'SELECT id, workflow_id, name FROM stages ORDER BY position',
    );
    final workflows = await tx.getAll('SELECT * FROM workflows');
    return [
      for (final w in workflows)
        Workflow(
          id: w['id'] as String,
          name: w['name'] as String,
          ownedStageId: w['owned_stage_id'] as String,
          finishedStageId: w['finished_stage_id'] as String,
          stages: [
            for (final s in stages)
              if (s['workflow_id'] == w['id'])
                Stage(id: s['id'] as String, name: s['name'] as String),
          ],
        ),
    ];
  });

  @override
  Future<void> insertWorkflow(Workflow workflow) =>
      _db.writeTransaction((tx) async {
        await tx.execute(
          'INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id) VALUES (?, ?, ?, ?)',
          [
            workflow.id,
            workflow.name,
            workflow.ownedStageId,
            workflow.finishedStageId,
          ],
        );
        for (final (position, stage) in workflow.stages.indexed) {
          await tx.execute(
            'INSERT INTO stages (id, workflow_id, name, position) VALUES (?, ?, ?, ?)',
            [stage.id, workflow.id, stage.name, position],
          );
        }
      });

  @override
  Future<List<Collection>> collections() async => [
    for (final c in await _db.getAll(
      'SELECT * FROM collections ORDER BY name COLLATE NOCASE',
    ))
      Collection(
        id: c['id'] as String,
        name: c['name'] as String,
        workflowId: c['workflow_id'] as String,
      ),
  ];

  @override
  Future<void> insertCollection(Collection collection) => _db.execute(
    'INSERT INTO collections (id, name, workflow_id) VALUES (?, ?, ?)',
    [collection.id, collection.name, collection.workflowId],
  );

  // An UPDATE of one column, so sync can send it as a per-field change.
  @override
  Future<void> renameCollection(String id, String name) =>
      _db.execute('UPDATE collections SET name = ? WHERE id = ?', [name, id]);
}
