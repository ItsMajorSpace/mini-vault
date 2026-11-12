/// The Workflow editor: the list of Workflows, and one Workflow's Stages.
library;

import 'package:domain_core/domain_core.dart';
import 'package:material_ui/material_ui.dart';

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
      case _StageAction.delete:
        await attempt(context, () => vault.deleteStage(id, stage.id));
    }
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
  delete('Delete');

  const _StageAction(this.label);
  final String label;
}

class NameDialog extends StatefulWidget {
  const NameDialog({super.key, required this.title, required this.initial});

  final String title;
  final String initial;

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
        decoration: const InputDecoration(labelText: 'Name'),
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
class NewCollectionDialog extends StatefulWidget {
  const NewCollectionDialog({super.key, required this.workflows});

  final List<Workflow> workflows;

  @override
  State<NewCollectionDialog> createState() => _NewCollectionDialogState();
}

class _NewCollectionDialogState extends State<NewCollectionDialog> {
  final _name = TextEditingController();
  late String _workflowId = widget.workflows.first.id;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    void save() => Navigator.pop(context, (_name.text, _workflowId));
    return AlertDialog(
      title: const Text('New Collection'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
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
        TextButton(onPressed: save, child: const Text('Create')),
      ],
    );
  }
}
