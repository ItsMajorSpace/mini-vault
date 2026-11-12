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

  Stage get ownedStage => stages.firstWhere((s) => s.id == ownedStageId);
  Stage get finishedStage => stages.firstWhere((s) => s.id == finishedStageId);
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
  Future<List<Workflow>> workflows();
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
  // shortcut: returns whichever Workflow exists, since there is only ever one; pick by user choice once Workflows can be created.
  Future<Workflow?> starterWorkflow() async =>
      (await _store.workflows()).firstOrNull;

  Future<List<Collection>> collections() => _store.collections();

  Stream<List<Collection>> watchCollections() => _store.watchCollections();

  /// Creates a Collection that uses the starter Workflow.
  /// Throws a [StateError] while the starter Workflow has not synced yet.
  Future<Collection> createCollection(String name) async {
    final workflow = await starterWorkflow();
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
