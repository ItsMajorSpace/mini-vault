import 'package:domain_core/domain_core.dart';
import 'package:material_ui/material_ui.dart';

import 'main.dart';
import 'paints.dart';
import 'section.dart';
import 'theme.dart';
import 'workflows.dart';

String _stepCountText(int n) => n == 1 ? '1 Scheme Step' : '$n Scheme Steps';

/// A Collection's Paint Schemes as one horizontal row of cards, with an action to add one; a card opens its scheme.
class PaintSchemesSection extends StatefulWidget {
  const PaintSchemesSection({
    super.key,
    required this.vault,
    required this.collection,
  });

  final Vault vault;
  final Collection collection;

  @override
  State<PaintSchemesSection> createState() => _PaintSchemesSectionState();
}

class _PaintSchemesSectionState extends State<PaintSchemesSection> {
  late final _schemes = widget.vault.watchPaintSchemes(widget.collection.id);
  late final _others = widget.vault.watchOtherPaintSchemes(
    widget.collection.id,
  );

  Vault get vault => widget.vault;
  Collection get collection => widget.collection;

  Future<void> _add(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const NameDialog(title: 'New Paint Scheme', initial: ''),
    );
    if (name == null || !context.mounted) return;
    await attempt(context, () => vault.addPaintScheme(collection.id, name));
  }

  /// Starts a Paint Scheme here as a copy of one picked from [others].
  Future<void> _copy(
    BuildContext context,
    List<({Collection collection, PaintScheme scheme})> others,
  ) async {
    final from = await showDialog<PaintScheme>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Copy a Paint Scheme from'),
        children: [
          for (final o in others)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, o.scheme),
              child: Text('${o.scheme.name} · ${o.collection.name}'),
            ),
        ],
      ),
    );
    if (from == null || !context.mounted) return;
    await attempt(context, () => vault.copyPaintScheme(from, collection.id));
  }

  @override
  Widget build(BuildContext context) => StreamBuilder(
    stream: _schemes,
    builder: (context, snapshot) {
      final schemes = snapshot.data ?? const [];
      final colours = Theme.of(context).colorScheme;
      return Section(
        title: 'Paint Schemes',
        card: schemes.isEmpty,
        actions: [
          StreamBuilder(
            stream: _others,
            builder: (context, others) => (others.data ?? const []).isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    icon: const Icon(Icons.content_copy),
                    tooltip: 'Copy a Paint Scheme',
                    onPressed: () => _copy(context, others.data!),
                  ),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New Paint Scheme',
            onPressed: () => _add(context),
          ),
        ],
        child: schemes.isEmpty
            ? const SectionHint('No Paint Schemes yet')
            : SizedBox(
                height: 56,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: schemes.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, i) => Card.filled(
                    margin: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    color: colours.surfaceContainerLow,
                    child: InkWell(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => PaintSchemeScreen(
                            vault: vault,
                            collection: collection,
                            scheme: schemes[i],
                          ),
                        ),
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(color: colours.primary, width: 3),
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              schemes[i].name,
                              style: stencil(
                                Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            Text(
                              _stepCountText(schemes[i].stepCount),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: colours.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
      );
    },
  );
}

/// A Paint Scheme's numbered Scheme Steps: tap one to edit it, drag its handle to reorder, add one with the button.
class PaintSchemeScreen extends StatefulWidget {
  const PaintSchemeScreen({
    super.key,
    required this.vault,
    required this.collection,
    required this.scheme,
  });

  final Vault vault;
  final Collection collection;
  final PaintScheme scheme;

  @override
  State<PaintSchemeScreen> createState() => _PaintSchemeScreenState();
}

class _PaintSchemeScreenState extends State<PaintSchemeScreen> {
  late final _schemes = widget.vault.watchPaintSchemes(widget.collection.id);
  late final _paints = widget.vault.watchPaints();
  late var _steps = widget.vault.watchSchemeSteps(widget.scheme.id);
  late var _scheme = widget.scheme;
  List<Paint> _library = const [];

  Future<void> _rename() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) =>
          NameDialog(title: 'Rename Paint Scheme', initial: _scheme.name),
    );
    if (name == null || !mounted) return;
    await attempt(
      context,
      () => widget.vault.renamePaintScheme(_scheme.id, name),
    );
  }

  /// Asks first; back to the Collection once deleted.
  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${_scheme.name}?'),
        content: Text(
          'Its ${_stepCountText(_scheme.stepCount)} will be deleted on all your devices. Its Paints stay in your paints.',
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
    );
    if (!(confirmed ?? false) || !mounted) return;
    await widget.vault.deletePaintScheme(_scheme.id);
    if (mounted) Navigator.pop(context);
  }

  /// Opens the Scheme Step sheet for [step] (number [number]) or a new Step, and saves what it returns.
  Future<void> _openStep([SchemeStep? step, int number = 0]) async {
    final techniques = await widget.vault.techniques();
    if (!mounted) return;
    final fields = await showModalBottomSheet<StepFields>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SchemeStepSheet(
        vault: widget.vault,
        title: step == null ? 'New Scheme Step' : 'Scheme Step $number',
        library: _library,
        techniques: techniques,
        step: step,
        onDelete: step == null
            ? null
            : () => attempt(
                context,
                () => widget.vault.deleteSchemeStep(step.id),
              ),
      ),
    );
    if (fields == null || !mounted) return;
    final (:paintIds, :technique, :note) = fields;
    await attempt(
      context,
      () => step == null
          ? widget.vault.addSchemeStep(
              _scheme.id,
              paintIds: paintIds,
              technique: technique,
              note: note,
            )
          : widget.vault.editSchemeStep(
              step,
              paintIds: paintIds,
              technique: technique,
              note: note,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder(
      stream: _paints,
      builder: (context, paints) => StreamBuilder(
        stream: _schemes,
        builder: (context, schemes) {
          _library = paints.data ?? _library;
          _scheme =
              schemes.data?.where((s) => s.id == _scheme.id).firstOrNull ??
              _scheme;
          return Scaffold(
            appBar: AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_scheme.name),
                  Text(
                    '${widget.collection.name} · Paint Scheme',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.edit),
                  tooltip: 'Rename Paint Scheme',
                  onPressed: _rename,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete Paint Scheme',
                  onPressed: _delete,
                ),
              ],
            ),
            body: StreamBuilder(
              stream: _steps,
              builder: (context, snapshot) => switch (snapshot) {
                AsyncSnapshot(:final error?) => LoadError(
                  what: 'the Scheme Steps',
                  error: error,
                  onRetry: () => setState(
                    () => _steps = widget.vault.watchSchemeSteps(_scheme.id),
                  ),
                ),
                AsyncSnapshot(data: null) => const Center(
                  child: CircularProgressIndicator(),
                ),
                AsyncSnapshot(data: []) => const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'A Paint Scheme is how you paint one part of your models, step by step: which Paints, which Technique, in what order.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                AsyncSnapshot(data: final steps!) =>
                  ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
                    itemCount: steps.length,
                    // shortcut: the list snaps back until the new order is read back from SQLite (milliseconds); keep
                    // a local order meanwhile if that ever shows.
                    onReorderItem: (from, to) => attempt(
                      context,
                      () => widget.vault.moveSchemeStep(
                        _scheme.id,
                        steps[from].id,
                        to,
                      ),
                    ),
                    itemBuilder: (context, i) => _StepCard(
                      key: ValueKey(steps[i].id),
                      index: i,
                      step: steps[i],
                      onTap: () => _openStep(steps[i], i + 1),
                    ),
                  ),
              },
            ),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: _openStep,
              tooltip: 'Add Scheme Step',
              icon: const Icon(Icons.add),
              label: const Text('Add Scheme Step'),
            ),
          );
        },
      ),
    );
  }
}

/// One Scheme Step: its number, Technique (or "No Technique"), Paints (a MIX badge for several, wanted ones
/// outlined), note, and a drag handle.
class _StepCard extends StatelessWidget {
  const _StepCard({
    super.key,
    required this.index,
    required this.step,
    required this.onTap,
  });

  final int index;
  final SchemeStep step;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colours = theme.colorScheme;
    final note = [
      if (step.paints.any((p) => !p.owned)) 'Wanted',
      if (step.note.isNotEmpty) step.note,
    ].join(' · ');
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      color: colours.surfaceContainerLow,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(left: 12, top: 12, bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: colours.primary, width: 2),
                ),
                child: Text(
                  '${index + 1}',
                  style: stencil(theme.textTheme.titleSmall),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 6,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: step.technique.isEmpty
                              ? Text(
                                  'No Technique',
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    fontStyle: FontStyle.italic,
                                    color: colours.onSurfaceVariant,
                                  ),
                                )
                              : Text(
                                  step.technique,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                        ),
                        if (step.paints.length > 1)
                          Container(
                            margin: const EdgeInsets.only(left: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: colours.primary,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'MIX',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colours.onPrimary,
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (step.paints.isNotEmpty)
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final p in step.paints)
                            // shortcut: wanted Paints are outlined, not dashed as in the mockup; a dashed border
                            // needs a custom painter.
                            Chip(
                              avatar: const Icon(Icons.format_paint, size: 16),
                              label: Text(p.name),
                              visualDensity: VisualDensity.compact,
                              backgroundColor: p.owned
                                  ? colours.secondaryContainer
                                  : Colors.transparent,
                              side: p.owned
                                  ? BorderSide.none
                                  : BorderSide(color: colours.outline),
                            ),
                        ],
                      ),
                    if (note.isNotEmpty)
                      Text(
                        note,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colours.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              ReorderableDragStartListener(
                index: index,
                child: const SizedBox(
                  width: 48,
                  height: 48,
                  child: Icon(Icons.drag_handle),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

typedef StepFields = ({List<String> paintIds, String technique, String note});

/// Asks for a Scheme Step's Paints (picked from [library], or new), Technique (typed, or one of [techniques]) and
/// note. Pops the fields once one is set; the Vault checks them.
class SchemeStepSheet extends StatefulWidget {
  const SchemeStepSheet({
    super.key,
    required this.vault,
    required this.title,
    required this.library,
    required this.techniques,
    this.step,
    this.onDelete,
  });

  /// For adding a new Paint to the library.
  final Vault vault;
  final String title;
  final List<Paint> library;
  final List<String> techniques;

  /// The Step being edited; null for a new one.
  final SchemeStep? step;

  /// Shown as Delete when set; closes the sheet and calls it.
  final VoidCallback? onDelete;

  @override
  State<SchemeStepSheet> createState() => _SchemeStepSheetState();
}

class _SchemeStepSheetState extends State<SchemeStepSheet> {
  /// How many Technique suggestions show before "+N".
  static const _shown = 7;

  late final _paints = [...?widget.step?.paints];
  late final _technique = TextEditingController(text: widget.step?.technique)
    ..addListener(() => setState(() {}));
  late final _note = TextEditingController(text: widget.step?.note)
    ..addListener(() => setState(() {}));
  bool _allTechniques = false;

  @override
  void dispose() {
    _technique.dispose();
    _note.dispose();
    super.dispose();
  }

  bool get _empty =>
      _paints.isEmpty &&
      _technique.text.trim().isEmpty &&
      _note.text.trim().isEmpty;

  /// Picks a Paint from the library not yet in the Step, or creates one, wanted to start with.
  Future<void> _addPaint() async {
    final picked = await showDialog<Object>(
      context: context,
      builder: (_) => AddPaintDialog(
        paints: [
          for (final p in widget.library)
            if (!_paints.any((s) => s.id == p.id)) p,
        ],
      ),
    );
    if (!mounted) return;
    if (picked is Paint) return setState(() => _paints.add(picked));
    if (picked is! String) return;
    final fields = await showDialog<PaintFields>(
      context: context,
      builder: (_) =>
          PaintDialog(paints: widget.library, name: picked, owned: false),
    );
    if (fields == null || !mounted) return;
    final (:brand, :range, :name, :owned) = fields;
    await attempt(context, () async {
      final paint = await widget.vault.addPaint(
        brand: brand,
        range: range,
        name: name,
        owned: owned,
      );
      if (mounted) setState(() => _paints.add(paint));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final typed = tagKey(_technique.text);
    final matching = [
      for (final t in widget.techniques)
        if (typed.isEmpty ||
            widget.techniques.any((k) => tagKey(k) == typed) ||
            tagKey(t).contains(typed))
          t,
    ];
    final chips = _allTechniques ? matching : matching.take(_shown).toList();
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
            Text(widget.title, style: stencil(theme.textTheme.titleLarge)),
            const SizedBox(height: 16),
            Text.rich(
              TextSpan(
                text: 'Paints ',
                children: [
                  TextSpan(
                    text: 'several = mixed',
                    style: TextStyle(
                      fontStyle: FontStyle.italic,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              style: theme.textTheme.titleSmall,
            ),
            for (final p in _paints)
              ListTile(
                key: ValueKey(p.id),
                contentPadding: EdgeInsets.zero,
                title: Text(p.name),
                subtitle: Text(
                  [p.brand, if (p.range.isNotEmpty) p.range].join(' / '),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Remove ${p.name}',
                  onPressed: () => setState(() => _paints.remove(p)),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _addPaint,
                icon: const Icon(Icons.add),
                label: const Text('Add Paint'),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _technique,
              decoration: InputDecoration(
                labelText: 'Technique',
                suffixIcon: _technique.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.cancel),
                        tooltip: 'Clear Technique',
                        onPressed: _technique.clear,
                      ),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in chips)
                  ChoiceChip(
                    label: Text(t),
                    selected: tagKey(t) == typed,
                    onSelected: (_) => _technique.text = t,
                  ),
                if (chips.length < matching.length)
                  ActionChip(
                    label: Text('+${matching.length - chips.length}'),
                    onPressed: () => setState(() => _allTechniques = true),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _note,
              minLines: 2,
              maxLines: null,
              decoration: InputDecoration(
                labelText: 'Note (optional)',
                helperText: _empty
                    ? 'Add a Paint, a Technique or a note'
                    : null,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (widget.onDelete case final delete?)
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                      delete();
                    },
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
                  onPressed: _empty
                      ? null
                      : () => Navigator.pop<StepFields>(context, (
                          paintIds: [for (final p in _paints) p.id],
                          technique: _technique.text,
                          note: _note.text,
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
