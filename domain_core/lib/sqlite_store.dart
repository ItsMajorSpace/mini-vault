/// [VaultStore] over the app's local SQLite database, managed by PowerSync. Kept out of `domain_core.dart` so the server never needs it.
library;

import 'package:powersync/powersync.dart';
import 'package:sqlite_async/sqlite_async.dart';

import 'domain_core.dart';

class SqliteVaultStore implements VaultStore {
  /// Takes the app's `PowerSyncDatabase`, opened with [schema].
  SqliteVaultStore(this._db);

  final SqliteConnection _db;

  /// The synced tables, as PowerSync views. Each row's `owner_id` stays on the server: sync only sends a user their own rows.
  static const schema = Schema([
    Table('workflows', [
      Column.text('name'),
      Column.text('owned_stage_id'),
      Column.text('finished_stage_id'),
      // Set by the server on the account's starter Workflow; read-only for the client.
      Column.integer('starter'),
    ]),
    Table('stages', [
      Column.text('workflow_id'),
      Column.text('name'),
      Column.integer('position'),
    ]),
    Table('collections', [Column.text('name'), Column.text('workflow_id')]),
    Table('units', [
      Column.text('collection_id'),
      Column.text('stage_id'),
      Column.text('name'),
      Column.integer('model_count'),
      Column.text('notes'),
    ]),
  ]);

  // Stage order is (position, id): concurrent reorders on two devices can merge into equal positions, and the id
  // breaks the tie the same way everywhere (as on the server), so every merge still reads as one clean order.
  @override
  Future<List<Workflow>> workflows() => _db.readTransaction((tx) async {
    final stages = await tx.getAll(
      'SELECT id, workflow_id, name FROM stages ORDER BY position, id',
    );
    final workflows = await tx.getAll(
      'SELECT * FROM workflows ORDER BY starter IS NOT 1, name COLLATE NOCASE, id',
    );
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
  Stream<List<Workflow>> watchWorkflows() =>
      _db.onChange(['workflows', 'stages']).asyncMap((_) => workflows());

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
  Future<void> renameWorkflow(String id, String name) =>
      _db.execute('UPDATE workflows SET name = ? WHERE id = ?', [name, id]);

  // Stages first, so the server never sees a moment where the Workflow is gone but its Stages are not.
  @override
  Future<void> deleteWorkflow(String id) => _db.writeTransaction((tx) async {
    await tx.execute('DELETE FROM stages WHERE workflow_id = ?', [id]);
    await tx.execute('DELETE FROM workflows WHERE id = ?', [id]);
  });

  @override
  Future<void> setOwnedStage(String workflowId, String stageId) => _db.execute(
    'UPDATE workflows SET owned_stage_id = ? WHERE id = ?',
    [stageId, workflowId],
  );

  @override
  Future<void> setFinishedStage(String workflowId, String stageId) =>
      _db.execute('UPDATE workflows SET finished_stage_id = ? WHERE id = ?', [
        stageId,
        workflowId,
      ]);

  @override
  Future<void> insertStage(
    String workflowId,
    Stage stage,
    List<String> order,
  ) => _db.writeTransaction((tx) async {
    await tx.execute(
      'INSERT INTO stages (id, workflow_id, name, position) VALUES (?, ?, ?, 0)',
      [stage.id, workflowId, stage.name],
    );
    await _writeOrder(tx, order);
  });

  @override
  Future<void> renameStage(String id, String name) =>
      _db.execute('UPDATE stages SET name = ? WHERE id = ?', [name, id]);

  @override
  Future<void> reorderStages(List<String> order) =>
      _db.writeTransaction((tx) => _writeOrder(tx, order));

  /// Renumbers the Stages 0, 1, 2... in [order], writing (and so uploading) only the positions that change.
  static Future<void> _writeOrder(
    SqliteWriteContext tx,
    List<String> order,
  ) async {
    for (final (position, id) in order.indexed) {
      await tx.execute(
        'UPDATE stages SET position = ? WHERE id = ? AND position IS NOT ?',
        [position, id, position],
      );
    }
  }

  @override
  Future<void> deleteStage(String id) =>
      _db.execute('DELETE FROM stages WHERE id = ?', [id]);

  @override
  Future<bool> stageHoldsUnits(String id) async => (await _db.getAll(
    'SELECT 1 FROM units WHERE stage_id = ? LIMIT 1',
    [id],
  )).isNotEmpty;

  static const _collectionsQuery =
      'SELECT * FROM collections ORDER BY name COLLATE NOCASE';

  @override
  Future<List<Collection>> collections() async =>
      _toCollections(await _db.getAll(_collectionsQuery));

  @override
  Stream<List<Collection>> watchCollections() =>
      _db.watch(_collectionsQuery).map(_toCollections);

  static List<Collection> _toCollections(Iterable<Map<String, Object?>> rows) =>
      [
        for (final c in rows)
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

  // An UPDATE of one column, so sync uploads it as a per-field change (PATCH).
  @override
  Future<void> renameCollection(String id, String name) =>
      _db.execute('UPDATE collections SET name = ? WHERE id = ?', [name, id]);

  @override
  Stream<List<Unit>> watchUnits(String collectionId) => _db
      .watch(
        'SELECT * FROM units WHERE collection_id = ? ORDER BY name COLLATE NOCASE',
        parameters: [collectionId],
      )
      .map(
        (rows) => [
          for (final u in rows)
            Unit(
              id: u['id'] as String,
              collectionId: u['collection_id'] as String,
              stageId: u['stage_id'] as String,
              name: u['name'] as String,
              modelCount: u['model_count'] as int,
              notes: u['notes'] as String? ?? '',
            ),
        ],
      );

  @override
  Future<void> insertUnit(Unit unit) => _db.execute(
    'INSERT INTO units (id, collection_id, stage_id, name, model_count, notes) VALUES (?, ?, ?, ?, ?, ?)',
    [
      unit.id,
      unit.collectionId,
      unit.stageId,
      unit.name,
      unit.modelCount,
      unit.notes,
    ],
  );

  // Only the given columns, so sync uploads a PATCH of just those fields.
  @override
  Future<void> updateUnit(
    String id, {
    String? name,
    int? modelCount,
    String? notes,
  }) async {
    final changes = {
      'name': ?name,
      'model_count': ?modelCount,
      'notes': ?notes,
    };
    if (changes.isEmpty) return;
    await _db.execute(
      'UPDATE units SET ${changes.keys.map((c) => '$c = ?').join(', ')} WHERE id = ?',
      [...changes.values, id],
    );
  }

  @override
  Future<void> deleteUnit(String id) =>
      _db.execute('DELETE FROM units WHERE id = ?', [id]);
}
