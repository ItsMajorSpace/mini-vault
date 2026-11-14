import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// A titled block of a screen: a [SectionHeader] with [title], [count] and [actions], then [child] in a filled card
/// unless [card] is false.
class Section extends StatelessWidget {
  const Section({
    super.key,
    required this.title,
    this.count,
    this.actions = const [],
    required this.child,
    this.card = true,
  });

  final String title;
  final int? count;

  /// IconButtons, shown in the accent colour.
  final List<Widget> actions;
  final Widget child;
  final bool card;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title: title, count: count, actions: actions),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: card
              ? Card.filled(
                  margin: EdgeInsets.zero,
                  clipBehavior: Clip.antiAlias,
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  child: child,
                )
              : child,
        ),
      ],
    ),
  );
}

/// A [Section]'s 48dp header row, also used alone in flat lists: an accent bar and caps [title] in the heading font, an
/// optional [count], trailing [actions] in the accent colour.
///
/// Collapsible when [expanded] is non-null: the whole row calls [onToggle], a chevron comes last, and while collapsed
/// the row sits on the lowest surface with an outline bar and [summary] as one muted line under the title. [muted]
/// gives the outline bar and a muted title while expanded too.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.count,
    this.actions = const [],
    this.expanded,
    this.onToggle,
    this.summary,
    this.muted = false,
  });

  final String title;
  final int? count;

  /// IconButtons, shown in the accent colour before the chevron.
  final List<Widget> actions;

  /// Null: not collapsible.
  final bool? expanded;
  final VoidCallback? onToggle;

  /// Shown under the title while collapsed.
  final String? summary;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colours = theme.colorScheme;
    final collapsed = expanded == false;
    final quiet = muted || collapsed;
    final titleRow = Row(
      children: [
        Flexible(
          child: Text(
            title.toUpperCase(),
            overflow: TextOverflow.ellipsis,
            style: heading(context)?.copyWith(
              letterSpacing: 1.2,
              color: muted ? colours.onSurfaceVariant : null,
            ),
          ),
        ),
        if (count case final n?)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(
              '$n',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colours.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
    final row = Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: EdgeInsets.fromLTRB(16, collapsed ? 8 : 0, 0, collapsed ? 8 : 0),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 18,
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
              color: quiet ? colours.outline : colours.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: collapsed && summary != null
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      titleRow,
                      const SizedBox(height: 4),
                      Text(
                        summary!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colours.onSurfaceVariant,
                        ),
                      ),
                    ],
                  )
                : titleRow,
          ),
          IconButtonTheme(
            data: IconButtonThemeData(
              style: IconButton.styleFrom(foregroundColor: colours.primary),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: actions),
          ),
          if (expanded case final open?)
            SizedBox.square(
              dimension: 48,
              child: Icon(
                open ? Icons.expand_less : Icons.expand_more,
                color: colours.onSurfaceVariant,
              ),
            )
          else
            const SizedBox(width: 16),
        ],
      ),
    );
    if (expanded == null) return row;
    return Semantics(
      expanded: expanded,
      child: Material(
        color: collapsed ? colours.surfaceContainerLowest : Colors.transparent,
        child: InkWell(onTap: onToggle, child: row),
      ),
    );
  }
}

/// Which groups of a list this device shows collapsed, kept one key per line in [file]. Not synced: each device keeps
/// its own. Keys: `game-system:` and the lower-cased Game System ('' for none).
class CollapsedGroups extends ChangeNotifier {
  CollapsedGroups._(this.file, this._keys);

  final File file;
  final Set<String> _keys;

  /// The groups saved in [file]; none (all expanded) when there is no file.
  static Future<CollapsedGroups> load(File file) async => CollapsedGroups._(
    file,
    await file.exists() ? (await file.readAsLines()).toSet() : {},
  );

  bool isCollapsed(String key) => _keys.contains(key);

  void toggle(String key) {
    if (!_keys.remove(key)) _keys.add(key);
    notifyListeners();
    // Sync, so quick toggles are written in order.
    file.writeAsStringSync(_keys.map((k) => '$k\n').join());
  }
}

/// The one italic line an empty [Section] shows, so the sections never shift.
class SectionHint extends StatelessWidget {
  const SectionHint(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Text(
      text,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontStyle: FontStyle.italic,
      ),
    ),
  );
}

/// [tiles] in a [Section]'s card, a hairline between each.
Widget sectionRows(BuildContext context, Iterable<Widget> tiles) => Column(
  children: ListTile.divideTiles(context: context, tiles: tiles).toList(),
);
