/// Mini Vault's domain operations. Pure Dart: shared by the app and the server.
library;

import 'dart:math';

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
  Future<void> insertUnit(Unit unit);

  /// Updates only the given fields, so concurrent edits of other fields on other devices are kept.
  Future<void> updateUnit(
    String id, {
    String? name,
    int? modelCount,
    String? notes,
  });
  Future<void> deleteUnit(String id);
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
    await _store.insertUnit(unit);
    return unit;
  }

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
}

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
