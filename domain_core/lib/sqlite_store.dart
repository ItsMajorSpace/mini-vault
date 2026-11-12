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
