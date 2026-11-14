import 'package:domain_core/domain_core.dart';
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// One segment per Stage in its colour, accent ticks where the Owned and Finished Stages begin (one tick when both
/// begin at the same Stage). Used in the Workflows list, Workflow pickers and the Delete Stage preview.
class StageStrip extends StatelessWidget {
  const StageStrip(this.workflow, {super.key, this.height = 10});

  final Workflow workflow;
  final double height;

  @override
  Widget build(BuildContext context) {
    final n = workflow.stages.length;
    final owned = workflow.ownedStage.id;
    final finished = workflow.finishedStage.id;
    final accent = Theme.of(context).colorScheme.primary;
    return Semantics(
      label:
          '$n ${n == 1 ? 'Stage' : 'Stages'}, owned from ${workflow.ownedStage.name}, '
          'finished from ${workflow.finishedStage.name}',
      excludeSemantics: true,
      child: SizedBox(
        height: height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 2,
          children: [
            for (final s in workflow.stages) ...[
              if (s.id == owned || s.id == finished)
                Container(
                  key: ValueKey('tick:${s.id}'),
                  width: 3,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              Expanded(
                key: ValueKey(s.id),
                child: Container(
                  decoration: BoxDecoration(
                    color: stageColour(s.colour),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
