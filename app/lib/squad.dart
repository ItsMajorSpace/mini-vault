import 'package:domain_core/domain_core.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'main.dart';
import 'paints.dart';
import 'photos.dart';
import 'theme.dart';
import 'workflows.dart';

String modelCountText(int n) => n == 1 ? '1 model' : '$n models';

/// A Squad's ladder: every Stage of the Workflow in order, with the Squad's model count at each.
class SquadScreen extends StatefulWidget {
  const SquadScreen({
    super.key,
    required this.vault,
    this.photos,
    required this.collection,
    required this.name,
  });

  final Vault vault;
  final PhotoFiles? photos;
  final Collection collection;

  /// The Squad's name when opened; the screen follows it through a rename.
  final String name;

  @override
  State<SquadScreen> createState() => _SquadScreenState();
}

class _SquadScreenState extends State<SquadScreen> {
  late final _squads = widget.vault.watchSquads(widget.collection);
  late final _library = widget.vault.watchPaints();
  late final _links = widget.vault.watchAllSquadPaints();
  late String _name = widget.name;

  // Tags are read once per set of Units, and again on return from a Unit screen, where they are edited.
  String? _tagsFor;
  Future<List<String>>? _tags;

  Future<List<String>> _tagsOf(Squad squad) {
    final ids = squad.units.map((u) => u.id).join(',');
    if (ids != _tagsFor) {
      _tagsFor = ids;
      _tags =
          Future.wait([for (final u in squad.units) widget.vault.tagsOf(u.id)])
              .then((lists) {
                final byKey = <String, String>{};
                for (final t in lists.expand((l) => l)) {
                  byKey.putIfAbsent(tagKey(t), () => t);
                }
                return byKey.values.toList()
                  ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
              });
    }
    return _tags!;
  }

  Future<void> _rename(Squad squad) async {
    final name = await askName(context, 'Rename Squad', squad.name);
    if (name == null || !mounted) return;
    await attempt(context, () async {
      await widget.vault.renameSquad(squad, name);
      if (mounted) setState(() => _name = name.trim());
    });
  }

  /// The Squad's Paints, with their notes and the wanted ones marked, and actions to add, copy, edit and remove them.
  Widget _paints(
    List<Paint> library,
    List<({Collection collection, SquadPaint link})> all,
  ) {
    final used = [
      for (final (:collection, :link) in all)
        if (collection.id == widget.collection.id && link.squad == _name) link,
    ];
    final others = [
      for (final s in paintedSquads(all))
        if (s.collection.id != widget.collection.id || s.squad != _name) s,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Text(
            'Paints',
            style: stencil(Theme.of(context).textTheme.titleSmall),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (others.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.content_copy),
                  tooltip: 'Copy Paints from another Squad',
                  onPressed: () => _copyPaints(others),
                ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                tooltip: 'Add Paint',
                onPressed: () => _addPaint(library, used),
              ),
            ],
          ),
        ),
        for (final l in used)
          ListTile(
            key: ValueKey(l.id),
            title: Text(l.paint.name),
            subtitle: Text(
              [
                '${l.paint.brand} / ${l.paint.range}',
                if (l.note.isNotEmpty) l.note,
                if (!l.paint.owned) 'Wanted',
              ].join(' · '),
            ),
            onTap: () => _editNote(l),
            trailing: IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              tooltip: 'Remove Paint',
              onPressed: () =>
                  attempt(context, () => widget.vault.removeSquadPaint(l.id)),
            ),
          ),
      ],
    );
  }

  /// Picks a Paint from the library that the Squad does not use yet, or creates one, wanted to start with.
  Future<void> _addPaint(List<Paint> library, List<SquadPaint> used) async {
    final usedIds = {for (final l in used) l.paint.id};
    final picked = await showDialog<Object>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Add Paint'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'new'),
            child: const Text('New Paint…'),
          ),
          for (final p in library)
            if (!usedIds.contains(p.id))
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, p),
                child: Text('${p.brand} / ${p.range} / ${p.name}'),
              ),
        ],
      ),
    );
    if (!mounted) return;
    if (picked is Paint) {
      return attempt(
        context,
        () =>
            widget.vault.addSquadPaint(widget.collection.id, _name, picked.id),
      );
    }
    if (picked != 'new') return;
    final fields = await showDialog<PaintFields>(
      context: context,
      builder: (_) => PaintDialog(paints: library, owned: false),
    );
    if (fields == null || !mounted) return;
    final (:brand, :range, :name, :owned) = fields;
    await attempt(
      context,
      () => widget.vault.addNewSquadPaint(
        widget.collection.id,
        _name,
        brand: brand,
        range: range,
        name: name,
        owned: owned,
      ),
    );
  }

  Future<void> _copyPaints(
    List<({Collection collection, String squad})> others,
  ) async {
    final from = await showDialog<({Collection collection, String squad})>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Copy Paints from'),
        children: [
          for (final s in others)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, s),
              child: Text('${s.squad} · ${s.collection.name}'),
            ),
        ],
      ),
    );
    if (from == null || !mounted) return;
    await attempt(
      context,
      () => widget.vault.copySquadPaints(
        fromCollectionId: from.collection.id,
        from: from.squad,
        toCollectionId: widget.collection.id,
        to: _name,
      ),
    );
  }

  Future<void> _editNote(SquadPaint link) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => NameDialog(
        title: 'Note for ${link.paint.name}',
        initial: link.note,
        label: 'Where or how',
      ),
    );
    if (note == null || !mounted) return;
    await attempt(context, () => widget.vault.setSquadPaintNote(link.id, note));
  }

  /// Merges the other Units at one Stage into the first: tapping the Merge chip is the explicit choice.
  Future<void> _merge(List<Unit> units) => attempt(context, () async {
    for (final other in units.skip(1)) {
      await widget.vault.mergeUnits(units.first, other);
    }
  });

  /// Sets how many of the Squad's models are at one Stage, without moving any: a recount of the Unit there or, once
  /// confirmed, deleting it when set to 0. Only for a Stage with exactly one Unit.
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
    // Not disposed: the closing dialog's TextField still uses it (as in the Unit screen's move dialog).
    final n = int.tryParse(count.text);
    if (save != true || n == null || n == g.modelCount || !mounted) return;
    final unit = g.units.single;
    if (n > 0) {
      return attempt(
        context,
        () => widget.vault.editUnit(unit.id, modelCount: n),
      );
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete the Unit at ${g.stage.name}?'),
        content: Text(
          'Its ${modelCountText(unit.modelCount)}, photos and history will be deleted on all your devices.',
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
    if ((confirmed ?? false) && mounted) {
      await attempt(context, () => widget.vault.deleteUnit(unit.id));
    }
  }

  Future<void> _sheet(Squad squad, StageGroup g) => showMoveSheet(
    context,
    widget.vault,
    widget.collection,
    squad,
    g,
    // Several Units here: Merge them first, as before.
    onRecount: g.units.length > 1 ? null : () => _recount(g),
    onDetails: () => _details(g.units),
  );

  /// Opens the only Unit, or asks which one when there are several.
  Future<void> _details(List<Unit> units) async {
    final unit = units.length == 1
        ? units.single
        : await showDialog<Unit>(
            context: context,
            builder: (context) => SimpleDialog(
              title: const Text('Which Unit?'),
              children: [
                for (final u in units)
                  ListTile(
                    title: Text(modelCountText(u.modelCount)),
                    subtitle: u.notes.isEmpty ? null : Text(u.notes),
                    onTap: () => Navigator.pop(context, u),
                  ),
              ],
            ),
          );
    if (unit != null && mounted) await _open(unit);
  }

  Future<void> _open(Unit unit) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => UnitScreen(
          vault: widget.vault,
          photos: widget.photos,
          collection: widget.collection,
          unitId: unit.id,
        ),
      ),
    );
    if (mounted) setState(() => _tagsFor = null);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: _squads,
      builder: (context, snapshot) {
        final squad = snapshot.data?.where((s) => s.name == _name).firstOrNull;
        return Scaffold(
          appBar: AppBar(
            title: Text(_name),
            actions: [
              if (squad != null)
                IconButton(
                  icon: const Icon(Icons.edit),
                  tooltip: 'Rename Squad',
                  onPressed: () => _rename(squad),
                ),
            ],
          ),
          body: switch (snapshot) {
            AsyncSnapshot(:final error?) => Center(
              child: Text('Could not load the Squad: $error'),
            ),
            AsyncSnapshot(data: null) => const Center(
              child: CircularProgressIndicator(),
            ),
            _ when squad == null => const Center(
              child: Text('This Squad has no Units left'),
            ),
            _ => ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                FutureBuilder(
                  future: _tagsOf(squad),
                  builder: (context, tags) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final t in tags.data ?? const <String>[])
                          Chip(label: Text(t)),
                      ],
                    ),
                  ),
                ),
                for (final g in squad.stages)
                  // Empty Stages stay in Workflow order, dimmed, with nothing to move.
                  Opacity(
                    opacity: g.modelCount == 0 ? 0.38 : 1,
                    child: ListTile(
                      dense: true,
                      leading: Icon(
                        Icons.circle,
                        size: 12,
                        color: stageColour(g.stage.colour),
                      ),
                      title: Text(g.stage.name),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (g.units.length > 1)
                            ActionChip(
                              label: const Text('Merge'),
                              tooltip: 'Merge the ${g.units.length} Units here',
                              onPressed: () => _merge(g.units),
                            ),
                          const SizedBox(width: 8),
                          Text(modelCountText(g.modelCount)),
                        ],
                      ),
                      onTap: g.modelCount == 0 ? null : () => _sheet(squad, g),
                    ),
                  ),
                StreamBuilder(
                  stream: _library,
                  builder: (context, library) => StreamBuilder(
                    stream: _links,
                    builder: (context, links) =>
                        library.data == null || links.data == null
                        ? const SizedBox.shrink()
                        : _paints(library.data!, links.data!),
                  ),
                ),
              ],
            ),
          },
          floatingActionButton: snapshot.data == null
              ? null
              : FloatingActionButton(
                  onPressed: () => addUnit(
                    context,
                    widget.vault,
                    widget.collection,
                    [for (final s in snapshot.data!) s.name],
                    name: _name,
                  ),
                  tooltip: 'New Unit',
                  child: const Icon(Icons.add),
                ),
        );
      },
    );
  }
}

/// The Move sheet for a Stage of [squad] with models: how many to move and where, or recount them ([onRecount], null
/// to disable), or open their details.
Future<void> showMoveSheet(
  BuildContext context,
  Vault vault,
  Collection collection,
  Squad squad,
  StageGroup from, {
  VoidCallback? onRecount,
  required VoidCallback onDetails,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _MoveSheet(
    from: from,
    stages: [for (final s in squad.stages) s.stage],
    onMove: (n, to) => attempt(
      context,
      () => vault.moveModels(collection, squad.name, from.stage.id, to.id, n),
    ),
    onRecount: onRecount,
    onDetails: onDetails,
  ),
);

/// Moves [from]'s models: a count from 1 to all of them, and a target Stage, the next one to start with.
class _MoveSheet extends StatefulWidget {
  const _MoveSheet({
    required this.from,
    required this.stages,
    required this.onMove,
    required this.onRecount,
    required this.onDetails,
  });

  final StageGroup from;

  /// The Workflow's Stages, in order.
  final List<Stage> stages;
  final void Function(int count, Stage to) onMove;
  final VoidCallback? onRecount;
  final VoidCallback onDetails;

  @override
  State<_MoveSheet> createState() => _MoveSheetState();
}

class _MoveSheetState extends State<_MoveSheet> {
  int _count = 1;
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
            Row(
              children: [
                TextButton(
                  onPressed: widget.onRecount == null
                      ? null
                      : _then(widget.onRecount!),
                  child: const Text('Edit count'),
                ),
                TextButton(
                  onPressed: _then(widget.onDetails),
                  child: const Text('Details'),
                ),
              ],
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
