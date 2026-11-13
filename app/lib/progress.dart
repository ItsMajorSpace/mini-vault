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
