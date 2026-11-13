import 'package:domain_core/domain_core.dart';
import 'package:material_ui/material_ui.dart';

import 'main.dart';
import 'photos.dart';
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

  /// Merges the other Units at one Stage into the first: tapping the Merge chip is the explicit choice.
  Future<void> _merge(List<Unit> units) => attempt(context, () async {
    for (final other in units.skip(1)) {
      await widget.vault.mergeUnits(units.first, other);
    }
  });

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
                for (final g in squad.stages) ...[
                  ListTile(
                    title: Text(g.stage.name),
                    subtitle: LinearProgressIndicator(
                      value: squad.modelCount == 0
                          ? 0
                          : g.modelCount / squad.modelCount,
                    ),
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
                    // shortcut: with several Units at a Stage this opens the first; Merge them to see one.
                    onTap: g.units.isEmpty ? null : () => _open(g.units.first),
                  ),
                  // Room between Stages for the move buttons to come (#36).
                  const SizedBox(height: 16),
                ],
              ],
            ),
          },
        );
      },
    );
  }
}
