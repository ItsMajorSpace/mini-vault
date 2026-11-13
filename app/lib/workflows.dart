/// The Workflow editor: the list of Workflows, and one Workflow's Stages.
library;

import 'package:domain_core/domain_core.dart';
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

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

class WorkflowsScreen extends StatelessWidget {
  const WorkflowsScreen({super.key, required this.vault});

  final Vault vault;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Workflows')),
      body: StreamBuilder(
        stream: vault.watchWorkflows(),
        builder: (context, snapshot) {
          final workflows = snapshot.data;
          if (workflows == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            children: [
              for (final w in workflows)
                ListTile(
                  title: Text(w.name),
                  subtitle: Text('${w.stages.length} Stages'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          WorkflowScreen(vault: vault, workflowId: w.id),
                    ),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete),
                    tooltip: 'Delete Workflow',
                    style: destructive(context),
                    onPressed: () =>
                        attempt(context, () => vault.deleteWorkflow(w.id)),
                  ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New Workflow',
        child: const Icon(Icons.add),
        onPressed: () async {
          final name = await askName(context, 'New Workflow');
          if (name != null && context.mounted) {
            await attempt(context, () => vault.createWorkflow(name));
          }
        },
      ),
    );
  }
}

/// One Workflow's Stages, in order: drag to reorder, and a menu per Stage for the rest.
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

  Vault get vault => widget.vault;
  String get id => widget.workflowId;

  Future<void> _addStage(int index) async {
    final name = await askName(context, 'New Stage');
    if (name != null && mounted) {
      await attempt(context, () => vault.addStage(id, name, index));
    }
  }

  Future<void> _onMenu(_StageAction action, Stage stage, int index) async {
    switch (action) {
      case _StageAction.rename:
        final name = await askName(context, 'Rename Stage', stage.name);
        if (name != null && mounted) {
          await attempt(context, () => vault.renameStage(stage.id, name));
        }
      case _StageAction.addAbove:
        await _addStage(index);
      case _StageAction.addBelow:
        await _addStage(index + 1);
      case _StageAction.owned:
        await attempt(context, () => vault.setOwnedStage(id, stage.id));
      case _StageAction.finished:
        await attempt(context, () => vault.setFinishedStage(id, stage.id));
      case _StageAction.colour:
        final colour = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text('Colour of ${stage.name}'),
            contentPadding: const EdgeInsets.all(16),
            children: [
              Wrap(
                children: [
                  for (final c in Vault.stageColours)
                    IconButton(
                      tooltip: c,
                      icon: Icon(
                        c == stage.colour ? Icons.check_circle : Icons.circle,
                        color: stageColour(c),
                      ),
                      onPressed: () => Navigator.pop(context, c),
                    ),
                ],
              ),
            ],
          ),
        );
        if (colour != null && mounted) {
          await attempt(context, () => vault.setStageColour(stage.id, colour));
        }
      case _StageAction.delete:
        await _deleteStage(stage);
    }
  }

  /// Deletes the Stage, first asking where its Batches go and which Stage replaces it as Owned or Finished, if needed.
  Future<void> _deleteStage(Stage stage) async {
    final workflow = (await vault.workflows()).firstWhere((w) => w.id == id);
    final held = (await vault.batchesAt(stage.id)).length;
    final owned = stage.id == workflow.ownedStage.id;
    final finished = stage.id == workflow.finishedStage.id;
    final others = [...workflow.stages]..removeWhere((s) => s.id == stage.id);
    if (!mounted) return;
    if ((held == 0 && !owned && !finished) || others.isEmpty) {
      return attempt(context, () => vault.deleteStage(id, stage.id));
    }
    final choice = await showDialog<_DeleteChoice>(
      context: context,
      builder: (_) => _DeleteStageDialog(
        stage: stage,
        others: others,
        held: held,
        owned: owned,
        finished: finished,
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
          body: ReorderableListView(
            onReorderItem: (from, to) => attempt(
              context,
              () => vault.moveStage(id, workflow.stages[from].id, to),
            ),
            children: [
              for (final (i, stage) in workflow.stages.indexed)
                ListTile(
                  key: ValueKey(stage.id),
                  title: Text(stage.name),
                  subtitle: switch ((
                    stage.id == workflow.ownedStage.id,
                    stage.id == workflow.finishedStage.id,
                  )) {
                    (true, true) => const Text('Owned Stage, Finished Stage'),
                    (true, false) => const Text('Owned Stage'),
                    (false, true) => const Text('Finished Stage'),
                    _ => null,
                  },
                  trailing: PopupMenuButton<_StageAction>(
                    tooltip: 'Stage actions for ${stage.name}',
                    onSelected: (action) => _onMenu(action, stage, i),
                    itemBuilder: (_) => [
                      for (final a in _StageAction.values)
                        PopupMenuItem(value: a, child: Text(a.label)),
                    ],
                  ),
                ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            tooltip: 'New Stage',
            child: const Icon(Icons.add),
            onPressed: () => _addStage(workflow.stages.length),
          ),
        );
      },
    );
  }
}

enum _StageAction {
  rename('Rename'),
  addAbove('Add Stage above'),
  addBelow('Add Stage below'),
  owned('Set as Owned Stage'),
  finished('Set as Finished Stage'),
  colour('Set colour'),
  delete('Delete');

  const _StageAction(this.label);
  final String label;
}

typedef _DeleteChoice = ({
  String? destination,
  String? owned,
  String? finished,
});

/// Asks where a deleted Stage's Batches go, and which Stage replaces it as Owned or Finished, as needed.
class _DeleteStageDialog extends StatefulWidget {
  const _DeleteStageDialog({
    required this.stage,
    required this.others,
    required this.held,
    required this.owned,
    required this.finished,
  });

  final Stage stage;

  /// The Workflow's other Stages, in order.
  final List<Stage> others;
  final int held;
  final bool owned;
  final bool finished;

  @override
  State<_DeleteStageDialog> createState() => _DeleteStageDialogState();
}

class _DeleteStageDialogState extends State<_DeleteStageDialog> {
  late String _destination = widget.others.first.id;
  late String _owned = widget.others.first.id;
  late String _finished = widget.others.last.id;

  Widget _picker(String label, String value, ValueChanged<String> onChanged) =>
      DropdownButtonFormField<String>(
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final s in widget.others)
            DropdownMenuItem(value: s.id, child: Text(s.name)),
        ],
        onChanged: (id) => setState(() => onChanged(id!)),
      );

  @override
  Widget build(BuildContext context) {
    final held = widget.held;
    return AlertDialog(
      title: Text('Delete ${widget.stage.name}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (held > 0) ...[
            Text(
              '$held ${held == 1 ? 'Unit is' : 'Units are'} at this Stage, '
              'across all Collections using this Workflow.',
            ),
            _picker('Move them to', _destination, (v) => _destination = v),
          ],
          if (widget.owned)
            _picker('New Owned Stage', _owned, (v) => _owned = v),
          if (widget.finished)
            _picker('New Finished Stage', _finished, (v) => _finished = v),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop<_DeleteChoice>(context, (
            destination: held > 0 ? _destination : null,
            owned: widget.owned ? _owned : null,
            finished: widget.finished ? _finished : null,
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
  final others = [
    for (final w in await vault.workflows())
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
    builder: (context) => SimpleDialog(
      title: Text('Switch ${collection.name} to'),
      children: [
        for (final w in others)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, w),
            child: Text(w.name),
          ),
      ],
    ),
  );
  if (target == null || !context.mounted) return;
  final mapping = await vault.stageMapping(collection, target);
  if (!context.mounted) return;
  final moveTo = await showDialog<Map<String, String>>(
    context: context,
    builder: (_) => _MapStagesDialog(target: target, mapping: mapping),
  );
  if (moveTo == null || !context.mounted) return;
  await attempt(
    context,
    () => vault.switchWorkflow(collection, target.id, moveTo),
  );
}

/// One target Stage picker per old Stage that holds Batches, pre-set to the same-name Stage or else the first.
class _MapStagesDialog extends StatefulWidget {
  const _MapStagesDialog({required this.target, required this.mapping});

  final Workflow target;
  final List<({Stage from, Stage? to})> mapping;

  @override
  State<_MapStagesDialog> createState() => _MapStagesDialogState();
}

class _MapStagesDialogState extends State<_MapStagesDialog> {
  late final _moveTo = {
    for (final m in widget.mapping)
      m.from.id: (m.to ?? widget.target.stages.first).id,
  };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Switch to ${widget.target.name}?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.mapping.isEmpty
                  ? 'This Collection has no Units to move.'
                  : 'Move the Units at each Stage to:',
            ),
            for (final m in widget.mapping)
              DropdownButtonFormField<String>(
                initialValue: _moveTo[m.from.id],
                decoration: InputDecoration(labelText: m.from.name),
                items: [
                  for (final s in widget.target.stages)
                    DropdownMenuItem(value: s.id, child: Text(s.name)),
                ],
                onChanged: (id) => setState(() => _moveTo[m.from.id] = id!),
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
          onPressed: () => Navigator.pop(context, _moveTo),
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
/// Name, Game System and (for a new Collection) Workflow. Pops `(name, workflowId, gameSystem)`; the Workflow is
/// null when editing.
class NewCollectionDialog extends StatefulWidget {
  const NewCollectionDialog({
    super.key,
    this.workflows = const [],
    this.gameSystems = const [],
    this.collection,
  });

  final List<Workflow> workflows;

  /// Game Systems in use, suggested as the user types.
  final List<String> gameSystems;

  /// The Collection being edited; null for a new one.
  final Collection? collection;

  @override
  State<NewCollectionDialog> createState() => _NewCollectionDialogState();
}

class _NewCollectionDialogState extends State<NewCollectionDialog> {
  late final _name = TextEditingController(text: widget.collection?.name);
  late final _gameSystem = TextEditingController(
    text: widget.collection?.gameSystem,
  );
  final _gameSystemFocus = FocusNode();
  late String? _workflowId = widget.workflows.firstOrNull?.id;

  @override
  void dispose() {
    _name.dispose();
    _gameSystem.dispose();
    _gameSystemFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.collection != null;
    void save() =>
        Navigator.pop(context, (_name.text, _workflowId, _gameSystem.text));
    return AlertDialog(
      title: Text(editing ? 'Edit Collection' : 'New Collection'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
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
          if (!editing)
            DropdownButtonFormField<String>(
              initialValue: _workflowId,
              decoration: const InputDecoration(labelText: 'Workflow'),
              items: [
                for (final w in widget.workflows)
                  DropdownMenuItem(value: w.id, child: Text(w.name)),
              ],
              onChanged: (id) => setState(() => _workflowId = id!),
            ),
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
