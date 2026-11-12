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

/// The narrow storage interface the domain core talks to.
/// The app implements it over local SQLite (`package:domain_core/sqlite_store.dart`).
abstract interface class VaultStore {
  Future<List<Workflow>> workflows();
  Future<void> insertWorkflow(Workflow workflow);
  Future<List<Collection>> collections();
  Future<void> insertCollection(Collection collection);
  Future<void> renameCollection(String id, String name);
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

  /// Returns the starter Workflow, creating it on first launch.
  // shortcut: returns whichever Workflow exists, since there is only ever one; pick by user choice once Workflows can be created.
  Future<Workflow> ensureStarterWorkflow() async {
    final existing = await _store.workflows();
    if (existing.isNotEmpty) return existing.first;

    final stages = [
      for (final name in starterStageNames) Stage(id: _newId(), name: name),
    ];
    final workflow = Workflow(
      id: _newId(),
      name: 'Starter',
      stages: stages,
      ownedStageId: stages[1].id,
      finishedStageId: stages.last.id,
    );
    await _store.insertWorkflow(workflow);
    return workflow;
  }

  Future<List<Collection>> collections() => _store.collections();

  /// Creates a Collection that uses the starter Workflow.
  Future<Collection> createCollection(String name) async {
    final workflow = await ensureStarterWorkflow();
    final collection = Collection(
      id: _newId(),
      name: _validName(name),
      workflowId: workflow.id,
    );
    await _store.insertCollection(collection);
    return collection;
  }

  Future<void> renameCollection(String id, String name) =>
      _store.renameCollection(id, _validName(name));
}

String _validName(String name) {
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
