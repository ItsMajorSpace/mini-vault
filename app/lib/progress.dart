import 'package:domain_core/domain_core.dart';
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// A Collection's progress totals ("86 / 140 finished"), kept live as Batches and the Workflow change.
class ProgressSummary extends StatefulWidget {
  const ProgressSummary({
    super.key,
    required this.vault,
    required this.collection,
  });

  final Vault vault;
  final Collection collection;

  @override
  State<ProgressSummary> createState() => _ProgressSummaryState();
}

class _ProgressSummaryState extends State<ProgressSummary> {
  late final _progress = widget.vault.watchProgress(widget.collection);

  @override
  Widget build(BuildContext context) => StreamBuilder(
    stream: _progress,
    builder: (context, snapshot) {
      final p = snapshot.data;
      if (p == null) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(progressWords(p)),
          const SizedBox(height: 4),
          StageBar(p),
        ],
      );
    },
  );
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
