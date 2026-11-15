import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:postgres/postgres.dart';
import 'package:powersync/powersync.dart';
import 'package:test/test.dart';

import 'stack.dart';

/// The synced tables a device and Postgres must agree on, with the columns the device has, and which rows to compare:
/// the server deletes a Batch's Stage Changes with it, the device keeps them until the next sync.
const _tables = {
  'workflows': ('id, name, owned_stage_id, finished_stage_id', ''),
  'stages': ('id, workflow_id, name, position, colour', ''),
  'collections': ('id, name, workflow_id, game_system, description', ''),
  'units': ('id, collection_id, stage_id, name, model_count', ''),
  'stage_changes': (
    'id, unit_id, from_stage_id, to_stage_id, model_count',
    'unit_id IN (SELECT id FROM units)',
  ),
  'paints': ('id, brand, range, name, owned', ''),
  'squad_paints': ('id, collection_id, squad_name, paint_id, note', ''),
  'squad_notes': ('id, collection_id, squad_name, notes', ''),
  'squad_tags': ('id, collection_id, squad_name, name', ''),
  'squad_photos': ('id, collection_id, squad_name, file_id', ''),
  'categories': ('id, collection_id, name, position', ''),
  'squad_categories': (
    'id, collection_id, squad_name, category_id, position',
    '',
  ),
};

// Contract: what a real Vault uploads, sent as the app's uploadData sends it, is accepted by the write API and leaves
// Postgres matching the device. One device per test, against the Docker stack (see stack.dart).
void main() {
  late Connection pg;
  late Directory dir;
  late PowerSyncDatabase db;
  late Vault vault;
  late ({String token, String id}) user;

  setUpAll(() async => pg = await openPostgres());
  tearDownAll(() => pg.close());

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('contract_test');
    db = PowerSyncDatabase(
      schema: SqliteVaultStore.schema,
      path: '${dir.path}/vault.db',
    );
    await db.initialize();
    vault = Vault(SqliteVaultStore(db));
    user = await signUp();
    // Stands in for the first sync delivering the starter Workflow the server created.
    for (final row in await pg.execute(
      r'''SELECT id::text, name, owned_stage_id::text, finished_stage_id::text, starter::int
        FROM workflows WHERE owner_id = $1::uuid''',
      parameters: [user.id],
    )) {
      await db.execute(
        'INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id, starter) VALUES (?, ?, ?, ?, ?)',
        row,
      );
    }
    for (final row in await pg.execute(
      r'''SELECT id::text, workflow_id::text, name, position, colour FROM stages WHERE owner_id = $1::uuid''',
      parameters: [user.id],
    )) {
      await db.execute(
        'INSERT INTO stages (id, workflow_id, name, position, colour) VALUES (?, ?, ?, ?, ?)',
        row,
      );
    }
    await (await db.getCrudBatch(limit: 1000))?.complete();
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  /// Uploads the device's queued writes, one transaction at a time, as the app's uploadData does.
  Future<void> sync() async {
    while (true) {
      final tx = await db.getNextCrudTransaction();
      if (tx == null) return;
      final response = await upload(user.token, [
        for (final op in tx.crud) op.toJson(),
      ]);
      expect(response.statusCode ~/ 100, 2, reason: response.body);
      await tx.complete();
    }
  }

  /// Expects every synced table to hold the same rows on the device as the user's in Postgres.
  Future<void> expectPostgresMatches() async {
    List<String?> row(Iterable<Object?> values) => [
      for (final v in values) v?.toString(),
    ];
    int byText(List<String?> a, List<String?> b) =>
        a.join('|').compareTo(b.join('|'));
    for (final MapEntry(key: table, value: (columns, where))
        in _tables.entries) {
      final local = [
        for (final r in await db.getAll(
          'SELECT $columns FROM $table${where.isEmpty ? '' : ' WHERE $where'}',
        ))
          row(r.values),
      ]..sort(byText);
      final cast = [for (final c in columns.split(', ')) '$c::text'].join(', ');
      final server = [
        for (final r in await pg.execute(
          'SELECT $cast FROM $table WHERE owner_id = \$1::uuid'
          '${where.isEmpty ? '' : ' AND $where'}',
          parameters: [user.id],
        ))
          row(r),
      ]..sort(byText);
      expect(server, local, reason: table);
    }
  }

  Future<Workflow> starter() async => (await vault.starterWorkflow())!;
  Future<Collection> newCollection() async {
    final c = await vault.createCollection('Space Marines');
    await sync();
    return c;
  }

  Future<Batch> add(Collection c, String name, int models, Stage at) async {
    final b = await vault.addBatch(
      c,
      name: name,
      modelCount: models,
      stageId: at.id,
    );
    await sync();
    return b;
  }

  Future<Unit> unit(Collection c, String name) async =>
      (await vault.watchUnits(c).first).firstWhere((u) => u.name == name);

  Future<List<(String, int)>> batches(Collection c) async =>
      [for (final b in await vault.batchesOf(c)) (b.stageId, b.modelCount)]
        ..sort((a, b) => a.$1.compareTo(b.$1));

  test(
    'moving models onto a Stage where the Unit has models Merges them',
    () async {
      final w = await starter();
      final [_, unassembled, assembled, ...] = w.stages;
      final c = await newCollection();
      await add(c, 'Intercessors', 10, unassembled);
      await add(c, 'Intercessors', 5, assembled);

      await vault.moveModels(
        c,
        'Intercessors',
        unassembled.id,
        assembled.id,
        4,
      );
      await sync();
      await expectPostgresMatches();
      expect(
        await batches(c),
        unorderedEquals([(unassembled.id, 6), (assembled.id, 9)]),
      );

      await vault.moveModels(
        c,
        'Intercessors',
        unassembled.id,
        assembled.id,
        6,
      );
      await sync();
      await expectPostgresMatches();
      expect(await batches(c), [(assembled.id, 15)]);
    },
  );

  test('a Split moves some models to a new Batch', () async {
    final w = await starter();
    final [_, unassembled, _, primed, ...] = w.stages;
    final c = await newCollection();
    await add(c, 'Intercessors', 10, unassembled);

    await vault.moveModels(c, 'Intercessors', unassembled.id, primed.id, 3);
    await sync();

    await expectPostgresMatches();
    expect(
      await batches(c),
      unorderedEquals([(unassembled.id, 7), (primed.id, 3)]),
    );
  });

  test('renaming a Unit onto an existing one carries its notes, Tags, Photos, Paints and Category', () async {
    final w = await starter();
    final c = await newCollection();
    const shared = '00000000-0000-4000-8000-0000000000f1';
    final base = await vault.addPaint(
      brand: 'Citadel',
      range: 'Base',
      name: 'Macragge Blue',
    );
    final layer = await vault.addPaint(
      brand: 'Citadel',
      range: 'Layer',
      name: 'Calgar Blue',
    );
    await sync();
    for (final (name, notes, tag, file, category) in [
      (
        'Intercessors',
        'Magnetised',
        'Troops',
        '00000000-0000-4000-8000-0000000000f2',
        'Infantry',
      ),
      (
        'Hellblasters',
        'Plasma',
        'Elite',
        '00000000-0000-4000-8000-0000000000f3',
        'Heavy',
      ),
    ]) {
      await add(c, name, name == 'Intercessors' ? 10 : 5, w.ownedStage);
      await vault.setNotes(c.id, name, notes);
      await sync();
      await vault.addTags(c.id, name, [tag]);
      await sync();
      await vault.addPhotos(c.id, name, [shared, file]);
      await sync();
      await vault.addUnitPaint(
        c.id,
        name,
        base.id,
        note: name == 'Intercessors' ? 'Basecoat' : '',
      );
      await sync();
      final cat = await vault.addCategory(c.id, category);
      await sync();
      await vault.setUnitCategory(c.id, name, cat.id);
      await sync();
    }
    await vault.addUnitPaint(c.id, 'Hellblasters', layer.id, note: 'Edges');
    await sync();

    await vault.renameUnit(await unit(c, 'Hellblasters'), 'Intercessors');
    await sync();
    await expectPostgresMatches();

    await vault.keepBatchesMerged().first;
    await sync();
    await expectPostgresMatches();
    expect(await batches(c), [(w.ownedStage.id, 15)]);
    expect(await vault.notesOf(c.id, 'Intercessors'), 'Magnetised\nPlasma');
    expect(
      await vault.tagsOf(c.id, 'Intercessors'),
      unorderedEquals(['Troops', 'Elite']),
    );
  });

  test('editUnit changes Tags, notes, Category and name; deleteUnit deletes its Batches', () async {
    final w = await starter();
    final c = await newCollection();
    await add(c, 'Intercessors', 10, w.ownedStage);
    await add(c, 'Intercessors', 3, w.finishedStage);
    await vault.addTags(c.id, 'Intercessors', ['Troops', 'Bolters']);
    await sync();
    await vault.setNotes(c.id, 'Intercessors', 'Magnetised');
    await sync();

    await vault.editUnit(
      await unit(c, 'Intercessors'),
      name: 'Assault Intercessors',
      tags: ['Troops', 'Jump packs'],
      notes: 'Magnetised arms',
      newCategory: 'Infantry',
    );
    await sync();
    await expectPostgresMatches();
    expect(
      await vault.tagsOf(c.id, 'Assault Intercessors'),
      unorderedEquals(['Troops', 'Jump packs']),
    );

    await vault.deleteUnit(await unit(c, 'Assault Intercessors'));
    await sync();
    await expectPostgresMatches();
    expect(await vault.batchesOf(c), isEmpty);
  });

  test('editCollection changes all three fields, then one', () async {
    final c = await newCollection();

    await vault.editCollection(
      c,
      name: 'Dark Angels',
      gameSystem: 'Warhammer 40,000',
      description: '1st Company',
    );
    await sync();
    await expectPostgresMatches();

    final edited = (await vault.collections()).single;
    expect(
      (edited.name, edited.gameSystem, edited.description),
      ('Dark Angels', 'Warhammer 40,000', '1st Company'),
    );
    await vault.editCollection(
      edited,
      name: 'Dark Angels',
      gameSystem: 'Warhammer 40,000',
      description: 'Ravenwing',
    );
    await sync();
    await expectPostgresMatches();
  });

  test(
    'deleting the Owned Stage while it holds Units moves them and replaces it',
    () async {
      final w = await starter();
      final c = await newCollection();
      await add(c, 'Intercessors', 10, w.ownedStage);
      await add(c, 'Hellblasters', 5, w.ownedStage);

      final plan = await vault.planStageDelete(w.id, w.ownedStage.id);
      expect(
        (plan.held, plan.replacesOwned, plan.replacesFinished),
        (2, true, false),
      );
      await vault.deleteStage(
        w.id,
        plan.stage.id,
        moveBatchesTo: plan.destination.id,
        ownedStageId: plan.owned.id,
      );
      await sync();

      await expectPostgresMatches();
      expect((await starter()).ownedStage.name, 'Assembled');
      expect(
        await batches(c),
        unorderedEquals([(plan.destination.id, 10), (plan.destination.id, 5)]),
      );
    },
  );

  test(
    'switchWorkflow moves each Batch to the Stage stageMapping picks',
    () async {
      final w = await starter();
      final c = await newCollection();
      final target = await vault.createWorkflow('Speed painting');
      await sync();
      await vault.renameStage(target.stages[3].id, 'Undercoated');
      await sync();
      await add(c, 'Intercessors', 10, w.stages[3]);
      await add(c, 'Hellblasters', 5, w.finishedStage);

      final mapping = await vault.stageMapping(
        c,
        (await vault.workflows()).firstWhere((x) => x.id == target.id),
      );
      expect(
        [for (final m in mapping) (m.from.name, m.to.name)],
        [('Primed', 'Unassembled'), ('Done', 'Done')],
      );
      await vault.switchWorkflow(c, target.id, {
        for (final m in mapping) m.from.id: m.to.id,
      });
      await sync();

      await expectPostgresMatches();
      expect(
        await batches(c),
        unorderedEquals([
          (target.stages[1].id, 10),
          (target.finishedStage.id, 5),
        ]),
      );
    },
  );
}
