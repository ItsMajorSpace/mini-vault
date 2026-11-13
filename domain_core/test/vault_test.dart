import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:powersync/powersync.dart';
import 'package:test/test.dart';

// Seam 1: the domain core over real local SQLite (a PowerSync database file in a temp dir), no mocks.
// The starter Workflow's shape is tested on the server, which creates it (server/test).
void main() {
  late Directory dir;
  late PowerSyncDatabase db;
  late Vault vault;

  /// Opens the database file the way the app does on launch.
  Future<void> launch() async {
    db = PowerSyncDatabase(
      schema: SqliteVaultStore.schema,
      path: '${dir.path}/vault.db',
    );
    await db.initialize();
    vault = Vault(SqliteVaultStore(db));
  }

  /// Closes and reopens the database, like an app restart.
  Future<void> restart() async {
    await db.close();
    await launch();
  }

  /// Stands in for the first sync delivering the starter Workflow the server created.
  Future<String> syncStarterWorkflow() async {
    const workflowId = '00000000-0000-4000-8000-000000000001';
    await db.execute(
      "INSERT INTO workflows (id, name, owned_stage_id, finished_stage_id, starter) VALUES (?, 'Starter', 's1', 's6', 1)",
      [workflowId],
    );
    for (final (position, name) in Vault.starterStageNames.indexed) {
      await db.execute(
        'INSERT INTO stages (id, workflow_id, name, position) VALUES (?, ?, ?, ?)',
        ['s$position', workflowId, name, position],
      );
    }
    return workflowId;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('domain_core_test');
    await launch();
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  group('starter Workflow', () {
    test('is read back in Stage order once synced', () async {
      expect(await vault.starterWorkflow(), isNull);
      await syncStarterWorkflow();

      final workflow = (await vault.starterWorkflow())!;

      expect(workflow.stages.map((s) => s.name), Vault.starterStageNames);
      expect(workflow.ownedStage.name, 'Unassembled');
      expect(workflow.finishedStage.name, 'Done');
    });
  });

  group('Workflow', () {
    List<String> names(Workflow w) => [for (final s in w.stages) s.name];
    Future<Workflow> reload(String id) async =>
        (await vault.workflows()).firstWhere((w) => w.id == id);

    test('is created with the starter Stages and renamed, and persists across restarts', () async {
      await syncStarterWorkflow();
      final created = await vault.createWorkflow(' Speed painting ');
      await vault.renameWorkflow(created.id, 'Batch painting');
      await restart();

      final [starter, workflow] = await vault.workflows();
      expect(starter.name, 'Starter');
      expect(workflow.name, 'Batch painting');
      expect(names(workflow), Vault.starterStageNames);
      expect(workflow.ownedStage.name, 'Unassembled');
      expect(workflow.finishedStage.name, 'Done');
      expect((await vault.starterWorkflow())!.id, starter.id);
      expect(() => vault.renameWorkflow(created.id, ' '), throwsArgumentError);
    });

    test('Stages are added at any position, renamed and moved', () async {
      final w = await vault.createWorkflow('Mine');
      await vault.addStage(w.id, 'Washed', 3);
      await vault.addStage(w.id, 'Bought', 0);
      final last = await vault.addStage(w.id, 'Shelved', 99);
      await vault.renameStage(last.id, 'Displayed');
      await restart();
      expect(names(await reload(w.id)), [
        'Bought',
        'Wishlist',
        'Unassembled',
        'Assembled',
        'Washed',
        'Primed',
        'Painted',
        'Based',
        'Done',
        'Displayed',
      ]);

      final washed = (await reload(w.id)).stages[4];
      await vault.moveStage(w.id, washed.id, 2);
      expect(names(await reload(w.id)).take(4), [
        'Bought',
        'Wishlist',
        'Washed',
        'Unassembled',
      ]);
    });

    test('a new Stage gets the first colour its Workflow is not using; reordering keeps colours', () async {
      final w = await vault.createWorkflow('Mine');
      List<String> colours(Workflow w) => [for (final s in w.stages) s.colour];
      expect(colours(w), Vault.stageColours.take(7));

      // A colour the Workflow stops using is the first free one again.
      await vault.setStageColour(w.stages[2].id, Vault.stageColours[0]);
      final added = await vault.addStage(w.id, 'Washed', 0);
      expect(added.colour, Vault.stageColours[2]);
      expect(
        (await vault.addStage(w.id, 'Shelved', 99)).colour,
        Vault.stageColours[7],
      );

      await vault.moveStage(w.id, added.id, 5);
      await restart();
      final reloaded = await reload(w.id);
      expect(
        {for (final s in reloaded.stages) s.name: s.colour},
        {
          'Washed': Vault.stageColours[2],
          'Wishlist': Vault.stageColours[0],
          'Unassembled': Vault.stageColours[1],
          'Assembled': Vault.stageColours[0],
          'Primed': Vault.stageColours[3],
          'Painted': Vault.stageColours[4],
          'Based': Vault.stageColours[5],
          'Done': Vault.stageColours[6],
          'Shelved': Vault.stageColours[7],
        },
      );
      expect(names(reloaded)[5], 'Washed');
    });

    test('with every colour used, a new Stage gets the first one', () async {
      final w = await vault.createWorkflow('Mine');
      for (var i = 7; i < Vault.stageColours.length; i++) {
        expect(
          (await vault.addStage(w.id, 'S$i', 99)).colour,
          Vault.stageColours[i],
        );
      }
      expect(
        (await vault.addStage(w.id, 'One more', 99)).colour,
        Vault.stageColours.first,
      );
    });

    test('a Stage colour must be #RRGGBB', () async {
      final w = await vault.createWorkflow('Mine');
      for (final bad in ['#ff7b7b', 'FF7B7B', '#FF7B7', '#FF7B7BAA', 'red']) {
        expect(
          () => vault.setStageColour(w.stages[0].id, bad),
          throwsArgumentError,
        );
      }
      await vault.setStageColour(w.stages[0].id, '#123ABC');
      expect((await reload(w.id)).stages[0].colour, '#123ABC');
    });

    test(
      'only positions that change are uploaded when a Stage moves',
      () async {
        final w = await vault.createWorkflow('Mine');
        await (await db.getCrudBatch(limit: 1000))!.complete();
        await vault.moveStage(w.id, w.stages[3].id, 2);

        final ops = (await db.getCrudBatch())!.crud;
        expect(ops.map((e) => '${e.id} ${e.opData}'), [
          '${w.stages[3].id} {position: 2}',
          '${w.stages[2].id} {position: 3}',
        ]);
      },
    );

    test('concurrent reorders that merge into equal positions still read as one order', () async {
      final w = await vault.createWorkflow('Mine');
      // Per-field last-write-wins can leave two Stages at the same position.
      await db.execute('UPDATE stages SET position = 1 WHERE id IN (?, ?)', [
        w.stages[2].id,
        w.stages[3].id,
      ]);
      final read = await reload(w.id);
      expect(read.stages, hasLength(7));
      expect(read.stages.map((s) => s.id).toSet(), hasLength(7));

      // The next move renumbers them into a clean order again.
      await vault.moveStage(w.id, w.stages.last.id, 6);
      final rows = await db.getAll(
        'SELECT position FROM stages WHERE workflow_id = ? ORDER BY position',
        [w.id],
      );
      expect(rows.map((r) => r['position']), [0, 1, 2, 3, 4, 5, 6]);
    });

    test('the Owned Stage may not come after the Finished Stage', () async {
      final w = await vault.createWorkflow('Mine');
      final [wishlist, unassembled, ..., based, done] = w.stages;

      await vault.setOwnedStage(w.id, wishlist.id);
      await vault.setFinishedStage(w.id, based.id);
      var read = await reload(w.id);
      expect(
        (read.ownedStage.name, read.finishedStage.name),
        ('Wishlist', 'Based'),
      );

      await expectLater(
        vault.setOwnedStage(w.id, done.id),
        throwsArgumentError,
      );
      await vault.setFinishedStage(w.id, unassembled.id);
      await expectLater(
        vault.setFinishedStage(w.id, 'not-a-stage'),
        throwsArgumentError,
      );
      // Moving the Finished Stage (now Unassembled) above the Owned Stage (Wishlist) is refused.
      await expectLater(
        vault.moveStage(w.id, unassembled.id, 0),
        throwsArgumentError,
      );
      read = await reload(w.id);
      expect(
        (read.ownedStage.name, read.finishedStage.name),
        ('Wishlist', 'Unassembled'),
      );
      expect(names(read).first, 'Wishlist');
    });

    test('an empty Stage is deleted, but never the last one, nor the Owned or Finished Stage', () async {
      final w = await vault.createWorkflow('Mine');
      final [wishlist, unassembled, ..., done] = w.stages;

      await expectLater(
        vault.deleteStage(w.id, unassembled.id),
        throwsStateError,
      );
      await expectLater(vault.deleteStage(w.id, done.id), throwsStateError);
      await vault.deleteStage(w.id, wishlist.id);
      for (final s in w.stages.sublist(2, 6)) {
        await vault.deleteStage(w.id, s.id);
      }
      await vault.setFinishedStage(w.id, unassembled.id);
      await vault.deleteStage(w.id, done.id);

      expect(names(await reload(w.id)), ['Unassembled']);
      await expectLater(
        vault.deleteStage(w.id, unassembled.id),
        throwsStateError,
      );
    });

    test(
      'is deleted with its Stages only while no Collection uses it',
      () async {
        await syncStarterWorkflow();
        final used = await vault.createWorkflow('Used');
        final unused = await vault.createWorkflow('Unused');
        await vault.createCollection('Space Marines', workflowId: used.id);

        await expectLater(vault.deleteWorkflow(used.id), throwsStateError);
        await vault.deleteWorkflow(unused.id);

        expect((await vault.workflows()).map((w) => w.name), [
          'Starter',
          'Used',
        ]);
        final stages = await db.get(
          'SELECT count(*) AS n FROM stages WHERE workflow_id = ?',
          [unused.id],
        );
        expect(stages['n'], 0);
      },
    );

    test('changes apply to every Collection using it', () async {
      await syncStarterWorkflow();
      final w = await vault.createWorkflow('Shared');
      final a = await vault.createCollection('Space Marines', workflowId: w.id);
      final b = await vault.createCollection('Orks', workflowId: w.id);
      await vault.renameStage(w.stages.first.id, 'Wanted');

      final workflows = await vault.workflows();
      for (final c in [a, b]) {
        expect(
          workflows.firstWhere((x) => x.id == c.workflowId).stages.first.name,
          'Wanted',
        );
      }
    });

    test('are watched: the stream emits again after a Stage change', () async {
      final w = await vault.createWorkflow('Mine');
      final firstStages = vault.watchWorkflows().map(
        (ws) => ws.single.stages.first.name,
      );
      final expectation = expectLater(firstStages, emitsThrough('Wanted'));
      await vault.renameStage(w.stages.first.id, 'Wanted');
      await expectation;
    });
  });

  group('Collection', () {
    test('cannot be created before the starter Workflow has synced', () async {
      await expectLater(
        vault.createCollection('Space Marines'),
        throwsStateError,
      );
      expect(await vault.collections(), isEmpty);
    });

    test('is created with the starter Workflow and a UUID id, and persists across restarts', () async {
      final workflowId = await syncStarterWorkflow();
      final created = await vault.createCollection('  Space Marines ');
      await restart();

      final [collection] = await vault.collections();
      expect(collection.id, created.id);
      expect(
        collection.id,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(collection.name, 'Space Marines');
      expect(collection.workflowId, workflowId);
    });

    test('is created with a picked Workflow', () async {
      await syncStarterWorkflow();
      final w = await vault.createWorkflow('Speed painting');
      await vault.createCollection('Orks', workflowId: w.id);
      await expectLater(
        vault.createCollection('Orks', workflowId: 'nope'),
        throwsArgumentError,
      );

      expect((await vault.collections()).single.workflowId, w.id);
    });

    test('is renamed, and the new name persists across restarts', () async {
      await syncStarterWorkflow();
      final created = await vault.createCollection('Space Marines');
      await vault.createCollection('Kill Team');

      await vault.renameCollection(created.id, 'Ultramarines');
      await restart();

      expect((await vault.collections()).map((c) => c.name), [
        'Kill Team',
        'Ultramarines',
      ]);
    });

    test('cannot be created or renamed with a blank name', () async {
      await syncStarterWorkflow();
      final created = await vault.createCollection('Space Marines');

      await expectLater(vault.createCollection('  '), throwsArgumentError);
      expect(() => vault.renameCollection(created.id, ''), throwsArgumentError);
      expect((await vault.collections()).map((c) => c.name), ['Space Marines']);
    });

    test(
      'changes are queued for upload: an insert, then a per-field update',
      () async {
        await syncStarterWorkflow();
        final created = await vault.createCollection('Space Marines');
        await vault.renameCollection(created.id, 'Ultramarines');

        final batch = (await db.getCrudBatch())!;
        final ops = batch.crud.where((e) => e.table == 'collections').toList();
        expect(ops.map((e) => e.op), [UpdateType.put, UpdateType.patch]);
        expect(ops.last.opData, {'name': 'Ultramarines'});
      },
    );

    test('has an optional Game System, set, respelled like one in use, cleared, and kept across restarts', () async {
      await syncStarterWorkflow();
      final marines = await vault.createCollection(
        'Space Marines',
        gameSystem: ' Warhammer 40k ',
      );
      final orks = await vault.createCollection(
        'Orks',
        gameSystem: 'WARHAMMER 40K',
      );
      final party = await vault.createCollection('Party', gameSystem: '  ');
      await vault.setGameSystem(party.id, 'D&D');
      await vault.setGameSystem(marines.id, 'warhammer 40k');
      await restart();

      final byName = {
        for (final c in await vault.collections()) c.name: c.gameSystem,
      };
      expect(byName, {
        'Orks': 'Warhammer 40k',
        'Party': 'D&D',
        'Space Marines': 'Warhammer 40k',
      });
      expect(await vault.gameSystems(), ['D&D', 'Warhammer 40k']);

      await vault.setGameSystem(orks.id, '');
      await vault.setGameSystem(party.id, null);
      expect((await vault.collections()).map((c) => c.gameSystem), [
        null,
        null,
        'Warhammer 40k',
      ]);
      expect(await vault.gameSystems(), ['Warhammer 40k']);

      final ops = (await db.getCrudBatch(limit: 100))!.crud
          .where((e) => e.table == 'collections' && e.op == UpdateType.patch);
      expect(ops.last.opData, {'game_system': null});
    });

    test('are grouped by Game System ignoring case, A–Z, with those without one last', () {
      Collection c(String name, [String? gameSystem]) => Collection(
        id: name,
        name: name,
        workflowId: 'w',
        gameSystem: gameSystem,
      );
      final groups = groupByGameSystem([
        c('Kill Team'),
        c('Orks', 'warhammer'),
        c('Party', 'D&D'),
        c('Marines', 'Warhammer'),
        c('Terrain'),
      ]);
      expect(
        [
          for (final g in groups)
            '${g.gameSystem}: ${g.collections.map((c) => c.name).join(', ')}',
        ],
        ['D&D: Party', 'warhammer: Orks, Marines', 'null: Kill Team, Terrain'],
      );
      expect(groupByGameSystem([]), isEmpty);
    });

    test('are watched: the stream emits again after a change', () async {
      await syncStarterWorkflow();
      final names = vault.watchCollections().map(
        (cs) => cs.map((c) => c.name).toList(),
      );
      final expectation = expectLater(names, emitsThrough(['Space Marines']));
      await vault.createCollection('Space Marines');
      await expectation;
    });
    test('is deleted with its Units and their Tags and Photos, in one upload; another Collection is untouched', () async {
      await syncStarterWorkflow();
      final doomed = await vault.createCollection('Space Marines');
      final kept = await vault.createCollection('Kill Team');
      Future<Unit> add(Collection c, String name) async {
        final u = await vault.addUnit(
          c,
          name: name,
          modelCount: 5,
          stageId: 's0',
        );
        await vault.moveUnit(u, 's1');
        await vault.addTags(u.id, ['Imperium']);
        await vault.addPhotos(u.id, ['file-$name']);
        return u;
      }

      final a = await add(doomed, 'Intercessors');
      final b = await add(doomed, 'Hellblasters');
      final c = await add(kept, 'Veterans');
      await (await db.getCrudBatch(limit: 1000))!.complete();

      expect((await vault.unitsOf(doomed)).length, 2);
      await vault.deleteCollection(doomed.id);
      await restart();

      expect((await vault.collections()).map((c) => c.name), ['Kill Team']);
      expect(await vault.unitsOf(doomed), isEmpty);
      for (final u in [a, b]) {
        expect(await vault.tagsOf(u.id), isEmpty);
        expect(await vault.photosOf(u.id), isEmpty);
      }
      expect((await vault.unitsOf(kept)).single.id, c.id);
      expect(await vault.tagsOf(c.id), ['Imperium']);
      expect(await vault.photosOf(c.id), hasLength(1));
      expect(await vault.watchHistory(c.id).first, hasLength(2));

      // One transaction: children first, then the Collection. Stage Changes are append-only: the server deletes them.
      final tx = (await db.getNextCrudTransaction())!;
      expect(
        (await db.getCrudBatch(limit: 1000))!.crud,
        hasLength(tx.crud.length),
      );
      expect(
        [for (final e in tx.crud) (e.op, e.table)],
        [
          (UpdateType.delete, 'unit_tags'),
          (UpdateType.delete, 'unit_tags'),
          (UpdateType.delete, 'photos'),
          (UpdateType.delete, 'photos'),
          (UpdateType.delete, 'units'),
          (UpdateType.delete, 'units'),
          (UpdateType.delete, 'collections'),
        ],
      );
      expect(tx.crud.last.id, doomed.id);
    });
  });

  group('Unit', () {
    late Collection collection;
    setUp(() async {
      await syncStarterWorkflow();
      collection = await vault.createCollection('Space Marines');
    });

    /// The Collection's groups as "Stage (model count): Unit names", for compact expectations.
    Future<List<String>> groups() async => [
      for (final g in await vault.watchStageGroups(collection).first)
        '${g.stage.name} (${g.modelCount}): ${g.units.map((u) => u.name).join(', ')}',
    ];

    test(
      'is added at a Stage with its fields, and persists across restarts',
      () async {
        final added = await vault.addUnit(
          collection,
          name: ' Intercessors ',
          modelCount: 10,
          notes: ' Magnetised arms ',
          stageId: 's2',
        );
        await restart();

        final [group] = (await vault.watchStageGroups(collection).first)
            .where((g) => g.units.isNotEmpty)
            .toList();
        final [unit] = group.units;
        expect(group.stage.name, 'Assembled');
        expect(unit.id, added.id);
        expect(unit.collectionId, collection.id);
        expect(
          (unit.name, unit.modelCount, unit.notes),
          ('Intercessors', 10, 'Magnetised arms'),
        );
      },
    );

    test('keeps its Stage from being deleted until the Unit is gone', () async {
      final unit = await vault.addUnit(
        collection,
        name: 'Intercessors',
        modelCount: 10,
        stageId: 's3',
      );

      await expectLater(
        vault.deleteStage(collection.workflowId, 's3'),
        throwsStateError,
      );
      await vault.deleteUnit(unit.id);
      await vault.deleteStage(collection.workflowId, 's3');

      expect(await groups(), isNot(contains(startsWith('Primed'))));
    });

    test('cannot be added with a blank name, no models, or a Stage outside the Workflow', () async {
      Future<Unit> add({
        String name = 'Intercessors',
        int count = 1,
        String stage = 's0',
      }) => vault.addUnit(
        collection,
        name: name,
        modelCount: count,
        stageId: stage,
      );

      await expectLater(add(name: ' '), throwsArgumentError);
      await expectLater(add(count: 0), throwsArgumentError);
      await expectLater(add(stage: 'elsewhere'), throwsArgumentError);
      expect(await groups(), everyElement(endsWith('(0): ')));
    });

    test('is edited per field, rejecting a blank name or no models', () async {
      final unit = await vault.addUnit(
        collection,
        name: 'Intercessors',
        modelCount: 10,
        notes: 'Magnetised',
        stageId: 's0',
      );
      await db.execute('DELETE FROM ps_crud');

      await vault.editUnit(
        unit.id,
        name: 'Assault Intercessors',
        modelCount: 5,
      );
      await vault.editUnit(unit.id, notes: 'Jump packs');
      expect(() => vault.editUnit(unit.id, name: ''), throwsArgumentError);
      expect(() => vault.editUnit(unit.id, modelCount: 0), throwsArgumentError);

      final [unitNow] =
          (await vault.watchStageGroups(collection).first).first.units;
      expect(
        (unitNow.name, unitNow.modelCount, unitNow.notes),
        ('Assault Intercessors', 5, 'Jump packs'),
      );
      final ops = (await db.getCrudBatch())!.crud;
      expect(ops.map((e) => [e.op, e.opData]), [
        [
          UpdateType.patch,
          {'name': 'Assault Intercessors', 'model_count': 5},
        ],
        [
          UpdateType.patch,
          {'notes': 'Jump packs'},
        ],
      ]);
    });

    test('is deleted', () async {
      final unit = await vault.addUnit(
        collection,
        name: 'Intercessors',
        modelCount: 10,
        stageId: 's0',
      );
      await vault.addUnit(
        collection,
        name: 'Hellblasters',
        modelCount: 5,
        stageId: 's0',
      );

      await vault.deleteUnit(unit.id);

      expect((await groups()).first, 'Wishlist (5): Hellblasters');
    });

    test(
      'are grouped by Stage in Workflow order, with a model count per Stage',
      () async {
        final other = await vault.createCollection('Kill Team');
        await vault.addUnit(
          other,
          name: 'Elsewhere',
          modelCount: 3,
          stageId: 's0',
        );
        await vault.addUnit(
          collection,
          name: 'Terminators',
          modelCount: 5,
          stageId: 's4',
        );
        await vault.addUnit(
          collection,
          name: 'Intercessors',
          modelCount: 10,
          stageId: 's0',
        );
        await vault.addUnit(
          collection,
          name: 'Captain',
          modelCount: 1,
          stageId: 's4',
        );
        await vault.addUnit(
          collection,
          name: 'hellblasters',
          modelCount: 5,
          stageId: 's0',
        );

        expect(await groups(), [
          'Wishlist (15): hellblasters, Intercessors',
          'Unassembled (0): ',
          'Assembled (0): ',
          'Primed (0): ',
          'Painted (6): Captain, Terminators',
          'Based (0): ',
          'Done (0): ',
        ]);
      },
    );

    test('groups are watched: the stream emits again after a change', () async {
      final counts = vault
          .watchStageGroups(collection)
          .map((gs) => gs.first.modelCount);
      final expectation = expectLater(counts, emitsThrough(10));
      await vault.addUnit(
        collection,
        name: 'Intercessors',
        modelCount: 10,
        stageId: 's0',
      );
      await expectation;
    });
  });

  // The starter Workflow: s0 Wishlist, s1 Unassembled (Owned), s2 Assembled, s3 Primed, s4 Painted, s5 Based,
  // s6 Done (Finished).
  group('Progress', () {
    late String workflowId;
    late Collection collection;
    setUp(() async {
      workflowId = await syncStarterWorkflow();
      collection = await vault.createCollection('Space Marines');
    });

    Future<void> add(int modelCount, String stageId) => vault.addUnit(
      collection,
      name: 'Unit at $stageId',
      modelCount: modelCount,
      stageId: stageId,
    );
    Future<Progress> progress() => vault.watchProgress(collection).first;
    Matcher p(int wanted, int owned, int finished) => isA<Progress>()
        .having((p) => p.wanted, 'wanted', wanted)
        .having((p) => p.owned, 'owned', owned)
        .having((p) => p.finished, 'finished', finished);

    /// Progress.stages as "Stage name: models".
    Future<List<String>> perStage() async => [
      for (final s in (await progress()).stages) '${s.stage.name}: ${s.models}',
    ];

    test('of an empty Collection is 0 / 0, with no division by zero', () async {
      final empty = await progress();
      expect(empty, p(0, 0, 0));
      expect(empty.finishedShare, 0);
    });

    test('counts models before the Owned Stage as wanted only, and after the Finished Stage as finished', () async {
      await vault.setFinishedStage(workflowId, 's4');
      await add(5, 's0');
      await add(10, 's1');
      await add(2, 's3');
      await add(3, 's4');
      await add(4, 's6');
      final other = await vault.createCollection('Orks');
      await vault.addUnit(other, name: 'Boyz', modelCount: 20, stageId: 's6');

      final totals = await progress();
      expect(totals, p(5, 19, 7));
      expect(totals.finishedShare, 7 / 19);
    });

    test('counts owned models per Stage, in Workflow order; the finished ones are the Finished Stage on', () async {
      await vault.setFinishedStage(workflowId, 's4');
      await add(5, 's0');
      await add(10, 's1');
      await add(2, 's3');
      await vault.addUnit(
        collection,
        name: 'Other',
        modelCount: 1,
        stageId: 's3',
      );
      await add(3, 's4');
      await add(4, 's6');

      // Wishlist is wanted, so not counted; Stages without models are left out.
      expect(await perStage(), [
        'Unassembled: 10',
        'Primed: 3',
        'Painted: 3',
        'Done: 4',
      ]);
      final totals = await progress();
      expect(totals, p(5, 20, 7));
      expect(totals.stages.fold(0, (n, s) => n + s.models), totals.owned);
      expect(
        totals.stages.skip(2).fold(0, (n, s) => n + s.models),
        totals.finished,
      );
    });

    test('is watched: emits again when models move between Stages with the same totals, or a Stage colour changes', () async {
      await add(5, 's2');
      final totals = vault.watchProgress(collection).asBroadcastStream();
      final moved = expectLater(
        totals,
        emitsThrough(
          isA<Progress>().having(
            (p) => p.stages.single.stage.id,
            'Stage',
            's3',
          ),
        ),
      );
      await vault.moveUnit((await vault.unitsOf(collection)).single, 's3');
      await moved;
      final recoloured = expectLater(
        totals,
        emitsThrough(
          isA<Progress>().having(
            (p) => p.stages.single.stage.colour,
            'colour',
            '#123456',
          ),
        ),
      );
      await vault.setStageColour('s3', '#123456');
      await recoloured;
    });

    test('with the Owned and Finished Stage the same Stage', () async {
      await vault.setFinishedStage(workflowId, 's1');
      await add(5, 's0');
      await add(10, 's1');
      await add(2, 's3');

      expect(await progress(), p(5, 12, 12));
    });

    test('follows the Stage order', () async {
      await add(5, 's0');
      // Wishlist moved after Unassembled, so the Owned Stage comes first and Wishlist models are owned.
      await vault.moveStage(workflowId, 's0', 1);

      expect(await progress(), p(0, 5, 0));
    });

    test('is watched: emits again after a Unit change and after the Owned or Finished Stage changes', () async {
      await add(5, 's0');
      await add(10, 's2');
      final totals = vault.watchProgress(collection).asBroadcastStream();
      Future<void> expectAfter(
        Future<void> Function() change,
        Matcher expected,
      ) async {
        final expectation = expectLater(totals, emitsThrough(expected));
        await change();
        await expectation;
      }

      await expectAfter(() => add(3, 's3'), p(5, 13, 0));
      await expectAfter(
        () => vault.setOwnedStage(workflowId, 's0'),
        p(0, 18, 0),
      );
      await expectAfter(
        () => vault.setFinishedStage(workflowId, 's2'),
        p(0, 18, 13),
      );
    });

    group('per Workflow', () {
      /// Each section as "Workflow: Stage models, ...", every Stage of it listed.
      Future<List<String>> sections([Collection? only]) async => [
        for (final w in await vault.watchProgressByWorkflow(only).first)
          '${w.workflow.name}: ${[for (final g in w.stages) '${g.stage.name} ${g.modelCount}'].join(', ')}',
      ];

      test('sums the Collections using a Workflow, listing every Stage, pre-owned and empty ones included', () async {
        await add(5, 's0');
        await add(10, 's1');
        final orks = await vault.createCollection('Orks');
        await vault.addUnit(orks, name: 'Boyz', modelCount: 20, stageId: 's6');
        await vault.addUnit(orks, name: 'Grots', modelCount: 3, stageId: 's1');

        expect(await sections(), [
          'Starter: Wishlist 5, Unassembled 13, Assembled 0, Primed 0, Painted 0, Based 0, Done 20',
        ]);
        final all = await vault.watchProgressByWorkflow().first;
        expect(all.single.progress, p(5, 33, 20));
        expect(Progress.combined(all.map((w) => w.progress)), p(5, 33, 20));
        // Only the given Collection.
        expect(await sections(collection), [
          'Starter: Wishlist 5, Unassembled 10, Assembled 0, Primed 0, Painted 0, Based 0, Done 0',
        ]);
      });

      test('keeps Workflows apart, even where Stage names match, and totals them together', () async {
        await add(10, 's1');
        final other = await vault.createWorkflow('Kill Team');
        final kt = await vault.createCollection(
          'Kommandos',
          workflowId: other.id,
        );
        await vault.addUnit(
          kt,
          name: 'Kommandos',
          modelCount: 4,
          stageId: other.stages[1].id,
        );
        await vault.addUnit(
          kt,
          name: 'Nob',
          modelCount: 1,
          stageId: other.stages.last.id,
        );
        // A Workflow no Collection uses gets no section.
        await vault.createWorkflow('Unused');

        expect(await sections(), [
          'Starter: Wishlist 0, Unassembled 10, Assembled 0, Primed 0, Painted 0, Based 0, Done 0',
          'Kill Team: Wishlist 0, Unassembled 4, Assembled 0, Primed 0, Painted 0, Based 0, Done 1',
        ]);
        final total = Progress.combined(
          (await vault.watchProgressByWorkflow().first).map((w) => w.progress),
        );
        expect(total, p(0, 15, 1));
        expect(
          [for (final s in total.stages) '${s.stage.name}: ${s.models}'],
          ['Unassembled: 10', 'Unassembled: 4', 'Done: 1'],
        );
      });

      test('is empty without Collections, and watched', () async {
        await vault.deleteCollection(collection.id);
        final all = vault.watchProgressByWorkflow().asBroadcastStream();
        expect(await all.first, isEmpty);
        final added = expectLater(
          all,
          emitsThrough(
            isA<List<WorkflowProgress>>().having(
              (ws) => ws.single.progress,
              'progress',
              p(0, 2, 0),
            ),
          ),
        );
        final orks = await vault.createCollection('Orks');
        await vault.addUnit(orks, name: 'Boyz', modelCount: 2, stageId: 's1');
        await added;
      });
    });
  });

  group('Stage Change', () {
    late Collection collection;
    late Unit unit;
    setUp(() async {
      await syncStarterWorkflow();
      collection = await vault.createCollection('Space Marines');
      unit = await vault.addUnit(
        collection,
        name: 'Intercessors',
        modelCount: 10,
        stageId: 's1',
      );
    });

    /// The Unit's history as "from -> to (models)", oldest first.
    Future<List<String>> history() async => [
      for (final c in await vault.watchHistory(unit.id).first)
        '${c.fromStageId} -> ${c.toStageId} (${c.modelCount})',
    ];
    Future<Unit> reload() async =>
        (await vault.watchStageGroups(collection).first)
            .expand((g) => g.units)
            .single;

    test('creating a Unit records its starting Stage', () async {
      expect(await history(), ['null -> s1 (10)']);
    });

    test(
      'a move sorts after a synced one stamped ahead of this device\'s clock',
      () async {
        // Another device, its clock far ahead, moved the Unit to s3; sync delivers it in Postgres's text format.
        await db.execute(
          "INSERT INTO stage_changes (id, unit_id, from_stage_id, to_stage_id, model_count, happened_at) VALUES ('sc-ahead', ?, 's1', 's3', 10, '2099-01-01 00:00:00+00')",
          [unit.id],
        );
        await db.execute("UPDATE units SET stage_id = 's3' WHERE id = ?", [
          unit.id,
        ]);

        await vault.moveUnit(await reload(), 's5');

        final latest = (await vault.watchHistory(unit.id).first).last;
        expect(latest.toStageId, 's5');
        expect(latest.happenedAt.isAfter(DateTime.utc(2099)), isTrue);
        expect((await reload()).stageId, 's5');
      },
    );

    test('moves a Unit forward and back, recording each move in order, across restarts', () async {
      await vault.moveUnit(unit, 's4');
      await vault.moveUnit(await reload(), 's2');
      await restart();

      expect((await reload()).stageId, 's2');
      expect(await history(), [
        'null -> s1 (10)',
        's1 -> s4 (10)',
        's4 -> s2 (10)',
      ]);
      final times = [
        for (final c in await vault.watchHistory(unit.id).first) c.happenedAt,
      ];
      expect(times, orderedEquals([...times]..sort()));
    });

    test('moving to the current Stage records nothing', () async {
      await vault.moveUnit(unit, 's1');
      expect(await history(), hasLength(1));
    });

    test('a Stage outside the Workflow is rejected', () async {
      await expectLater(vault.moveUnit(unit, 'elsewhere'), throwsArgumentError);
      expect((await reload()).stageId, 's1');
      expect(await history(), hasLength(1));
    });

    test('a move uploads a Stage Change insert', () async {
      await db.execute('DELETE FROM ps_crud');
      await vault.moveUnit(unit, 's4');

      final ops = (await db.getCrudBatch())!.crud;
      expect(ops.map((e) => (e.op, e.table)), [
        (UpdateType.patch, 'units'),
        (UpdateType.put, 'stage_changes'),
      ]);
    });

    test('history is watched: the stream emits again after a move', () async {
      final lengths = vault.watchHistory(unit.id).map((h) => h.length);
      final expectation = expectLater(lengths, emitsThrough(2));
      await vault.moveUnit(unit, 's3');
      await expectation;
    });
  });

  group('Deleting a Stage that holds Units', () {
    late Workflow w;
    late Collection marines, orks;
    late Unit a, b;
    setUp(() async {
      await syncStarterWorkflow();
      w = await vault.createWorkflow('Shared');
      marines = await vault.createCollection('Marines', workflowId: w.id);
      orks = await vault.createCollection('Orks', workflowId: w.id);
      a = await vault.addUnit(
        marines,
        name: 'A',
        modelCount: 5,
        stageId: w.stages[3].id,
      );
      b = await vault.addUnit(
        orks,
        name: 'B',
        modelCount: 3,
        stageId: w.stages[3].id,
      );
    });

    Future<List<String>> stageNames() async => [
      for (final s
          in (await vault.workflows()).firstWhere((x) => x.id == w.id).stages)
        s.name,
    ];
    Future<List<String>> history(Unit u) async => [
      for (final c in await vault.watchHistory(u.id).first)
        '${c.fromStageId} -> ${c.toStageId} (${c.modelCount})',
    ];

    test('moves its Units in every Collection to the destination, recording a Stage Change each, then deletes it', () async {
      final [..., assembled, primed, _, _, _] = w.stages;
      await expectLater(vault.deleteStage(w.id, primed.id), throwsStateError);

      await vault.deleteStage(w.id, primed.id, moveUnitsTo: assembled.id);
      await restart();

      expect(await stageNames(), isNot(contains('Primed')));
      for (final c in [marines, orks]) {
        final units = (await vault.watchStageGroups(c).first).expand(
          (g) => g.units,
        );
        expect(units.single.stageId, assembled.id);
      }
      expect(await history(a), [
        'null -> ${primed.id} (5)',
        '${primed.id} -> ${assembled.id} (5)',
      ]);
      expect(await history(b), [
        'null -> ${primed.id} (3)',
        '${primed.id} -> ${assembled.id} (3)',
      ]);
    });

    test('uploads as one transaction: moves, then the Owned or Finished change, then the Stage delete', () async {
      final unassembled = w.stages[1];
      await vault.moveUnit(a, unassembled.id);
      await vault.moveUnit(b, unassembled.id);
      await db.execute('DELETE FROM ps_crud');

      await vault.deleteStage(
        w.id,
        unassembled.id,
        moveUnitsTo: w.stages[0].id,
        ownedStageId: w.stages[2].id,
      );

      final transaction = (await db.getNextCrudTransaction())!;
      expect(transaction.crud.map((e) => (e.op, e.table)), [
        (UpdateType.patch, 'units'),
        (UpdateType.put, 'stage_changes'),
        (UpdateType.patch, 'units'),
        (UpdateType.put, 'stage_changes'),
        (UpdateType.patch, 'workflows'),
        (UpdateType.delete, 'stages'),
      ]);
      await transaction.complete();
      expect(await db.getNextCrudTransaction(), isNull);
    });

    test('the Owned or Finished Stage needs a replacement, in order, and nothing changes without one', () async {
      final [wishlist, unassembled, assembled, ..., based, done] = w.stages;
      await vault.moveUnit(a, done.id);

      await expectLater(
        vault.deleteStage(w.id, done.id, moveUnitsTo: based.id),
        throwsStateError,
      );
      await expectLater(
        vault.deleteStage(
          w.id,
          done.id,
          moveUnitsTo: based.id,
          finishedStageId: done.id,
        ),
        throwsStateError,
      );
      await expectLater(
        vault.deleteStage(
          w.id,
          done.id,
          moveUnitsTo: based.id,
          finishedStageId: wishlist.id,
        ),
        throwsArgumentError,
      );
      expect(await stageNames(), contains('Done'));

      await vault.deleteStage(
        w.id,
        done.id,
        moveUnitsTo: based.id,
        finishedStageId: based.id,
      );
      await vault.deleteStage(w.id, unassembled.id, ownedStageId: assembled.id);

      final read = (await vault.workflows()).firstWhere((x) => x.id == w.id);
      expect(
        (read.ownedStage.name, read.finishedStage.name),
        ('Assembled', 'Based'),
      );
      expect(
        await stageNames(),
        isNot(anyOf(contains('Done'), contains('Unassembled'))),
      );
    });

    test(
      'the destination must be another Stage of the same Workflow',
      () async {
        final primed = w.stages[3];
        final starter = (await vault.starterWorkflow())!;
        for (final destination in [
          primed.id,
          starter.stages.first.id,
          'nowhere',
        ]) {
          await expectLater(
            vault.deleteStage(w.id, primed.id, moveUnitsTo: destination),
            throwsArgumentError,
            reason: destination,
          );
        }
        expect(await stageNames(), contains('Primed'));
        expect(await history(a), hasLength(1));
      },
    );
  });

  group('Switching a Collection to another Workflow', () {
    late Workflow starter, target;
    late Collection marines;
    late Unit a, b, c;
    setUp(() async {
      await syncStarterWorkflow();
      starter = (await vault.starterWorkflow())!;
      // Stages: Wishlist, Unassembled, Assembled, Primed, Painted, Based, Done. Renamed to test the matching; the
      // untrimmed name stands in for one synced from elsewhere (the app trims names it stores).
      target = await vault.createWorkflow('Speed painting');
      await db.execute("UPDATE stages SET name = '  WISHLIST ' WHERE id = ?", [
        target.stages[0].id,
      ]);
      await vault.renameStage(target.stages[3].id, 'Sprayed');
      target = (await vault.workflows()).firstWhere((w) => w.id == target.id);
      marines = await vault.createCollection('Marines');
      a = await vault.addUnit(marines, name: 'A', modelCount: 5, stageId: 's0');
      b = await vault.addUnit(marines, name: 'B', modelCount: 3, stageId: 's3');
      c = await vault.addUnit(marines, name: 'C', modelCount: 1, stageId: 's3');
      // A Unit of another Collection on the same Workflow stays where it is.
      await vault.addUnit(
        await vault.createCollection('Orks'),
        name: 'Boyz',
        modelCount: 10,
        stageId: 's5',
      );
    });

    Future<List<String>> history(Unit u) async => [
      for (final c in await vault.watchHistory(u.id).first)
        '${c.fromStageId} -> ${c.toStageId} (${c.modelCount})',
    ];

    test('asks only about Stages that hold Units, pre-matching same-name Stages ignoring case and outer spaces', () async {
      final mapping = await vault.stageMapping(marines, target);

      expect(
        [for (final m in mapping) (m.from.name, m.to?.name)],
        [('Wishlist', '  WISHLIST '), ('Primed', null)],
      );
    });

    test('moves every Unit to its mapped Stage with a Stage Change, and points the Collection at the new Workflow', () async {
      final [wishlist, ..., sprayed, _, _, _] = target.stages;
      await vault.switchWorkflow(marines, target.id, {
        's0': wishlist.id,
        's3': sprayed.id,
      });
      await restart();

      final switched = (await vault.collections()).firstWhere(
        (x) => x.id == marines.id,
      );
      expect(switched.workflowId, target.id);
      final groups = await vault.watchStageGroups(switched).first;
      expect(
        {
          for (final g in groups)
            if (g.units.isNotEmpty)
              g.stage.name: [for (final u in g.units) u.name],
        },
        {
          '  WISHLIST ': ['A'],
          'Sprayed': ['B', 'C'],
        },
      );
      expect(await history(a), ['null -> s0 (5)', 's0 -> ${wishlist.id} (5)']);
      expect(await history(b), ['null -> s3 (3)', 's3 -> ${sprayed.id} (3)']);
      expect(await history(c), ['null -> s3 (1)', 's3 -> ${sprayed.id} (1)']);
      final orks = (await vault.collections()).firstWhere(
        (x) => x.name == 'Orks',
      );
      expect(orks.workflowId, starter.id);
    });

    test(
      'uploads as one transaction: the moves, then the Collection',
      () async {
        await db.execute('DELETE FROM ps_crud');
        await vault.switchWorkflow(marines, target.id, {
          's0': target.stages[0].id,
          's3': target.stages[3].id,
        });

        final transaction = (await db.getNextCrudTransaction())!;
        expect(transaction.crud.map((e) => (e.op, e.table)), [
          for (var i = 0; i < 3; i++) ...[
            (UpdateType.patch, 'units'),
            (UpdateType.put, 'stage_changes'),
          ],
          (UpdateType.patch, 'collections'),
        ]);
        expect(transaction.crud.last.opData, {'workflow_id': target.id});
        await transaction.complete();
        expect(await db.getNextCrudTransaction(), isNull);
      },
    );

    test('every held Stage must map to a Stage of the new Workflow; nothing changes otherwise', () async {
      for (final moveTo in [
        {'s0': target.stages[0].id}, // Primed unmapped
        {'s0': target.stages[0].id, 's3': 's4'}, // a Stage of the old Workflow
        {'s0': target.stages[0].id, 's3': 'nowhere'},
      ]) {
        await expectLater(
          vault.switchWorkflow(marines, target.id, moveTo),
          throwsArgumentError,
          reason: '$moveTo',
        );
      }
      await expectLater(
        vault.switchWorkflow(marines, 'no-such-workflow', {}),
        throwsArgumentError,
      );

      final read = (await vault.collections()).firstWhere(
        (x) => x.id == marines.id,
      );
      expect(read.workflowId, starter.id);
      expect(await history(b), hasLength(1));
    });

    test(
      'a Collection without Units has nothing to map and just switches',
      () async {
        final empty = await vault.createCollection('Empty');
        expect(await vault.stageMapping(empty, target), isEmpty);

        await vault.switchWorkflow(empty, target.id, {});

        final read = (await vault.collections()).firstWhere(
          (x) => x.id == empty.id,
        );
        expect(read.workflowId, target.id);
      },
    );
  });

  group('Tags', () {
    late Collection collection;
    late Unit unit;
    setUp(() async {
      await syncStarterWorkflow();
      collection = await vault.createCollection('Necrons');
      unit = await vault.addUnit(
        collection,
        name: 'Warriors',
        modelCount: 10,
        stageId: 's0',
      );
    });

    test('are added and removed, and persist across restarts', () async {
      await vault.addTags(unit.id, [' Warhammer 40k ', 'Necrons', '  ']);
      await restart();
      expect(await vault.tagsOf(unit.id), ['Necrons', 'Warhammer 40k']);

      await vault.removeTag(unit.id, 'NECRONS ');
      expect(await vault.tagsOf(unit.id), ['Warhammer 40k']);
    });

    test('are the same Tag ignoring case and outer spaces, keeping the first casing', () async {
      await vault.addTags(unit.id, ['Necrons', ' necrons', 'NECRONS']);
      final other = await vault.addUnit(
        collection,
        name: 'Immortals',
        modelCount: 5,
        stageId: 's0',
      );
      await vault.addTags(other.id, ['necrons ']);

      expect(await vault.tagsOf(unit.id), ['Necrons']);
      expect(await vault.tagsOf(other.id), ['Necrons']);
      // The same Unit and Tag give the same row id on every device, so offline adds merge into one row.
      expect(tagId(unit.id, ' NECRONS'), tagId(unit.id, 'Necrons'));
      expect(tagId(other.id, 'Necrons'), isNot(tagId(unit.id, 'Necrons')));
    });

    test(
      'are suggested by prefix from the Tags already used, once each',
      () async {
        final other = await vault.addUnit(
          collection,
          name: 'Immortals',
          modelCount: 5,
          stageId: 's0',
        );
        await vault.addTags(unit.id, [
          'Necrons',
          'Warhammer 40k',
          'Nightbringer',
        ]);
        await vault.addTags(other.id, ['necrons', 'Kill Team']);

        expect(await vault.suggestTags(' n'), ['Necrons', 'Nightbringer']);
        expect(await vault.suggestTags('WAR'), ['Warhammer 40k']);
        expect(await vault.suggestTags('x'), isEmpty);
      },
    );

    test("suggestions are only the user's own: another account's database knows none of them", () async {
      await vault.addTags(unit.id, ['Necrons']);
      expect(await vault.suggestTags('N'), ['Necrons']);

      // A second account signs in on a fresh database; sync only delivers each user their own rows (server/test).
      await db.close();
      await dir.delete(recursive: true);
      dir = await Directory.systemTemp.createTemp('domain_core_test');
      await launch();
      expect(await vault.suggestTags(''), isEmpty);
    });

    test('are deleted with their Unit, uploading the deletes', () async {
      await vault.addTags(unit.id, ['Necrons', 'Warhammer 40k']);
      await vault.deleteUnit(unit.id);

      expect(await db.getAll('SELECT * FROM unit_tags'), isEmpty);
      final uploads = [
        for (final op in (await db.getCrudBatch(limit: 100))!.crud)
          if (op.op == UpdateType.delete) op.table,
      ];
      expect(uploads, ['unit_tags', 'unit_tags', 'units']);
    });

    test('are watched: the stream emits again after a change', () async {
      final tags = vault.watchTags(unit.id);
      final expectation = expectLater(tags, emitsThrough(['Necrons']));
      await vault.addTags(unit.id, ['Necrons']);
      await expectation;
    });
  });

  group('Photos', () {
    late Collection collection;
    late Unit unit;
    setUp(() async {
      await syncStarterWorkflow();
      collection = await vault.createCollection('Necrons');
      unit = await vault.addUnit(
        collection,
        name: 'Warriors',
        modelCount: 10,
        stageId: 's0',
      );
    });

    List<String> files(List<Photo> photos) => [
      for (final p in photos) p.fileId,
    ];

    test('are added and removed, and persist across restarts', () async {
      // The app's path for a new image: the Photo is stored in the transaction that queues its file.
      final photo = await vault.newPhoto(unit.id);
      await db.writeTransaction(
        (tx) => SqliteVaultStore.insertPhoto(tx, photo),
      );
      final [second] = await vault.addPhotos(unit.id, ['f2']);
      await restart();
      expect(
        files(await vault.photosOf(unit.id)),
        unorderedEquals([photo.fileId, 'f2']),
      );

      await vault.removePhoto(photo.id);
      expect(await vault.photosOf(unit.id), [
        isA<Photo>().having((p) => p.id, 'id', second.id),
      ]);
    });

    test('are at most ten per Unit', () async {
      await vault.addPhotos(unit.id, [for (var i = 0; i < 9; i++) 'f$i']);
      await expectLater(vault.addPhotos(unit.id, ['a', 'b']), throwsStateError);
      await vault.newPhoto(unit.id);
      // f0 is already there, so only f9 is added.
      await vault.addPhotos(unit.id, ['f9', 'f0']);

      expect(await vault.photosOf(unit.id), hasLength(Vault.maxPhotos));
      await expectLater(vault.newPhoto(unit.id), throwsStateError);
      await expectLater(vault.addPhotos(unit.id, ['f10']), throwsStateError);
    });

    test('are deleted with their Unit, uploading the deletes', () async {
      await vault.addPhotos(unit.id, ['f1', 'f2']);
      await (await db.getCrudBatch())!.complete();
      await vault.deleteUnit(unit.id);

      expect(await db.getAll('SELECT * FROM photos'), isEmpty);
      final uploads = [
        for (final op in (await db.getCrudBatch(limit: 100))!.crud) op.table,
      ];
      expect(uploads, ['photos', 'photos', 'units']);
    });

    test('of one Unit can be attached to another, sharing the files', () async {
      final other = await vault.addUnit(
        collection,
        name: 'Warriors',
        modelCount: 4,
        stageId: 's1',
      );
      await vault.addPhotos(unit.id, ['f1', 'f2']);

      await vault.addPhotos(other.id, files(await vault.photosOf(unit.id)));
      final copies = await vault.photosOf(other.id);
      expect(files(copies), unorderedEquals(['f1', 'f2']));

      // Removing a copy leaves the original's row, and so its file.
      await vault.removePhoto(copies.firstWhere((p) => p.fileId == 'f1').id);
      expect(
        files(await vault.photosOf(unit.id)),
        unorderedEquals(['f1', 'f2']),
      );
      expect(files(await vault.photosOf(other.id)), ['f2']);
    });
  });

  group('Split and Merge', () {
    late Collection collection;
    late Unit unit;
    setUp(() async {
      await syncStarterWorkflow();
      collection = await vault.createCollection('Space Marines');
      unit = await vault.addUnit(
        collection,
        name: 'Intercessors',
        modelCount: 10,
        notes: 'Blue',
        stageId: 's1',
      );
      await vault.addTags(unit.id, ['Ultramarines', '40k']);
      await vault.addPhotos(unit.id, ['f1', 'f2']);
    });

    Future<List<Unit>> units() async =>
        (await vault.watchStageGroups(collection).first)
            .expand((g) => g.units)
            .toList();
    Future<Unit> reload(String id) async =>
        (await units()).firstWhere((u) => u.id == id);
    Future<List<String>> history(String id) async => [
      for (final c in await vault.watchHistory(id).first)
        '${c.fromStageId} -> ${c.toStageId} (${c.modelCount})',
    ];
    List<String> files(List<Photo> photos) => [
      for (final p in photos) p.fileId,
    ];

    test('a Split creates a Unit with the moved models, copying name, notes, Tags and Photos; the rest stay', () async {
      await db.execute('DELETE FROM ps_crud');
      final split = await vault.splitUnit(unit, 's3', 4);

      expect((await reload(unit.id)).modelCount, 6);
      final created = await reload(split.id);
      expect(
        (created.name, created.notes, created.modelCount, created.stageId),
        ('Intercessors', 'Blue', 4, 's3'),
      );
      expect(await vault.tagsOf(split.id), ['40k', 'Ultramarines']);
      expect(
        files(await vault.photosOf(split.id)),
        unorderedEquals(['f1', 'f2']),
      );
      expect(await history(split.id), ['s1 -> s3 (4)']);
      expect(await history(unit.id), ['null -> s1 (10)']);

      // One batch, the new Unit's rows first; the Split is the delta, and the count PATCH follows it.
      final transaction = (await db.getNextCrudTransaction())!;
      expect(transaction.crud.map((e) => e.table), [
        'units',
        'stage_changes',
        'unit_tags',
        'unit_tags',
        'photos',
        'photos',
        'splits',
        'units',
      ]);
      expect(transaction.crud[6].opData, {
        'unit_id': unit.id,
        'new_unit_id': split.id,
        'model_count': 4,
      });
      await transaction.complete();
      expect(await db.getNextCrudTransaction(), isNull);
    });

    test('a Split takes at least 1 model and leaves at least 1, to another Stage of the Workflow', () async {
      for (final count in [0, 10, 11]) {
        await expectLater(
          vault.splitUnit(unit, 's3', count),
          throwsArgumentError,
        );
      }
      await expectLater(vault.splitUnit(unit, 's1', 4), throwsArgumentError);
      await expectLater(vault.splitUnit(unit, 'x', 4), throwsArgumentError);
      expect(await units(), hasLength(1));
      expect((await reload(unit.id)).modelCount, 10);
    });

    test('Merge is offered only for Units in the same Collection, with the same name, at the same Stage', () async {
      final split = await vault.splitUnit(unit, 's3', 4);
      final renamed = await vault.addUnit(
        collection,
        name: 'Hellblasters',
        modelCount: 5,
        stageId: 's3',
      );
      final elsewhere = await vault.addUnit(
        await vault.createCollection('Other'),
        name: 'Intercessors',
        modelCount: 5,
        stageId: 's3',
      );
      final all = [...await units(), elsewhere];

      // At different Stages, nothing; a Unit added at the same Stage (as after moves on two devices), each other only.
      expect(Vault.mergeCandidates(await reload(unit.id), all), isEmpty);
      final twin = await vault.addUnit(
        collection,
        name: 'Intercessors',
        modelCount: 2,
        stageId: 's3',
      );
      expect(
        Vault.mergeCandidates(twin, [...await units(), elsewhere, renamed]),
        [isA<Unit>().having((u) => u.id, 'id', split.id)],
      );
      await expectLater(vault.mergeUnits(twin, renamed), throwsArgumentError);
      await expectLater(vault.mergeUnits(twin, elsewhere), throwsArgumentError);
      // Units that already share a Stage are Merged only by explicit choice.
      expect(await units(), hasLength(4));
    });

    test('Merge sums the counts, unites the Tags and Photos (up to the cap) and keeps both histories', () async {
      // A second Unit at the same Stage, as after moves on two devices.
      final split = await vault.addUnit(
        collection,
        name: 'Intercessors',
        modelCount: 4,
        stageId: 's1',
      );
      await vault.addTags(split.id, ['Primaris']);
      // 5 + 8 new files is over the cap of 10.
      await vault.addPhotos(unit.id, ['g1', 'g2', 'g3']);
      await vault.addPhotos(split.id, [for (var i = 3; i < 11; i++) 'f$i']);
      await db.execute('DELETE FROM ps_crud');

      await vault.mergeUnits(await reload(unit.id), await reload(split.id));

      expect(await units(), [
        isA<Unit>()
            .having((u) => u.id, 'id', unit.id)
            .having((u) => u.modelCount, 'modelCount', 14)
            .having((u) => u.stageId, 'stageId', 's1'),
      ]);
      expect(await vault.tagsOf(unit.id), ['40k', 'Primaris', 'Ultramarines']);
      final photos = files(await vault.photosOf(unit.id));
      expect(photos, hasLength(Vault.maxPhotos));
      expect(photos, containsAll(['f1', 'f2', 'g1', 'g2', 'g3']));
      expect(await vault.tagsOf(split.id), isEmpty);
      expect(await vault.photosOf(split.id), isEmpty);
      expect(await history(unit.id), ['null -> s1 (10)', 'null -> s1 (4)']);

      // One batch, the Merge first so the server checks it before anything else.
      final transaction = (await db.getNextCrudTransaction())!;
      expect(transaction.crud.first.table, 'merges');
      expect(transaction.crud.last.op, UpdateType.delete);
      expect(transaction.crud.last.id, split.id);
    });
  });

  group('Squads', () {
    late Collection collection;
    setUp(() async {
      await syncStarterWorkflow();
      collection = await vault.createCollection('Space Marines');
      for (final (name, count, stage) in [
        ('Intercessors', 6, 's1'),
        ('Intercessors', 4, 's6'),
        ('Captain', 1, 's0'),
        ('Intercessors', 2, 's6'),
      ]) {
        await vault.addUnit(
          collection,
          name: name,
          modelCount: count,
          stageId: stage,
        );
      }
    });

    test(
      'groups Units by name over every Stage, with their progress',
      () async {
        final squads = await vault.watchSquads(collection).first;

        expect(
          [for (final s in squads) (s.name, s.modelCount)],
          [('Captain', 1), ('Intercessors', 12)],
        );
        final intercessors = squads.last;
        expect(
          [for (final g in intercessors.stages) g.modelCount],
          [
            0, 6, 0, 0, 0, 0, 6, //
          ],
        );
        expect(intercessors.stages[6].units, hasLength(2));
        expect(
          (
            intercessors.progress.wanted,
            intercessors.progress.owned,
            intercessors.progress.finished,
          ),
          (0, 12, 6),
        );
      },
    );

    test('renaming a Squad renames each of its Units', () async {
      final squad = (await vault.watchSquads(collection).first).last;

      await vault.renameSquad(squad, ' Assault Intercessors ');

      expect(
        [
          for (final s in await vault.watchSquads(collection).first)
            (s.name, s.modelCount),
        ],
        [('Assault Intercessors', 12), ('Captain', 1)],
      );
      expect(() => vault.renameSquad(squad, '  '), throwsArgumentError);
    });
  });

  group('Merge on arrival and Squad moves', () {
    late Collection collection;
    setUp(() async {
      await syncStarterWorkflow();
      collection = await vault.createCollection('Space Marines');
    });

    Future<Unit> add(
      int count,
      String stageId, {
      String name = 'Intercessors',
    }) => vault.addUnit(
      collection,
      name: name,
      modelCount: count,
      stageId: stageId,
    );
    Future<List<(String, String, int)>> squad() async => [
      for (final u in await vault.unitsOf(collection))
        (u.id, u.stageId, u.modelCount),
    ];
    Future<List<String>> history(String id) async => [
      for (final c in await vault.watchHistory(id).first)
        '${c.fromStageId} -> ${c.toStageId} (${c.modelCount})',
    ];

    test('moving a whole Unit onto a Stage with a matching Unit Merges it into that Unit, move recorded', () async {
      final there = await add(3, 's3');
      await vault.addTags(there.id, ['Ultramarines']);
      final moving = await add(5, 's1');
      await vault.addTags(moving.id, ['40k']);
      await vault.addPhotos(moving.id, ['f1']);
      await db.execute('DELETE FROM ps_crud');

      await vault.moveUnit(moving, 's3');

      expect(await squad(), [(there.id, 's3', 8)]);
      expect(await vault.tagsOf(there.id), ['40k', 'Ultramarines']);
      expect(
        [for (final p in await vault.photosOf(there.id)) p.fileId],
        ['f1'],
      );
      expect(
        await history(there.id),
        unorderedEquals(['null -> s3 (3)', 'null -> s1 (5)', 's1 -> s3 (5)']),
      );
      // The move uploads first, so the write API sees both Units at s3 when it checks the Merge.
      final move = (await db.getNextCrudTransaction())!;
      expect(move.crud.map((e) => e.table), ['units', 'stage_changes']);
      await move.complete();
      expect((await db.getNextCrudTransaction())!.crud.first.table, 'merges');
    });

    test(
      'splitting models onto a Stage with a matching Unit adds them to it',
      () async {
        final there = await add(3, 's3');
        final source = await add(10, 's1');

        final into = await vault.splitUnit(source, 's3', 4);

        expect((into.id, into.stageId, into.modelCount), (there.id, 's3', 7));
        expect(
          await squad(),
          unorderedEquals([(there.id, 's3', 7), (source.id, 's1', 6)]),
        );
        expect(await history(there.id), contains('s1 -> s3 (4)'));
      },
    );

    test('with no matching Unit, a move or Split is unchanged; another name or Collection does not match', () async {
      await add(2, 's3', name: 'Hellblasters');
      final elsewhere = await vault.addUnit(
        await vault.createCollection('Other'),
        name: 'Intercessors',
        modelCount: 2,
        stageId: 's3',
      );
      final unit = await add(10, 's1');

      final split = await vault.splitUnit(unit, 's3', 4);
      expect(split.id, isNot(unit.id));
      expect((split.stageId, split.modelCount), ('s3', 4));
      await vault.moveUnit((await vault.unitsAt('s1')).single, 's2');

      expect([
        for (final (id, stage, n) in await squad())
          if (n != 2) (id, stage, n),
      ], unorderedEquals([(unit.id, 's2', 6), (split.id, 's3', 4)]));
      expect(await vault.unitsAt('s3'), hasLength(3));
      expect(
        (await vault.unitsAt('s3')).map((u) => u.id),
        contains(elsewhere.id),
      );
      expect(await history(unit.id), ['null -> s1 (10)', 's1 -> s2 (6)']);
    });

    test('a Squad move takes N models forward and back, one Stage Change each, Merging on arrival', () async {
      final unit = await add(10, 's1');

      await vault.moveModels(collection, 'Intercessors', 's1', 's2', 1);
      await vault.moveModels(collection, 'Intercessors', 's1', 's2', 2);
      final atS2 = (await vault.unitsAt('s2')).single;
      expect(
        await squad(),
        unorderedEquals([(unit.id, 's1', 7), (atS2.id, 's2', 3)]),
      );
      expect(
        await history(atS2.id),
        unorderedEquals(['s1 -> s2 (1)', 's1 -> s2 (2)']),
      );

      // Back: into the Unit at s1; then all of s2, so the Unit there moves whole and nothing is left behind.
      await vault.moveModels(collection, 'Intercessors', 's2', 's1', 1);
      expect(
        await squad(),
        unorderedEquals([(unit.id, 's1', 8), (atS2.id, 's2', 2)]),
      );
      await vault.moveModels(collection, 'Intercessors', 's2', 's1', 2);
      expect(await squad(), [(unit.id, 's1', 10)]);
      // Its own creation, the 1-model Split's move, and the whole Unit's history (two moves in, one back) copied.
      expect(
        await history(unit.id),
        unorderedEquals([
          'null -> s1 (10)',
          's2 -> s1 (1)',
          's1 -> s2 (1)',
          's1 -> s2 (2)',
          's2 -> s1 (2)',
        ]),
      );

      // Any Stages, not just neighbours.
      await vault.moveModels(collection, 'Intercessors', 's1', 's6', 10);
      expect(await squad(), [(unit.id, 's6', 10)]);
    });

    test('a Squad move rejects N under 1 or above what the source Stage holds, and the same Stage', () async {
      final unit = await add(4, 's1');
      await add(3, 's1', name: 'Hellblasters');
      for (final n in [0, -1, 5]) {
        await expectLater(
          vault.moveModels(collection, 'Intercessors', 's1', 's2', n),
          throwsArgumentError,
        );
      }
      await expectLater(
        vault.moveModels(collection, 'Intercessors', 's2', 's3', 1),
        throwsArgumentError,
      );
      await expectLater(
        vault.moveModels(collection, 'Intercessors', 's1', 's1', 1),
        throwsArgumentError,
      );
      expect(
        (await vault.unitsAt('s1')).map((u) => u.modelCount),
        unorderedEquals([3, 4]),
      );
      expect(await history(unit.id), hasLength(1));
    });

    test('a Squad move takes from the oldest Unit at the source Stage first, then the next', () async {
      // Two Units at s1, as after moves on two devices; the first-created is the oldest.
      final oldest = await add(3, 's1');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final younger = await add(4, 's1');

      await vault.moveModels(collection, 'Intercessors', 's1', 's2', 5);

      expect(
        await squad(),
        unorderedEquals([(oldest.id, 's2', 5), (younger.id, 's1', 2)]),
      );
    });

    test('an Army List import adds Units at one Stage with the Tag, Merging same-name entries and Units there', () async {
      final there = await add(3, 's2');
      final other = await add(4, 's1');

      await vault.importArmyList(collection, 's2', [
        (name: 'Intercessors', count: 5),
        (name: 'Captain', count: 1),
        (name: 'Captain', count: 1),
      ], tag: 'Ultramarines');

      final units = await vault.unitsOf(collection);
      expect(
        [for (final u in units) (u.name, u.stageId, u.modelCount)],
        unorderedEquals([
          ('Intercessors', 's2', 8),
          ('Intercessors', 's1', 4),
          ('Captain', 's2', 2),
        ]),
      );
      expect(await history(there.id), contains('null -> s2 (5)'));
      expect(await vault.tagsOf(there.id), ['Ultramarines']);
      expect(await vault.tagsOf(other.id), isEmpty);
      final captain = units.firstWhere((u) => u.name == 'Captain');
      expect(await vault.tagsOf(captain.id), ['Ultramarines']);
    });

    test('an Army List import with a bad entry adds nothing', () async {
      await expectLater(
        vault.importArmyList(collection, 's2', [
          (name: 'Captain', count: 1),
          (name: ' ', count: 1),
        ]),
        throwsArgumentError,
      );
      expect(await vault.unitsOf(collection), isEmpty);
    });
  });

  group('Recently moved Squads', () {
    test('are the last 3 Squads moved, across Collections, newest first, each starting where it last moved from', () async {
      await syncStarterWorkflow();
      final marines = await vault.createCollection('Space Marines');
      final orks = await vault.createCollection('Orks');
      expect(await vault.watchRecentlyMoved().first, isEmpty);
      Future<void> add(Collection c, String name, int n, String stageId) =>
          vault.addUnit(c, name: name, modelCount: n, stageId: stageId);
      await add(marines, 'Intercessors', 5, 's1');
      await add(marines, 'Captain', 1, 's1');
      await add(orks, 'Boyz', 10, 's3');
      await add(orks, 'Nobz', 3, 's0');
      // Never moved: not listed.
      await add(orks, 'Gretchin', 4, 's1');

      await vault.moveModels(marines, 'Intercessors', 's1', 's2', 2);
      await vault.moveModels(orks, 'Nobz', 's0', 's1', 3);
      await vault.moveModels(marines, 'Captain', 's1', 's4', 1);
      await vault.moveModels(orks, 'Boyz', 's3', 's4', 4);
      await vault.moveModels(marines, 'Intercessors', 's1', 's2', 1);

      final recent = await vault.watchRecentlyMoved().first;
      expect(
        [
          for (final r in recent)
            (r.collection.name, r.squad.name, r.from.stage.id),
        ],
        [
          ('Space Marines', 'Intercessors', 's1'),
          ('Orks', 'Boyz', 's3'),
          // Nothing left at s1: its earliest Stage with models from the Owned Stage (s1) on.
          ('Space Marines', 'Captain', 's4'),
        ],
      );
      expect(recent.first.squad.modelCount, 5);
    });
  });

  group('Paint', () {
    Future<List<String>> library() async => [
      for (final p in await vault.watchPaints().first)
        '${p.brand} / ${p.range} / ${p.name}${p.owned ? '' : ' (wanted)'}',
    ];

    test('is added trimmed, edited, toggled owned or wanted, deleted, and kept across restarts', () async {
      final blue = await vault.addPaint(
        brand: ' Citadel ',
        range: 'Base',
        name: ' Macragge Blue ',
      );
      final flat = await vault.addPaint(
        brand: 'Vallejo',
        range: 'Model Color',
        name: 'Flat Blue',
        owned: false,
      );
      await restart();
      expect(await library(), [
        'Citadel / Base / Macragge Blue',
        'Vallejo / Model Color / Flat Blue (wanted)',
      ]);

      await vault.editPaint(
        Paint(
          id: blue.id,
          brand: 'Citadel',
          range: 'Layer',
          name: 'Calgar Blue',
          owned: true,
        ),
      );
      await vault.setPaintOwned(flat.id, true);
      await vault.setPaintOwned(blue.id, false);
      expect(await library(), [
        'Citadel / Layer / Calgar Blue (wanted)',
        'Vallejo / Model Color / Flat Blue',
      ]);
      final toggle = (await db.getCrudBatch(limit: 100))!.crud.last;
      expect(toggle.opData, {'owned': 0}); // One field, so it merges per field.

      await vault.deletePaint(flat.id);
      await restart();
      expect(await library(), ['Citadel / Layer / Calgar Blue (wanted)']);
    });

    test('needs a brand, range and name', () async {
      for (final (brand, range, name) in [
        (' ', 'Base', 'Abaddon Black'),
        ('Citadel', '', 'Abaddon Black'),
        ('Citadel', 'Base', '  '),
      ]) {
        await expectLater(
          vault.addPaint(brand: brand, range: range, name: name),
          throwsArgumentError,
        );
      }
      expect(await library(), isEmpty);
    });

    test('is refused as a duplicate of another, ignoring case, when added or edited', () async {
      await vault.addPaint(
        brand: 'Citadel',
        range: 'Base',
        name: 'Mephiston Red',
      );
      final other = await vault.addPaint(
        brand: 'Citadel',
        range: 'Base',
        name: 'Khorne Red',
      );
      await expectLater(
        vault.addPaint(brand: 'CITADEL', range: ' base', name: 'mephiston red'),
        throwsStateError,
      );
      await expectLater(
        vault.editPaint(
          Paint(
            id: other.id,
            brand: 'citadel',
            range: 'Base',
            name: 'Mephiston RED',
            owned: true,
          ),
        ),
        throwsStateError,
      );
      // Saving a Paint unchanged is not a duplicate of itself.
      await vault.editPaint(other);
      expect(await library(), [
        'Citadel / Base / Khorne Red',
        'Citadel / Base / Mephiston Red',
      ]);
    });

    test('takes the spelling of a brand and range already in use', () async {
      await vault.addPaint(brand: 'Citadel', range: 'Shade', name: 'Nuln Oil');
      await vault.addPaint(
        brand: 'citadel',
        range: 'SHADE',
        name: 'Agrax Earthshade',
      );
      await vault.addPaint(
        brand: 'Vallejo',
        range: 'shade',
        name: 'Black Wash',
      );
      expect(await library(), [
        'Citadel / Shade / Agrax Earthshade',
        'Citadel / Shade / Nuln Oil',
        'Vallejo / shade / Black Wash',
      ]);
    });

    test('are grouped by brand ignoring case, A–Z, then by range and name', () {
      Paint p(String brand, String range, String name) =>
          Paint(id: name, brand: brand, range: range, name: name, owned: true);
      final groups = groupByBrand([
        p('vallejo', 'Model Color', 'Flat Blue'),
        p('Citadel', 'Layer', 'Calgar Blue'),
        p('Army Painter', 'Warpaints', 'Matt Black'),
        p('Vallejo', 'Game Color', 'Bloody Red'),
        p('citadel', 'base', 'Macragge Blue'),
        p('Citadel', 'Base', 'Abaddon Black'),
      ]);
      expect(
        [
          for (final g in groups)
            '${g.brand}: ${g.paints.map((p) => p.name).join(', ')}',
        ],
        [
          'Army Painter: Matt Black',
          'Citadel: Abaddon Black, Macragge Blue, Calgar Blue',
          'vallejo: Bloody Red, Flat Blue',
        ],
      );
      expect(groupByBrand([]), isEmpty);
    });
  });
}
