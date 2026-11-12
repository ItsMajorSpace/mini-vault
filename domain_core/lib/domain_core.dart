/// Mini Vault's domain operations. Pure Dart: shared by the app and the server.
library;

import 'dart:async';
import 'dart:math';

import 'package:uuid/uuid.dart';

/// One step in a [Workflow].
class Stage {
  const Stage({required this.id, required this.name});

  final String id;
  final String name;
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
  });

  final String id;
  final String name;
  final String workflowId;
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

/// How many of a Collection's models are wanted, owned and finished, by its Workflow's Owned and Finished Stage.
class Progress {
  const Progress({
    required this.wanted,
    required this.owned,
    required this.finished,
  });

  /// Models before the Owned Stage.
  final int wanted;

  /// Models at the Owned Stage or later.
  final int owned;

  /// Models at the Finished Stage or later; always part of [owned].
  final int finished;

  /// [finished] as a share of [owned], 0 when nothing is owned.
  double get finishedShare => owned == 0 ? 0 : finished / owned;

  @override
  bool operator ==(Object other) =>
      other is Progress &&
      other.wanted == wanted &&
      other.owned == owned &&
      other.finished == finished;

  @override
  int get hashCode => Object.hash(wanted, owned, finished);

  @override
  String toString() => '$finished / $owned finished, $wanted wanted';
}

/// Counts [units]' models against [workflow]'s Owned and Finished Stage, in Workflow order.
// Units at a Stage outside the Workflow are left out, as in [groupByStage].
Progress progressOf(Workflow workflow, Iterable<Unit> units) {
  final index = {for (final (i, s) in workflow.stages.indexed) s.id: i};
  final owned = index[workflow.ownedStage.id]!;
  final finished = index[workflow.finishedStage.id]!;
  var (w, o, f) = (0, 0, 0);
  for (final u in units) {
    final i = index[u.stageId];
    if (i == null) continue;
    if (i < owned) w += u.modelCount;
    if (i >= owned) o += u.modelCount;
    if (i >= finished) f += u.modelCount;
  }
  return Progress(wanted: w, owned: o, finished: f);
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

  /// Stores [order] (all of a Workflow's Stage ids) as its Stage order.
  Future<void> reorderStages(List<String> order);
  Future<void> deleteStage(String id);
  Future<bool> stageHoldsUnits(String id);

  Future<List<Collection>> collections();

  /// Emits the Collections now and again whenever they change, locally or through sync.
  Stream<List<Collection>> watchCollections();
  Future<void> insertCollection(Collection collection);
  Future<void> renameCollection(String id, String name);

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

  /// Deletes the Unit and its Tags.
  Future<void> deleteUnit(String id);

  /// Emits the Unit's Tags, by name, now and again whenever they change.
  Stream<List<String>> watchTags(String unitId);

  /// Every Tag name on any of the user's Units.
  Future<List<String>> allTagNames();

  /// Adds Tags to a Unit, keyed by their [tagId]; a Tag whose id is already there is left as it is.
  Future<void> insertTags(String unitId, Map<String, String> namesById);
  Future<void> deleteTag(String id);
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

  /// Creates a Workflow with the starter Stages, the second Stage Owned and the last Finished.
  Future<Workflow> createWorkflow(String name) async {
    final stages = [
      for (final name in starterStageNames) Stage(id: _newId(), name: name),
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

  /// Adds a Stage at [index] (0 is first; clamped to the end).
  Future<Stage> addStage(String workflowId, String name, int index) async {
    final w = await _workflow(workflowId);
    final stage = Stage(id: _newId(), name: validName(name));
    final order = [for (final s in w.stages) s.id]
      ..insert(index.clamp(0, w.stages.length), stage.id);
    await _store.insertStage(workflowId, stage, order);
    return stage;
  }

  Future<void> renameStage(String id, String name) =>
      _store.renameStage(id, validName(name));

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

  /// Throws a [StateError] if it is the Workflow's only Stage, its Owned or Finished Stage, or holds Units.
  Future<void> deleteStage(String workflowId, String stageId) async {
    final w = await _workflow(workflowId);
    if (!w.stages.any((s) => s.id == stageId)) {
      throw ArgumentError.value(stageId, 'stageId', 'not in this Workflow');
    }
    if (w.stages.length == 1) {
      throw StateError('A Workflow needs at least one Stage');
    }
    if (stageId == w.ownedStage.id || stageId == w.finishedStage.id) {
      throw StateError('Pick another Owned or Finished Stage first');
    }
    if (await _store.stageHoldsUnits(stageId)) {
      throw StateError('This Stage holds Units');
    }
    await _store.deleteStage(stageId);
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
  Future<Collection> createCollection(String name, {String? workflowId}) async {
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
    );
    await _store.insertCollection(collection);
    return collection;
  }

  Future<void> renameCollection(String id, String name) =>
      _store.renameCollection(id, validName(name));

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

  /// The Collection's [Progress], emitted again whenever its Units or its Workflow (Stages, Owned or Finished Stage) change.
  Stream<Progress> watchProgress(Collection collection) {
    List<Workflow>? workflows;
    List<Unit>? units;
    final subscriptions = <StreamSubscription<void>>[];
    late final StreamController<Progress> controller;
    void emit() {
      if (workflows == null || units == null) return;
      final workflow = workflows!
          .where((w) => w.id == collection.workflowId)
          .firstOrNull;
      workflow == null
          ? controller.addError(StateError('The Workflow has not synced yet'))
          : controller.add(progressOf(workflow, units!));
    }

    controller = StreamController(
      onListen: () => subscriptions.addAll([
        _store.watchWorkflows().listen((ws) {
          workflows = ws;
          emit();
        }, onError: controller.addError),
        _store.watchUnits(collection.id).listen((us) {
          units = us;
          emit();
        }, onError: controller.addError),
      ]),
      onCancel: () => Future.wait([for (final s in subscriptions) s.cancel()]),
    );
    return controller.stream.distinct();
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

  /// Moves the whole Unit to [stageId], any Stage of its Collection's Workflow, forward or back.
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

  /// Changes only the given fields of a Unit.
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
String validName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(name, 'name', 'must not be blank');
  }
  return trimmed;
}

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
