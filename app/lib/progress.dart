import 'package:domain_core/domain_core.dart';
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// A Collection's progress totals ("86 / 140 finished"), kept live as Units and the Workflow change.
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
          Text(
            [
              '${p.finished} / ${p.owned} finished',
              if (p.wanted > 0) '${p.wanted} wanted',
            ].join(' · '),
          ),
          const SizedBox(height: 4),
          StageBar(p),
        ],
      );
    },
  );
}

/// [progress]'s owned models as one segment per Stage, in its colour and sized by model count, the latest Stage
/// leftmost, so the finished part fills from the left.
class StageBar extends StatelessWidget {
  const StageBar(this.progress, {super.key});

  final Progress progress;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 4,
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
        ],
      ),
    ),
  );
}

/// Progress peeking from the bottom of the screen: [count] [noun]s and the owned, finished and wanted totals over a
/// [StageBar]. Dragged up (or its button tapped) it lists each Workflow's Stages with their model counts. Hidden while
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
                        for (final w in widget.workflows) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Text(
                              w.workflow.name,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          for (final g in w.stages)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: SizedBox.square(
                                dimension: 16,
                                child: ColoredBox(
                                  color: stageColour(g.stage.colour),
                                ),
                              ),
                              title: Text(g.stage.name),
                              trailing: Text('${g.modelCount}'),
                            ),
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
