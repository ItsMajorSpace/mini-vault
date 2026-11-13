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
      Column.text('colour'),
    ]),
    Table('collections', [
      Column.text('name'),
      Column.text('workflow_id'),
      Column.text('game_system'),
    ]),
    Table('units', [
      Column.text('collection_id'),
      Column.text('stage_id'),
      Column.text('name'),
      Column.integer('model_count'),
      Column.text('notes'),
    ]),
    Table('stage_changes', [
      Column.text('unit_id'),
      Column.text('from_stage_id'),
      Column.text('to_stage_id'),
      Column.integer('model_count'),
      Column.text('happened_at'),
    ]),
    // One row per Tag on a Unit; its id is [tagId], so the same Tag added on two devices is one row.
    Table('unit_tags', [Column.text('unit_id'), Column.text('name')]),
    // file_id is the image file's PowerSync attachment id; a Split's copy of a Photo shares it.
    Table('photos', [Column.text('unit_id'), Column.text('file_id')]),
    // Append-only deltas the write API applies to model_count: a Split takes model_count models off unit_id into
    // new_unit_id, and a Merge adds merged_unit_id's models to unit_id and deletes it.
    Table('splits', [
      Column.text('unit_id'),
      Column.text('new_unit_id'),
      Column.integer('model_count'),
    ]),
    Table('merges', [Column.text('unit_id'), Column.text('merged_unit_id')]),
    // The paint library; owned is 1, wanted 0.
    Table('paints', [
      Column.text('brand'),
      Column.text('range'),
      Column.text('name'),
      Column.integer('owned'),
    ]),
  ]);

  // Stage order is (position, id): concurrent reorders on two devices can merge into equal positions, and the id
  // breaks the tie the same way everywhere (as on the server), so every merge still reads as one clean order.
  @override
  Future<List<Workflow>> workflows() => _db.readTransaction((tx) async {
    final stages = await tx.getAll(
      'SELECT id, workflow_id, name, colour FROM stages ORDER BY position, id',
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
            for (final (i, s)
                in stages.where((s) => s['workflow_id'] == w['id']).indexed)
              Stage(
                id: s['id'] as String,
                name: s['name'] as String,
                // Null only on a Stage written before colours, not yet synced: as the server's backfill would.
                colour:
                    s['colour'] as String? ??
                    Vault.stageColours[i % Vault.stageColours.length],
              ),
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
            'INSERT INTO stages (id, workflow_id, name, position, colour) VALUES (?, ?, ?, ?, ?)',
            [stage.id, workflow.id, stage.name, position, stage.colour],
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
      'INSERT INTO stages (id, workflow_id, name, position, colour) VALUES (?, ?, ?, 0, ?)',
      [stage.id, workflowId, stage.name, stage.colour],
    );
    await _writeOrder(tx, order);
  });

  @override
  Future<void> renameStage(String id, String name) =>
      _db.execute('UPDATE stages SET name = ? WHERE id = ?', [name, id]);

  @override
  Future<void> setStageColour(String id, String colour) =>
      _db.execute('UPDATE stages SET colour = ? WHERE id = ?', [colour, id]);

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
  Future<void> deleteStage(
    String workflowId,
    String id, {
    List<StageChange> moves = const [],
    String? ownedStageId,
    String? finishedStageId,
  }) => _db.writeTransaction((tx) async {
    for (final move in moves) {
      await _move(tx, move);
    }
    for (final (column, stageId) in [
      ('owned_stage_id', ownedStageId),
      ('finished_stage_id', finishedStageId),
    ]) {
      if (stageId != null) {
        await tx.execute('UPDATE workflows SET $column = ? WHERE id = ?', [
          stageId,
          workflowId,
        ]);
      }
    }
    await tx.execute('DELETE FROM stages WHERE id = ?', [id]);
  });

  @override
  Future<void> switchWorkflow(
    String collectionId,
    String workflowId,
    List<StageChange> moves,
  ) => _db.writeTransaction((tx) async {
    for (final move in moves) {
      await _move(tx, move);
    }
    await tx.execute('UPDATE collections SET workflow_id = ? WHERE id = ?', [
      workflowId,
      collectionId,
    ]);
  });

  @override
  Future<List<Unit>> unitsAt(String stageId) async => _toUnits(
    await _db.getAll('SELECT * FROM units WHERE stage_id = ?', [stageId]),
  );

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
            gameSystem: c['game_system'] as String?,
          ),
      ];

  @override
  Future<void> insertCollection(Collection collection) => _db.execute(
    'INSERT INTO collections (id, name, workflow_id, game_system) VALUES (?, ?, ?, ?)',
    [
      collection.id,
      collection.name,
      collection.workflowId,
      collection.gameSystem,
    ],
  );

  // An UPDATE of one column, so sync uploads it as a per-field change (PATCH).
  @override
  Future<void> renameCollection(String id, String name) =>
      _db.execute('UPDATE collections SET name = ? WHERE id = ?', [name, id]);

  @override
  Future<void> setGameSystem(String id, String? gameSystem) => _db.execute(
    'UPDATE collections SET game_system = ? WHERE id = ?',
    [gameSystem, id],
  );

  // As deleteUnit, for every Unit: Stage Changes are left to the server, and children go first. The server also
  // deletes Units this device hasn't seen yet when the Collection's delete arrives.
  @override
  Future<void> deleteCollection(String id) => _db.writeTransaction((tx) async {
    const units = 'SELECT id FROM units WHERE collection_id = ?';
    await tx.execute('DELETE FROM unit_tags WHERE unit_id IN ($units)', [id]);
    await tx.execute('DELETE FROM photos WHERE unit_id IN ($units)', [id]);
    await tx.execute('DELETE FROM units WHERE collection_id = ?', [id]);
    await tx.execute('DELETE FROM collections WHERE id = ?', [id]);
  });

  @override
  Stream<List<Unit>> watchUnits(String collectionId) => _db
      .watch(
        'SELECT * FROM units WHERE collection_id = ? ORDER BY name COLLATE NOCASE',
        parameters: [collectionId],
      )
      .map(_toUnits);

  @override
  Stream<List<Unit>> watchAllUnits() =>
      _db.watch('SELECT * FROM units').map(_toUnits);

  static List<Unit> _toUnits(Iterable<Map<String, Object?>> rows) => [
    for (final u in rows)
      Unit(
        id: u['id'] as String,
        collectionId: u['collection_id'] as String,
        stageId: u['stage_id'] as String,
        name: u['name'] as String,
        modelCount: u['model_count'] as int,
        notes: u['notes'] as String? ?? '',
      ),
  ];

  @override
  Future<void> insertUnit(Unit unit, StageChange initial) =>
      _db.writeTransaction((tx) async {
        await tx.execute(
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
        await _insertStageChange(tx, initial);
      });

  // stage_id is written here only so the move shows at once offline; the server re-derives it from the latest Stage Change.
  @override
  Future<void> insertStageChange(StageChange change) =>
      _db.writeTransaction((tx) => _move(tx, change));

  static Future<void> _move(SqliteWriteContext tx, StageChange change) async {
    await tx.execute('UPDATE units SET stage_id = ? WHERE id = ?', [
      change.toStageId,
      change.unitId,
    ]);
    await _insertStageChange(tx, change);
  }

  // A new Stage Change must sort after every one this device knows for the Unit, or a device whose clock runs
  // behind another's could never move it: so it is stamped at least 1 ms after the latest known one.
  static Future<void> _insertStageChange(
    SqliteWriteContext tx,
    StageChange c,
  ) async {
    var at = c.happenedAt.toUtc();
    for (final row in await tx.getAll(
      'SELECT happened_at FROM stage_changes WHERE unit_id = ?',
      [c.unitId],
    )) {
      final known = DateTime.parse(row['happened_at'] as String).toUtc();
      if (!at.isAfter(known)) at = known.add(const Duration(milliseconds: 1));
    }
    await tx.execute(
      'INSERT INTO stage_changes (id, unit_id, from_stage_id, to_stage_id, model_count, happened_at) VALUES (?, ?, ?, ?, ?, ?)',
      [
        c.id,
        c.unitId,
        c.fromStageId,
        c.toStageId,
        c.modelCount,
        at.toIso8601String(),
      ],
    );
  }

  @override
  Stream<List<StageChange>> watchStageChanges(String unitId) => _db
      .watch(
        'SELECT * FROM stage_changes WHERE unit_id = ?',
        parameters: [unitId],
      )
      .map(_toStageChanges);

  // shortcut: reads every move ever made to find the latest few, fine for one person's collection; sort and limit in
  // SQL once happened_at is stored in one text format, if it gets slow.
  @override
  Stream<List<StageChange>> watchMoves() => _db
      .watch('SELECT * FROM stage_changes WHERE from_stage_id IS NOT NULL')
      .map((rows) => _toStageChanges(rows).reversed.toList());

  // Sorted after parsing: synced timestamps come back from Postgres in a different text format than local ones.
  // Oldest first, ties broken on id, as on the server.
  static List<StageChange> _toStageChanges(
    Iterable<Map<String, Object?>> rows,
  ) =>
      [
        for (final c in rows)
          StageChange(
            id: c['id'] as String,
            unitId: c['unit_id'] as String,
            fromStageId: c['from_stage_id'] as String?,
            toStageId: c['to_stage_id'] as String,
            modelCount: c['model_count'] as int,
            happenedAt: DateTime.parse(c['happened_at'] as String),
          ),
      ]..sort(
        (a, b) => switch (a.happenedAt.compareTo(b.happenedAt)) {
          0 => a.id.compareTo(b.id),
          final order => order,
        },
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

  // Its Stage Changes are append-only, so they are not deleted here: the server deletes them with the Unit,
  // and sync then removes them from this device.
  // Tags and Photos first, so their deletes upload too and nothing points at the deleted Unit.
  @override
  Future<void> deleteUnit(String id) => _db.writeTransaction((tx) async {
    await tx.execute('DELETE FROM unit_tags WHERE unit_id = ?', [id]);
    await tx.execute('DELETE FROM photos WHERE unit_id = ?', [id]);
    await tx.execute('DELETE FROM units WHERE id = ?', [id]);
  });

  @override
  Stream<List<String>> watchTags(String unitId) => _db
      .watch(
        'SELECT name FROM unit_tags WHERE unit_id = ? ORDER BY name COLLATE NOCASE',
        parameters: [unitId],
      )
      .map((rows) => [for (final r in rows) r['name'] as String]);

  // addTags reuses a Tag's first casing, so casings differ only after offline adds on two devices; ORDER BY
  // makes the pick the same everywhere.
  @override
  Future<List<String>> allTagNames() async => [
    for (final r in await _db.getAll(
      'SELECT DISTINCT name FROM unit_tags ORDER BY name',
    ))
      r['name'] as String,
  ];

  @override
  Future<void> insertTags(String unitId, Map<String, String> namesById) =>
      _db.writeTransaction((tx) async {
        for (final MapEntry(key: id, value: name) in namesById.entries) {
          await tx.execute(
            'INSERT INTO unit_tags (id, unit_id, name) SELECT ?, ?, ? '
            'WHERE NOT EXISTS (SELECT 1 FROM unit_tags WHERE id = ?)',
            [id, unitId, name, id],
          );
        }
      });

  @override
  Future<void> deleteTag(String id) =>
      _db.execute('DELETE FROM unit_tags WHERE id = ?', [id]);

  @override
  Stream<List<Photo>> watchPhotos(String unitId) => _db
      .watch(
        'SELECT id, unit_id, file_id FROM photos WHERE unit_id = ? ORDER BY id',
        parameters: [unitId],
      )
      .map(
        (rows) => [
          for (final r in rows)
            Photo(
              id: r['id'] as String,
              unitId: r['unit_id'] as String,
              fileId: r['file_id'] as String,
            ),
        ],
      );

  @override
  Future<void> insertPhotos(List<Photo> photos) =>
      _db.writeTransaction((tx) async {
        for (final p in photos) {
          await insertPhoto(tx, p);
        }
      });

  /// Inserts [photo] inside [tx]: the app stores a new image file's Photo in the transaction that queues the file.
  static Future<void> insertPhoto(SqliteWriteContext tx, Photo photo) =>
      tx.execute('INSERT INTO photos (id, unit_id, file_id) VALUES (?, ?, ?)', [
        photo.id,
        photo.unitId,
        photo.fileId,
      ]);

  @override
  Future<void> deletePhoto(String id) =>
      _db.execute('DELETE FROM photos WHERE id = ?', [id]);

  // The new Unit's rows come first, so the Split's reference to it resolves on the server. The count changes
  // relatively here too; their uploaded absolute values are ignored by the write API, which applies the delta.
  @override
  Future<void> insertSplit(
    String id,
    String sourceId,
    Unit created,
    StageChange move,
    Map<String, String> tagsById,
    List<Photo> photos,
  ) => _db.writeTransaction((tx) async {
    await tx.execute(
      'INSERT INTO units (id, collection_id, stage_id, name, model_count, notes) VALUES (?, ?, ?, ?, ?, ?)',
      [
        created.id,
        created.collectionId,
        created.stageId,
        created.name,
        created.modelCount,
        created.notes,
      ],
    );
    await _insertStageChange(tx, move);
    await _copy(tx, created.id, tagsById, photos);
    await tx.execute(
      'INSERT INTO splits (id, unit_id, new_unit_id, model_count) VALUES (?, ?, ?, ?)',
      [id, sourceId, created.id, created.modelCount],
    );
    await tx.execute(
      'UPDATE units SET model_count = model_count - ? WHERE id = ?',
      [created.modelCount, sourceId],
    );
  });

  // The Merge comes first, so the write API checks it against the Units as they were before anything else in it.
  // The copied Stage Changes keep their timestamps (no clock-skew bump): they are history, not new moves.
  @override
  Future<void> insertMerge(
    String id,
    String unitId,
    String otherId,
    List<StageChange> history,
    Map<String, String> tagsById,
    List<Photo> photos,
  ) => _db.writeTransaction((tx) async {
    await tx.execute(
      'INSERT INTO merges (id, unit_id, merged_unit_id) VALUES (?, ?, ?)',
      [id, unitId, otherId],
    );
    for (final c in history) {
      await tx.execute(
        'INSERT INTO stage_changes (id, unit_id, from_stage_id, to_stage_id, model_count, happened_at) VALUES (?, ?, ?, ?, ?, ?)',
        [
          c.id,
          c.unitId,
          c.fromStageId,
          c.toStageId,
          c.modelCount,
          c.happenedAt.toUtc().toIso8601String(),
        ],
      );
    }
    await _copy(tx, unitId, tagsById, photos);
    await tx.execute(
      'UPDATE units SET model_count = model_count + (SELECT model_count FROM units WHERE id = ?) WHERE id = ?',
      [otherId, unitId],
    );
    await tx.execute('DELETE FROM unit_tags WHERE unit_id = ?', [otherId]);
    await tx.execute('DELETE FROM photos WHERE unit_id = ?', [otherId]);
    await tx.execute('DELETE FROM units WHERE id = ?', [otherId]);
  });

  static Future<void> _copy(
    SqliteWriteContext tx,
    String unitId,
    Map<String, String> tagsById,
    List<Photo> photos,
  ) async {
    for (final MapEntry(key: id, value: name) in tagsById.entries) {
      await tx.execute(
        'INSERT INTO unit_tags (id, unit_id, name) SELECT ?, ?, ? '
        'WHERE NOT EXISTS (SELECT 1 FROM unit_tags WHERE id = ?)',
        [id, unitId, name, id],
      );
    }
    for (final p in photos) {
      await insertPhoto(tx, p);
    }
  }

  @override
  Stream<List<Paint>> watchPaints() => _db
      .watch(
        'SELECT * FROM paints ORDER BY brand COLLATE NOCASE, range COLLATE NOCASE, name COLLATE NOCASE, id',
      )
      .map(
        (rows) => [
          for (final p in rows)
            Paint(
              id: p['id'] as String,
              brand: p['brand'] as String,
              range: p['range'] as String,
              name: p['name'] as String,
              owned: p['owned'] == 1,
            ),
        ],
      );

  @override
  Future<void> insertPaint(Paint paint) => _db.execute(
    'INSERT INTO paints (id, brand, range, name, owned) VALUES (?, ?, ?, ?, ?)',
    [paint.id, paint.brand, paint.range, paint.name, paint.owned ? 1 : 0],
  );

  @override
  Future<void> updatePaint(Paint paint) => _db.execute(
    'UPDATE paints SET brand = ?, range = ?, name = ?, owned = ? WHERE id = ?',
    [paint.brand, paint.range, paint.name, paint.owned ? 1 : 0, paint.id],
  );

  // One column, so toggling on two devices merges per field.
  @override
  Future<void> setPaintOwned(String id, bool owned) => _db.execute(
    'UPDATE paints SET owned = ? WHERE id = ?',
    [owned ? 1 : 0, id],
  );

  @override
  Future<void> deletePaint(String id) =>
      _db.execute('DELETE FROM paints WHERE id = ?', [id]);
}
