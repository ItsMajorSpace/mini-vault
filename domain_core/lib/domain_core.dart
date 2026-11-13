/// Mini Vault's domain operations. Pure Dart: shared by the app and the server.
library;

import 'dart:async';
import 'dart:math';

import 'package:uuid/uuid.dart';

/// One step in a [Workflow].
class Stage {
  const Stage({required this.id, required this.name, required this.colour});

  final String id;
  final String name;

  /// `#RRGGBB`, one of [Vault.stageColours] unless set elsewhere; see [validColour].
  final String colour;

  @override
  bool operator ==(Object other) =>
      other is Stage &&
      other.id == id &&
      other.name == name &&
      other.colour == colour;

  @override
  int get hashCode => Object.hash(id, name, colour);
}

/// An ordered, linear list of [Stage]s, reusable across Collections.
class Workflow {
  const Workflow({
    required this.id,
    required this.name,
    required this.stages,
    required this.ownedStageId,
    required this.finishedStageId,
  });

  final String id;
  final String name;

  /// In Workflow order.
  final List<Stage> stages;
  final String ownedStageId;
  final String finishedStageId;

  // Fall back to the glossary defaults if a merge from another device deleted the Stage the id points at.
  Stage get ownedStage => stages.firstWhere(
    (s) => s.id == ownedStageId,
    orElse: () => stages[min(1, stages.length - 1)],
  );
  Stage get finishedStage => stages.firstWhere(
    (s) => s.id == finishedStageId,
    orElse: () => stages.last,
  );
}

/// A named set of Units owned by one person, all progressing through the same Workflow.
class Collection {
  const Collection({
    required this.id,
    required this.name,
    required this.workflowId,
    this.gameSystem,
  });

  final String id;
  final String name;
  final String workflowId;

  /// The Game System it belongs to, as typed; null if none.
  final String? gameSystem;
}

/// Groups [collections] by Game System (ignoring case and outer spaces, as [tagKey]): A–Z, with the Collections
/// without one last under a null name. Each group is named as its first Collection spells it and keeps their order.
List<({String? gameSystem, List<Collection> collections})> groupByGameSystem(
  Iterable<Collection> collections,
) {
  final byKey = <String?, List<Collection>>{};
  for (final c in collections) {
    (byKey[c.gameSystem == null ? null : tagKey(c.gameSystem!)] ??= []).add(c);
  }
  final keys = byKey.keys.toList()
    ..sort((a, b) => a == null ? 1 : (b == null ? -1 : a.compareTo(b)));
  return [
    for (final k in keys)
      (gameSystem: byKey[k]!.first.gameSystem?.trim(), collections: byKey[k]!),
  ];
}

/// A number of models tracked together because they are at the same Stage; it belongs to exactly one Collection.
class Unit {
  const Unit({
    required this.id,
    required this.collectionId,
    required this.stageId,
    required this.name,
    required this.modelCount,
    required this.notes,
  });

  final String id;
  final String collectionId;
  final String stageId;
  final String name;
  final int modelCount;
  final String notes;
}

/// A record that a Unit moved from one Stage to another, and when. A Unit's Stage Changes form its history.
/// Append-only: never edited or deleted on its own (deleting the Unit removes them).
class StageChange {
  const StageChange({
    required this.id,
    required this.unitId,
    required this.fromStageId,
    required this.toStageId,
    required this.modelCount,
    required this.happenedAt,
  });

  final String id;
  final String unitId;

  /// Null for the Stage Change that records where the Unit was created.
  final String? fromStageId;
  final String toStageId;

  /// The number of models moved.
  final int modelCount;

  /// The device's clock when it happened. Used only to order Stage Changes: the latest sets the Unit's Stage.
  final DateTime happenedAt;
}

/// A photo of a Unit. Its image file is stored once, under [fileId]: a Split's copy of a photo is a second row
/// pointing at the same file, and the file is only deleted once no row points at it.
class Photo {
  const Photo({required this.id, required this.unitId, required this.fileId});

  final String id;
  final String unitId;

  /// The image file's id, which is also its PowerSync attachment id.
  final String fileId;
}

/// One Stage of a Collection's Workflow, with the Collection's Units at it.
class StageGroup {
  const StageGroup(this.stage, this.units);

  final Stage stage;
  final List<Unit> units;

  int get modelCount => units.fold(0, (sum, u) => sum + u.modelCount);
}

/// Groups [units] by Stage: one group per Stage of [workflow], in Workflow order, including Stages without Units.
// shortcut: Units at a Stage outside the Workflow are left out (the write API rejects them); revisit if Stages can be deleted (#11).
List<StageGroup> groupByStage(Workflow workflow, Iterable<Unit> units) => [
  for (final stage in workflow.stages)
    StageGroup(stage, [
      for (final u in units)
        if (u.stageId == stage.id) u,
    ]),
];

/// All Units in a Collection sharing a name, laid out over every Stage of the Workflow.
class Squad {
  const Squad(this.name, this.stages, this.progress);

  final String name;

  /// One group per Stage of the Workflow, in Workflow order, including Stages without Units.
  final List<StageGroup> stages;
  final Progress progress;

  Iterable<Unit> get units => stages.expand((g) => g.units);
  int get modelCount => stages.fold(0, (sum, g) => sum + g.modelCount);
}

/// Groups [units] into Squads by exact name (as [Vault.mergeCandidates] matches), in the order names first appear.
List<Squad> squadsOf(Workflow workflow, Iterable<Unit> units) {
  final byName = <String, List<Unit>>{};
  for (final u in units) {
    (byName[u.name] ??= []).add(u);
  }
  return [
    for (final MapEntry(key: name, value: us) in byName.entries)
      Squad(name, groupByStage(workflow, us), progressOf(workflow, us)),
  ];
}

/// How many of a Collection's models are wanted, owned and finished, by its Workflow's Owned and Finished Stage.
class Progress {
  const Progress({
    required this.wanted,
    required this.owned,
    required this.finished,
    required this.stages,
  });

  /// Models before the Owned Stage.
  final int wanted;

  /// Models at the Owned Stage or later.
  final int owned;

  /// Models at the Finished Stage or later; always part of [owned].
  final int finished;

  /// The owned models per Stage: each Stage from the Owned Stage on that has models, in Workflow order.
  final List<({Stage stage, int models})> stages;

  /// [all] together: their counts summed, their [stages] one after another.
  Progress.combined(Iterable<Progress> all)
    : wanted = all.fold(0, (n, p) => n + p.wanted),
      owned = all.fold(0, (n, p) => n + p.owned),
      finished = all.fold(0, (n, p) => n + p.finished),
      stages = [for (final p in all) ...p.stages];

  /// [finished] as a share of [owned], 0 when nothing is owned.
  double get finishedShare => owned == 0 ? 0 : finished / owned;

  @override
  bool operator ==(Object other) =>
      other is Progress &&
      other.wanted == wanted &&
      other.owned == owned &&
      other.finished == finished &&
      other.stages.length == stages.length &&
      stages.indexed.every((e) => other.stages[e.$1] == e.$2);

  @override
  int get hashCode =>
      Object.hash(wanted, owned, finished, Object.hashAll(stages));

  @override
  String toString() => '$finished / $owned finished, $wanted wanted';
}

/// The [Progress] of the Collections using one Workflow, together.
class WorkflowProgress {
  const WorkflowProgress(this.workflow, this.stages, this.progress);

  final Workflow workflow;

  /// One group per Stage of the Workflow, in Workflow order, including Stages without Units and before the Owned Stage.
  final List<StageGroup> stages;
  final Progress progress;
}

/// Counts [units]' models against [workflow]'s Owned and Finished Stage, in Workflow order.
// Units at a Stage outside the Workflow are left out, as in [groupByStage].
Progress progressOf(Workflow workflow, Iterable<Unit> units) {
  final index = {for (final (i, s) in workflow.stages.indexed) s.id: i};
  final owned = index[workflow.ownedStage.id]!;
  final finished = index[workflow.finishedStage.id]!;
  var (w, o, f) = (0, 0, 0);
  final perStage = List.filled(workflow.stages.length, 0);
  for (final u in units) {
    final i = index[u.stageId];
    if (i == null) continue;
    if (i < owned) w += u.modelCount;
    if (i >= owned) o += u.modelCount;
    if (i >= finished) f += u.modelCount;
    perStage[i] += u.modelCount;
  }
  return Progress(
    wanted: w,
    owned: o,
    finished: f,
    stages: [
      for (final (i, s) in workflow.stages.indexed)
        if (i >= owned && perStage[i] > 0) (stage: s, models: perStage[i]),
    ],
  );
}

/// The narrow storage interface the domain core talks to.
/// The app implements it over local SQLite (`package:domain_core/sqlite_store.dart`).
abstract interface class VaultStore {
  /// The starter Workflow first, then the rest by name. Each Workflow's Stages are in Workflow order.
  Future<List<Workflow>> workflows();

  /// Emits the Workflows now and again whenever they or their Stages change.
  Stream<List<Workflow>> watchWorkflows();

  /// Inserts the Workflow and its Stages, positioned in list order.
  Future<void> insertWorkflow(Workflow workflow);
  Future<void> renameWorkflow(String id, String name);

  /// Deletes the Workflow and its Stages.
  Future<void> deleteWorkflow(String id);
  Future<void> setOwnedStage(String workflowId, String stageId);
  Future<void> setFinishedStage(String workflowId, String stageId);

  /// Inserts [stage] into the Workflow and stores [order] (all its Stage ids, the new one included) as the Stage order.
  Future<void> insertStage(String workflowId, Stage stage, List<String> order);
  Future<void> renameStage(String id, String name);
  Future<void> setStageColour(String id, String colour);

  /// Stores [order] (all of a Workflow's Stage ids) as its Stage order.
  Future<void> reorderStages(List<String> order);

  /// In one transaction, so it uploads as one batch in an order the write API accepts: appends [moves] and sets
  /// each Unit's Stage, then sets the Workflow's Owned and Finished Stage if given, then deletes the Stage.
  Future<void> deleteStage(
    String workflowId,
    String id, {
    List<StageChange> moves = const [],
    String? ownedStageId,
    String? finishedStageId,
  });

  /// The Units at the Stage, in every Collection.
  Future<List<Unit>> unitsAt(String stageId);

  /// In one transaction, so it uploads as one batch: appends [moves] and sets each Unit's Stage, then points the
  /// Collection at the Workflow. The write API checks Units against their Collection's Workflow after the whole batch.
  Future<void> switchWorkflow(
    String collectionId,
    String workflowId,
    List<StageChange> moves,
  );

  Future<List<Collection>> collections();

  /// Emits the Collections now and again whenever they change, locally or through sync.
  Stream<List<Collection>> watchCollections();
  Future<void> insertCollection(Collection collection);
  Future<void> renameCollection(String id, String name);
  Future<void> setGameSystem(String id, String? gameSystem);

  /// Deletes the Collection and its Units, with their Tags and Photos, in one transaction.
  Future<void> deleteCollection(String id);

  /// Emits every Collection's Units now and again whenever they change.
  Stream<List<Unit>> watchAllUnits();

  /// Emits the Collection's Units, by name, now and again whenever they change.
  Stream<List<Unit>> watchUnits(String collectionId);

  /// Inserts the Unit and the Stage Change that records its starting Stage, in one transaction.
  Future<void> insertUnit(Unit unit, StageChange initial);

  /// Appends [change] and sets its Unit's Stage to its to-Stage, in one transaction.
  Future<void> insertStageChange(StageChange change);

  /// Emits the Unit's Stage Changes, oldest first, now and again whenever they change.
  Stream<List<StageChange>> watchStageChanges(String unitId);

  /// Updates only the given fields, so concurrent edits of other fields on other devices are kept.
  Future<void> updateUnit(
    String id, {
    String? name,
    int? modelCount,
    String? notes,
  });

  /// Deletes the Unit, its Tags and its Photos.
  Future<void> deleteUnit(String id);

  /// Emits the Unit's Tags, by name, now and again whenever they change.
  Stream<List<String>> watchTags(String unitId);

  /// Every Tag name on any of the user's Units.
  Future<List<String>> allTagNames();

  /// Adds Tags to a Unit, keyed by their [tagId]; a Tag whose id is already there is left as it is.
  Future<void> insertTags(String unitId, Map<String, String> namesById);
  Future<void> deleteTag(String id);

  /// Emits the Unit's Photos, in the same order on every device, now and again whenever they change.
  Stream<List<Photo>> watchPhotos(String unitId);
  Future<void> insertPhotos(List<Photo> photos);
  Future<void> deletePhoto(String id);

  /// In one transaction, so it uploads as one batch the write API applies whole or not at all: inserts [created]
  /// with [move] (its first Stage Change), its Tags ([tagsById]) and [photos], then records Split [id] of
  /// [created]'s models off Unit [sourceId] and takes them off that Unit's count.
  Future<void> insertSplit(
    String id,
    String sourceId,
    Unit created,
    StageChange move,
    Map<String, String> tagsById,
    List<Photo> photos,
  );

  /// In one transaction: records Merge [id] of Unit [otherId] into Unit [unitId], then copies [history], Tags
  /// ([tagsById]) and [photos] onto [unitId], adds the other Unit's models to its count and deletes the other Unit.
  Future<void> insertMerge(
    String id,
    String unitId,
    String otherId,
    List<StageChange> history,
    Map<String, String> tagsById,
    List<Photo> photos,
  );
}

/// The domain operations a collector can perform.
class Vault {
  Vault(this._store);

  final VaultStore _store;

  static const starterStageNames = [
    'Wishlist',
    'Unassembled',
    'Assembled',
    'Primed',
    'Painted',
    'Based',
    'Done',
  ];

  /// The server creates the starter Workflow when the account is created; it is null until the first sync delivers it.
  /// If it was deleted, the first other Workflow stands in for it.
  Future<Workflow?> starterWorkflow() async =>
      (await _store.workflows()).firstOrNull;

  Future<List<Workflow>> workflows() => _store.workflows();

  Stream<List<Workflow>> watchWorkflows() => _store.watchWorkflows();

  /// The swatches a Stage's colour is picked from: 12 hues, then 4 neutrals. Each reaches AA contrast (>= 4.5:1)
  /// on the app's gunmetal background. A new Workflow's Stages, and the server's backfill, take them by position.
  static const stageColours = [
    '#FF7B7B', '#FF9E5E', '#FFC24D', '#F2E05C', '#B5E061', '#6FD98A', //
    '#4FD1C0', '#5CC8EB', '#7FB2FF', '#A3A3FF', '#C79BFF', '#F28AD2', //
    '#F2F2F2', '#C4C9CE', '#9AA1A8', '#C2B59B', //
  ];

  /// Creates a Workflow with the starter Stages, the second Stage Owned and the last Finished.
  Future<Workflow> createWorkflow(String name) async {
    final stages = [
      for (final (i, name) in starterStageNames.indexed)
        Stage(
          id: _newId(),
          name: name,
          colour: stageColours[i % stageColours.length],
        ),
    ];
    final workflow = Workflow(
      id: _newId(),
      name: validName(name),
      stages: stages,
      ownedStageId: stages[1].id,
      finishedStageId: stages.last.id,
    );
    await _store.insertWorkflow(workflow);
    return workflow;
  }

  Future<void> renameWorkflow(String id, String name) =>
      _store.renameWorkflow(id, validName(name));

  /// Throws a [StateError] while any Collection uses the Workflow.
  Future<void> deleteWorkflow(String id) async {
    if ((await _store.collections()).any((c) => c.workflowId == id)) {
      throw StateError('A Collection uses this Workflow');
    }
    await _store.deleteWorkflow(id);
  }

  /// Throws an [ArgumentError] if the Stage is not in the Workflow or comes after its Finished Stage.
  Future<void> setOwnedStage(String workflowId, String stageId) async {
    final w = await _workflow(workflowId);
    _checkOrder(w.stages, owned: stageId, finished: w.finishedStage.id);
    await _store.setOwnedStage(workflowId, stageId);
  }

  /// Throws an [ArgumentError] if the Stage is not in the Workflow or comes before its Owned Stage.
  Future<void> setFinishedStage(String workflowId, String stageId) async {
    final w = await _workflow(workflowId);
    _checkOrder(w.stages, owned: w.ownedStage.id, finished: stageId);
    await _store.setFinishedStage(workflowId, stageId);
  }

  /// Adds a Stage at [index] (0 is first; clamped to the end), coloured with the first of [stageColours] the
  /// Workflow isn't using yet (the first one once all are used).
  Future<Stage> addStage(String workflowId, String name, int index) async {
    final w = await _workflow(workflowId);
    final used = {for (final s in w.stages) s.colour};
    final stage = Stage(
      id: _newId(),
      name: validName(name),
      colour: stageColours.firstWhere(
        (c) => !used.contains(c),
        orElse: () => stageColours.first,
      ),
    );
    final order = [for (final s in w.stages) s.id]
      ..insert(index.clamp(0, w.stages.length), stage.id);
    await _store.insertStage(workflowId, stage, order);
    return stage;
  }

  Future<void> renameStage(String id, String name) =>
      _store.renameStage(id, validName(name));

  /// Sets the Stage's colour, `#RRGGBB`. Other Stages may share it.
  Future<void> setStageColour(String id, String colour) =>
      _store.setStageColour(id, validColour(colour));

  /// Moves a Stage to [index] in the Workflow's order.
  /// Throws an [ArgumentError] if that would put the Owned Stage after the Finished Stage.
  Future<void> moveStage(String workflowId, String stageId, int index) async {
    final w = await _workflow(workflowId);
    final stage = w.stages.firstWhere(
      (s) => s.id == stageId,
      orElse: () =>
          throw ArgumentError.value(stageId, 'stageId', 'not in this Workflow'),
    );
    final order = [...w.stages]..remove(stage);
    order.insert(index.clamp(0, order.length), stage);
    _checkOrder(order, owned: w.ownedStage.id, finished: w.finishedStage.id);
    await _store.reorderStages([for (final s in order) s.id]);
  }

  /// The Units at the Stage, in every Collection using its Workflow.
  Future<List<Unit>> unitsAt(String stageId) => _store.unitsAt(stageId);

  /// Deletes a Stage in one transaction. If it holds Units, in any Collection, they all move to [moveUnitsTo] first,
  /// each recording a Stage Change. If it is the Owned or Finished Stage, [ownedStageId] or [finishedStageId] replaces it.
  /// Throws a [StateError] if it is the Workflow's only Stage, or holds Units or is the Owned or Finished Stage without
  /// the replacement; an [ArgumentError] if a replacement is not another Stage of the Workflow, or Owned would come
  /// after Finished.
  Future<void> deleteStage(
    String workflowId,
    String stageId, {
    String? moveUnitsTo,
    String? ownedStageId,
    String? finishedStageId,
  }) async {
    final w = await _workflow(workflowId);
    if (!w.stages.any((s) => s.id == stageId)) {
      throw ArgumentError.value(stageId, 'stageId', 'not in this Workflow');
    }
    if (w.stages.length == 1) {
      throw StateError('A Workflow needs at least one Stage');
    }
    final owned = ownedStageId ?? w.ownedStage.id;
    final finished = finishedStageId ?? w.finishedStage.id;
    if (owned == stageId || finished == stageId) {
      throw StateError('Pick another Owned or Finished Stage first');
    }
    final rest = [...w.stages]..removeWhere((s) => s.id == stageId);
    _checkOrder(rest, owned: owned, finished: finished);
    final units = await _store.unitsAt(stageId);
    if (units.isNotEmpty && moveUnitsTo == null) {
      throw StateError('This Stage holds Units');
    }
    if (units.isNotEmpty && !rest.any((s) => s.id == moveUnitsTo)) {
      throw ArgumentError.value(
        moveUnitsTo,
        'moveUnitsTo',
        'must be another Stage of this Workflow',
      );
    }
    await _store.deleteStage(
      workflowId,
      stageId,
      moves: [for (final u in units) _stageChange(u, stageId, moveUnitsTo!)],
      ownedStageId: ownedStageId,
      finishedStageId: finishedStageId,
    );
  }

  Future<Workflow> _workflow(String id) async =>
      (await _store.workflows()).firstWhere(
        (w) => w.id == id,
        orElse: () =>
            throw ArgumentError.value(id, 'workflowId', 'no such Workflow'),
      );

  static void _checkOrder(
    List<Stage> stages, {
    required String owned,
    required String finished,
  }) {
    final ids = [for (final s in stages) s.id];
    final (o, f) = (ids.indexOf(owned), ids.indexOf(finished));
    if (o < 0 || f < 0) {
      throw ArgumentError(
        'The Owned and Finished Stage must be in this Workflow',
      );
    }
    if (o > f) {
      throw ArgumentError(
        'The Owned Stage may not come after the Finished Stage',
      );
    }
  }

  Future<List<Collection>> collections() => _store.collections();

  Stream<List<Collection>> watchCollections() => _store.watchCollections();

  /// Creates a Collection that uses the given Workflow, or the starter Workflow.
  /// Throws a [StateError] while there is no Workflow yet (the starter Workflow has not synced).
  Future<Collection> createCollection(
    String name, {
    String? workflowId,
    String? gameSystem,
  }) async {
    final workflow = workflowId == null
        ? await starterWorkflow()
        : await _workflow(workflowId);
    if (workflow == null) {
      throw StateError('The starter Workflow has not synced yet');
    }
    final collection = Collection(
      id: _newId(),
      name: validName(name),
      workflowId: workflow.id,
      gameSystem: await _knownGameSystem(gameSystem),
    );
    await _store.insertCollection(collection);
    return collection;
  }

  Future<void> renameCollection(String id, String name) =>
      _store.renameCollection(id, validName(name));

  /// Sets the Collection's Game System; blank or null removes it.
  Future<void> setGameSystem(String id, String? gameSystem) async =>
      _store.setGameSystem(id, await _knownGameSystem(gameSystem));

  /// The Game Systems in use, A–Z, each spelled as its first Collection spells it.
  Future<List<String>> gameSystems() async => [
    for (final g in groupByGameSystem(await _store.collections()))
      ?g.gameSystem,
  ];

  /// [name] as [validGameSystem], spelled like a Game System already in use if one matches.
  Future<String?> _knownGameSystem(String? name) async {
    final valid = validGameSystem(name);
    if (valid == null) return null;
    return (await gameSystems())
            .where((g) => tagKey(g) == tagKey(valid))
            .firstOrNull ??
        valid;
  }

  /// The Collection's Units, by name: what deleting it would delete.
  Future<List<Unit>> unitsOf(Collection collection) =>
      _store.watchUnits(collection.id).first;

  /// Deletes the Collection, its Units and their history, Tags and Photos. The server deletes the history with the
  /// Units, and any Unit another device added meanwhile, and each photo file once no Photo points at it.
  Future<void> deleteCollection(String id) => _store.deleteCollection(id);

  /// What switching [collection] to [target] has to map: each Stage of its Workflow that holds its Units, in Workflow
  /// order, with the Stage of [target] that has the same name (ignoring case and outer spaces), or null.
  Future<List<({Stage from, Stage? to})>> stageMapping(
    Collection collection,
    Workflow target,
  ) async {
    String key(Stage s) => s.name.trim().toLowerCase();
    final units = await _store.watchUnits(collection.id).first;
    return [
      for (final g in groupByStage(await workflowOf(collection), units))
        if (g.units.isNotEmpty)
          (
            from: g.stage,
            to: target.stages.where((s) => key(s) == key(g.stage)).firstOrNull,
          ),
    ];
  }

  /// Switches [collection] to Workflow [workflowId] in one transaction: each of its Units moves to the Stage that
  /// [moveTo] maps its current Stage to (see [stageMapping]), recording a Stage Change. Does nothing if the Collection
  /// already uses the Workflow. Throws an [ArgumentError] if there is no such Workflow, or a Unit's Stage is not
  /// mapped to a Stage of it.
  Future<void> switchWorkflow(
    Collection collection,
    String workflowId,
    Map<String, String> moveTo,
  ) async {
    final target = await _workflow(workflowId);
    if (target.id == collection.workflowId) return;
    final moves = [
      for (final u in await _store.watchUnits(collection.id).first)
        if (moveTo[u.stageId] case final to?
            when target.stages.any((s) => s.id == to))
          _stageChange(u, u.stageId, to)
        else
          throw ArgumentError.value(
            moveTo[u.stageId],
            'moveTo[${u.stageId}]',
            'must be a Stage of the new Workflow',
          ),
    ];
    await _store.switchWorkflow(collection.id, target.id, moves);
  }

  /// The Workflow [collection] uses. Throws a [StateError] if it has not synced.
  Future<Workflow> workflowOf(Collection collection) async =>
      (await _store.workflows()).firstWhere(
        (w) => w.id == collection.workflowId,
        orElse: () => throw StateError('The Workflow has not synced yet'),
      );

  /// The Collection's Units grouped by Stage in Workflow order, emitted again whenever they change.
  Stream<List<StageGroup>> watchStageGroups(Collection collection) => _store
      .watchUnits(collection.id)
      .asyncMap(
        (units) async => groupByStage(await workflowOf(collection), units),
      );

  /// The Collection's Squads, by name, emitted again whenever its Units change.
  Stream<List<Squad>> watchSquads(Collection collection) => _store
      .watchUnits(collection.id)
      .asyncMap((units) async => squadsOf(await workflowOf(collection), units));

  /// The Collection's [Progress], emitted again whenever its Units or its Workflow (Stages, Owned or Finished Stage) change.
  Stream<Progress> watchProgress(Collection collection) => _combineLatest(
    [_store.watchWorkflows(), _store.watchUnits(collection.id)],
    (latest) {
      final [workflows as List<Workflow>, units as List<Unit>] = latest;
      final workflow = workflows
          .where((w) => w.id == collection.workflowId)
          .firstOrNull;
      if (workflow == null) throw StateError('The Workflow has not synced yet');
      return progressOf(workflow, units);
    },
  ).distinct();

  /// The [Progress] of every Collection, or only of [collection], per Workflow: one [WorkflowProgress] per Workflow
  /// that at least one of them uses, in [workflows] order. Emitted again whenever the Collections, their Units or the
  /// Workflows change. Collections whose Workflow has not synced are left out.
  Stream<List<WorkflowProgress>> watchProgressByWorkflow([
    Collection? collection,
  ]) => _combineLatest(
    [
      _store.watchWorkflows(),
      _store.watchCollections(),
      collection == null
          ? _store.watchAllUnits()
          : _store.watchUnits(collection.id),
    ],
    (latest) {
      final [
        workflows as List<Workflow>,
        collections as List<Collection>,
        units as List<Unit>,
      ] = latest;
      final workflowOf = {
        for (final c in collections)
          if (collection == null || c.id == collection.id) c.id: c.workflowId,
      };
      WorkflowProgress of(Workflow w) {
        final us = [
          for (final u in units)
            if (workflowOf[u.collectionId] == w.id) u,
        ];
        return WorkflowProgress(w, groupByStage(w, us), progressOf(w, us));
      }

      return [
        for (final w in workflows)
          if (workflowOf.containsValue(w.id)) of(w),
      ];
    },
  );

  /// Emits [combine] of each stream's latest value once all have emitted, and again whenever one emits. What
  /// [combine] throws is emitted as an error.
  static Stream<T> _combineLatest<T>(
    List<Stream<Object>> streams,
    T Function(List<Object>) combine,
  ) {
    final latest = List<Object?>.filled(streams.length, null);
    final subscriptions = <StreamSubscription<void>>[];
    late final StreamController<T> controller;
    controller = StreamController(
      onListen: () => subscriptions.addAll([
        for (final (i, stream) in streams.indexed)
          stream.listen((value) {
            latest[i] = value;
            if (latest.contains(null)) return;
            try {
              controller.add(combine(latest.cast()));
            } catch (e, s) {
              controller.addError(e, s);
            }
          }, onError: controller.addError),
      ]),
      onCancel: () => Future.wait([for (final s in subscriptions) s.cancel()]),
    );
    return controller.stream;
  }

  /// Adds a Unit at [stageId], which must be a Stage of the Collection's Workflow.
  Future<Unit> addUnit(
    Collection collection, {
    required String name,
    required int modelCount,
    String notes = '',
    required String stageId,
  }) async {
    final workflow = await workflowOf(collection);
    if (!workflow.stages.any((s) => s.id == stageId)) {
      throw ArgumentError.value(
        stageId,
        'stageId',
        "is not a Stage of the Collection's Workflow",
      );
    }
    final unit = Unit(
      id: _newId(),
      collectionId: collection.id,
      stageId: stageId,
      name: validName(name),
      modelCount: validModelCount(modelCount),
      notes: notes.trim(),
    );
    await _store.insertUnit(unit, _stageChange(unit, null, stageId));
    return unit;
  }

  /// Moves the whole Unit to [stageId], any Stage of its Collection's Workflow, forward or back, and Merges it into
  /// the Unit already there with its name, if any (ADR 0004): that Unit survives, with this move in its history.
  /// Does nothing if it is already there.
  Future<void> moveUnit(Unit unit, String stageId) async {
    final collection = (await _store.collections()).firstWhere(
      (c) => c.id == unit.collectionId,
      orElse: () => throw StateError('The Collection has not synced yet'),
    );
    if (!(await workflowOf(collection)).stages.any((s) => s.id == stageId)) {
      throw ArgumentError.value(
        stageId,
        'stageId',
        "is not a Stage of the Collection's Workflow",
      );
    }
    if (stageId == unit.stageId) return;
    await _store.insertStageChange(_stageChange(unit, unit.stageId, stageId));
    await _mergeOnArrival(collection, _at(unit, stageId));
  }

  /// Merges [arrived], just moved to its Stage, into a Unit already there with its name; returns the Unit now
  /// holding its models. Two uploads (move, then Merge): if the write API rejects the Merge, the move still stands.
  Future<Unit> _mergeOnArrival(Collection collection, Unit arrived) async {
    final there = mergeCandidates(arrived, await unitsOf(collection));
    if (there.isEmpty) return arrived;
    await mergeUnits(there.first, arrived);
    return _at(
      there.first,
      there.first.stageId,
      there.first.modelCount + arrived.modelCount,
    );
  }

  static Unit _at(Unit u, String stageId, [int? modelCount]) => Unit(
    id: u.id,
    collectionId: u.collectionId,
    stageId: stageId,
    name: u.name,
    modelCount: modelCount ?? u.modelCount,
    notes: u.notes,
  );

  /// Moves [modelCount] models of the Squad [name] in [collection] from [fromStageId] to [toStageId], forward or
  /// back, Merging them into the Squad's Unit there (see [moveUnit], [splitUnit]). When several of its Units are at
  /// [fromStageId] (after concurrent moves on two devices), it takes from the oldest first: the one whose earliest
  /// Stage Change is earliest, ties broken by id. Throws an [ArgumentError] unless [modelCount] is at least 1 and at
  /// most what the Squad has at [fromStageId], or if the two Stages are the same.
  Future<void> moveModels(
    Collection collection,
    String name,
    String fromStageId,
    String toStageId,
    int modelCount,
  ) async {
    if (fromStageId == toStageId) {
      throw ArgumentError.value(
        toStageId,
        'toStageId',
        'is the Stage the models are at',
      );
    }
    final at = [
      for (final u in await unitsOf(collection))
        if (u.name == name && u.stageId == fromStageId)
          (u, (await _store.watchStageChanges(u.id).first).first.happenedAt),
    ];
    at.sort((a, b) {
      final byAge = a.$2.compareTo(b.$2);
      return byAge != 0 ? byAge : a.$1.id.compareTo(b.$1.id);
    });
    final total = at.fold(0, (n, e) => n + e.$1.modelCount);
    if (modelCount < 1 || modelCount > total) {
      throw ArgumentError.value(
        modelCount,
        'modelCount',
        'must be at least 1 and at most the $total models at that Stage',
      );
    }
    var left = modelCount;
    for (final (unit, _) in at) {
      if (left == 0) break;
      if (left >= unit.modelCount) {
        await moveUnit(unit, toStageId);
        left -= unit.modelCount;
      } else {
        await splitUnit(unit, toStageId, left);
        left = 0;
      }
    }
  }

  /// Splits [unit]: moves [modelCount] of its models, at least 1 and fewer than all (all is [moveUnit]), to another
  /// Stage of its Collection's Workflow. The new Unit holding them copies the name, notes, Tags and Photos, and its
  /// history starts with this move. The Split uploads as a delta (N models off [unit]), never as [unit]'s new count,
  /// so Splits made on other devices add up; the write API rejects one that would leave [unit] under 1 model.
  /// If a Unit with its name is already at [stageId], the new Unit is then Merged into it (ADR 0004), and that Unit,
  /// with its new count, is returned instead.
  Future<Unit> splitUnit(Unit unit, String stageId, int modelCount) async {
    if (modelCount < 1 || modelCount >= unit.modelCount) {
      throw ArgumentError.value(
        modelCount,
        'modelCount',
        'must be at least 1 and fewer than the Unit has',
      );
    }
    final collection = (await _store.collections()).firstWhere(
      (c) => c.id == unit.collectionId,
      orElse: () => throw StateError('The Collection has not synced yet'),
    );
    if (stageId == unit.stageId ||
        !(await workflowOf(collection)).stages.any((s) => s.id == stageId)) {
      throw ArgumentError.value(
        stageId,
        'stageId',
        "is not another Stage of the Collection's Workflow",
      );
    }
    final created = Unit(
      id: _newId(),
      collectionId: unit.collectionId,
      stageId: stageId,
      name: unit.name,
      modelCount: modelCount,
      notes: unit.notes,
    );
    await _store.insertSplit(
      _newId(),
      unit.id,
      created,
      _stageChange(created, unit.stageId, stageId),
      {for (final t in await tagsOf(unit.id)) tagId(created.id, t): t},
      [
        for (final p in await photosOf(unit.id))
          Photo(id: _newId(), unitId: created.id, fileId: p.fileId),
      ],
    );
    return _mergeOnArrival(collection, created);
  }

  /// The Units [unit] may be Merged with: the others in [units] in its Collection, with its name, at its Stage.
  static List<Unit> mergeCandidates(Unit unit, Iterable<Unit> units) => [
    for (final u in units)
      if (u.id != unit.id &&
          u.collectionId == unit.collectionId &&
          u.name == unit.name &&
          u.stageId == unit.stageId)
        u,
  ];

  /// Merges [other] into [unit]. [unit] gets both counts, the union of their Tags,
  /// [other]'s Photos up to [maxPhotos], and a copy of [other]'s Stage Changes in its history (Stage Changes are
  /// append-only, so they are copied, not moved); [other] is deleted. The write API adds [other]'s count as it is
  /// on the server, and rejects the Merge if either Unit is gone or they no longer share Collection, name and Stage.
  /// Throws an [ArgumentError] unless [other] is one of [mergeCandidates].
  Future<void> mergeUnits(Unit unit, Unit other) async {
    if (mergeCandidates(unit, [other]).isEmpty) {
      throw ArgumentError.value(
        other.id,
        'other',
        'must be another Unit in the same Collection, with the same name, at the same Stage',
      );
    }
    final tags = {for (final t in await tagsOf(unit.id)) tagKey(t)};
    final files = {for (final p in await photosOf(unit.id)) p.fileId};
    await _store.insertMerge(
      _newId(),
      unit.id,
      other.id,
      [
        for (final c in await _store.watchStageChanges(other.id).first)
          StageChange(
            id: _newId(),
            unitId: unit.id,
            fromStageId: c.fromStageId,
            toStageId: c.toStageId,
            modelCount: c.modelCount,
            happenedAt: c.happenedAt,
          ),
      ],
      {
        for (final t in await tagsOf(other.id))
          if (!tags.contains(tagKey(t))) tagId(unit.id, t): t,
      },
      [
        for (final f in {
          for (final p in await photosOf(other.id)) p.fileId,
        }.difference(files).take(max(0, maxPhotos - files.length)))
          Photo(id: _newId(), unitId: unit.id, fileId: f),
      ],
    );
  }

  /// The Unit's history, oldest first, emitted again whenever it changes.
  Stream<List<StageChange>> watchHistory(String unitId) =>
      _store.watchStageChanges(unitId);

  static StageChange _stageChange(Unit unit, String? from, String to) =>
      StageChange(
        id: _newId(),
        unitId: unit.id,
        fromStageId: from,
        toStageId: to,
        modelCount: unit.modelCount,
        happenedAt: DateTime.now().toUtc(),
      );

  /// Changes only the given fields of a Unit. A new [modelCount] is a recount: it sets the absolute count, and the
  /// latest write wins, unlike a Split or Merge (deltas). A Split uploaded after it still takes its models off.
  Future<void> editUnit(
    String id, {
    String? name,
    int? modelCount,
    String? notes,
  }) => _store.updateUnit(
    id,
    name: name == null ? null : validName(name),
    modelCount: modelCount == null ? null : validModelCount(modelCount),
    notes: notes?.trim(),
  );

  /// Renames every Unit in [squad], one field edit each, so other fields edited elsewhere are kept.
  Future<void> renameSquad(Squad squad, String name) async {
    final valid = validName(
      name,
    ); // Before any write, so a bad name renames none.
    for (final u in squad.units) {
      await editUnit(u.id, name: valid);
    }
  }

  Future<void> deleteUnit(String id) => _store.deleteUnit(id);

  /// The Unit's Tags, by name, emitted again whenever they change.
  Stream<List<String>> watchTags(String unitId) => _store.watchTags(unitId);

  /// The Unit's Tags, by name. With [addTags], what a Split needs to copy them to the new Unit.
  Future<List<String>> tagsOf(String unitId) => _store.watchTags(unitId).first;

  /// Adds Tags to a Unit, skipping blank names and ones it already has (ignoring case and outer spaces).
  /// A Tag the user has used before keeps the casing it was first entered with.
  Future<void> addTags(String unitId, Iterable<String> names) async {
    final known = _byKey(await _store.allTagNames());
    final namesById = <String, String>{};
    for (final name in names.map((n) => n.trim()).where((n) => n.isNotEmpty)) {
      final display = known[tagKey(name)] ?? name;
      namesById.putIfAbsent(tagId(unitId, display), () => display);
    }
    if (namesById.isNotEmpty) await _store.insertTags(unitId, namesById);
  }

  Future<void> removeTag(String unitId, String name) =>
      _store.deleteTag(tagId(unitId, name));

  /// The user's Tags that start with [prefix] (ignoring case and outer spaces), by name.
  Future<List<String>> suggestTags(String prefix) async {
    final key = tagKey(prefix);
    return [
      for (final MapEntry(key: k, value: name) in _byKey(
        await _store.allTagNames(),
      ).entries)
        if (k.startsWith(key)) name,
    ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// The most Photos a Unit may have. The write API enforces the same limit.
  static const maxPhotos = 10;

  /// The Unit's Photos, in the same order on every device, emitted again whenever they change.
  Stream<List<Photo>> watchPhotos(String unitId) => _store.watchPhotos(unitId);

  /// The Unit's Photos. With [addPhotos], what a Split needs to copy them to the new Unit.
  Future<List<Photo>> photosOf(String unitId) =>
      _store.watchPhotos(unitId).first;

  /// A Photo for a new image file on the Unit, not yet stored: the app stores it in the same transaction that
  /// queues its file for upload. Throws a [StateError] if the Unit already has [maxPhotos].
  Future<Photo> newPhoto(String unitId) async {
    await _checkRoom(unitId, 1);
    return Photo(id: _newId(), unitId: unitId, fileId: _newId());
  }

  /// Attaches already stored image files to the Unit, e.g. a Split's copies of its source's Photos.
  /// A file the Unit already has is skipped. Throws a [StateError] if the Unit would get more than [maxPhotos].
  Future<List<Photo>> addPhotos(String unitId, Iterable<String> fileIds) async {
    final has = {for (final p in await photosOf(unitId)) p.fileId};
    final photos = [
      for (final fileId in {...fileIds}.difference(has))
        Photo(id: _newId(), unitId: unitId, fileId: fileId),
    ];
    await _checkRoom(unitId, photos.length);
    if (photos.isNotEmpty) await _store.insertPhotos(photos);
    return photos;
  }

  /// Removes the Photo. The server deletes its file once no Photo points at it.
  Future<void> removePhoto(String id) => _store.deletePhoto(id);

  Future<void> _checkRoom(String unitId, int adding) async {
    if ((await photosOf(unitId)).length + adding > maxPhotos) {
      throw StateError('A Unit can have at most $maxPhotos photos');
    }
  }

  static Map<String, String> _byKey(Iterable<String> names) {
    final byKey = <String, String>{};
    for (final n in names) {
      byKey.putIfAbsent(tagKey(n), () => n);
    }
    return byKey;
  }
}

/// What makes two Tag names the same Tag: case and outer spaces are ignored.
String tagKey(String name) => name.trim().toLowerCase();

/// The id of [name] as a Tag on Unit [unitId]: the same on every device, so two devices adding the same Tag
/// to the same Unit offline write the same row instead of a duplicate. The write API checks it.
String tagId(String unitId, String name) =>
    const Uuid().v5(unitId, tagKey(name));

/// Throws an [ArgumentError] unless a Unit has at least one model. The server's database enforces the same rule.
int validModelCount(int count) => count >= 1
    ? count
    : throw ArgumentError.value(count, 'modelCount', 'must be at least 1');

/// Trims [name], throwing an [ArgumentError] if it is blank. Shared with the write API, which validates uploaded names.
/// A Game System name, trimmed; null if [name] is null or blank (no Game System).
String? validGameSystem(String? name) => switch (name?.trim()) {
  '' || null => null,
  final n => n,
};

String validName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(name, 'name', 'must not be blank');
  }
  return trimmed;
}

/// A Stage colour: `#RRGGBB`, upper-case hex. The write API checks uploads against it.
final stageColourFormat = RegExp(r'^#[0-9A-F]{6}$');

/// Returns [colour] if it matches [stageColourFormat], else throws an [ArgumentError].
String validColour(String colour) => stageColourFormat.hasMatch(colour)
    ? colour
    : throw ArgumentError.value(colour, 'colour', 'must be #RRGGBB');

final _random = Random.secure();

/// A random (v4) UUID. Ids are generated on the client so rows can be created offline and synced later.
String _newId() {
  final b = List<int>.generate(16, (_) => _random.nextInt(256));
  b[6] = b[6] & 0x0f | 0x40;
  b[8] = b[8] & 0x3f | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}
