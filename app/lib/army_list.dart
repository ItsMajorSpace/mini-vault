/// Importing an Army List: paste its text, preview the entries, confirm.
library;

import 'package:domain_core/army_list.dart';
import 'package:domain_core/domain_core.dart';
import 'package:material_ui/material_ui.dart';

import 'unit.dart';
import 'workflows.dart';

/// One previewed entry: ticked to import, with an editable name and count.
class _Row {
  _Row(ArmyListEntry e)
    : name = TextEditingController(text: e.name),
      count = TextEditingController(text: '${e.count}');
  bool ticked = true;
  final TextEditingController name;
  final TextEditingController count;
}

/// Paste → preview → confirm. [collection], if given, is preselected; otherwise the import makes a new Collection.
class ArmyListScreen extends StatefulWidget {
  const ArmyListScreen({super.key, required this.vault, this.collection});

  final Vault vault;
  final Collection? collection;

  @override
  State<ArmyListScreen> createState() => _ArmyListScreenState();
}

class _ArmyListScreenState extends State<ArmyListScreen> {
  final _form = GlobalKey<FormState>();
  final _text = TextEditingController();
  String? _error;

  // Set once the pasted text is recognised; the preview step.
  ArmyList? _list;
  var _rows = <_Row>[];
  var _collections = <Collection>[];
  var _workflows = <Workflow>[];
  Workflow? _starter;
  var _gameSystems = <String>[];
  final _name = TextEditingController();
  final _gameSystem = TextEditingController();
  final _gameSystemFocus = FocusNode();
  final _tag = TextEditingController();

  /// Null for a new Collection.
  Collection? _collection;
  String? _stageId;

  /// Models the chosen Collection already has, by exact Unit name.
  var _existing = <String, int>{};

  Workflow? get _workflow => _collection == null
      ? _starter
      : _workflows.where((w) => w.id == _collection!.workflowId).firstOrNull;

  @override
  void dispose() {
    for (final c in [_text, _name, _gameSystem, _tag]) {
      c.dispose();
    }
    for (final r in _rows) {
      r.name.dispose();
      r.count.dispose();
    }
    _gameSystemFocus.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    final list = parseArmyList(_text.text);
    if (list == null) {
      setState(
        () => _error = 'Unrecognised list. Paste the text export from the Warhammer 40k app or Army Forge.',
      );
      return;
    }
    final vault = widget.vault;
    final collections = await vault.collections();
    final workflows = await vault.workflows();
    final starter = await vault.starterWorkflow();
    final gameSystems = await vault.gameSystems();
    if (!mounted) return;
    setState(() {
      _list = list;
      _rows = [for (final e in list.entries) _Row(e)];
      _collections = collections;
      _workflows = workflows;
      _starter = starter;
      _gameSystems = gameSystems;
      _name.text = list.faction;
      _gameSystem.text = list.gameSystem;
      _tag.text = list.faction;
    });
    await _select(
      collections.where((c) => c.id == widget.collection?.id).firstOrNull,
    );
  }

  Future<void> _select(Collection? collection) async {
    final batches = collection == null
        ? const <Batch>[]
        : await widget.vault.batchesOf(collection);
    if (!mounted) return;
    setState(() {
      _collection = collection;
      _stageId = _workflow?.stages.firstOrNull?.id;
      _existing = {};
      for (final u in batches) {
        _existing[u.name] = (_existing[u.name] ?? 0) + u.modelCount;
      }
    });
  }

  Future<void> _import() async {
    if (!_form.currentState!.validate()) return;
    final entries = [
      for (final r in _rows)
        if (r.ticked)
          (name: r.name.text.trim(), count: int.parse(r.count.text.trim())),
    ];
    await attempt(context, () async {
      final collection =
          _collection ??
          await widget.vault.createCollection(
            _name.text,
            gameSystem: _gameSystem.text,
          );
      await widget.vault.importArmyList(
        collection,
        _stageId!,
        entries,
        tag: _tag.text,
      );
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final stages = _workflow?.stages ?? const <Stage>[];
    final importable = _rows.any((r) => r.ticked) && _stageId != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Import army list'),
        actions: [
          if (_list == null)
            TextButton(onPressed: _preview, child: const Text('Preview'))
          else
            TextButton(
              onPressed: importable ? _import : null,
              child: const Text('Import'),
            ),
        ],
      ),
      body: _list == null
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _text,
                  autofocus: true,
                  minLines: 8,
                  maxLines: null,
                  decoration: InputDecoration(
                    labelText: 'Army list',
                    hintText: 'Paste the text export from the Warhammer 40k app or Army Forge',
                    errorText: _error,
                    errorMaxLines: 3,
                  ),
                ),
              ],
            )
          : Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  DropdownButtonFormField<String?>(
                    initialValue: _collection?.id,
                    decoration: const InputDecoration(labelText: 'Collection'),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('New Collection'),
                      ),
                      for (final c in _collections)
                        DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ],
                    onChanged: (id) => _select(
                      _collections.where((c) => c.id == id).firstOrNull,
                    ),
                  ),
                  if (_collection == null) ...[
                    TextFormField(
                      controller: _name,
                      decoration: const InputDecoration(labelText: 'Name'),
                      validator: (v) =>
                          v!.trim().isEmpty ? 'Enter a name' : null,
                    ),
                    Autocomplete<String>(
                      textEditingController: _gameSystem,
                      focusNode: _gameSystemFocus,
                      optionsBuilder: (value) => [
                        for (final g in _gameSystems)
                          if (tagKey(g).startsWith(tagKey(value.text)) &&
                              tagKey(g) != tagKey(value.text))
                            g,
                      ],
                      fieldViewBuilder: (context, field, focus, submit) =>
                          TextField(
                            controller: field,
                            focusNode: focus,
                            decoration: const InputDecoration(
                              labelText: 'Game System',
                            ),
                          ),
                    ),
                  ],
                  DropdownButtonFormField<String>(
                    // A new Collection or Workflow resets the Stage to its first.
                    key: ValueKey(_collection?.id),
                    initialValue: _stageId,
                    decoration: const InputDecoration(labelText: 'Stage'),
                    items: [
                      for (final s in stages)
                        DropdownMenuItem(value: s.id, child: Text(s.name)),
                    ],
                    onChanged: (id) => setState(() => _stageId = id),
                  ),
                  TextField(
                    controller: _tag,
                    decoration: const InputDecoration(
                      labelText: 'Faction Tag',
                      helperText:
                          'Added to every imported Unit; clear for none',
                    ),
                  ),
                  const SizedBox(height: 16),
                  for (final r in _rows)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Checkbox(
                          value: r.ticked,
                          onChanged: (v) => setState(() => r.ticked = v!),
                        ),
                        Expanded(
                          child: TextFormField(
                            controller: r.name,
                            enabled: r.ticked,
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              labelText: 'Name',
                              helperText: switch (_existing[r.name.text
                                  .trim()]) {
                                final n? => 'Already ${modelCountText(n)}',
                                null => null,
                              },
                            ),
                            validator: (v) => r.ticked && v!.trim().isEmpty
                                ? 'Enter a name'
                                : null,
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 72,
                          child: TextFormField(
                            controller: r.count,
                            enabled: r.ticked,
                            decoration: const InputDecoration(
                              labelText: 'Models',
                            ),
                            keyboardType: TextInputType.number,
                            validator: (v) =>
                                r.ticked && (int.tryParse(v!.trim()) ?? 0) < 1
                                ? 'At least 1'
                                : null,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
    );
  }
}
