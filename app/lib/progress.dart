import 'package:domain_core/domain_core.dart';
import 'package:material_ui/material_ui.dart';

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
          LinearProgressIndicator(value: p.finishedShare),
        ],
      );
    },
  );
}
