import 'package:domain_core/domain_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/progress.dart';
import 'package:mini_vault/theme.dart';

void main() {
  testWidgets(
    'the Stage bar puts the latest Stage leftmost, each segment sized by its models',
    (tester) async {
      const primed = Stage(id: 'p', name: 'Primed', colour: '#FF7B7B');
      const done = Stage(id: 'd', name: 'Done', colour: '#6FD98A');
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: SizedBox(
              width: 400,
              child: StageBar(
                Progress(
                  wanted: 5,
                  owned: 4,
                  finished: 1,
                  stages: [
                    (stage: primed, models: 3),
                    (stage: done, models: 1),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      final segments = find.descendant(
        of: find.byType(Expanded),
        matching: find.byType(ColoredBox),
      );
      final left = tester.getTopLeft(find.byType(StageBar)).dx;
      expect(
        [
          for (final e in tester.elementList(segments))
            (
              (e.widget as ColoredBox).color,
              tester.getTopLeft(find.byElementPredicate((x) => x == e)).dx -
                  left,
              tester.getSize(find.byElementPredicate((x) => x == e)),
            ),
        ],
        [
          (stageColour('#6FD98A'), 0.0, const Size(100, 4)),
          (stageColour('#FF7B7B'), 100.0, const Size(300, 4)),
        ],
      );
    },
  );
}
