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
      Column.text('description'),
    ]),
    Table('units', [
      Column.text('collection_id'),
      Column.text('stage_id'),
      Column.text('name'),
      Column.integer('model_count'),
    ]),
    Table('stage_changes', [
      Column.text('unit_id'),
      Column.text('from_stage_id'),
      Column.text('to_stage_id'),
      Column.integer('model_count'),
      Column.text('happened_at'),
    ]),
    // unit_tags, photos and units.notes are synced but left out: Tags, Photos and notes now belong to the Unit
    // (squad_tags, squad_photos, squad_notes); the server keeps the old ones until every device runs this version.
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
    // A Paint a Unit uses, keyed by the Unit's Collection and name (squad_name), not by its Batches.
    Table('squad_paints', [
      Column.text('collection_id'),
      Column.text('squad_name'),
      Column.text('paint_id'),
      Column.text('note'),
    ]),
    // A Unit's notes, Tags and Photos, keyed like squad_paints. A notes row's id is the Unit's [unitId], a Tag's its
    // [tagId], so the same Unit or Tag added on two devices is one row. file_id is the image file's attachment id.
    Table('squad_notes', [
      Column.text('collection_id'),
      Column.text('squad_name'),
      Column.text('notes'),
    ]),
    Table('squad_tags', [
      Column.text('collection_id'),
      Column.text('squad_name'),
      Column.text('name'),
    ]),
    Table('squad_photos', [
      Column.text('collection_id'),
      Column.text('squad_name'),
      Column.text('file_id'),
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
  Future<List<Batch>> batchesAt(String stageId) async => _toBatches(
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
            // Null until the server's '' syncs down to a Collection from before descriptions.
            description: c['description'] as String? ?? '',
          ),
      ];

  @override
  Future<void> insertCollection(Collection collection) => _db.execute(
    'INSERT INTO collections (id, name, workflow_id, game_system, description) VALUES (?, ?, ?, ?, ?)',
    [
      collection.id,
      collection.name,
      collection.workflowId,
      collection.gameSystem,
      collection.description,
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

  @override
  Future<void> setCollectionDescription(String id, String description) =>
      _db.execute('UPDATE collections SET description = ? WHERE id = ?', [
        description,
        id,
      ]);

  // As deleteBatch, for every Batch: Stage Changes are left to the server, and children go first. The server also
  // deletes Batches and Unit rows this device hasn't seen yet when the Collection's delete arrives.
  @override
  Future<void> deleteCollection(String id) => _db.writeTransaction((tx) async {
    for (final table in [
      'units',
      'squad_paints',
      'squad_notes',
      'squad_tags',
      'squad_photos',
    ]) {
      await tx.execute('DELETE FROM $table WHERE collection_id = ?', [id]);
    }
    await tx.execute('DELETE FROM collections WHERE id = ?', [id]);
  });

  @override
  Stream<List<Batch>> watchBatches(String collectionId) => _db
      .watch(
        'SELECT * FROM units WHERE collection_id = ? ORDER BY name COLLATE NOCASE',
        parameters: [collectionId],
      )
      .map(_toBatches);

  @override
  Stream<List<Batch>> watchAllBatches() =>
      _db.watch('SELECT * FROM units').map(_toBatches);

  // Table `units` holds Batches (ADR 0008).
  static List<Batch> _toBatches(Iterable<Map<String, Object?>> rows) => [
    for (final u in rows)
      Batch(
        id: u['id'] as String,
        collectionId: u['collection_id'] as String,
        stageId: u['stage_id'] as String,
        name: u['name'] as String,
        modelCount: u['model_count'] as int,
      ),
  ];

  @override
  Future<void> insertBatch(Batch batch, StageChange initial) =>
      _db.writeTransaction((tx) async {
        await _insertBatch(tx, batch);
        await _insertStageChange(tx, initial);
      });

  static Future<void> _insertBatch(SqliteWriteContext tx, Batch batch) =>
      tx.execute(
        'INSERT INTO units (id, collection_id, stage_id, name, model_count) VALUES (?, ?, ?, ?, ?)',
        [
          batch.id,
          batch.collectionId,
          batch.stageId,
          batch.name,
          batch.modelCount,
        ],
      );

  // stage_id is written here only so the move shows at once offline; the server re-derives it from the latest Stage Change.
  @override
  Future<void> insertStageChange(StageChange change) =>
      _db.writeTransaction((tx) => _move(tx, change));

  static Future<void> _move(SqliteWriteContext tx, StageChange change) async {
    await tx.execute('UPDATE units SET stage_id = ? WHERE id = ?', [
      change.toStageId,
      change.batchId,
    ]);
    await _insertStageChange(tx, change);
  }

  // A new Stage Change must sort after every one this device knows for the Batch, or a device whose clock runs
  // behind another's could never move it: so it is stamped at least 1 ms after the latest known one.
  static Future<void> _insertStageChange(
    SqliteWriteContext tx,
    StageChange c,
  ) async {
    var at = c.happenedAt.toUtc();
    for (final row in await tx.getAll(
      'SELECT happened_at FROM stage_changes WHERE unit_id = ?',
      [c.batchId],
    )) {
      final known = DateTime.parse(row['happened_at'] as String).toUtc();
      if (!at.isAfter(known)) at = known.add(const Duration(milliseconds: 1));
    }
    await tx.execute(
      'INSERT INTO stage_changes (id, unit_id, from_stage_id, to_stage_id, model_count, happened_at) VALUES (?, ?, ?, ?, ?, ?)',
      [
        c.id,
        c.batchId,
        c.fromStageId,
        c.toStageId,
        c.modelCount,
        at.toIso8601String(),
      ],
    );
  }

  @override
  Stream<List<StageChange>> watchStageChanges(String batchId) => _db
      .watch(
        'SELECT * FROM stage_changes WHERE unit_id = ?',
        parameters: [batchId],
      )
      .map(_toStageChanges);

  // Joined on units: a merged-away Batch's Stage Changes linger here until the server deletes them, copied already.
  @override
  Stream<List<StageChange>> watchUnitStageChanges(
    String collectionId,
    String unit,
  ) => _db
      .watch(
        'SELECT c.* FROM stage_changes c JOIN units u ON u.id = c.unit_id '
        'WHERE u.collection_id = ? AND u.name = ?',
        parameters: [collectionId, unit],
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
            batchId: c['unit_id'] as String,
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
  Future<void> updateBatch(String id, {String? name, int? modelCount}) async {
    final changes = {'name': ?name, 'model_count': ?modelCount};
    if (changes.isEmpty) return;
    await _db.execute(
      'UPDATE units SET ${changes.keys.map((c) => '$c = ?').join(', ')} WHERE id = ?',
      [...changes.values, id],
    );
  }

  // Its Stage Changes are append-only, so they are not deleted here: the server deletes them with the Batch,
  // and sync then removes them from this device.
  @override
  Future<void> deleteBatch(String id) =>
      _db.execute('DELETE FROM units WHERE id = ?', [id]);

  @override
  Stream<String> watchNotes(String collectionId, String unit) => _db
      .watch(
        'SELECT notes FROM squad_notes WHERE id = ?',
        parameters: [unitId(collectionId, unit)],
      )
      .map((rows) => rows.firstOrNull?['notes'] as String? ?? '');

  // An UPDATE of the one column once the row exists, so edits on two devices merge per field (the latest wins).
  @override
  Future<void> setNotes(String collectionId, String unit, String notes) =>
      _db.writeTransaction((tx) async {
        final id = unitId(collectionId, unit);
        if (await tx.getOptional('SELECT 1 FROM squad_notes WHERE id = ?', [
              id,
            ]) ==
            null) {
          await tx.execute(
            'INSERT INTO squad_notes (id, collection_id, squad_name, notes) VALUES (?, ?, ?, ?)',
            [id, collectionId, unit, notes],
          );
        } else {
          await tx.execute('UPDATE squad_notes SET notes = ? WHERE id = ?', [
            notes,
            id,
          ]);
        }
      });

  @override
  Future<void> deleteNotes(String collectionId, String unit) => _db.execute(
    'DELETE FROM squad_notes WHERE id = ?',
    [unitId(collectionId, unit)],
  );

  @override
  Stream<List<String>> watchTags(String collectionId, String unit) => _db
      .watch(
        'SELECT name FROM squad_tags WHERE collection_id = ? AND squad_name = ? ORDER BY name COLLATE NOCASE',
        parameters: [collectionId, unit],
      )
      .map((rows) => [for (final r in rows) r['name'] as String]);

  // addTags reuses a Tag's first casing, so casings differ only after offline adds on two devices; ORDER BY
  // makes the pick the same everywhere.
  @override
  Future<List<String>> allTagNames() async => [
    for (final r in await _db.getAll(
      'SELECT DISTINCT name FROM squad_tags ORDER BY name',
    ))
      r['name'] as String,
  ];

  @override
  Future<void> insertTags(
    String collectionId,
    String unit,
    Map<String, String> namesById,
  ) => _db.writeTransaction((tx) async {
    for (final MapEntry(key: id, value: name) in namesById.entries) {
      await tx.execute(
        'INSERT INTO squad_tags (id, collection_id, squad_name, name) SELECT ?, ?, ?, ? '
        'WHERE NOT EXISTS (SELECT 1 FROM squad_tags WHERE id = ?)',
        [id, collectionId, unit, name, id],
      );
    }
  });

  @override
  Future<void> deleteTag(String id) =>
      _db.execute('DELETE FROM squad_tags WHERE id = ?', [id]);

  @override
  Stream<List<Photo>> watchPhotos(String collectionId, String unit) => _db
      .watch(
        'SELECT id, file_id FROM squad_photos WHERE collection_id = ? AND squad_name = ? ORDER BY id',
        parameters: [collectionId, unit],
      )
      .map(
        (rows) => [
          for (final r in rows)
            Photo(
              id: r['id'] as String,
              collectionId: collectionId,
              unit: unit,
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
      tx.execute(
        'INSERT INTO squad_photos (id, collection_id, squad_name, file_id) VALUES (?, ?, ?, ?)',
        [photo.id, photo.collectionId, photo.unit, photo.fileId],
      );

  @override
  Future<void> movePhoto(String id, String unit) => _db.execute(
    'UPDATE squad_photos SET squad_name = ? WHERE id = ?',
    [unit, id],
  );

  @override
  Future<void> deletePhoto(String id) =>
      _db.execute('DELETE FROM squad_photos WHERE id = ?', [id]);

  // The new Batch's rows come first, so the Split's reference to it resolves on the server. The count changes
  // relatively here too; their uploaded absolute values are ignored by the write API, which applies the delta.
  @override
  Future<void> insertSplit(
    String id,
    String sourceId,
    Batch created,
    StageChange move,
  ) => _db.writeTransaction((tx) async {
    await _insertBatch(tx, created);
    await _insertStageChange(tx, move);
    await tx.execute(
      'INSERT INTO splits (id, unit_id, new_unit_id, model_count) VALUES (?, ?, ?, ?)',
      [id, sourceId, created.id, created.modelCount],
    );
    await tx.execute(
      'UPDATE units SET model_count = model_count - ? WHERE id = ?',
      [created.modelCount, sourceId],
    );
  });

  // The Merge comes first, so the write API checks it against the Batches as they were before anything else in it.
  // The copied Stage Changes keep their timestamps (no clock-skew bump): they are history, not new moves.
  @override
  Future<void> insertMerge(
    String id,
    String batchId,
    String otherId,
    List<StageChange> history,
  ) => _db.writeTransaction((tx) async {
    // Checked inside the transaction, as the write API does, so a Merge racing another (e.g. a move's Merge on
    // arrival and the automatic Merge) cannot add the same models twice.
    final pair = await tx.getAll(
      'SELECT 1 FROM units a JOIN units b ON b.collection_id = a.collection_id AND b.name = a.name '
      'AND b.stage_id = a.stage_id AND b.id <> a.id WHERE a.id = ? AND b.id = ?',
      [batchId, otherId],
    );
    if (pair.isEmpty) return;
    await tx.execute(
      'INSERT INTO merges (id, unit_id, merged_unit_id) VALUES (?, ?, ?)',
      [id, batchId, otherId],
    );
    for (final c in history) {
      await tx.execute(
        'INSERT INTO stage_changes (id, unit_id, from_stage_id, to_stage_id, model_count, happened_at) VALUES (?, ?, ?, ?, ?, ?)',
        [
          c.id,
          c.batchId,
          c.fromStageId,
          c.toStageId,
          c.modelCount,
          c.happenedAt.toUtc().toIso8601String(),
        ],
      );
    }
    await tx.execute(
      'UPDATE units SET model_count = model_count + (SELECT model_count FROM units WHERE id = ?) WHERE id = ?',
      [otherId, batchId],
    );
    await tx.execute('DELETE FROM units WHERE id = ?', [otherId]);
  });

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
  Future<void> deletePaint(String id) => _db.writeTransaction((tx) async {
    await tx.execute('DELETE FROM squad_paints WHERE paint_id = ?', [id]);
    await tx.execute('DELETE FROM paints WHERE id = ?', [id]);
  });

  @override
  // Table `squad_paints` holds Unit Paints, keyed by Unit name in `squad_name` (ADR 0008).
  Stream<List<UnitPaint>> watchUnitPaints() => _db
      .watch(
        'SELECT l.id, l.collection_id, l.squad_name, l.note, p.id AS paint_id, p.brand, p.range, p.name, p.owned '
        'FROM squad_paints l JOIN paints p ON p.id = l.paint_id '
        'ORDER BY p.brand COLLATE NOCASE, p.range COLLATE NOCASE, p.name COLLATE NOCASE, l.id',
      )
      .map(
        (rows) => [
          for (final r in rows)
            UnitPaint(
              id: r['id'] as String,
              collectionId: r['collection_id'] as String,
              unit: r['squad_name'] as String,
              note: r['note'] as String? ?? '',
              paint: Paint(
                id: r['paint_id'] as String,
                brand: r['brand'] as String,
                range: r['range'] as String,
                name: r['name'] as String,
                owned: r['owned'] == 1,
              ),
            ),
        ],
      );

  @override
  Future<void> insertUnitPaints(List<UnitPaint> links) =>
      _db.writeTransaction((tx) async {
        for (final l in links) {
          await tx.execute(
            'INSERT INTO squad_paints (id, collection_id, squad_name, paint_id, note) VALUES (?, ?, ?, ?, ?)',
            [l.id, l.collectionId, l.unit, l.paint.id, l.note],
          );
        }
      });

  // Only the given columns, so a rename and a note edit on two devices merge per field.
  @override
  Future<void> updateUnitPaint(String id, {String? unit, String? note}) async {
    final changes = {'squad_name': ?unit, 'note': ?note};
    if (changes.isEmpty) return;
    await _db.execute(
      'UPDATE squad_paints SET ${changes.keys.map((c) => '$c = ?').join(', ')} WHERE id = ?',
      [...changes.values, id],
    );
  }

  @override
  Future<void> deleteUnitPaint(String id) =>
      _db.execute('DELETE FROM squad_paints WHERE id = ?', [id]);
}
