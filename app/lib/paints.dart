import 'package:domain_core/domain_core.dart';
import 'package:material_ui/material_ui.dart';

import 'main.dart';
import 'photos.dart';
import 'unit.dart';
import 'theme.dart';
import 'workflows.dart';

/// The paint library: every Paint, under a header per brand, with a search and a Wanted filter for the shopping list.
class PaintsScreen extends StatefulWidget {
  const PaintsScreen({super.key, required this.vault, this.photos});

  final Vault vault;

  /// Passed on to a Unit opened from a Paint.
  final PhotoFiles? photos;

  @override
  State<PaintsScreen> createState() => _PaintsScreenState();
}

class _PaintsScreenState extends State<PaintsScreen> {
  late var _paints = widget.vault.watchPaints();
  late final _links = widget.vault.watchAllUnitPaints();
  List<Paint> _known = const [];
  List<({Collection collection, UnitPaint link})> _usage = const [];
  bool _wantedOnly = false;
  String _query = '';

  /// Opens the Paint dialog, for [paint] or a new one, and saves what it returns.
  Future<void> _edit([Paint? paint]) async {
    final fields = await showDialog<PaintFields>(
      context: context,
      builder: (_) => PaintDialog(
        paints: _known,
        paint: paint,
        usedBy: paint == null
            ? const []
            : paintedUnits(_usage, paintId: paint.id),
        onDelete: paint == null ? null : () => _delete(paint),
        onOpenUnit: (collection, unit) => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => UnitScreen(
              vault: widget.vault,
              photos: widget.photos,
              collection: collection,
              name: unit,
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
    final units = paintedUnits(_usage, paintId: paint.id).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${paint.name}?'),
        content: Text(
          '${paint.label} will be removed from your paints on all your devices.'
          '${units == 0 ? '' : ' ${units == 1 ? '1 Unit uses' : '$units Units use'} it; it will be removed from them.'}',
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
          if (snapshot.error case final error?) {
            return LoadError(
              what: 'your Paints',
              error: error,
              onRetry: () =>
                  setState(() => _paints = widget.vault.watchPaints()),
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
          final shown = paints.where(
            (p) => (!_wantedOnly || !p.owned) && paintMatches(p, _query),
          );
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: TextField(
                  decoration: const InputDecoration(
                    labelText: 'Search Paints',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (q) => setState(() => _query = q),
                ),
              ),
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
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _query.trim().isEmpty
                        ? 'No Paints wanted.'
                        : 'No Paints match.',
                    textAlign: TextAlign.center,
                  ),
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
                    subtitle: p.range.isEmpty ? null : Text(p.range),
                    onTap: () => _edit(p),
                    trailing: ChoiceChip(
                      label: Text(p.owned ? 'Owned' : 'Wanted'),
                      selected: p.owned,
                      onSelected: (owned) => attempt(
                        context,
                        () => widget.vault.setPaintOwned(p.id, owned),
                      ),
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
    this.name = '',
    this.owned = true,
    this.usedBy = const [],
    this.onOpenUnit,
    this.onDelete,
  });

  /// The library, for suggestions.
  final List<Paint> paints;

  /// The Paint being edited; null for a new one.
  final Paint? paint;

  /// The name a new Paint starts with.
  final String name;

  /// Whether a new Paint starts as owned.
  final bool owned;

  /// The Units that use the Paint; tapping one closes the dialog and calls [onOpenUnit].
  final List<({Collection collection, String unit})> usedBy;
  final void Function(Collection collection, String unit)? onOpenUnit;

  /// Shown as Delete when set; closes the dialog and calls it, which asks to confirm.
  final VoidCallback? onDelete;

  @override
  State<PaintDialog> createState() => _PaintDialogState();
}

class _PaintDialogState extends State<PaintDialog> {
  late final _brand = TextEditingController(text: widget.paint?.brand);
  late final _range = TextEditingController(text: widget.paint?.range);
  late final _name = TextEditingController(
    text: widget.paint?.name ?? widget.name,
  );
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
              for (final (:collection, :unit) in widget.usedBy)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(unit),
                  subtitle: Text(collection.name),
                  onTap: () {
                    Navigator.pop(context);
                    widget.onOpenUnit?.call(collection, unit);
                  },
                ),
            ],
          ],
        ),
      ),
      actions: [
        if (widget.onDelete case final delete?)
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              delete();
            },
            style: destructive(context),
            child: const Text('Delete'),
          ),
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

/// Picks a Paint from [paints], searched as typed; pops the Paint, or the search text for a new Paint.
class AddPaintDialog extends StatefulWidget {
  const AddPaintDialog({super.key, required this.paints});

  final List<Paint> paints;

  @override
  State<AddPaintDialog> createState() => _AddPaintDialogState();
}

class _AddPaintDialogState extends State<AddPaintDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final g in groupByBrand(
        widget.paints.where((p) => paintMatches(p, _query)),
      ))
        ...g.paints,
    ];
    return AlertDialog(
      title: const Text('Add Paint'),
      contentPadding: const EdgeInsets.fromLTRB(0, 20, 0, 0),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Search Paints',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (q) => setState(() => _query = q),
              ),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: const Icon(Icons.add),
              title: const Text('New Paint…'),
              onTap: () => Navigator.pop(context, _query.trim()),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in shown)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 24,
                      ),
                      title: Text(p.label),
                      onTap: () => Navigator.pop(context, p),
                    ),
                ],
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
      ],
    );
  }
}
