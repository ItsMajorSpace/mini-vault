/// Managing a Collection's Categories (ADR 0011): rename, reorder, add and delete them.
library;

import 'package:domain_core/domain_core.dart';
import 'package:material_ui/material_ui.dart';

import 'theme.dart';
import 'unit.dart' show modelCountText, showUndo;
import 'workflows.dart' show askName, attempt;

/// Opens the Categories sheet for [collection].
Future<void> showCategoriesSheet(
  BuildContext context,
  Vault vault,
  Collection collection,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  // Its own Scaffold, so the Undo SnackBar shows above the sheet rather than under its barrier.
  builder: (_) => FractionallySizedBox(
    heightFactor: 0.7,
    child: ScaffoldMessenger(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: CategoriesSheet(vault: vault, collection: collection),
      ),
    ),
  ),
);

/// The Collection's Categories with their Unit counts: tap to rename, drag to reorder, delete; Uncategorised last.
class CategoriesSheet extends StatefulWidget {
  const CategoriesSheet({
    super.key,
    required this.vault,
    required this.collection,
  });

  final Vault vault;
  final Collection collection;

  @override
  State<CategoriesSheet> createState() => _CategoriesSheetState();
}

class _CategoriesSheetState extends State<CategoriesSheet> {
  late final _groups = widget.vault.watchUnitsByCategory(widget.collection);

  Vault get vault => widget.vault;
  Collection get collection => widget.collection;

  static String _units(int n) => switch (n) {
    0 => 'No Units',
    1 => '1 Unit',
    _ => '$n Units',
  };

  /// Asks for a name no Category but [except] has, ignoring case; null if cancelled.
  Future<String?> _askName(
    List<Category> categories,
    String title, [
    Category? except,
  ]) => askName(context, title, except?.name ?? '', (name) {
    final taken = categories
        .where((c) => c.id != except?.id && tagKey(c.name) == tagKey(name))
        .firstOrNull;
    return taken == null
        ? null
        : '${collection.name} already has a Category "${taken.name}"';
  });

  Future<void> _add(List<Category> categories) async {
    final name = await _askName(categories, 'New Category');
    if (name != null && mounted) {
      await attempt(context, () => vault.addCategory(collection.id, name));
    }
  }

  Future<void> _rename(List<Category> categories, Category category) async {
    final name = await _askName(categories, 'Rename Category', category);
    if (name != null && mounted) {
      await attempt(context, () => vault.renameCategory(category, name));
    }
  }

  /// With Units, asks first; empty, deletes at once offering Undo.
  Future<void> _delete(
    List<Category> categories,
    Category category,
    List<Unit> units,
  ) async {
    if (units.isEmpty) {
      final index = categories.indexOf(category);
      await attempt(context, () => vault.deleteCategory(category.id));
      if (mounted) {
        showUndo(context, 'Deleted ${category.name}', () async {
          final restored = await vault.addCategory(
            collection.id,
            category.name,
          );
          await vault.moveCategory(restored, index);
        });
      }
      return;
    }
    final models = units.fold(0, (sum, u) => sum + u.modelCount);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${category.name}?'),
        content: Text(
          'Its ${_units(units.length)} (${modelCountText(models)}) stay in ${collection.name} '
          'and become Uncategorised. Nothing else is deleted.',
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
      await attempt(context, () => vault.deleteCategory(category.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    return StreamBuilder(
      stream: _groups,
      builder: (context, snapshot) {
        final groups = snapshot.data ?? const [];
        final categories = [for (final g in groups) ?g.category];
        final uncategorised =
            groups.where((g) => g.category == null).firstOrNull?.units ??
            const [];
        return ReorderableListView(
          buildDefaultDragHandles: false,
          onReorderItem: (from, to) =>
              attempt(context, () => vault.moveCategory(categories[from], to)),
          header: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Categories', style: theme.textTheme.titleLarge),
                Text(
                  'Tap to rename, drag to reorder. Units keep their order within a Category.',
                  style: muted,
                ),
              ],
            ),
          ),
          footer: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                title: const Text(
                  'Uncategorised',
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
                subtitle: Text('${_units(uncategorised.length)} · always last'),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: OutlinedButton.icon(
                  onPressed: () => _add(categories),
                  icon: const Icon(Icons.add),
                  label: const Text('New Category'),
                ),
              ),
            ],
          ),
          children: [
            for (final (i, g) in groups.indexed)
              if (g.category case final category?)
                ListTile(
                  key: ValueKey(category.id),
                  onTap: () => _rename(categories, category),
                  contentPadding: const EdgeInsets.only(left: 16),
                  title: Text(category.name),
                  subtitle: Text(_units(g.units.length)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        color: theme.colorScheme.error,
                        tooltip: 'Delete ${category.name}',
                        onPressed: () => _delete(categories, category, g.units),
                      ),
                      ReorderableDragStartListener(
                        index: i,
                        child: SizedBox.square(
                          dimension: 48,
                          child: Icon(
                            Icons.drag_handle,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        );
      },
    );
  }
}
