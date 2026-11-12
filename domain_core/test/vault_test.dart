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

    test('are watched: the stream emits again after a change', () async {
      await syncStarterWorkflow();
      final names = vault.watchCollections().map(
        (cs) => cs.map((c) => c.name).toList(),
      );
      final expectation = expectLater(names, emitsThrough(['Space Marines']));
      await vault.createCollection('Space Marines');
      await expectation;
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
    Progress p(int wanted, int owned, int finished) =>
        Progress(wanted: wanted, owned: owned, finished: finished);

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
        Progress expected,
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
}
