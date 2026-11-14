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

/// A named set of Batches owned by one person, all progressing through the same Workflow.
class Collection {
  const Collection({
    required this.id,
    required this.name,
    required this.workflowId,
    this.gameSystem,
    this.description = '',
  });

  final String id;
  final String name;
  final String workflowId;

  /// The Game System it belongs to, as typed; null if none.
  final String? gameSystem;

  /// Free text, trimmed; '' if none.
  final String description;
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

/// One product from one manufacturer in a person's paint library, independent of any Collection.
class Paint {
  const Paint({
    required this.id,
    required this.brand,
    required this.range,
    required this.name,
    required this.owned,
  });

  final String id;
  final String brand;

  /// Empty when the Paint has none.
  final String range;
  final String name;

  /// Owned, or else wanted (on the shopping list).
  final bool owned;

  /// Brand, range and name, as "Citadel / Base / Macragge Blue", or "AP / Greedy Gold" with no range.
  String get label => [brand, if (range.isNotEmpty) range, name].join(' / ');
}

/// Groups [paints] by brand (ignoring case and outer spaces, as [tagKey]), A–Z; inside a brand, by range then name,
/// ignoring case. Each brand is spelled as its first Paint spells it.
List<({String brand, List<Paint> paints})> groupByBrand(
  Iterable<Paint> paints,
) {
  final byKey = <String, List<Paint>>{};
  for (final p in paints) {
    (byKey[tagKey(p.brand)] ??= []).add(p);
  }
  int compare(Paint a, Paint b) =>
      switch (tagKey(a.range).compareTo(tagKey(b.range))) {
        0 => tagKey(a.name).compareTo(tagKey(b.name)),
        final c => c,
      };
  return [
    for (final k in byKey.keys.toList()..sort())
      (brand: byKey[k]!.first.brand, paints: [...byKey[k]!]..sort(compare)),
  ];
}

/// Whether [paint] matches what was typed in a search: each word of [query] is in its brand, range or name, ignoring
/// case. An empty query matches every Paint.
bool paintMatches(Paint paint, String query) {
  final text = '${paint.brand} ${paint.range} ${paint.name}'.toLowerCase();
  return query.toLowerCase().split(RegExp(r'\s+')).every(text.contains);
}

/// A Paint a Unit uses, with a note on where or how. Keyed by the Unit's Collection and exact name (as [unitsOf]
/// groups Batches), not by its Batches, so it stays with the name while no Batch has it.
class UnitPaint {
  const UnitPaint({
    required this.id,
    required this.collectionId,
    required this.unit,
    required this.paint,
    this.note = '',
  });

  final String id;
  final String collectionId;

  /// The Unit's name.
  final String unit;
  final Paint paint;
  final String note;
}

/// The Units in [links] (only those using Paint [paintId], if given), once each, by Collection then Unit name,
/// ignoring case.
List<({Collection collection, String unit})> paintedUnits(
  Iterable<({Collection collection, UnitPaint link})> links, {
  String? paintId,
}) {
  final seen = <(String, String)>{};
  String key(({Collection collection, String unit}) s) =>
      '${s.collection.name.toLowerCase()}\n${s.unit.toLowerCase()}';
  return [
    for (final (:collection, :link) in links)
      if ((paintId == null || link.paint.id == paintId) &&
          seen.add((collection.id, link.unit)))
        (collection: collection, unit: link.unit),
  ]..sort((a, b) => key(a).compareTo(key(b)));
}

/// A named, ordered recipe for painting one part of a Collection's models (ADR 0010).
class PaintScheme {
  const PaintScheme({
    required this.id,
    required this.collectionId,
    required this.name,
    this.stepCount = 0,
  });

  final String id;
  final String collectionId;
  final String name;

  /// How many Scheme Steps it has.
  final int stepCount;
}

/// One numbered entry in a [PaintScheme]: any number of Paints (several means mixed), a Technique and a note, at
/// least one of the three when saved. Deleting a Paint takes it out, so a Step may be left empty.
class SchemeStep {
  const SchemeStep({
    required this.id,
    required this.schemeId,
    this.paints = const [],
    this.technique = '',
    this.note = '',
  });

  final String id;
  final String schemeId;

  /// In the order picked; only those that have synced.
  final List<Paint> paints;

  /// '' if none.
  final String technique;

  /// '' if none.
  final String note;
}

/// A named group of Units within one Collection, in the order the person chooses (ADR 0011). A Unit is in at most
/// one; Units in none are Uncategorised.
class Category {
  const Category({
    required this.id,
    required this.collectionId,
    required this.name,
  });

  final String id;
  final String collectionId;
  final String name;
}

/// [units] under their Category: one group per [categories], in that order and empty ones included, then the Units
/// in none (or in a Category not synced yet) under a null Category, only if there are any. [categoryOf] maps a
/// Unit's name to its Category's id. Each group keeps [units]' order.
List<({Category? category, List<Unit> units})> groupByCategory(
  List<Category> categories,
  List<Unit> units,
  Map<String, String> categoryOf,
) {
  final known = {for (final c in categories) c.id};
  final rest = [
    for (final u in units)
      if (!known.contains(categoryOf[u.name])) u,
  ];
  return [
    for (final c in categories)
      (
        category: c,
        units: [
          for (final u in units)
            if (categoryOf[u.name] == c.id) u,
        ],
      ),
    if (rest.isNotEmpty) (category: null, units: rest),
  ];
}

/// A number of models tracked together because they are at the same Stage; it belongs to exactly one Collection.
/// Its notes, Tags and photos belong to its Unit, not to it (ADR 0008).
class Batch {
  const Batch({
    required this.id,
    required this.collectionId,
    required this.stageId,
    required this.name,
    required this.modelCount,
  });

  final String id;
  final String collectionId;
  final String stageId;
  final String name;
  final int modelCount;
}

/// A record that a Batch moved from one Stage to another, and when. A Batch's Stage Changes form its history.
/// Append-only: never edited or deleted on its own (deleting the Batch removes them).
class StageChange {
  const StageChange({
    required this.id,
    required this.batchId,
    required this.fromStageId,
    required this.toStageId,
    required this.modelCount,
    required this.happenedAt,
  });

  final String id;
  final String batchId;

  /// Null for the Stage Change that records where the Batch was created.
  final String? fromStageId;
  final String toStageId;

  /// The number of models moved.
  final int modelCount;

  /// The device's clock when it happened. Used only to order Stage Changes: the latest sets the Batch's Stage.
  final DateTime happenedAt;
}

/// A photo of a Unit, keyed by its Collection and name like a [UnitPaint]. Its image file is stored once, under
/// [fileId]; the file is only deleted once no row points at it.
class Photo {
  const Photo({
    required this.id,
    required this.collectionId,
    required this.unit,
    required this.fileId,
  });

  final String id;
  final String collectionId;

  /// The Unit's name.
  final String unit;

  /// The image file's id, which is also its PowerSync attachment id.
  final String fileId;
}

/// One Stage of a Collection's Workflow, with the Collection's Batches at it.
class StageGroup {
  const StageGroup(this.stage, this.batches);

  final Stage stage;
  final List<Batch> batches;

  int get modelCount => batches.fold(0, (sum, u) => sum + u.modelCount);
}

/// Groups [batches] by Stage: one group per Stage of [workflow], in Workflow order, including Stages without Batches.
// shortcut: Batches at a Stage outside the Workflow are left out (the write API rejects them); revisit if Stages can be deleted (#11).
List<StageGroup> groupByStage(Workflow workflow, Iterable<Batch> batches) => [
  for (final stage in workflow.stages)
    StageGroup(stage, [
      for (final u in batches)
        if (u.stageId == stage.id) u,
    ]),
];

/// All Batches in a Collection sharing a name, laid out over every Stage of the Workflow.
class Unit {
  const Unit(this.name, this.stages, this.progress);

  final String name;

  /// One group per Stage of the Workflow, in Workflow order, including Stages without Batches.
  final List<StageGroup> stages;
  final Progress progress;

  Iterable<Batch> get batches => stages.expand((g) => g.batches);
  int get modelCount => stages.fold(0, (sum, g) => sum + g.modelCount);
}

/// Groups [batches] into Units by exact name (as [Vault.mergeCandidates] matches), in the order names first appear.
List<Unit> unitsOf(Workflow workflow, Iterable<Batch> batches) {
  final byName = <String, List<Batch>>{};
  for (final u in batches) {
    (byName[u.name] ??= []).add(u);
  }
  return [
    for (final MapEntry(key: name, value: us) in byName.entries)
      Unit(name, groupByStage(workflow, us), progressOf(workflow, us)),
  ];
}

/// A Unit whose models moved recently, with its Collection and the Stage a move from it starts at: its latest
/// move's from-Stage while that still has models, otherwise its earliest Stage with models from the Owned Stage on,
/// otherwise its earliest with any.
class RecentUnit {
  const RecentUnit(this.collection, this.unit, this.from);

  final Collection collection;
  final Unit unit;
  final StageGroup from;
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

  /// One group per Stage of the Workflow, in Workflow order, including Stages without Batches and before the Owned Stage.
  final List<StageGroup> stages;
  final Progress progress;
}

/// Counts [batches]' models against [workflow]'s Owned and Finished Stage, in Workflow order.
// Batches at a Stage outside the Workflow are left out, as in [groupByStage].
Progress progressOf(Workflow workflow, Iterable<Batch> batches) {
  final index = {for (final (i, s) in workflow.stages.indexed) s.id: i};
  final owned = index[workflow.ownedStage.id]!;
  final finished = index[workflow.finishedStage.id]!;
  var (w, o, f) = (0, 0, 0);
  final perStage = List.filled(workflow.stages.length, 0);
  for (final u in batches) {
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
  /// each Batch's Stage, then sets the Workflow's Owned and Finished Stage if given, then deletes the Stage.
  Future<void> deleteStage(
    String workflowId,
    String id, {
    List<StageChange> moves = const [],
    String? ownedStageId,
    String? finishedStageId,
  });

  /// The Batches at the Stage, in every Collection.
  Future<List<Batch>> batchesAt(String stageId);

  /// In one transaction, so it uploads as one batch: appends [moves] and sets each Batch's Stage, then points the
  /// Collection at the Workflow. The write API checks Batches against their Collection's Workflow after the whole batch.
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
  Future<void> setCollectionDescription(String id, String description);

  /// Deletes the Collection, its Batches, its Units' notes, Tags, Photos and [UnitPaint]s, and its Paint Schemes, in
  /// one transaction.
  Future<void> deleteCollection(String id);

  /// Emits every Collection's Batches now and again whenever they change.
  Stream<List<Batch>> watchAllBatches();

  /// Emits the Collection's Batches, by name, now and again whenever they change.
  Stream<List<Batch>> watchBatches(String collectionId);

  /// Inserts the Batch and the Stage Change that records its starting Stage, in one transaction.
  Future<void> insertBatch(Batch batch, StageChange initial);

  /// Appends [change] and sets its Batch's Stage to its to-Stage, in one transaction.
  Future<void> insertStageChange(StageChange change);

  /// Emits the Batch's Stage Changes, oldest first, now and again whenever they change.
  Stream<List<StageChange>> watchStageChanges(String batchId);

  /// Emits the Stage Changes of every Batch of Unit [unit] in Collection [collectionId], oldest first, now and again
  /// whenever they change.
  Stream<List<StageChange>> watchUnitStageChanges(
    String collectionId,
    String unit,
  );

  /// Emits every Batch's Stage Changes from a move (those with a from-Stage), newest first, now and again whenever
  /// they change.
  Stream<List<StageChange>> watchMoves();

  /// Updates only the given fields, so concurrent edits of other fields on other devices are kept.
  Future<void> updateBatch(String id, {String? name, int? modelCount});

  /// Deletes the Batch. Its Unit's notes, Tags and Photos stay.
  Future<void> deleteBatch(String id);

  /// Emits the paint library now and again whenever it changes.
  Stream<List<Paint>> watchPaints();
  Future<void> insertPaint(Paint paint);
  Future<void> updatePaint(Paint paint);
  Future<void> setPaintOwned(String id, bool owned);

  /// Deletes the Paint, its [UnitPaint]s and its place in every Scheme Step, in one transaction.
  Future<void> deletePaint(String id);

  /// Emits the Collection's Paint Schemes, by name, with their Step counts, now and again whenever they change.
  Stream<List<PaintScheme>> watchPaintSchemes(String collectionId);

  /// Emits every Paint Scheme, by name, with their Step counts, now and again whenever they change.
  Stream<List<PaintScheme>> watchAllPaintSchemes();
  Future<void> insertPaintScheme(PaintScheme scheme);
  Future<void> renamePaintScheme(String id, String name);

  /// Deletes the Paint Scheme and its Scheme Steps, in one transaction.
  Future<void> deletePaintScheme(String id);

  /// Emits the Paint Scheme's Scheme Steps in order, now and again whenever they or their Paints change.
  Stream<List<SchemeStep>> watchSchemeSteps(String schemeId);

  /// Appends [step] to the end of its Paint Scheme, with its Paints in list order.
  Future<void> insertSchemeStep(SchemeStep step);

  /// Stores [step]'s Paints (in list order), Technique and note, writing only what changed.
  Future<void> updateSchemeStep(SchemeStep step);

  /// Stores [order] (all of a Paint Scheme's Scheme Step ids) as its Step order.
  Future<void> reorderSchemeSteps(List<String> order);
  Future<void> deleteSchemeStep(String id);

  /// Every Technique on any of the user's Scheme Steps.
  Future<List<String>> allTechniques();

  /// Emits which Paint Schemes use which Paints, once per pair, now and again whenever they change.
  Stream<List<({String paintId, String schemeId})>> watchSchemePaints();

  /// Emits every [UnitPaint] whose Paint has synced, by brand, range and name, now and again whenever they change.
  Stream<List<UnitPaint>> watchUnitPaints();
  Future<void> insertUnitPaints(List<UnitPaint> links);

  /// Updates only the given fields.
  Future<void> updateUnitPaint(String id, {String? unit, String? note});
  Future<void> deleteUnitPaint(String id);

  /// Emits the notes of Unit [unit] in Collection [collectionId] ('' if none), now and again whenever they change.
  Stream<String> watchNotes(String collectionId, String unit);

  /// Sets the Unit's notes, in the row whose id is its [unitId].
  Future<void> setNotes(String collectionId, String unit, String notes);
  Future<void> deleteNotes(String collectionId, String unit);

  /// Emits the Unit's Tags, by name, now and again whenever they change.
  Stream<List<String>> watchTags(String collectionId, String unit);

  /// Every Tag name on any of the user's Units.
  Future<List<String>> allTagNames();

  /// Adds Tags to a Unit, keyed by their [tagId]; a Tag whose id is already there is left as it is.
  Future<void> insertTags(
    String collectionId,
    String unit,
    Map<String, String> namesById,
  );
  Future<void> deleteTag(String id);

  /// Emits the Unit's Photos, in the same order on every device, now and again whenever they change.
  Stream<List<Photo>> watchPhotos(String collectionId, String unit);
  Future<void> insertPhotos(List<Photo> photos);

  /// Moves the Photo to Unit [unit] of its Collection.
  Future<void> movePhoto(String id, String unit);
  Future<void> deletePhoto(String id);

  /// The Collection's Categories, in order: (position, id), as Stages.
  Stream<List<Category>> watchCategories(String collectionId);

  /// Appends [category] after the Collection's others.
  Future<void> insertCategory(Category category);
  Future<void> renameCategory(String id, String name);

  /// Stores [order] (all of a Collection's Category ids) as its Category order.
  Future<void> reorderCategories(List<String> order);

  /// In one transaction: makes the Category's Units Uncategorised, then deletes it.
  Future<void> deleteCategory(String id);

  /// The Collection's Unit names with a Category, mapped to its id.
  Stream<Map<String, String>> watchUnitCategories(String collectionId);

  /// Puts Unit [unit] in Category [categoryId]; null makes it Uncategorised.
  Future<void> setUnitCategory(
    String collectionId,
    String unit,
    String? categoryId,
  );

  /// In one transaction, so it uploads as one batch the write API applies whole or not at all: inserts [created]
  /// with [move] (its first Stage Change), then records Split [id] of [created]'s models off Batch [sourceId] and
  /// takes them off that Batch's count.
  Future<void> insertSplit(
    String id,
    String sourceId,
    Batch created,
    StageChange move,
  );

  /// In one transaction: records Merge [id] of Batch [otherId] into Batch [batchId], then copies [history] onto
  /// [batchId], adds the other Batch's models to its count and deletes the other Batch. Does nothing unless both
  /// Batches still share Collection, name and Stage, so a repeated Merge changes nothing.
  Future<void> insertMerge(
    String id,
    String batchId,
    String otherId,
    List<StageChange> history,
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

  /// The Batches at the Stage, in every Collection using its Workflow.
  Future<List<Batch>> batchesAt(String stageId) => _store.batchesAt(stageId);

  /// Deletes a Stage in one transaction. If it holds Batches, in any Collection, they all move to [moveBatchesTo] first,
  /// each recording a Stage Change. If it is the Owned or Finished Stage, [ownedStageId] or [finishedStageId] replaces it.
  /// Throws a [StateError] if it is the Workflow's only Stage, or holds Batches or is the Owned or Finished Stage without
  /// the replacement; an [ArgumentError] if a replacement is not another Stage of the Workflow, or Owned would come
  /// after Finished.
  Future<void> deleteStage(
    String workflowId,
    String stageId, {
    String? moveBatchesTo,
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
    final batches = await _store.batchesAt(stageId);
    if (batches.isNotEmpty && moveBatchesTo == null) {
      throw StateError('This Stage holds Units');
    }
    if (batches.isNotEmpty && !rest.any((s) => s.id == moveBatchesTo)) {
      throw ArgumentError.value(
        moveBatchesTo,
        'moveUnitsTo',
        'must be another Stage of this Workflow',
      );
    }
    await _store.deleteStage(
      workflowId,
      stageId,
      moves: [
        for (final u in batches) _stageChange(u, stageId, moveBatchesTo!),
      ],
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

  /// Sets the Collection's description, trimmed; blank clears it.
  Future<void> setCollectionDescription(String id, String description) =>
      _store.setCollectionDescription(id, description.trim());

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

  /// The Collection's Batches, by name: what deleting it would delete.
  Future<List<Batch>> batchesOf(Collection collection) =>
      _store.watchBatches(collection.id).first;

  /// Deletes the Collection, its Batches and their history, its Units' notes, Tags, Photos and Paint links (not the
  /// Paints), its Paint Schemes and its Categories. The server deletes the history with the Batches, and any Batch another device added meanwhile, and each
  /// photo file once no Photo points at it.
  Future<void> deleteCollection(String id) => _store.deleteCollection(id);

  /// What switching [collection] to [target] has to map: each Stage of its Workflow that holds its Batches, in Workflow
  /// order, with the Stage of [target] that has the same name (ignoring case and outer spaces), or null.
  Future<List<({Stage from, Stage? to})>> stageMapping(
    Collection collection,
    Workflow target,
  ) async {
    String key(Stage s) => s.name.trim().toLowerCase();
    final batches = await _store.watchBatches(collection.id).first;
    return [
      for (final g in groupByStage(await workflowOf(collection), batches))
        if (g.batches.isNotEmpty)
          (
            from: g.stage,
            to: target.stages.where((s) => key(s) == key(g.stage)).firstOrNull,
          ),
    ];
  }

  /// Switches [collection] to Workflow [workflowId] in one transaction: each of its Batches moves to the Stage that
  /// [moveTo] maps its current Stage to (see [stageMapping]), recording a Stage Change. Does nothing if the Collection
  /// already uses the Workflow. Throws an [ArgumentError] if there is no such Workflow, or a Batch's Stage is not
  /// mapped to a Stage of it.
  Future<void> switchWorkflow(
    Collection collection,
    String workflowId,
    Map<String, String> moveTo,
  ) async {
    final target = await _workflow(workflowId);
    if (target.id == collection.workflowId) return;
    final moves = [
      for (final u in await _store.watchBatches(collection.id).first)
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

  /// The Collection's Batches grouped by Stage in Workflow order, emitted again whenever they change.
  Stream<List<StageGroup>> watchStageGroups(Collection collection) => _store
      .watchBatches(collection.id)
      .asyncMap(
        (batches) async => groupByStage(await workflowOf(collection), batches),
      );

  /// The Collection's Units, by name, emitted again whenever its Batches change.
  Stream<List<Unit>> watchUnits(Collection collection) => _store
      .watchBatches(collection.id)
      .asyncMap(
        (batches) async => unitsOf(await workflowOf(collection), batches),
      );

  /// The Collection's Units under their Categories (see [groupByCategory]), emitted again whenever they change.
  Stream<List<({Category? category, List<Unit> units})>> watchUnitsByCategory(
    Collection collection,
  ) => _combineLatest(
    [
      watchUnits(collection),
      _store.watchCategories(collection.id),
      _store.watchUnitCategories(collection.id),
    ],
    (latest) => groupByCategory(
      latest[1] as List<Category>,
      latest[0] as List<Unit>,
      latest[2] as Map<String, String>,
    ),
  );

  /// The Collection's Categories, in order, emitted again whenever they change.
  Stream<List<Category>> watchCategories(String collectionId) =>
      _store.watchCategories(collectionId);

  /// Appends Category [name] to the Collection's, or returns the one already named so, ignoring case and outer spaces.
  Future<Category> addCategory(String collectionId, String name) async {
    final valid = validName(name);
    final known = await watchCategories(collectionId).first;
    if (known.where((c) => tagKey(c.name) == tagKey(valid)).firstOrNull
        case final c?) {
      return c;
    }
    final category = Category(
      id: _newId(),
      collectionId: collectionId,
      name: valid,
    );
    await _store.insertCategory(category);
    return category;
  }

  /// Renames the Category. Throws a [StateError] if another Category of its Collection has that name, ignoring case.
  Future<void> renameCategory(Category category, String name) async {
    final valid = validName(name);
    final known = await watchCategories(category.collectionId).first;
    if (known.any(
      (c) => c.id != category.id && tagKey(c.name) == tagKey(valid),
    )) {
      throw StateError('Already a Category "$valid"');
    }
    await _store.renameCategory(category.id, valid);
  }

  /// Moves the Category to [index] in its Collection's order.
  Future<void> moveCategory(Category category, int index) async {
    final order = [
      for (final c in await watchCategories(category.collectionId).first)
        if (c.id != category.id) c.id,
    ];
    order.insert(index.clamp(0, order.length), category.id);
    await _store.reorderCategories(order);
  }

  /// Deletes the Category; its Units stay, Uncategorised.
  Future<void> deleteCategory(String id) => _store.deleteCategory(id);

  /// The Collection's Unit names with a Category, mapped to its id, emitted again whenever they change.
  Stream<Map<String, String>> watchUnitCategories(String collectionId) =>
      _store.watchUnitCategories(collectionId);

  /// The id of Unit [unit]'s Category; null if Uncategorised. Like its notes, it stays with the name.
  Future<String?> categoryOf(String collectionId, String unit) async =>
      (await watchUnitCategories(collectionId).first)[unit];

  /// Puts the Unit in Category [categoryId]; null makes it Uncategorised.
  Future<void> setUnitCategory(
    String collectionId,
    String unit,
    String? categoryId,
  ) => _store.setUnitCategory(collectionId, unit, categoryId);

  /// The Collection's [Progress], emitted again whenever its Batches or its Workflow (Stages, Owned or Finished Stage) change.
  Stream<Progress> watchProgress(Collection collection) => _combineLatest(
    [_store.watchWorkflows(), _store.watchBatches(collection.id)],
    (latest) {
      final [workflows as List<Workflow>, batches as List<Batch>] = latest;
      final workflow = workflows
          .where((w) => w.id == collection.workflowId)
          .firstOrNull;
      if (workflow == null) throw StateError('The Workflow has not synced yet');
      return progressOf(workflow, batches);
    },
  ).distinct();

  /// The [Progress] of every Collection, or only of [collection], per Workflow: one [WorkflowProgress] per Workflow
  /// that at least one of them uses, in [workflows] order. Emitted again whenever the Collections, their Batches or the
  /// Workflows change. Collections whose Workflow has not synced are left out.
  Stream<List<WorkflowProgress>> watchProgressByWorkflow([
    Collection? collection,
  ]) => _combineLatest(
    [
      _store.watchWorkflows(),
      _store.watchCollections(),
      collection == null
          ? _store.watchAllBatches()
          : _store.watchBatches(collection.id),
    ],
    (latest) {
      final [
        workflows as List<Workflow>,
        collections as List<Collection>,
        batches as List<Batch>,
      ] = latest;
      final workflowOf = {
        for (final c in collections)
          if (collection == null || c.id == collection.id) c.id: c.workflowId,
      };
      WorkflowProgress of(Workflow w) {
        final us = [
          for (final u in batches)
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

  /// The [limit] Units, across all Collections, whose models moved most recently, newest first by their latest Stage
  /// Change from a move. Emitted again whenever the moves, Batches, Collections or Workflows change.
  Stream<List<RecentUnit>> watchRecentlyMoved({
    int limit = 3,
  }) => _combineLatest(
    [
      _store.watchWorkflows(),
      _store.watchCollections(),
      _store.watchAllBatches(),
      _store.watchMoves(),
    ],
    (latest) {
      final [
        workflows as List<Workflow>,
        collections as List<Collection>,
        batches as List<Batch>,
        moves as List<StageChange>,
      ] = latest;
      final batchById = {for (final u in batches) u.id: u};
      final recent = <RecentUnit>[];
      final seen = <(String, String)>{};
      for (final m in moves) {
        if (recent.length == limit) break;
        final batch = batchById[m.batchId];
        final collection = collections
            .where((c) => c.id == batch?.collectionId)
            .firstOrNull;
        final workflow = workflows
            .where((w) => w.id == collection?.workflowId)
            .firstOrNull;
        if (batch == null || workflow == null) continue;
        if (!seen.add((batch.collectionId, batch.name))) continue;
        final unit = unitsOf(workflow, [
          for (final u in batches)
            if (u.collectionId == batch.collectionId && u.name == batch.name) u,
        ]).single;
        final owned = workflow.stages.indexOf(workflow.ownedStage);
        final withModels = [
          for (final g in unit.stages)
            if (g.modelCount > 0) g,
        ];
        final from =
            withModels.where((g) => g.stage.id == m.fromStageId).firstOrNull ??
            withModels
                .where((g) => unit.stages.indexOf(g) >= owned)
                .firstOrNull ??
            withModels.first;
        recent.add(RecentUnit(collection!, unit, from));
      }
      return recent;
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

  /// Adds a Batch at [stageId], which must be a Stage of the Collection's Workflow. [notes], unless blank, are added
  /// to its Unit's notes (see [joinNotes]). A new Unit (one without Batches) goes in Category [categoryId] if given;
  /// adding to an existing Unit never moves it.
  Future<Batch> addBatch(
    Collection collection, {
    required String name,
    required int modelCount,
    String notes = '',
    required String stageId,
    String? categoryId,
  }) async {
    final workflow = await workflowOf(collection);
    if (!workflow.stages.any((s) => s.id == stageId)) {
      throw ArgumentError.value(
        stageId,
        'stageId',
        "is not a Stage of the Collection's Workflow",
      );
    }
    final batch = Batch(
      id: _newId(),
      collectionId: collection.id,
      stageId: stageId,
      name: validName(name),
      modelCount: validModelCount(modelCount),
    );
    final isNew =
        categoryId != null &&
        !(await batchesOf(collection)).any((b) => b.name == batch.name);
    await _store.insertBatch(batch, _stageChange(batch, null, stageId));
    if (isNew) await setUnitCategory(collection.id, batch.name, categoryId);
    if (notes.trim().isNotEmpty) {
      final had = await notesOf(collection.id, batch.name);
      await _store.setNotes(collection.id, batch.name, joinNotes([had, notes]));
    }
    return batch;
  }

  /// Imports an Army List's [entries] into [collection]: one Batch each at [stageId], with the Tag [tag] unless it is
  /// blank, Merged on arrival (ADR 0004) with a Batch already there under its name, earlier entries included. Never
  /// changes other Batches. Checks every entry first, so a bad one adds nothing.
  Future<void> importArmyList(
    Collection collection,
    String stageId,
    Iterable<({String name, int count})> entries, {
    String? tag,
  }) async {
    for (final e in entries) {
      validName(e.name);
      validModelCount(e.count);
    }
    for (final e in entries) {
      final batch = await addBatch(
        collection,
        name: e.name,
        modelCount: e.count,
        stageId: stageId,
      );
      await addTags(collection.id, batch.name, [?tag]);
      await _mergeOnArrival(collection, batch);
    }
  }

  /// Moves the whole Batch to [stageId], any Stage of its Collection's Workflow, forward or back, and Merges it into
  /// the Batch already there with its name, if any (ADR 0004): that Batch survives, with this move in its history.
  /// Does nothing if it is already there.
  Future<void> moveBatch(Batch batch, String stageId) async {
    final collection = (await _store.collections()).firstWhere(
      (c) => c.id == batch.collectionId,
      orElse: () => throw StateError('The Collection has not synced yet'),
    );
    if (!(await workflowOf(collection)).stages.any((s) => s.id == stageId)) {
      throw ArgumentError.value(
        stageId,
        'stageId',
        "is not a Stage of the Collection's Workflow",
      );
    }
    if (stageId == batch.stageId) return;
    await _store.insertStageChange(_stageChange(batch, batch.stageId, stageId));
    await _mergeOnArrival(collection, _at(batch, stageId));
  }

  /// Merges [arrived], just moved to its Stage, into a Batch already there with its name; returns the Batch now
  /// holding its models. Two uploads (move, then Merge): if the write API rejects the Merge, the move still stands.
  Future<Batch> _mergeOnArrival(Collection collection, Batch arrived) async {
    final there = mergeCandidates(arrived, await batchesOf(collection));
    if (there.isEmpty) return arrived;
    await mergeBatches(there.first, arrived);
    return _at(
      there.first,
      there.first.stageId,
      there.first.modelCount + arrived.modelCount,
    );
  }

  static Batch _at(Batch u, String stageId, [int? modelCount]) => Batch(
    id: u.id,
    collectionId: u.collectionId,
    stageId: stageId,
    name: u.name,
    modelCount: modelCount ?? u.modelCount,
  );

  /// Moves [modelCount] models of the Unit [name] in [collection] from [fromStageId] to [toStageId], forward or
  /// back, Merging them into the Unit's Batch there (see [moveBatch], [splitBatch]). When several of its Batches are at
  /// [fromStageId] (after concurrent moves on two devices), it takes from the oldest first: the one whose earliest
  /// Stage Change is earliest, ties broken by id. Throws an [ArgumentError] unless [modelCount] is at least 1 and at
  /// most what the Unit has at [fromStageId], or if the two Stages are the same.
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
      for (final u in await batchesOf(collection))
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
    for (final (batch, _) in at) {
      if (left == 0) break;
      if (left >= batch.modelCount) {
        await moveBatch(batch, toStageId);
        left -= batch.modelCount;
      } else {
        await splitBatch(batch, toStageId, left);
        left = 0;
      }
    }
  }

  /// Splits [batch]: moves [modelCount] of its models, at least 1 and fewer than all (all is [moveBatch]), to another
  /// Stage of its Collection's Workflow. The new Batch holding them has its name, and its history starts with this
  /// move; the Unit's notes, Tags and Photos are not touched. The Split uploads as a delta (N models off [batch]), never as [batch]'s new count,
  /// so Splits made on other devices add up; the write API rejects one that would leave [batch] under 1 model.
  /// If a Batch with its name is already at [stageId], the new Batch is then Merged into it (ADR 0004), and that Batch,
  /// with its new count, is returned instead.
  Future<Batch> splitBatch(Batch batch, String stageId, int modelCount) async {
    if (modelCount < 1 || modelCount >= batch.modelCount) {
      throw ArgumentError.value(
        modelCount,
        'modelCount',
        'must be at least 1 and fewer than the Unit has',
      );
    }
    final collection = (await _store.collections()).firstWhere(
      (c) => c.id == batch.collectionId,
      orElse: () => throw StateError('The Collection has not synced yet'),
    );
    if (stageId == batch.stageId ||
        !(await workflowOf(collection)).stages.any((s) => s.id == stageId)) {
      throw ArgumentError.value(
        stageId,
        'stageId',
        "is not another Stage of the Collection's Workflow",
      );
    }
    final created = Batch(
      id: _newId(),
      collectionId: batch.collectionId,
      stageId: stageId,
      name: batch.name,
      modelCount: modelCount,
    );
    await _store.insertSplit(
      _newId(),
      batch.id,
      created,
      _stageChange(created, batch.stageId, stageId),
    );
    return _mergeOnArrival(collection, created);
  }

  /// Keeps a Unit at one Batch per Stage (ADR 0009): whenever Batches change, locally or through sync, Merges each
  /// Unit's Batches that share a Stage into the one with the lowest id. Every device picks the same survivor, and
  /// the write API rejects a Merge of a Batch already merged away, so two devices merging the same pair add its
  /// models once. Emits after each pass; listen for as long as the app runs.
  Stream<void> keepBatchesMerged() => _store.watchAllBatches().asyncMap((
    batches,
  ) async {
    final byStage = <(String, String, String), List<Batch>>{};
    for (final b in batches) {
      byStage.putIfAbsent((b.collectionId, b.name, b.stageId), () => []).add(b);
    }
    for (final group in byStage.values) {
      group.sort((a, b) => a.id.compareTo(b.id));
      for (final other in group.skip(1)) {
        await mergeBatches(group.first, other);
      }
    }
  });

  /// The Batches [batch] may be Merged with: the others in [batches] in its Collection, with its name, at its Stage.
  static List<Batch> mergeCandidates(Batch batch, Iterable<Batch> batches) => [
    for (final u in batches)
      if (u.id != batch.id &&
          u.collectionId == batch.collectionId &&
          u.name == batch.name &&
          u.stageId == batch.stageId)
        u,
  ];

  /// Merges [other] into [batch]. [batch] gets both counts and a copy of [other]'s Stage Changes in its history
  /// (Stage Changes are append-only, so they are copied, not moved); [other] is deleted. The Unit's notes, Tags and
  /// Photos are not touched. The write API adds [other]'s count as it is
  /// on the server, and rejects the Merge if either Batch is gone or they no longer share Collection, name and Stage.
  /// Throws an [ArgumentError] unless [other] is one of [mergeCandidates].
  Future<void> mergeBatches(Batch batch, Batch other) async {
    if (mergeCandidates(batch, [other]).isEmpty) {
      throw ArgumentError.value(
        other.id,
        'other',
        'must be another Unit in the same Collection, with the same name, at the same Stage',
      );
    }
    await _store.insertMerge(_newId(), batch.id, other.id, [
      for (final c in await _store.watchStageChanges(other.id).first)
        StageChange(
          id: _newId(),
          batchId: batch.id,
          fromStageId: c.fromStageId,
          toStageId: c.toStageId,
          modelCount: c.modelCount,
          happenedAt: c.happenedAt,
        ),
    ]);
  }

  /// The Batch's history, oldest first, emitted again whenever it changes.
  Stream<List<StageChange>> watchHistory(String batchId) =>
      _store.watchStageChanges(batchId);

  /// The history of Unit [unit] in Collection [collectionId]: every one of its Batches' Stage Changes, newest first,
  /// emitted again whenever it changes. A Merge copies the merged Batch's Stage Changes and deletes it, so each shows
  /// once.
  Stream<List<StageChange>> watchUnitHistory(
    String collectionId,
    String unit,
  ) => _store
      .watchUnitStageChanges(collectionId, unit)
      .map((h) => h.reversed.toList());

  static StageChange _stageChange(Batch batch, String? from, String to) =>
      StageChange(
        id: _newId(),
        batchId: batch.id,
        fromStageId: from,
        toStageId: to,
        modelCount: batch.modelCount,
        happenedAt: DateTime.now().toUtc(),
      );

  /// Changes only the given fields of a Batch. A new [modelCount] is a recount: it sets the absolute count, and the
  /// latest write wins, unlike a Split or Merge (deltas). A Split uploaded after it still takes its models off.
  Future<void> editBatch(String id, {String? name, int? modelCount}) =>
      _store.updateBatch(
        id,
        name: name == null ? null : validName(name),
        modelCount: modelCount == null ? null : validModelCount(modelCount),
      );

  /// Renames every Batch in [unit], one field edit each, so other fields edited elsewhere are kept, and carries its
  /// notes, Tags, Photos and Paints to the new name. Onto an existing Unit they are combined: notes joined (see
  /// [joinNotes]), Tags and Photos unioned (all Photos kept, even past [maxPhotos]), and Paints unioned with the
  /// target's note winning for a Paint both use, unless it is empty. Its Category goes along, unless onto an existing
  /// Unit, which keeps its own.
  Future<void> renameUnit(Unit unit, String name) async {
    final valid = validName(
      name,
    ); // Before any write, so a bad name renames none.
    final onto =
        unit.batches.isNotEmpty &&
        (await _store.watchBatches(unit.batches.first.collectionId).first).any(
          (b) => b.name == valid,
        );
    for (final u in unit.batches) {
      await editBatch(u.id, name: valid);
    }
    if (valid == unit.name || unit.batches.isEmpty) return;
    final collectionId = unit.batches.first.collectionId;
    final notes = await notesOf(collectionId, unit.name);
    if (notes.isNotEmpty) {
      final had = await notesOf(collectionId, valid);
      await _store.setNotes(collectionId, valid, joinNotes([had, notes]));
    }
    await _store.deleteNotes(collectionId, unit.name);
    if (await categoryOf(collectionId, unit.name) case final category?) {
      if (!onto) await setUnitCategory(collectionId, valid, category);
      await setUnitCategory(collectionId, unit.name, null);
    }
    final tags = await tagsOf(collectionId, unit.name);
    await addTags(collectionId, valid, tags);
    for (final t in tags) {
      await removeTag(collectionId, unit.name, t);
    }
    final files = {
      for (final p in await photosOf(collectionId, valid)) p.fileId,
    };
    for (final p in await photosOf(collectionId, unit.name)) {
      if (files.contains(p.fileId)) {
        await _store.deletePhoto(p.id);
      } else {
        await _store.movePhoto(p.id, valid);
      }
    }
    final target = {
      for (final l in await _unitPaints(collectionId, valid)) l.paint.id: l,
    };
    for (final l in await _unitPaints(collectionId, unit.name)) {
      if (target[l.paint.id] case final t?) {
        if (t.note.isEmpty && l.note.isNotEmpty) {
          await _store.updateUnitPaint(t.id, note: l.note);
        }
        await _store.deleteUnitPaint(l.id);
      } else {
        await _store.updateUnitPaint(l.id, unit: valid);
      }
    }
  }

  Future<void> deleteBatch(String id) => _store.deleteBatch(id);

  /// The notes of Unit [unit] in Collection [collectionId] ('' if none), emitted again whenever they change. They
  /// stay with the name while the Unit has no Batches, like its Paints.
  Stream<String> watchNotes(String collectionId, String unit) =>
      _store.watchNotes(collectionId, unit);

  Future<String> notesOf(String collectionId, String unit) =>
      watchNotes(collectionId, unit).first;

  /// Sets the Unit's notes, trimmed; the latest edit wins.
  Future<void> setNotes(String collectionId, String unit, String notes) =>
      _store.setNotes(collectionId, unit, notes.trim());

  /// The Unit's Tags, by name, emitted again whenever they change.
  Stream<List<String>> watchTags(String collectionId, String unit) =>
      _store.watchTags(collectionId, unit);

  Future<List<String>> tagsOf(String collectionId, String unit) =>
      watchTags(collectionId, unit).first;

  /// Adds Tags to a Unit, skipping blank names and ones it already has (ignoring case and outer spaces).
  /// A Tag the user has used before keeps the casing it was first entered with.
  Future<void> addTags(
    String collectionId,
    String unit,
    Iterable<String> names,
  ) async {
    final known = _byKey(await _store.allTagNames());
    final namesById = <String, String>{};
    for (final name in names.map((n) => n.trim()).where((n) => n.isNotEmpty)) {
      final display = known[tagKey(name)] ?? name;
      namesById.putIfAbsent(
        tagId(unitId(collectionId, unit), display),
        () => display,
      );
    }
    if (namesById.isNotEmpty) {
      await _store.insertTags(collectionId, unit, namesById);
    }
  }

  Future<void> removeTag(String collectionId, String unit, String name) =>
      _store.deleteTag(tagId(unitId(collectionId, unit), name));

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

  /// The paint library, emitted again whenever it changes; see [groupByBrand].
  Stream<List<Paint>> watchPaints() => _store.watchPaints();

  /// Adds a Paint to the library. Throws an [ArgumentError] if a field is blank, or a [StateError] if the library
  /// already has a Paint with the same brand, range and name (ignoring case).
  Future<Paint> addPaint({
    required String brand,
    required String range,
    required String name,
    bool owned = true,
  }) async {
    final paint = await _checkedPaint(
      Paint(id: _newId(), brand: brand, range: range, name: name, owned: owned),
    );
    await _store.insertPaint(paint);
    return paint;
  }

  /// Saves [paint]'s brand, range, name and owned, checked as [addPaint] checks them.
  Future<void> editPaint(Paint paint) async =>
      _store.updatePaint(await _checkedPaint(paint));

  Future<void> setPaintOwned(String id, bool owned) =>
      _store.setPaintOwned(id, owned);

  /// Deletes the Paint and removes it from every Unit and Scheme Step that uses it; the Steps stay.
  Future<void> deletePaint(String id) => _store.deletePaint(id);

  /// The Paints Unit [unit] of Collection [collectionId] uses, by brand, range and name, emitted again whenever
  /// they change.
  Stream<List<UnitPaint>> watchUnitPaints(String collectionId, String unit) =>
      _store.watchUnitPaints().map(
        (links) => [
          for (final l in links)
            if (l.collectionId == collectionId && l.unit == unit) l,
        ],
      );

  Future<List<UnitPaint>> _unitPaints(String collectionId, String unit) =>
      watchUnitPaints(collectionId, unit).first;

  /// Every Unit's Paints with the Unit's Collection, emitted again whenever they or the Collections change; see
  /// [paintedUnits]. Links whose Collection has not synced are left out.
  Stream<List<({Collection collection, UnitPaint link})>>
  watchAllUnitPaints() => _combineLatest(
    [_store.watchUnitPaints(), _store.watchCollections()],
    (latest) {
      final [links as List<UnitPaint>, collections as List<Collection>] =
          latest;
      final byId = {for (final c in collections) c.id: c};
      return [
        for (final l in links)
          if (byId[l.collectionId] case final c?) (collection: c, link: l),
      ];
    },
  );

  /// Adds Paint [paintId] to the Unit with [note] (trimmed). Throws a [StateError] if the Unit already uses it.
  Future<void> addUnitPaint(
    String collectionId,
    String unit,
    String paintId, {
    String note = '',
  }) async {
    final paint = (await _store.watchPaints().first).firstWhere(
      (p) => p.id == paintId,
      orElse: () => throw StateError('That Paint is not in your paints'),
    );
    if ((await _unitPaints(
      collectionId,
      unit,
    )).any((l) => l.paint.id == paintId)) {
      throw StateError('$unit already uses ${paint.name}');
    }
    await _store.insertUnitPaints([
      UnitPaint(
        id: _newId(),
        collectionId: collectionId,
        unit: unit,
        paint: paint,
        note: note.trim(),
      ),
    ]);
  }

  /// Adds a new Paint to the library, checked as [addPaint] checks it, and to the Unit. It starts as wanted.
  Future<Paint> addNewUnitPaint(
    String collectionId,
    String unit, {
    required String brand,
    required String range,
    required String name,
    bool owned = false,
  }) async {
    final paint = await addPaint(
      brand: brand,
      range: range,
      name: name,
      owned: owned,
    );
    await addUnitPaint(collectionId, unit, paint.id);
    return paint;
  }

  Future<void> setUnitPaintNote(String id, String note) =>
      _store.updateUnitPaint(id, note: note.trim());

  Future<void> removeUnitPaint(String id) => _store.deleteUnitPaint(id);

  /// Copies the Paints and notes of Unit [from] in Collection [fromCollectionId] to Unit [to] in Collection
  /// [toCollectionId], skipping Paints it already uses.
  Future<void> copyUnitPaints({
    required String fromCollectionId,
    required String from,
    required String toCollectionId,
    required String to,
  }) async {
    final used = {
      for (final l in await _unitPaints(toCollectionId, to)) l.paint.id,
    };
    await _store.insertUnitPaints([
      for (final l in await _unitPaints(fromCollectionId, from))
        if (!used.contains(l.paint.id))
          UnitPaint(
            id: _newId(),
            collectionId: toCollectionId,
            unit: to,
            paint: l.paint,
            note: l.note,
          ),
    ]);
  }

  /// The Collection's Paint Schemes, by name, emitted again whenever they or their Step counts change.
  Stream<List<PaintScheme>> watchPaintSchemes(String collectionId) =>
      _store.watchPaintSchemes(collectionId);

  Future<PaintScheme> addPaintScheme(String collectionId, String name) async {
    final scheme = PaintScheme(
      id: _newId(),
      collectionId: collectionId,
      name: validName(name),
    );
    await _store.insertPaintScheme(scheme);
    return scheme;
  }

  Future<void> renamePaintScheme(String id, String name) =>
      _store.renamePaintScheme(id, validName(name));

  /// The Paint Schemes of Collections other than [collectionId], with their Collection, by name, emitted again
  /// whenever they or the Collections change. Schemes whose Collection has not synced are left out.
  Stream<List<({Collection collection, PaintScheme scheme})>>
  watchOtherPaintSchemes(String collectionId) => _combineLatest(
    [_store.watchAllPaintSchemes(), _store.watchCollections()],
    (latest) {
      final [schemes as List<PaintScheme>, collections as List<Collection>] =
          latest;
      final byId = {for (final c in collections) c.id: c};
      return [
        for (final s in schemes)
          if (s.collectionId != collectionId)
            if (byId[s.collectionId] case final c?) (collection: c, scheme: s),
      ];
    },
  );

  /// Starts a Paint Scheme in Collection [toCollectionId] as a copy of [from]: same name (names may repeat, as for a
  /// new one), and its Scheme Steps in order with their Paints, Technique and note. The copy has its own ids.
  Future<PaintScheme> copyPaintScheme(
    PaintScheme from,
    String toCollectionId,
  ) async {
    final steps = await watchSchemeSteps(from.id).first;
    final copy = await addPaintScheme(toCollectionId, from.name);
    // Stored as they are, not re-checked: a Step left empty by a deleted Paint is copied too.
    for (final s in steps) {
      await _store.insertSchemeStep(
        SchemeStep(
          id: _newId(),
          schemeId: copy.id,
          paints: s.paints,
          technique: s.technique,
          note: s.note,
        ),
      );
    }
    return copy;
  }

  /// Deletes the Paint Scheme and its Scheme Steps (not their Paints).
  Future<void> deletePaintScheme(String id) => _store.deletePaintScheme(id);

  /// How many Paint Schemes use each Paint, by Paint id, emitted again whenever that changes.
  Stream<Map<String, int>> watchPaintSchemeCounts() =>
      _store.watchSchemePaints().map((pairs) {
        final counts = <String, int>{};
        for (final p in pairs) {
          counts.update(p.paintId, (n) => n + 1, ifAbsent: () => 1);
        }
        return counts;
      });

  /// The Paint Scheme's Scheme Steps in order, emitted again whenever they change.
  Stream<List<SchemeStep>> watchSchemeSteps(String schemeId) =>
      _store.watchSchemeSteps(schemeId);

  /// The Techniques suggested before any is used.
  static const defaultTechniques = [
    'Basecoat',
    'Layer',
    'Wash',
    'Shade',
    'Drybrush',
    'Edge highlight',
    'Glaze',
    'Airbrush',
    'Contrast',
    'Stipple',
  ];

  /// The Techniques to suggest: [defaultTechniques], then the others used before, A–Z. Techniques written alike,
  /// ignoring case and outer spaces, are one, spelled as listed first.
  Future<List<String>> techniques() async =>
      _byKey([...defaultTechniques, ...await _store.allTechniques()]).values
          .toList();

  /// Appends a Scheme Step to the Paint Scheme, checked as [editSchemeStep] checks it.
  Future<SchemeStep> addSchemeStep(
    String schemeId, {
    Iterable<String> paintIds = const [],
    String technique = '',
    String note = '',
  }) async {
    final step = await _checkedStep(
      _newId(),
      schemeId,
      paintIds,
      technique,
      note,
    );
    await _store.insertSchemeStep(step);
    return step;
  }

  /// Sets [step]'s Paints (in the order given, each once), Technique (spelled as a known one if it matches, see
  /// [techniques]) and note, trimmed. Throws an [ArgumentError] if all three are empty, or a [StateError] if a Paint
  /// is not in the library.
  Future<void> editSchemeStep(
    SchemeStep step, {
    required Iterable<String> paintIds,
    required String technique,
    required String note,
  }) async => _store.updateSchemeStep(
    await _checkedStep(step.id, step.schemeId, paintIds, technique, note),
  );

  Future<SchemeStep> _checkedStep(
    String id,
    String schemeId,
    Iterable<String> paintIds,
    String technique,
    String note,
  ) async {
    final library = {for (final p in await _store.watchPaints().first) p.id: p};
    final paints = [
      for (final paintId in {...paintIds})
        library[paintId] ??
            (throw StateError('That Paint is not in your paints')),
    ];
    final typed = technique.trim();
    final known = typed.isEmpty
        ? ''
        : (await techniques()).firstWhere(
            (t) => tagKey(t) == tagKey(typed),
            orElse: () => typed,
          );
    if (paints.isEmpty && known.isEmpty && note.trim().isEmpty) {
      throw ArgumentError('A Scheme Step needs a Paint, a Technique or a note');
    }
    return SchemeStep(
      id: id,
      schemeId: schemeId,
      paints: paints,
      technique: known,
      note: note.trim(),
    );
  }

  /// Moves a Scheme Step to [index] (0 is first; clamped to the end) in its Paint Scheme's order.
  Future<void> moveSchemeStep(String schemeId, String stepId, int index) async {
    final order = [
      for (final s in await watchSchemeSteps(schemeId).first)
        if (s.id != stepId) s.id,
    ];
    order.insert(index.clamp(0, order.length), stepId);
    await _store.reorderSchemeSteps(order);
  }

  Future<void> deleteSchemeStep(String id) => _store.deleteSchemeStep(id);

  /// [paint] trimmed, with brand and range spelled as another Paint already spells them (ignoring case).
  Future<Paint> _checkedPaint(Paint paint) async {
    final others = (await _store.watchPaints().first).where(
      (p) => p.id != paint.id,
    );
    String known(String value, Iterable<String> used) =>
        used.where((u) => tagKey(u) == tagKey(value)).firstOrNull ?? value;
    final brand = known(validName(paint.brand), others.map((p) => p.brand));
    final sameBrand = others.where((p) => tagKey(p.brand) == tagKey(brand));
    final range = known(paint.range.trim(), sameBrand.map((p) => p.range));
    final name = validName(paint.name);
    final checked = Paint(
      id: paint.id,
      brand: brand,
      range: range,
      name: name,
      owned: paint.owned,
    );
    if (sameBrand.any(
      (p) => tagKey(p.range) == tagKey(range) && tagKey(p.name) == tagKey(name),
    )) {
      throw StateError('${checked.label} is already in your paints');
    }
    return checked;
  }

  /// The most Photos a Unit may be given. The write API enforces the same limit.
  static const maxPhotos = 10;

  /// The Unit's Photos, in the same order on every device, emitted again whenever they change.
  Stream<List<Photo>> watchPhotos(String collectionId, String unit) =>
      _store.watchPhotos(collectionId, unit);

  Future<List<Photo>> photosOf(String collectionId, String unit) =>
      watchPhotos(collectionId, unit).first;

  /// A Photo for a new image file on the Unit, not yet stored: the app stores it in the same transaction that
  /// queues its file for upload. Throws a [StateError] if the Unit already has [maxPhotos].
  Future<Photo> newPhoto(String collectionId, String unit) async {
    await _checkRoom(collectionId, unit, 1);
    return Photo(
      id: _newId(),
      collectionId: collectionId,
      unit: unit,
      fileId: _newId(),
    );
  }

  /// Attaches already stored image files to the Unit, e.g. another Unit's. A file the Unit already has is skipped.
  /// Throws a [StateError] if the Unit would get more than [maxPhotos].
  Future<List<Photo>> addPhotos(
    String collectionId,
    String unit,
    Iterable<String> fileIds,
  ) async {
    final has = {for (final p in await photosOf(collectionId, unit)) p.fileId};
    final photos = [
      for (final fileId in {...fileIds}.difference(has))
        Photo(
          id: _newId(),
          collectionId: collectionId,
          unit: unit,
          fileId: fileId,
        ),
    ];
    await _checkRoom(collectionId, unit, photos.length);
    if (photos.isNotEmpty) await _store.insertPhotos(photos);
    return photos;
  }

  /// Removes the Photo. The server deletes its file once no Photo points at it.
  Future<void> removePhoto(String id) => _store.deletePhoto(id);

  Future<void> _checkRoom(String collectionId, String unit, int adding) async {
    if ((await photosOf(collectionId, unit)).length + adding > maxPhotos) {
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

/// The id of [name] as a Tag on [owner], the Unit's [unitId] (or, for Tags uploaded by app versions before
/// ADR 0008, a Batch id): the same on every device, so two devices adding the same Tag to the same Unit offline write
/// the same row instead of a duplicate. The write API checks it.
String tagId(String owner, String name) => const Uuid().v5(owner, tagKey(name));

/// The id of Unit [name] in Collection [collectionId], the same on every device: its notes row's id, and the
/// namespace of its [tagId]s. The write API checks it.
String unitId(String collectionId, String name) =>
    const Uuid().v5(collectionId, name);

/// [notes] trimmed, without blank ones and repeats, one per line: how a Unit's notes combine with another's.
String joinNotes(Iterable<String> notes) =>
    {for (final n in notes) n.trim()}.where((n) => n.isNotEmpty).join('\n');

/// Throws an [ArgumentError] unless a Batch has at least one model. The server's database enforces the same rule.
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
