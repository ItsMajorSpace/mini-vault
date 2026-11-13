import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// A titled block of a screen: an amber bar and stencil caps [title], an optional [count], trailing [actions] in
/// amber, then [child] in a filled card unless [card] is false.
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

  /// IconButtons, shown in amber.
  final List<Widget> actions;
  final Widget child;
  final bool card;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colours = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 48,
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 18,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    color: colours.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Text(
                  title.toUpperCase(),
                  style: stencil(theme.textTheme.titleSmall)
                      ?.copyWith(letterSpacing: 1.2),
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
                const Spacer(),
                IconButtonTheme(
                  data: IconButtonThemeData(
                    style: IconButton.styleFrom(
                      foregroundColor: colours.primary,
                    ),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: actions),
                ),
              ],
            ),
          ),
          if (card)
            Card.filled(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              color: colours.surfaceContainerLow,
              child: child,
            )
          else
            child,
        ],
      ),
    );
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
