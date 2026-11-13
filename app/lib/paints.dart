import 'package:domain_core/domain_core.dart';
import 'package:material_ui/material_ui.dart';

import 'main.dart';
import 'photos.dart';
import 'squad.dart';
import 'theme.dart';
import 'workflows.dart';

/// The paint library: every Paint, under a header per brand, with a Wanted filter for the shopping list.
class PaintsScreen extends StatefulWidget {
  const PaintsScreen({super.key, required this.vault, this.photos});

  final Vault vault;

  /// Passed on to a Squad opened from a Paint.
  final PhotoFiles? photos;

  @override
  State<PaintsScreen> createState() => _PaintsScreenState();
}

class _PaintsScreenState extends State<PaintsScreen> {
  late final _paints = widget.vault.watchPaints();
  late final _links = widget.vault.watchAllSquadPaints();
  List<Paint> _known = const [];
  List<({Collection collection, SquadPaint link})> _usage = const [];
  bool _wantedOnly = false;

  /// Opens the Paint dialog, for [paint] or a new one, and saves what it returns.
  Future<void> _edit([Paint? paint]) async {
    final fields = await showDialog<PaintFields>(
      context: context,
      builder: (_) => PaintDialog(
        paints: _known,
        paint: paint,
        usedBy: paint == null
            ? const []
            : paintedSquads(_usage, paintId: paint.id),
        onOpenSquad: (collection, squad) => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => SquadScreen(
              vault: widget.vault,
              photos: widget.photos,
              collection: collection,
              name: squad,
            ),
          ),
        ),
      ),
    );
    if (fields == null || !mounted) return;
    final (:brand, :range, :name, :owned) = fields;
    await attempt(
      context,
      () => paint == null
          ? widget.vault.addPaint(
              brand: brand,
              range: range,
              name: name,
              owned: owned,
            )
          : widget.vault.editPaint(
              Paint(
                id: paint.id,
                brand: brand,
                range: range,
                name: name,
                owned: owned,
              ),
            ),
    );
  }

  Future<void> _delete(Paint paint) async {
    final squads = paintedSquads(_usage, paintId: paint.id).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${paint.name}?'),
        content: Text(
          '${paint.brand} ${paint.range} ${paint.name} will be removed from your paints on all your devices.'
          '${squads == 0 ? '' : ' ${squads == 1 ? '1 Squad uses' : '$squads Squads use'} it; it will be removed from them.'}',
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
      await attempt(context, () => widget.vault.deletePaint(paint.id));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Paints')),
    body: StreamBuilder(
      stream: _links,
      builder: (context, links) => StreamBuilder(
        stream: _paints,
        builder: (context, snapshot) {
          _usage = links.data ?? const [];
          if (snapshot.hasError) {
            return Center(
              child: Text('Could not load Paints: ${snapshot.error}'),
            );
          }
          final paints = snapshot.data;
          if (paints == null) {
            return const Center(child: CircularProgressIndicator());
          }
          _known = paints;
          if (paints.isEmpty) {
            return EmptyState(
              explanation: 'Keep track of the Paints you own, and the ones you want to buy.',
              label: 'New Paint',
              onPressed: _edit,
            );
          }
          final shown = _wantedOnly ? paints.where((p) => !p.owned) : paints;
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FilterChip(
                    label: const Text('Wanted'),
                    selected: _wantedOnly,
                    onSelected: (on) => setState(() => _wantedOnly = on),
                  ),
                ),
              ),
              if (shown.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No Paints wanted.', textAlign: TextAlign.center),
                ),
              for (final g in groupByBrand(shown)) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Text(
                    g.brand,
                    style: stencil(Theme.of(context).textTheme.titleSmall),
                  ),
                ),
                for (final p in g.paints)
                  ListTile(
                    key: ValueKey(p.id),
                    title: Text(p.name),
                    subtitle: Text(p.range),
                    onTap: () => _edit(p),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: p.owned
                              ? 'Owned: mark wanted'
                              : 'Wanted: mark owned',
                          icon: Icon(
                            p.owned
                                ? Icons.check_circle
                                : Icons.shopping_cart_outlined,
                          ),
                          onPressed: () => attempt(
                            context,
                            () => widget.vault.setPaintOwned(p.id, !p.owned),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Delete Paint',
                          icon: const Icon(Icons.delete),
                          style: destructive(context),
                          onPressed: () => _delete(p),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    ),
    floatingActionButton: FloatingActionButton(
      onPressed: _edit,
      tooltip: 'New Paint',
      child: const Icon(Icons.add),
    ),
  );
}

typedef PaintFields = ({String brand, String range, String name, bool owned});

/// Asks for a Paint's brand, range and name, suggesting brands in use and the ranges of the brand typed, and
/// whether it is owned. Returns the fields as typed; the Vault checks them.
class PaintDialog extends StatefulWidget {
  const PaintDialog({
    super.key,
    this.paints = const [],
    this.paint,
    this.owned = true,
    this.usedBy = const [],
    this.onOpenSquad,
  });

  /// The library, for suggestions.
  final List<Paint> paints;

  /// The Paint being edited; null for a new one.
  final Paint? paint;

  /// Whether a new Paint starts as owned.
  final bool owned;

  /// The Squads that use the Paint; tapping one closes the dialog and calls [onOpenSquad].
  final List<({Collection collection, String squad})> usedBy;
  final void Function(Collection collection, String squad)? onOpenSquad;

  @override
  State<PaintDialog> createState() => _PaintDialogState();
}

class _PaintDialogState extends State<PaintDialog> {
  late final _brand = TextEditingController(text: widget.paint?.brand);
  late final _range = TextEditingController(text: widget.paint?.range);
  late final _name = TextEditingController(text: widget.paint?.name);
  final _brandFocus = FocusNode();
  final _rangeFocus = FocusNode();
  late bool _owned = widget.paint?.owned ?? widget.owned;

  @override
  void dispose() {
    for (final c in [_brand, _range, _name]) {
      c.dispose();
    }
    _brandFocus.dispose();
    _rangeFocus.dispose();
    super.dispose();
  }

  /// [used] that start with [typed] but are not it, ignoring case; one spelling each.
  static List<String> _suggest(Iterable<String> used, String typed) {
    final byKey = <String, String>{};
    for (final u in used) {
      byKey.putIfAbsent(tagKey(u), () => u);
    }
    return [
      for (final MapEntry(key: k, value: u) in byKey.entries)
        if (k.startsWith(tagKey(typed)) && k != tagKey(typed)) u,
    ]..sort((a, b) => tagKey(a).compareTo(tagKey(b)));
  }

  Widget _suggesting(
    String label,
    TextEditingController controller,
    FocusNode focusNode,
    Iterable<String> Function() used,
  ) => Autocomplete<String>(
    textEditingController: controller,
    focusNode: focusNode,
    optionsBuilder: (value) => _suggest(used(), value.text),
    fieldViewBuilder: (context, field, focus, submit) => TextField(
      controller: field,
      focusNode: focus,
      decoration: InputDecoration(labelText: label),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final editing = widget.paint != null;
    return AlertDialog(
      title: Text(editing ? 'Edit Paint' : 'New Paint'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _suggesting(
              'Brand',
              _brand,
              _brandFocus,
              () => widget.paints.map((p) => p.brand),
            ),
            _suggesting(
              'Range',
              _range,
              _rangeFocus,
              () => [
                for (final p in widget.paints)
                  if (tagKey(p.brand) == tagKey(_brand.text)) p.range,
              ],
            ),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Owned'),
              subtitle: Text(_owned ? 'In my paints' : 'Wanted'),
              value: _owned,
              onChanged: (v) => setState(() => _owned = v),
            ),
            if (widget.usedBy.isNotEmpty) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Used by',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              for (final (:collection, :squad) in widget.usedBy)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(squad),
                  subtitle: Text(collection.name),
                  onTap: () {
                    Navigator.pop(context);
                    widget.onOpenSquad?.call(collection, squad);
                  },
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop<PaintFields>(context, (
            brand: _brand.text,
            range: _range.text,
            name: _name.text,
            owned: _owned,
          )),
          child: Text(editing ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}
