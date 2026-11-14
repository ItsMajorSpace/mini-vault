import 'package:domain_core/domain_core.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'main.dart';
import 'paints.dart';
import 'photos.dart';
import 'section.dart';
import 'theme.dart';
import 'workflows.dart';

String modelCountText(int n) => n == 1 ? '1 model' : '$n models';

/// The one place for a Unit: its Tags, then sections for every Stage of the Workflow in order with the Unit's model
/// count at each, its photos, notes, Paints and history.
class UnitScreen extends StatefulWidget {
  const UnitScreen({
    super.key,
    required this.vault,
    this.photos,
    required this.collection,
    required this.name,
  });

  final Vault vault;
  final PhotoFiles? photos;
  final Collection collection;

  /// The Unit's name when opened; the screen follows it through a rename.
  final String name;

  @override
  State<UnitScreen> createState() => _UnitScreenState();
}

class _UnitScreenState extends State<UnitScreen> {
  late var _units = widget.vault.watchUnits(widget.collection);
  // Listened to here, above the lazily built list: a list child scrolled out of view is disposed, and building it
  // again would listen to a single-subscription stream a second time.
  late final _library = widget.vault.watchPaints();
  late final _links = widget.vault.watchAllUnitPaints();
  late final _categories = widget.vault.watchCategories(widget.collection.id);
  late final _unitCategories = widget.vault.watchUnitCategories(
    widget.collection.id,
  );
  late String _name = widget.name;
  // The Unit's Tags, notes and history, followed through a rename.
  late var _tags = widget.vault.watchTags(widget.collection.id, _name);
  late var _notes = widget.vault.watchNotes(widget.collection.id, _name);
  late var _history = widget.vault.watchUnitHistory(
    widget.collection.id,
    _name,
  );

  /// Edits the Unit's name, Category, notes and Tags, writing only what changed so edits elsewhere are kept.
  Future<void> _edit(
    Unit unit,
    List<String> tags,
    String notes,
    List<Category> categories,
    String? categoryId,
  ) async {
    final result = await showDialog<UnitFields>(
      context: context,
      builder: (_) => UnitDialog(
        title: 'Edit Unit',
        name: unit.name,
        notes: notes,
        tags: tags,
        categories: categories,
        categoryId: categoryId,
        suggestTags: widget.vault.suggestTags,
      ),
    );
    if (result == null || !mounted) return;
    final (vault, collectionId) = (widget.vault, widget.collection.id);
    await attempt(context, () async {
      final kept = {for (final t in result.tags) tagKey(t)};
      for (final t in tags.where((t) => !kept.contains(tagKey(t)))) {
        await vault.removeTag(collectionId, unit.name, t);
      }
      await vault.addTags(collectionId, unit.name, result.tags);
      if (result.notes != notes) {
        await vault.setNotes(collectionId, unit.name, result.notes);
      }
      final category = switch (result.newCategory) {
        final name? => (await vault.addCategory(collectionId, name)).id,
        null => result.categoryId,
      };
      if (category != categoryId) {
        await vault.setUnitCategory(collectionId, unit.name, category);
      }
      // Last: a rename carries the notes and Tags just saved along.
      if (result.name == unit.name) return;
      await vault.renameUnit(unit, result.name);
      if (mounted) {
        setState(() {
          _name = result.name;
          _tags = vault.watchTags(collectionId, _name);
          _notes = vault.watchNotes(collectionId, _name);
          _history = vault.watchUnitHistory(collectionId, _name);
        });
      }
    });
  }

  /// Asks first, saying how many models go; back to the Collection once deleted.
  Future<void> _delete(Unit unit) async {
    final confirmed = await confirmDeleteModels(
      context,
      'Delete ${unit.name}?',
      unit.modelCount,
    );
    if (!confirmed || !mounted) return;
    await attempt(context, () async {
      for (final b in unit.batches) {
        await widget.vault.deleteBatch(b.id);
      }
    });
    if (mounted) Navigator.pop(context);
  }

  /// Sets how many of the Unit's models are at one Stage, without moving any: a recount of the Batch there or, once
  /// confirmed, deleting it when set to 0.
  Future<void> _recount(StageGroup g) async {
    final count = TextEditingController(text: '${g.modelCount}');
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Models at ${g.stage.name}'),
        content: TextField(
          controller: count,
          autofocus: true,
          keyboardType: TextInputType.number,
          // Digits only: no signs, so no negative counts.
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onSubmitted: (_) => Navigator.pop(context, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    // Not disposed: the closing dialog's TextField still uses it.
    final n = int.tryParse(count.text);
    if (save != true || n == null || n == g.modelCount || !mounted) return;
    // A Stage has one Batch, bar a moment after sync before the automatic Merge (ADR 0009).
    final batch = g.batches.first;
    if (n > 0) {
      return attempt(
        context,
        () => widget.vault.editBatch(batch.id, modelCount: n),
      );
    }
    final confirmed = await confirmDeleteModels(
      context,
      'Delete the models at ${g.stage.name}?',
      batch.modelCount,
    );
    if (confirmed && mounted) {
      await attempt(context, () => widget.vault.deleteBatch(batch.id));
    }
  }

  Future<void> _sheet(Unit unit, StageGroup g) => showMoveSheet(
    context,
    widget.vault,
    widget.collection,
    unit.name,
    [for (final s in unit.stages) s.stage],
    g,
    onRecount: () => _recount(g),
  );

  @override
  Widget build(BuildContext context) => StreamBuilder(
    stream: _library,
    builder: (context, library) => StreamBuilder(
      stream: _links,
      builder: (context, links) => StreamBuilder(
        stream: _categories,
        builder: (context, categories) => StreamBuilder(
          stream: _unitCategories,
          builder: (context, unitCategories) => StreamBuilder(
            stream: _tags,
            builder: (context, tags) => StreamBuilder(
              stream: _notes,
              builder: (context, notes) => StreamBuilder(
                stream: _history,
                builder: (context, history) => _build(
                  context,
                  library.data,
                  links.data,
                  tags.data ?? const [],
                  notes.data ?? '',
                  history.data ?? const [],
                  categories.data ?? const [],
                  unitCategories.data ?? const {},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _build(
    BuildContext context,
    List<Paint>? library,
    List<({Collection collection, UnitPaint link})>? links,
    List<String> tags,
    String notes,
    List<StageChange> history,
    List<Category> categories,
    Map<String, String> unitCategories,
  ) {
    final theme = Theme.of(context);
    // None while its Category is not synced yet, as on the Collection screen.
    final category = categories
        .where((c) => c.id == unitCategories[_name])
        .firstOrNull;
    return StreamBuilder(
      stream: _units,
      builder: (context, snapshot) {
        final unit = snapshot.data?.where((s) => s.name == _name).firstOrNull;
        String stageName(String? id) =>
            unit?.stages
                .where((g) => g.stage.id == id)
                .firstOrNull
                ?.stage
                .name ??
            'a deleted Stage';
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_name),
                if (unit != null)
                  Text(
                    '${widget.collection.name} · ${modelCountText(unit.modelCount)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            actions: [
              if (unit != null) ...[
                IconButton(
                  icon: const Icon(Icons.edit),
                  tooltip: 'Edit Unit',
                  onPressed: () =>
                      _edit(unit, tags, notes, categories, category?.id),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete Unit',
                  onPressed: () => _delete(unit),
                ),
              ],
            ],
          ),
          body: switch (snapshot) {
            AsyncSnapshot(:final error?) => LoadError(
              what: 'the Unit',
              error: error,
              onRetry: () => setState(
                () => _units = widget.vault.watchUnits(widget.collection),
              ),
            ),
            AsyncSnapshot(data: null) => const Center(
              child: CircularProgressIndicator(),
            ),
            _ when unit == null => const Center(
              child: Text('This Unit has no models left'),
            ),
            _ => ListView(
              // Room below the last section for the FAB.
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                // The Tags describe the whole Unit: above every section.
                if (tags.isNotEmpty || category != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (category != null)
                          Semantics(
                            label: 'Category ${category.name}',
                            excludeSemantics: true,
                            child: Chip(
                              avatar: Icon(
                                Icons.category,
                                color: theme.colorScheme.primary,
                              ),
                              label: Text(category.name),
                              labelStyle: TextStyle(
                                color: theme.colorScheme.primary,
                              ),
                              side: BorderSide(
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        for (final t in tags)
                          Chip(
                            label: Text(t),
                            backgroundColor:
                                theme.colorScheme.surfaceContainerHigh,
                            side: BorderSide.none,
                          ),
                      ],
                    ),
                  ),
                Section(
                  title: 'Models',
                  count: unit.modelCount,
                  child: sectionRows(context, [
                    for (final g in unit.stages)
                      // Empty Stages stay in Workflow order, dimmed, with nothing to move.
                      Opacity(
                        opacity: g.modelCount == 0 ? 0.38 : 1,
                        child: ListTile(
                          leading: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: stageColour(g.stage.colour),
                              shape: BoxShape.circle,
                              border: stageOutline(context),
                            ),
                          ),
                          title: Text(g.stage.name),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(modelCountText(g.modelCount)),
                              if (g.modelCount > 0)
                                Icon(
                                  Icons.chevron_right,
                                  size: 20,
                                  color: theme.colorScheme.outline,
                                ),
                            ],
                          ),
                          onTap: g.modelCount == 0
                              ? null
                              : () => _sheet(unit, g),
                        ),
                      ),
                  ]),
                ),
                if (widget.photos case final photos?)
                  UnitPhotos(
                    vault: widget.vault,
                    files: photos,
                    collectionId: widget.collection.id,
                    unit: _name,
                  ),
                Section(
                  title: 'Notes',
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.edit_note),
                      tooltip: 'Edit notes',
                      onPressed: () =>
                          _edit(unit, tags, notes, categories, category?.id),
                    ),
                  ],
                  child: InkWell(
                    onTap: () =>
                        _edit(unit, tags, notes, categories, category?.id),
                    child: notes.isEmpty
                        ? const SectionHint('No notes yet')
                        : Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            child: Text(notes),
                          ),
                  ),
                ),
                if (library != null && links != null)
                  _UnitPaints(
                    vault: widget.vault,
                    collection: widget.collection,
                    name: _name,
                    library: library,
                    links: links,
                  ),
                Section(
                  title: 'History',
                  child: history.isEmpty
                      ? const SectionHint('No history yet')
                      : sectionRows(context, [
                          for (final c in history)
                            ListTile(
                              title: Text(
                                c.fromStageId == null
                                    ? '${modelCountText(c.modelCount)} added at ${stageName(c.toStageId)}'
                                    : '${modelCountText(c.modelCount)} ${stageName(c.fromStageId)} → ${stageName(c.toStageId)}',
                              ),
                              subtitle: Text(
                                MaterialLocalizations.of(
                                  context,
                                ).formatShortMonthDay(c.happenedAt.toLocal()),
                              ),
                            ),
                        ]),
                ),
              ],
            ),
          },
          floatingActionButton: snapshot.data == null
              ? null
              : FloatingActionButton(
                  onPressed: () => addModels(
                    context,
                    widget.vault,
                    widget.collection,
                    [for (final s in snapshot.data!) s.name],
                    name: _name,
                  ),
                  tooltip: 'Add models',
                  child: const Icon(Icons.add),
                ),
        );
      },
    );
  }
}

/// Asks whether to delete [models] models, titled [title]; true only once confirmed.
Future<bool> confirmDeleteModels(
  BuildContext context,
  String title,
  int models,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(
          '${modelCountText(models)} and their history will be deleted on all your devices.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: destructive(context),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ??
    false;

/// Says what was just done, offering to [undo] it, itself a normal Vault operation.
void showUndo(
  BuildContext context,
  String message,
  Future<void> Function() undo,
) => ScaffoldMessenger.of(context).showSnackBar(
  SnackBar(
    content: Text(message),
    // A SnackBar with an action stays up until dismissed by default; an old Undo should not linger.
    persist: false,
    action: SnackBarAction(
      label: 'Undo',
      onPressed: () => attempt(context, undo),
    ),
  ),
);

/// The Move sheet for a Stage of the Unit [name] with models, [stages] being its Workflow's: how many to move and
/// where, or recount them ([onRecount], null to disable).
Future<void> showMoveSheet(
  BuildContext context,
  Vault vault,
  Collection collection,
  String name,
  List<Stage> stages,
  StageGroup from, {
  VoidCallback? onRecount,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _MoveSheet(
    from: from,
    stages: stages,
    onMove: (n, to) => attempt(context, () async {
      await vault.moveModels(collection, name, from.stage.id, to.id, n);
      if (context.mounted) {
        showUndo(
          context,
          'Moved ${modelCountText(n)} to ${to.name}',
          () => vault.moveModels(collection, name, to.id, from.stage.id, n),
        );
      }
    }),
    onRecount: onRecount,
  ),
);

/// Moves [from]'s models: a count from 1 to all of them, all to start with, and a target Stage, the next one to start
/// with.
class _MoveSheet extends StatefulWidget {
  const _MoveSheet({
    required this.from,
    required this.stages,
    required this.onMove,
    required this.onRecount,
  });

  final StageGroup from;

  /// The Workflow's Stages, in order.
  final List<Stage> stages;
  final void Function(int count, Stage to) onMove;
  final VoidCallback? onRecount;

  @override
  State<_MoveSheet> createState() => _MoveSheetState();
}

class _MoveSheetState extends State<_MoveSheet> {
  late int _count = widget.from.modelCount;
  late Stage? _to = () {
    final i = widget.stages.indexWhere((s) => s.id == widget.from.stage.id);
    // The last Stage has no next one: preselect the one before it.
    return widget.stages.elementAtOrNull(i + 1) ??
        widget.stages.elementAtOrNull(i - 1);
  }();

  /// Closes the sheet, then acts on the screen beneath it.
  VoidCallback _then(VoidCallback action) => () {
    Navigator.pop(context);
    action();
  };

  @override
  Widget build(BuildContext context) {
    final all = widget.from.modelCount;
    final to = _to;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Move from ${widget.from.stage.name}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.remove),
                  tooltip: 'One fewer',
                  onPressed: _count > 1 ? () => setState(() => _count--) : null,
                ),
                Text(
                  '$_count of $all',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: 'One more',
                  onPressed: _count < all
                      ? () => setState(() => _count++)
                      : null,
                ),
                const Spacer(),
                TextButton(
                  onPressed: _count < all
                      ? () => setState(() => _count = all)
                      : null,
                  child: const Text('All'),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final s in widget.stages)
                  if (s.id != widget.from.stage.id)
                    ChoiceChip(
                      label: Text(s.name),
                      selected: s.id == to?.id,
                      onSelected: (_) => setState(() => _to = s),
                    ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: widget.onRecount == null
                    ? null
                    : _then(widget.onRecount!),
                child: const Text('Edit count'),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
              ),
              onPressed: to == null
                  ? null
                  : _then(() => widget.onMove(_count, to)),
              child: Text(
                to == null
                    ? 'Move'
                    : 'Move ${modelCountText(_count)} to ${to.name}',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The Unit's Paints section, from the paint [library] and every Unit's Paint [links].
class _UnitPaints extends StatefulWidget {
  const _UnitPaints({
    required this.vault,
    required this.collection,
    required this.name,
    required this.library,
    required this.links,
  });

  final Vault vault;
  final Collection collection;
  final String name;
  final List<Paint> library;
  final List<({Collection collection, UnitPaint link})> links;

  @override
  State<_UnitPaints> createState() => _UnitPaintsState();
}

class _UnitPaintsState extends State<_UnitPaints> {
  @override
  Widget build(BuildContext context) => _paints(widget.library, widget.links);

  /// The Unit's Paints, with their notes and the wanted ones marked, and actions to add, copy, edit and remove them.
  Widget _paints(
    List<Paint> library,
    List<({Collection collection, UnitPaint link})> all,
  ) {
    final used = [
      for (final (:collection, :link) in all)
        if (collection.id == widget.collection.id && link.unit == widget.name)
          link,
    ];
    final others = [
      for (final s in paintedUnits(all))
        if (s.collection.id != widget.collection.id || s.unit != widget.name) s,
    ];
    return Section(
      title: 'Paints',
      count: used.length,
      actions: [
        if (others.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.content_copy),
            tooltip: 'Copy Paints from another Unit',
            onPressed: () => _copyPaints(others),
          ),
        IconButton(
          icon: const Icon(Icons.add),
          tooltip: 'Add Paint',
          onPressed: () => _addPaint(library, used),
        ),
      ],
      child: used.isEmpty
          ? const SectionHint('No Paints yet')
          : sectionRows(context, [
              for (final l in used)
                ListTile(
                  key: ValueKey(l.id),
                  title: Text(l.paint.name),
                  subtitle: Text(
                    [
                      [
                        l.paint.brand,
                        if (l.paint.range.isNotEmpty) l.paint.range,
                      ].join(' / '),
                      if (l.note.isNotEmpty) l.note,
                      if (!l.paint.owned) 'Wanted',
                    ].join(' · '),
                  ),
                  onTap: () => _editNote(l),
                  trailing: IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    tooltip: 'Remove Paint',
                    onPressed: () => attempt(context, () async {
                      await widget.vault.removeUnitPaint(l.id);
                      if (mounted) {
                        showUndo(
                          context,
                          'Removed ${l.paint.name}',
                          () => widget.vault.addUnitPaint(
                            l.collectionId,
                            l.unit,
                            l.paint.id,
                            note: l.note,
                          ),
                        );
                      }
                    }),
                  ),
                ),
            ]),
    );
  }

  /// Picks a Paint from the library that the Unit does not use yet, or creates one, wanted to start with.
  Future<void> _addPaint(List<Paint> library, List<UnitPaint> used) async {
    final usedIds = {for (final l in used) l.paint.id};
    final picked = await showDialog<Object>(
      context: context,
      builder: (_) => AddPaintDialog(
        paints: [
          for (final p in library)
            if (!usedIds.contains(p.id)) p,
        ],
      ),
    );
    if (!mounted) return;
    if (picked is Paint) {
      return attempt(
        context,
        () => widget.vault.addUnitPaint(
          widget.collection.id,
          widget.name,
          picked.id,
        ),
      );
    }
    if (picked is! String) return;
    final fields = await showDialog<PaintFields>(
      context: context,
      builder: (_) => PaintDialog(paints: library, name: picked, owned: false),
    );
    if (fields == null || !mounted) return;
    final (:brand, :range, :name, :owned) = fields;
    await attempt(
      context,
      () => widget.vault.addNewUnitPaint(
        widget.collection.id,
        widget.name,
        brand: brand,
        range: range,
        name: name,
        owned: owned,
      ),
    );
  }

  Future<void> _copyPaints(
    List<({Collection collection, String unit})> others,
  ) async {
    final from = await showDialog<({Collection collection, String unit})>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Copy Paints from'),
        children: [
          for (final s in others)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, s),
              child: Text('${s.unit} · ${s.collection.name}'),
            ),
        ],
      ),
    );
    if (from == null || !mounted) return;
    await attempt(
      context,
      () => widget.vault.copyUnitPaints(
        fromCollectionId: from.collection.id,
        from: from.unit,
        toCollectionId: widget.collection.id,
        to: widget.name,
      ),
    );
  }

  Future<void> _editNote(UnitPaint link) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => NameDialog(
        title: 'Note for ${link.paint.name}',
        initial: link.note,
        label: 'Where or how',
      ),
    );
    if (note == null || !mounted) return;
    await attempt(context, () => widget.vault.setUnitPaintNote(link.id, note));
  }
}
