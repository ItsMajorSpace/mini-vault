/// The Workflow editor: the list of Workflows, and one Workflow's Stages.
library;

import 'dart:math';

import 'package:domain_core/domain_core.dart';
import 'package:flutter/semantics.dart';
import 'package:material_ui/material_ui.dart';

import 'section.dart';
import 'stage_strip.dart';
import 'theme.dart';
import 'unit.dart' show showUndo;

/// Runs a Vault operation, showing a refusal (an [ArgumentError] or [StateError]) as a snack bar.
Future<void> attempt(BuildContext context, Future<void> Function() op) async {
  try {
    await op();
  } on Error catch (e) {
    final message = switch (e) {
      ArgumentError(:final message) => '$message',
      StateError(:final message) => message,
      _ => throw e,
    };
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

/// Asks for a name; null if cancelled or blank.
Future<String?> askName(
  BuildContext context,
  String title, [
  String initial = '',
]) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => NameDialog(title: title, initial: initial),
  );
  return (name == null || name.trim().isEmpty) ? null : name;
}

/// Every Workflow as a card: its Stages, and the Collections using it.
class WorkflowsScreen extends StatefulWidget {
  const WorkflowsScreen({super.key, required this.vault});

  final Vault vault;

  @override
  State<WorkflowsScreen> createState() => _WorkflowsScreenState();
}

class _WorkflowsScreenState extends State<WorkflowsScreen> {
  late final _workflows = widget.vault.watchWorkflows();
  late final _collections = widget.vault.watchCollections();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Workflows')),
      body: StreamBuilder(
        stream: _workflows,
        builder: (context, workflows) => StreamBuilder(
          stream: _collections,
          builder: (context, collections) {
            if (workflows.data == null || collections.data == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return ListView(
              padding: const EdgeInsets.only(top: 4, bottom: 88),
              children: [
                // The first Workflow is the starter, or stands in for it (see Vault.starterWorkflow).
                for (final (i, w) in workflows.data!.indexed)
                  _WorkflowCard(
                    vault: widget.vault,
                    workflow: w,
                    starter: i == 0,
                    usedBy: [
                      for (final c in collections.data!)
                        if (c.workflowId == w.id) c,
                    ],
                  ),
              ],
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        tooltip: 'New Workflow',
        icon: const Icon(Icons.add),
        label: const Text('New Workflow'),
        onPressed: () async {
          final name = await askName(context, 'New Workflow');
          if (name != null && context.mounted) {
            await attempt(context, () => widget.vault.createWorkflow(name));
          }
        },
      ),
    );
  }
}

enum _WorkflowAction { rename, delete }

/// A Workflow's name, [StageStrip], Stage range and the Collections using it; tap to edit its Stages.
class _WorkflowCard extends StatelessWidget {
  const _WorkflowCard({
    required this.vault,
    required this.workflow,
    required this.starter,
    required this.usedBy,
  });

  final Vault vault;
  final Workflow workflow;
  final bool starter;
  final List<Collection> usedBy;

  Future<void> _onMenu(BuildContext context, _WorkflowAction action) async {
    switch (action) {
      case _WorkflowAction.rename:
        final name = await askName(context, 'Rename Workflow', workflow.name);
        if (name != null && context.mounted) {
          await attempt(context, () => vault.renameWorkflow(workflow.id, name));
        }
      case _WorkflowAction.delete:
        await attempt(context, () => vault.deleteWorkflow(workflow.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colours = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colours.onSurfaceVariant,
    );
    final stages = workflow.stages;
    final n = usedBy.length;
    return Card.filled(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      clipBehavior: Clip.antiAlias,
      color: colours.surfaceContainerLow,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) =>
                WorkflowScreen(vault: vault, workflowId: workflow.id),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 4, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: [
                    Row(
                      spacing: 8,
                      children: [
                        Flexible(
                          child: Text(
                            workflow.name,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        if (starter)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(color: colours.primary),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'Starter',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colours.primary,
                              ),
                            ),
                          ),
                      ],
                    ),
                    StageStrip(workflow),
                    Text(
                      '${stages.length} ${stages.length == 1 ? 'Stage' : 'Stages'}'
                      '${stages.isEmpty ? '' : ' · ${stages.first.name} → ${stages.last.name}'}',
                      style: muted,
                    ),
                    if (usedBy.isEmpty)
                      Text(
                        'Not used by any Collection',
                        style: muted?.copyWith(fontStyle: FontStyle.italic),
                      )
                    else
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final c in usedBy)
                            Chip(
                              avatar: const Icon(Icons.inventory_2),
                              label: Text(c.name),
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),
                  ],
                ),
              ),
              PopupMenuButton<_WorkflowAction>(
                tooltip: 'Workflow actions for ${workflow.name}',
                onSelected: (action) => _onMenu(context, action),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: _WorkflowAction.rename,
                    child: Text('Rename'),
                  ),
                  // Disabled while in use, so nobody taps into the Vault's refusal.
                  PopupMenuItem(
                    value: _WorkflowAction.delete,
                    enabled: usedBy.isEmpty,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      enabled: usedBy.isEmpty,
                      title: const Text('Delete'),
                      subtitle: usedBy.isEmpty
                          ? null
                          : Text(
                              'Used by $n ${n == 1 ? 'Collection' : 'Collections'}',
                            ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One Workflow's Stages in Wanted / Owned / Finished zones: drag Stages to reorder and the zone markers to set the
/// Owned and Finished Stages; tap a Stage for its sheet.
class WorkflowScreen extends StatefulWidget {
  const WorkflowScreen({
    super.key,
    required this.vault,
    required this.workflowId,
  });

  final Vault vault;
  final String workflowId;

  @override
  State<WorkflowScreen> createState() => _WorkflowScreenState();
}

class _WorkflowScreenState extends State<WorkflowScreen> {
  late final _workflows = widget.vault.watchWorkflows();
  late final _collections = widget.vault.watchCollections();

  Vault get vault => widget.vault;
  String get id => widget.workflowId;

  /// Makes [to] the Owned or Finished Stage, offering Undo; refused if [to] is null (no Stage there).
  Future<void> _setBoundary(Workflow w, _Boundary b, Stage? to) =>
      attempt(context, () async {
        if (to == null) throw StateError('No Stage there');
        final finished = b == _Boundary.finished;
        final from = finished ? w.finishedStage : w.ownedStage;
        if (to.id == from.id) return;
        Future<void> set(Stage s) => finished
            ? vault.setFinishedStage(id, s.id)
            : vault.setOwnedStage(id, s.id);
        await set(to);
        if (mounted) {
          showUndo(
            context,
            '${finished ? 'Finished' : 'Owned'} from ${to.name}',
            () => set(from),
          );
        }
      });

  /// Moves a Stage, or drops a marker so the Stage right below it becomes the Owned or Finished Stage.
  Future<void> _onReorder(Workflow w, List<Object> rows, int from, int to) {
    final moved = [...rows];
    final item = moved.removeAt(from);
    moved.insert(to, item);
    return switch (item) {
      Stage s => attempt(
        context,
        () =>
            vault.moveStage(id, s.id, moved.take(to).whereType<Stage>().length),
      ),
      _Boundary b => _setBoundary(
        w,
        b,
        moved.skip(to).whereType<Stage>().firstOrNull,
      ),
      _ => throw StateError('Unknown row $item'),
    };
  }

  Future<void> _addStage(int index) async {
    final name = await askName(context, 'New Stage');
    if (name != null && mounted) {
      await attempt(context, () => vault.addStage(id, name, index));
    }
  }

  /// The Stage sheet; Save commits the name, colour and Owned/Finished switches together.
  Future<void> _openSheet(Workflow w, Stage stage, int index) async {
    final edit = await showModalBottomSheet<_StageEdit>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _StageSheet(
        workflow: w,
        stage: stage,
        onAddAbove: () => _addStage(index),
        onAddBelow: () => _addStage(index + 1),
        onDelete: () => _deleteStage(stage),
      ),
    );
    if (edit == null || !mounted) return;
    await attempt(context, () async {
      if (edit.name != stage.name) {
        await vault.renameStage(stage.id, edit.name);
      }
      if (edit.colour != stage.colour) {
        await vault.setStageColour(stage.id, edit.colour);
      }
    });
    final saved = Stage(id: stage.id, name: edit.name, colour: edit.colour);
    if (edit.owned) await _setBoundary(w, _Boundary.owned, saved);
    if (edit.finished) await _setBoundary(w, _Boundary.finished, saved);
  }

  /// Deletes the Stage, first asking where its Batches go and which Stage replaces it as Owned or Finished, if needed.
  Future<void> _deleteStage(Stage stage) async {
    final workflow = (await vault.workflows()).firstWhere((w) => w.id == id);
    final batches = await vault.batchesAt(stage.id);
    final inUse = {for (final b in batches) b.collectionId};
    final affected = [
      for (final c in await vault.collections())
        if (inUse.contains(c.id)) c.name,
    ]..sort();
    final owned = stage.id == workflow.ownedStage.id;
    final finished = stage.id == workflow.finishedStage.id;
    if (!mounted) return;
    if ((batches.isEmpty && !owned && !finished) ||
        workflow.stages.length == 1) {
      return attempt(context, () => vault.deleteStage(id, stage.id));
    }
    final choice = await showDialog<_DeleteChoice>(
      context: context,
      builder: (_) => _DeleteStageDialog(
        workflow: workflow,
        stage: stage,
        held: batches.length,
        affected: affected,
      ),
    );
    if (choice == null || !mounted) return;
    await attempt(
      context,
      () => vault.deleteStage(
        id,
        stage.id,
        moveBatchesTo: choice.destination,
        ownedStageId: choice.owned,
        finishedStageId: choice.finished,
      ),
    );
  }

  /// The used-by strip, then the Stages in Wanted / Owned / Finished zones split by the two markers.
  Widget _stages(BuildContext context, Workflow w, List<String> usedBy) {
    final theme = Theme.of(context);
    final colours = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colours.onSurfaceVariant,
    );
    final stages = w.stages;
    final owned = stages.indexWhere((s) => s.id == w.ownedStage.id);
    final finished = stages.indexWhere((s) => s.id == w.finishedStage.id);
    // Stages, with each marker right above the Stage it starts at.
    final rows = <Object>[
      for (final (i, s) in stages.indexed) ...[
        if (i == owned) _Boundary.owned,
        if (i == finished) _Boundary.finished,
        s,
      ],
    ];
    final n = usedBy.length;
    return ReorderableListView(
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.only(bottom: 88),
      onReorderItem: (from, to) => _onReorder(w, rows, from, to),
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (n > 0)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colours.surfaceContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 10,
                children: [
                  Icon(Icons.info, size: 20, color: colours.primary),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        style: muted,
                        children: [
                          const TextSpan(text: 'Used by '),
                          for (final (i, name) in usedBy.indexed) ...[
                            if (i > 0)
                              TextSpan(text: i == n - 1 ? ' and ' : ', '),
                            TextSpan(
                              text: name,
                              style: TextStyle(color: colours.onSurface),
                            ),
                          ],
                          TextSpan(
                            text:
                                '. Changes apply to ${switch (n) {
                                  1 => 'it',
                                  2 => 'both',
                                  _ => 'all $n',
                                }}.',
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          SizedBox(
            height: 40,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                spacing: 8,
                children: [
                  Text(
                    'WANTED',
                    style: heading(context)?.copyWith(letterSpacing: 1.2),
                  ),
                  Text('not yet owned', style: muted),
                ],
              ),
            ),
          ),
          if (owned == 0)
            _ZoneCard(
              zone: _Zone.wanted,
              first: true,
              last: true,
              child: const SectionHint('No Wanted Stages'),
            ),
        ],
      ),
      children: [
        for (final (i, row) in rows.indexed)
          switch (row) {
            Stage s => _stageRow(context, w, s, i, owned, finished),
            _Boundary b => _ZoneMarker(
              key: ValueKey(b.name),
              boundary: b,
              index: i,
              // Owned and Finished at one Stage: the Owned zone between the stacked markers is empty.
              empty: b == _Boundary.owned && owned == finished,
              onMove: (by) {
                final at = (b == _Boundary.owned ? owned : finished) + by;
                _setBoundary(
                  w,
                  b,
                  at >= 0 && at < stages.length ? stages[at] : null,
                );
              },
            ),
            _ => throw StateError('Unknown row $row'),
          },
      ],
    );
  }

  /// A Stage in its zone card: colour swatch, name and drag handle; tap for its sheet.
  Widget _stageRow(
    BuildContext context,
    Workflow w,
    Stage stage,
    int row,
    int owned,
    int finished,
  ) {
    final i = w.stages.indexOf(stage);
    bool starts(int at) => at == 0 || at == owned || at == finished;
    return _ZoneCard(
      key: ValueKey(stage.id),
      zone: i < owned
          ? _Zone.wanted
          : i < finished
          ? _Zone.owned
          : _Zone.finished,
      first: starts(i),
      last: i == w.stages.length - 1 || starts(i + 1),
      child: ListTile(
        onTap: () => _openSheet(w, stage, i),
        contentPadding: const EdgeInsets.only(left: 14),
        leading: Container(
          key: ValueKey('swatch:${stage.id}'),
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: stageColour(stage.colour),
            shape: BoxShape.circle,
          ),
        ),
        title: Text(stage.name),
        trailing: ReorderableDragStartListener(
          index: row,
          child: SizedBox.square(
            dimension: 48,
            child: Icon(
              Icons.drag_handle,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: _workflows,
      builder: (context, snapshot) {
        final workflow = snapshot.data?.where((w) => w.id == id).firstOrNull;
        if (workflow == null) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: snapshot.hasData
                  ? const Text('This Workflow was deleted')
                  : const CircularProgressIndicator(),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(workflow.name),
            actions: [
              IconButton(
                icon: const Icon(Icons.edit),
                tooltip: 'Rename Workflow',
                onPressed: () async {
                  final name = await askName(
                    context,
                    'Rename Workflow',
                    workflow.name,
                  );
                  if (name != null && context.mounted) {
                    await attempt(
                      context,
                      () => vault.renameWorkflow(id, name),
                    );
                  }
                },
              ),
            ],
          ),
          body: StreamBuilder(
            stream: _collections,
            builder: (context, collections) => _stages(context, workflow, [
              for (final c in collections.data ?? <Collection>[])
                if (c.workflowId == id) c.name,
            ]),
          ),
          floatingActionButton: FloatingActionButton.extended(
            tooltip: 'New Stage',
            icon: const Icon(Icons.add),
            label: const Text('New Stage'),
            onPressed: () => _addStage(workflow.stages.length),
          ),
        );
      },
    );
  }
}

/// Where the Owned or Finished zone begins.
enum _Boundary { owned, finished }

enum _Zone { wanted, owned, finished }

_Zone _zoneOf(Workflow w, Stage s) {
  final i = w.stages.indexOf(s);
  return i < w.stages.indexOf(w.ownedStage)
      ? _Zone.wanted
      : i < w.stages.indexOf(w.finishedStage)
      ? _Zone.owned
      : _Zone.finished;
}

/// A Stage's colour as a dot.
Widget _dot(Stage s, [double size = 16]) => Container(
  width: size,
  height: size,
  decoration: BoxDecoration(
    color: stageColour(s.colour),
    shape: BoxShape.circle,
  ),
);

/// One row of a zone's card: rounded at the zone's [first] and [last] row, with a left rail (outline = Wanted,
/// half accent = Owned, accent = Finished) and a hairline between rows.
class _ZoneCard extends StatelessWidget {
  const _ZoneCard({
    super.key,
    required this.zone,
    required this.first,
    required this.last,
    required this.child,
  });

  final _Zone zone;
  final bool first;
  final bool last;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colours = Theme.of(context).colorScheme;
    const r = Radius.circular(12);
    // shortcut: a solid outline rail stands in for the mockup's dashed Wanted rail; draw dashes if it reads unclear.
    final rail = switch (zone) {
      _Zone.wanted => colours.outline,
      _Zone.owned => Color.lerp(
        colours.primary,
        colours.surfaceContainerLow,
        0.45,
      )!,
      _Zone.finished => colours.primary,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.vertical(
          top: first ? r : Radius.zero,
          bottom: last ? r : Radius.zero,
        ),
        child: Material(
          color: zone == _Zone.wanted
              ? colours.surfaceContainerLowest
              : colours.surfaceContainerLow,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: rail, width: 4),
                top: first
                    ? BorderSide.none
                    : BorderSide(color: colours.outlineVariant, width: 0.5),
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// A draggable boundary between zones, "Owned from here" or "Finished from here"; [onMove] moves it by a Stage
/// (the semantics actions). [empty] adds the hint for an empty Owned zone below it.
class _ZoneMarker extends StatelessWidget {
  const _ZoneMarker({
    super.key,
    required this.boundary,
    required this.index,
    required this.empty,
    required this.onMove,
  });

  final _Boundary boundary;
  final int index;
  final bool empty;
  final void Function(int by) onMove;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final finished = boundary == _Boundary.finished;
    return Semantics(
      container: true,
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Move up a Stage'): () => onMove(-1),
        const CustomSemanticsAction(label: 'Move down a Stage'): () =>
            onMove(1),
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 48,
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            padding: const EdgeInsets.only(left: 12),
            decoration: ShapeDecoration(
              color: accent.withValues(alpha: 0.12),
              shape: StadiumBorder(side: BorderSide(color: accent, width: 1.5)),
            ),
            child: Row(
              spacing: 8,
              children: [
                Icon(
                  finished ? Icons.military_tech : Icons.flag,
                  size: 20,
                  color: accent,
                ),
                Expanded(
                  child: Text(
                    finished ? 'FINISHED FROM HERE' : 'OWNED FROM HERE',
                    style: heading(context)
                        ?.copyWith(color: accent, letterSpacing: 1),
                  ),
                ),
                ReorderableDragStartListener(
                  index: index,
                  child: SizedBox.square(
                    dimension: 48,
                    child: Icon(Icons.drag_indicator, color: accent),
                  ),
                ),
              ],
            ),
          ),
          if (empty) const SectionHint('Finished as soon as owned'),
        ],
      ),
    );
  }
}

typedef _StageEdit = ({String name, String colour, bool owned, bool finished});

/// A Stage's name, colour from [Vault.stageColours], Owned/Finished switches, add above/below and delete; pops a
/// [_StageEdit] on Save.
class _StageSheet extends StatefulWidget {
  const _StageSheet({
    required this.workflow,
    required this.stage,
    required this.onAddAbove,
    required this.onAddBelow,
    required this.onDelete,
  });

  final Workflow workflow;
  final Stage stage;
  final VoidCallback onAddAbove;
  final VoidCallback onAddBelow;
  final VoidCallback onDelete;

  @override
  State<_StageSheet> createState() => _StageSheetState();
}

class _StageSheetState extends State<_StageSheet> {
  late final _name = TextEditingController(text: widget.stage.name);
  late String _colour = widget.stage.colour;
  late bool _owned = _isOwned;
  late bool _finished = _isFinished;

  Workflow get w => widget.workflow;
  bool get _isOwned => widget.stage.id == w.ownedStage.id;
  bool get _isFinished => widget.stage.id == w.finishedStage.id;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _then(VoidCallback action) {
    Navigator.pop(context);
    action();
  }

  /// Can only be turned on (there is always exactly one); disabled with [forbidden] when the order rule refuses it.
  Widget _switch({
    required IconData icon,
    required String title,
    required bool current,
    required Stage now,
    required String? forbidden,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => SwitchListTile(
    secondary: Icon(icon),
    title: Text(title),
    subtitle: current ? null : Text(forbidden ?? 'Now from ${now.name}'),
    value: value,
    onChanged: current || forbidden != null ? null : onChanged,
    contentPadding: EdgeInsets.zero,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colours = theme.colorScheme;
    final i = w.stages.indexWhere((s) => s.id == widget.stage.id);
    final ownedAt = w.stages.indexWhere((s) => s.id == w.ownedStage.id);
    final finishedAt = w.stages.indexWhere((s) => s.id == w.finishedStage.id);
    final name = _name.text.trim();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              spacing: 12,
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: stageColour(_colour),
                    shape: BoxShape.circle,
                  ),
                ),
                Expanded(child: Text(name, style: theme.textTheme.titleLarge)),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            Text(
              'Colour',
              style: theme.textTheme.labelLarge?.copyWith(
                color: colours.onSurfaceVariant,
              ),
            ),
            Wrap(
              children: [
                for (final c in Vault.stageColours)
                  IconButton(
                    tooltip: c,
                    isSelected: c == _colour,
                    onPressed: () => setState(() => _colour = c),
                    icon: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: stageColour(c),
                        shape: BoxShape.circle,
                        border: c == _colour
                            ? Border.all(color: colours.onSurface, width: 3)
                            : null,
                      ),
                      // Every preset theme's surface is dark enough to read on the light Stage colours.
                      child: c == _colour
                          ? Icon(Icons.check, size: 20, color: colours.surface)
                          : null,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            _switch(
              icon: Icons.flag,
              title: 'Owned from here',
              current: _isOwned,
              now: w.ownedStage,
              forbidden: i > finishedAt
                  ? 'Comes after the Finished Stage'
                  : null,
              value: _owned,
              onChanged: (v) => setState(() => _owned = v),
            ),
            _switch(
              icon: Icons.military_tech,
              title: 'Finished from here',
              current: _isFinished,
              now: w.finishedStage,
              forbidden: i < ownedAt ? 'Comes before the Owned Stage' : null,
              value: _finished,
              onChanged: (v) => setState(() => _finished = v),
            ),
            const SizedBox(height: 8),
            Row(
              spacing: 8,
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _then(widget.onAddAbove),
                    icon: const Icon(Icons.vertical_align_top),
                    label: const Text('Add above'),
                  ),
                ),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _then(widget.onAddBelow),
                    icon: const Icon(Icons.vertical_align_bottom),
                    label: const Text('Add below'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton(
                  onPressed: () => _then(widget.onDelete),
                  style: destructive(context),
                  child: const Text('Delete'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: name.isEmpty
                      ? null
                      : () => Navigator.pop<_StageEdit>(context, (
                          name: name,
                          colour: _colour,
                          owned: _owned && !_isOwned,
                          finished: _finished && !_isFinished,
                        )),
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

typedef _DeleteChoice = ({
  String? destination,
  String? owned,
  String? finished,
});

/// Asks where a deleted Stage's Batches go, and which Stage replaces it as Owned or Finished, as needed. Every choice
/// defaults to the next Stage (the previous one if it is the last), and Owned/Finished list only Stages the order rule
/// allows; a [StageStrip] previews the Workflow after the delete.
class _DeleteStageDialog extends StatefulWidget {
  const _DeleteStageDialog({
    required this.workflow,
    required this.stage,
    required this.held,
    required this.affected,
  });

  final Workflow workflow;
  final Stage stage;

  /// Units at the Stage, and the names of their Collections, A–Z.
  final int held;
  final List<String> affected;

  @override
  State<_DeleteStageDialog> createState() => _DeleteStageDialogState();
}

class _DeleteStageDialogState extends State<_DeleteStageDialog> {
  Workflow get w => widget.workflow;
  late final bool _isOwned = widget.stage.id == w.ownedStage.id;
  late final bool _isFinished = widget.stage.id == w.finishedStage.id;

  /// The Stages left after the delete, in order.
  late final List<Stage> _rest = [...w.stages]..remove(widget.stage);
  late final Stage _next =
      _rest[min(w.stages.indexOf(widget.stage), _rest.length - 1)];
  late Stage _destination = _next;
  late Stage _owned = _isOwned ? _next : w.ownedStage;
  late Stage _finished = _isFinished ? _next : w.finishedStage;

  // Owned at or before Finished, as Vault.deleteStage requires.
  List<Stage> get _ownedChoices =>
      _isFinished ? _rest : _rest.sublist(0, _rest.indexOf(_finished) + 1);
  List<Stage> get _finishedChoices => _rest.sublist(_rest.indexOf(_owned));

  Widget _picker(
    String label,
    Stage value,
    List<Stage> choices,
    ValueChanged<Stage> onChanged,
  ) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: DropdownMenu<Stage>(
      initialSelection: value,
      label: Text(label),
      expandedInsets: EdgeInsets.zero,
      leadingIcon: Padding(
        padding: const EdgeInsets.all(12),
        child: _dot(value),
      ),
      dropdownMenuEntries: [
        for (final s in choices)
          DropdownMenuEntry(value: s, label: s.name, leadingIcon: _dot(s)),
      ],
      onSelected: (s) => setState(() => onChanged(s!)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final held = widget.held;
    final names = widget.affected;
    final where = names.length < 2
        ? 'in ${names.join()}'
        : 'across ${names.take(names.length - 1).join(', ')} and ${names.last}';
    final role = [
      if (_isOwned) 'Owned',
      if (_isFinished) 'Finished',
    ].join(' and ');
    return AlertDialog(
      title: Row(
        spacing: 12,
        children: [
          _dot(widget.stage, 24),
          Expanded(child: Text('Delete ${widget.stage.name}?')),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              [
                if (held > 0)
                  '$held ${held == 1 ? 'Unit' : 'Units'} $where '
                      '${held == 1 ? 'is' : 'are'} at this Stage.',
                if (role.isNotEmpty)
                  'It is ${held > 0 ? 'also ' : ''}the $role Stage.',
              ].join(' '),
            ),
            if (held > 0)
              _picker(
                'Move their models to',
                _destination,
                _rest,
                (s) => _destination = s,
              ),
            if (_isOwned)
              _picker('Owned from', _owned, _ownedChoices, (s) {
                _owned = s;
                // Keep Finished at or after Owned when both are being replaced.
                if (_rest.indexOf(_finished) < _rest.indexOf(s)) _finished = s;
              }),
            if (_isFinished)
              _picker(
                'Finished from',
                _finished,
                _finishedChoices,
                (s) => _finished = s,
              ),
            const SizedBox(height: 16),
            StageStrip(
              Workflow(
                id: w.id,
                name: w.name,
                stages: _rest,
                ownedStageId: _owned.id,
                finishedStageId: _finished.id,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'After deleting',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop<_DeleteChoice>(context, (
            destination: held > 0 ? _destination.id : null,
            owned: _isOwned ? _owned.id : null,
            finished: _isFinished ? _finished.id : null,
          )),
          style: destructive(context),
          child: const Text('Delete'),
        ),
      ],
    );
  }
}

/// Switches [collection] to another Workflow: asks which one, then where the Batches at each held Stage go.
Future<void> switchWorkflow(
  BuildContext context,
  Vault vault,
  Collection collection,
) async {
  final workflows = await vault.workflows();
  final collections = await vault.collections();
  final source = await vault.workflowOf(collection);
  final others = [
    for (final w in workflows)
      if (w.id != collection.workflowId) w,
  ];
  if (!context.mounted) return;
  if (others.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Create another Workflow first')),
    );
    return;
  }
  final target = await showDialog<Workflow>(
    context: context,
    builder: (_) => _PickWorkflowDialog(
      collection: collection,
      source: source,
      others: others,
      collections: collections,
    ),
  );
  if (target == null || !context.mounted) return;
  final mapping = await vault.stageMapping(collection, target);
  final units = <String, int>{};
  // A Unit has at most one Batch per Stage.
  for (final b in await vault.batchesOf(collection)) {
    units.update(b.stageId, (n) => n + 1, ifAbsent: () => 1);
  }
  if (!context.mounted) return;
  final moveTo = await showDialog<Map<String, String>>(
    context: context,
    builder: (_) => _MapStagesDialog(
      source: source,
      target: target,
      mapping: mapping,
      units: units,
    ),
  );
  if (moveTo == null || !context.mounted) return;
  await attempt(
    context,
    () => vault.switchWorkflow(collection, target.id, moveTo),
  );
}

/// The Workflows a Collection can switch to, one radio row each with its [StageStrip], Stage range and users.
class _PickWorkflowDialog extends StatefulWidget {
  const _PickWorkflowDialog({
    required this.collection,
    required this.source,
    required this.others,
    required this.collections,
  });

  final Collection collection;
  final Workflow source;
  final List<Workflow> others;
  final List<Collection> collections;

  @override
  State<_PickWorkflowDialog> createState() => _PickWorkflowDialogState();
}

class _PickWorkflowDialogState extends State<_PickWorkflowDialog> {
  late Workflow _picked = widget.others.first;

  String _summary(Workflow w) {
    final users = [
      for (final c in widget.collections)
        if (c.workflowId == w.id) c.name,
    ]..sort();
    return '${w.stages.first.name} → ${w.stages.last.name} · '
        '${users.isEmpty ? 'not used' : 'used by ${users.join(', ')}'}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return AlertDialog(
      title: Text('Switch ${widget.collection.name} to'),
      content: SingleChildScrollView(
        child: RadioGroup<Workflow>(
          groupValue: _picked,
          onChanged: (w) => setState(() => _picked = w!),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Now on ${widget.source.name}.'),
              for (final w in widget.others)
                RadioListTile<Workflow>(
                  value: w,
                  contentPadding: EdgeInsets.zero,
                  title: Text(w.name),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 6,
                      children: [
                        StageStrip(w),
                        Text(_summary(w), style: muted),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _picked),
          child: const Text('Next'),
        ),
      ],
    );
  }
}

/// One row per old Stage that holds Batches: its dot, name and Unit count → a picker of the new Workflow's Stages,
/// pre-set to the same-name Stage, else the Stage that starts the same zone (the first Stage for wanted). A choice
/// that changes the zone is flagged, not barred.
class _MapStagesDialog extends StatefulWidget {
  const _MapStagesDialog({
    required this.source,
    required this.target,
    required this.mapping,
    required this.units,
  });

  final Workflow source;
  final Workflow target;
  final List<({Stage from, Stage? to})> mapping;

  /// Units per old Stage id.
  final Map<String, int> units;

  @override
  State<_MapStagesDialog> createState() => _MapStagesDialogState();
}

class _MapStagesDialogState extends State<_MapStagesDialog> {
  late final _moveTo = {
    for (final m in widget.mapping)
      m.from.id:
          m.to ??
          switch (_zoneOf(widget.source, m.from)) {
            _Zone.wanted => widget.target.stages.first,
            _Zone.owned => widget.target.ownedStage,
            _Zone.finished => widget.target.finishedStage,
          },
  };

  Widget _row(ThemeData theme, Stage from) {
    final colours = theme.colorScheme;
    final to = _moveTo[from.id]!;
    final was = _zoneOf(widget.source, from);
    final now = _zoneOf(widget.target, to);
    final n = widget.units[from.id] ?? 0;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 4,
        children: [
          Row(
            spacing: 8,
            children: [
              _dot(from),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(from.name, overflow: TextOverflow.ellipsis),
                    Text(
                      '$n ${n == 1 ? 'Unit' : 'Units'}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colours.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward, color: colours.onSurfaceVariant),
              Expanded(
                flex: 2,
                child: DropdownMenu<Stage>(
                  key: ValueKey('to:${from.id}'),
                  initialSelection: to,
                  expandedInsets: EdgeInsets.zero,
                  leadingIcon: Center(widthFactor: 1, child: _dot(to)),
                  // Dense with a narrow dot slot, to fit three columns in 320dp; outlined in the error colour on a zone change.
                  inputDecorationTheme: theme.inputDecorationTheme.copyWith(
                    isDense: true,
                    prefixIconConstraints: const BoxConstraints(minWidth: 32),
                    enabledBorder: was == now
                        ? null
                        : OutlineInputBorder(
                            borderSide: BorderSide(color: colours.error),
                          ),
                  ),
                  dropdownMenuEntries: [
                    for (final s in widget.target.stages)
                      DropdownMenuEntry(
                        value: s,
                        label: s.name,
                        leadingIcon: _dot(s),
                      ),
                  ],
                  onSelected: (s) => setState(() => _moveTo[from.id] = s!),
                ),
              ),
            ],
          ),
          if (was != now)
            Row(
              spacing: 4,
              children: [
                Icon(Icons.warning_amber, size: 16, color: colours.error),
                Expanded(
                  child: Text(
                    '${was.name[0].toUpperCase()}${was.name.substring(1)} '
                    'models would count as ${now.name}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colours.error,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('Switch to ${widget.target.name}?'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.mapping.isEmpty
                  ? 'This Collection has no Units to move.'
                  : 'Move the Units at each Stage to:',
            ),
            for (final m in widget.mapping) _row(theme, m.from),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, {
            for (final e in _moveTo.entries) e.key: e.value.id,
          }),
          child: const Text('Switch'),
        ),
      ],
    );
  }
}

class NameDialog extends StatefulWidget {
  const NameDialog({
    super.key,
    required this.title,
    required this.initial,
    this.label = 'Name',
  });

  final String title;
  final String initial;
  final String label;

  @override
  State<NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<NameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    void save() => Navigator.pop(context, _controller.text);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.label),
        onSubmitted: (_) => save(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: save, child: const Text('Save')),
      ],
    );
  }
}

/// Asks for a new Collection's name and Workflow, the first (starter) Workflow preselected.
/// Name, Game System and either (for a new Collection) Workflow or (when editing) description. Pops
/// `(name, workflowId, gameSystem, description)`; the Workflow is null when editing, the description '' when not.
/// Workflows show their [StageStrip]. When editing, the current one shows read-only with "Switch…", which closes the
/// dialog without saving its edits (as the Stage sheet's actions do) and calls [onSwitch].
class NewCollectionDialog extends StatefulWidget {
  const NewCollectionDialog({
    super.key,
    this.workflows = const [],
    this.gameSystems = const [],
    this.collection,
    this.onSwitch,
  });

  final List<Workflow> workflows;

  /// Game Systems in use, suggested as the user types.
  final List<String> gameSystems;

  /// The Collection being edited; null for a new one.
  final Collection? collection;

  /// Runs the Switch Workflow flow (when editing).
  final VoidCallback? onSwitch;

  @override
  State<NewCollectionDialog> createState() => _NewCollectionDialogState();
}

class _NewCollectionDialogState extends State<NewCollectionDialog> {
  late final _name = TextEditingController(text: widget.collection?.name);
  late final _gameSystem = TextEditingController(
    text: widget.collection?.gameSystem,
  );
  late final _description = TextEditingController(
    text: widget.collection?.description,
  );
  final _gameSystemFocus = FocusNode();
  late Workflow? _workflow = widget.workflows.firstOrNull;

  @override
  void dispose() {
    _name.dispose();
    _gameSystem.dispose();
    _description.dispose();
    _gameSystemFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.collection != null;
    final theme = Theme.of(context);
    final current = widget.workflows
        .where((w) => w.id == widget.collection?.workflowId)
        .firstOrNull;
    void save() => Navigator.pop(context, (
      _name.text,
      editing ? null : _workflow?.id,
      _gameSystem.text,
      _description.text,
    ));
    return AlertDialog(
      title: Text(editing ? 'Edit Collection' : 'New Collection'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          Autocomplete<String>(
            textEditingController: _gameSystem,
            focusNode: _gameSystemFocus,
            optionsBuilder: (value) => [
              for (final g in widget.gameSystems)
                if (tagKey(g).startsWith(tagKey(value.text)) &&
                    tagKey(g) != tagKey(value.text))
                  g,
            ],
            fieldViewBuilder: (context, field, focus, submit) => TextField(
              controller: field,
              focusNode: focus,
              decoration: const InputDecoration(labelText: 'Game System'),
            ),
          ),
          if (editing)
            TextField(
              controller: _description,
              minLines: 1,
              maxLines: 5,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(labelText: 'Description'),
            ),
          if (editing && current != null) ...[
            const SizedBox(height: 16),
            Text(
              'Workflow',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Row(
              spacing: 8,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 6,
                    children: [Text(current.name), StageStrip(current)],
                  ),
                ),
                if (widget.onSwitch case final onSwitch?)
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                      onSwitch();
                    },
                    child: const Text('Switch…'),
                  ),
              ],
            ),
          ],
          if (!editing) ...[
            const SizedBox(height: 8),
            DropdownMenu<Workflow>(
              initialSelection: _workflow,
              label: const Text('Workflow'),
              expandedInsets: EdgeInsets.zero,
              dropdownMenuEntries: [
                for (final w in widget.workflows)
                  DropdownMenuEntry(
                    value: w,
                    label: w.name,
                    labelWidget: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 4,
                      children: [Text(w.name), StageStrip(w, height: 6)],
                    ),
                  ),
              ],
              onSelected: (w) => setState(() => _workflow = w),
            ),
            if (_workflow case final w?) ...[
              const SizedBox(height: 8),
              StageStrip(w),
            ],
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: save, child: Text(editing ? 'Save' : 'Create')),
      ],
    );
  }
}
