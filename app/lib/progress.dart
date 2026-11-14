import 'package:domain_core/domain_core.dart';
import 'package:material_ui/material_ui.dart';

import 'section.dart';
import 'theme.dart';

/// A Collection's row in a group card: its [ProgressRing], [collection]'s name with [match] highlighted, its
/// [progressWords] and a [StageBar], then a chevron; kept live as Batches and the Workflow change. Tapping calls [onTap].
class CollectionRow extends StatefulWidget {
  const CollectionRow({
    super.key,
    required this.vault,
    required this.collection,
    this.match = '',
    required this.onTap,
  });

  final Vault vault;
  final Collection collection;
  final String match;
  final VoidCallback onTap;

  @override
  State<CollectionRow> createState() => _CollectionRowState();
}

class _CollectionRowState extends State<CollectionRow> {
  late final _progress = widget.vault.watchProgress(widget.collection);

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: widget.onTap,
    child: Container(
      constraints: const BoxConstraints(minHeight: 76),
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      child: StreamBuilder(
        stream: _progress,
        builder: (context, snapshot) {
          final p = snapshot.data;
          return Row(
            children: [
              if (p != null) ...[ProgressRing(p), const SizedBox(width: 14)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      highlight(context, widget.collection.name, widget.match),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (p != null) ...[
                      Text(
                        progressWords(p),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 6),
                      StageBar(p, height: 6),
                    ],
                  ],
                ),
              ),
              SizedBox.square(
                dimension: 48,
                child: Icon(
                  Icons.chevron_right,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// A recently moved Unit as a 164dp card: its name with an open chevron, its Collection, a [StageBar] and
/// "Move from" its from-Stage. Tapping the card calls [onMove]; the chevron, [onOpen].
class RecentUnitCard extends StatelessWidget {
  const RecentUnitCard(
    this.recent, {
    super.key,
    required this.onMove,
    required this.onOpen,
  });

  final RecentUnit recent;
  final VoidCallback onMove;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colours = theme.colorScheme;
    return SizedBox(
      width: 164,
      child: Card.filled(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        color: colours.surfaceContainerLow,
        child: InkWell(
          onTap: onMove,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 0, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          recent.unit.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_right),
                      tooltip: 'Open ${recent.unit.name}',
                      onPressed: onOpen,
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        recent.collection.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colours.onSurfaceVariant),
                      ),
                      const SizedBox(height: 6),
                      StageBar(recent.unit.progress, height: 6),
                    ],
                  ),
                ),
                const Spacer(),
                Row(
                  children: [
                    Icon(Icons.swap_vert, size: 18, color: colours.primary),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Move from ${recent.from.stage.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: colours.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// [progress]'s finished share as a ring around the rounded %, in the heading font from [size] 64 up.
class ProgressRing extends StatelessWidget {
  const ProgressRing(this.progress, {super.key, this.size = 48});

  final Progress progress;
  final double size;

  @override
  Widget build(BuildContext context) {
    final percent = '${(progress.finishedShare * 100).round()}%';
    return Semantics(
      label: '$percent finished',
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: progress.finishedShare,
                  strokeWidth: 4,
                  backgroundColor: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest,
                ),
              ),
              Text(
                percent,
                style: size >= 64
                    ? heading(context)
                    : const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "86 / 140 finished · 12 wanted", leaving out wanted when there are none.
String progressWords(Progress p) => [
  '${p.finished} / ${p.owned} finished',
  if (p.wanted > 0) '${p.wanted} wanted',
].join(' · ');

/// A collapsed group's line: "3 Collections · 86 / 140 finished · 12 wanted" for [count] [noun]s with [progress].
String groupSummary(int count, String noun, Progress progress) =>
    '$count $noun${count == 1 ? '' : 's'} · ${progressWords(progress)}';

/// [progress]'s owned models as one segment per Stage, in its colour and sized by model count, the latest Stage
/// leftmost, so the finished part fills from the left. Its wanted models follow as one outlined segment in the
/// Wishlist colour, so they read as not yet owned; wanted and owned together fill the bar.
class StageBar extends StatelessWidget {
  const StageBar(this.progress, {super.key, this.height = 4});

  final Progress progress;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    foregroundDecoration: BoxDecoration(border: stageOutline(context)),
    child: ColoredBox(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final s in progress.stages.reversed)
            Expanded(
              flex: s.models,
              child: ColoredBox(color: stageColour(s.stage.colour)),
            ),
          if (progress.wanted > 0)
            Expanded(
              flex: progress.wanted,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  // shortcut: the starter Wishlist colour, not the Workflow's own first Stage; carry that Stage's
                  // colour in Progress once Stages are recoloured or Workflows mixed on one bar.
                  border: Border.all(
                    color: stageColour(Vault.stageColours.first),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// Progress peeking from the bottom of the screen: [count] [noun]s and the owned, finished and wanted totals over a
/// [StageBar]. Dragged up (or its button tapped) it shows a [StageBreakdown] per Workflow. Hidden while
/// [count] is 0. Meant for [Scaffold.bottomNavigationBar], which shrinks the body so nothing hides behind it.
class ProgressDrawer extends StatefulWidget {
  const ProgressDrawer({
    super.key,
    required this.count,
    required this.noun,
    required this.workflows,
  });

  final int count;
  final String noun;
  final List<WorkflowProgress> workflows;

  @override
  State<ProgressDrawer> createState() => _ProgressDrawerState();
}

class _ProgressDrawerState extends State<ProgressDrawer> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.count == 0) return const SizedBox.shrink();
    final total = Progress.combined(widget.workflows.map((w) => w.progress));
    final n = widget.count;
    return GestureDetector(
      onVerticalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v != 0) setState(() => _expanded = v < 0);
      },
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(_expanded ? Icons.expand_more : Icons.expand_less),
                  tooltip: _expanded ? 'Hide Stages' : 'Show Stages',
                  onPressed: () => setState(() => _expanded = !_expanded),
                ),
                Text(
                  [
                    '$n ${widget.noun}${n == 1 ? '' : 's'}',
                    '${total.owned} owned',
                    '${total.finished} finished',
                    '${total.wanted} wanted',
                  ].join(' · '),
                ),
                const SizedBox(height: 4),
                StageBar(total),
                if (_expanded)
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(context).height / 2,
                    ),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final (i, w) in widget.workflows.indexed) ...[
                          if (i > 0) const Divider(),
                          StageBreakdown(w),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One Workflow's Progress: its name and "finished / owned finished · %", then its Stages captioned Wanted (before the
/// Owned Stage), Owned and Finished (from the Finished Stage on). Each Stage row has a bar sized against the Workflow's
/// largest Stage, its model count and, unless wanted, its share of owned models. Display only.
class StageBreakdown extends StatelessWidget {
  const StageBreakdown(this.workflow, {super.key});

  final WorkflowProgress workflow;

  @override
  Widget build(BuildContext context) {
    final colours = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final p = workflow.progress;
    final stages = workflow.stages;
    int at(Stage s) => stages.indexWhere((g) => g.stage.id == s.id);
    final owned = at(workflow.workflow.ownedStage);
    final finished = at(workflow.workflow.finishedStage);
    final largest = stages.fold(
      0,
      (n, g) => g.modelCount > n ? g.modelCount : n,
    );
    String percent(double share) => '${(share * 100).round()}%';

    Widget row(StageGroup g, {required bool wanted}) {
      final n = g.modelCount;
      final colour = stageColour(g.stage.colour);
      final muted = n == 0 ? TextStyle(color: colours.onSurfaceVariant) : null;
      return SizedBox(
        height: 26,
        child: Row(
          children: [
            SizedBox.square(
              dimension: 16,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colour,
                  border: stageOutline(context),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: Text(
                g.stage.name,
                style: muted,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              flex: 3,
              child: Container(
                height: 10,
                color: colours.surfaceContainerLowest,
                alignment: Alignment.centerLeft,
                child: n == 0
                    ? null
                    : FractionallySizedBox(
                        widthFactor: n / largest,
                        heightFactor: 1,
                        child: DecoratedBox(
                          decoration: wanted
                              ? BoxDecoration(border: Border.all(color: colour))
                              : BoxDecoration(
                                  color: colour,
                                  border: stageOutline(context),
                                ),
                        ),
                      ),
              ),
            ),
            SizedBox(
              width: 40,
              child: Text('$n', style: muted, textAlign: TextAlign.end),
            ),
            SizedBox(
              width: 44,
              child: wanted || n == 0
                  ? null
                  : Text(
                      percent(n / p.owned),
                      style: TextStyle(color: colours.onSurfaceVariant),
                      textAlign: TextAlign.end,
                    ),
            ),
          ],
        ),
      );
    }

    Widget band(
      String caption,
      List<StageGroup> groups, {
      bool wanted = false,
    }) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 2),
          child: Text(
            caption,
            style: text.labelSmall?.copyWith(color: colours.onSurfaceVariant),
          ),
        ),
        for (final g in groups) row(g, wanted: wanted),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              Text(workflow.workflow.name, style: heading(context)),
              Text(
                '${p.finished} / ${p.owned} finished · ${percent(p.finishedShare)}',
                style: TextStyle(color: colours.onSurfaceVariant),
              ),
            ],
          ),
          if (owned > 0) band('Wanted', stages.sublist(0, owned), wanted: true),
          if (finished > owned) band('Owned', stages.sublist(owned, finished)),
          band('Finished', stages.sublist(finished)),
        ],
      ),
    );
  }
}
