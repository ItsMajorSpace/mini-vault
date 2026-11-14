import 'package:domain_core/domain_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/progress.dart';
import 'package:mini_vault/theme.dart';

void main() {
  testWidgets(
    'the Stage bar puts the latest Stage leftmost, each segment sized by its models, wanted models last',
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
                  wanted: 4,
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
          (stageColour('#6FD98A'), 0.0, const Size(50, 4)),
          (stageColour('#FF7B7B'), 50.0, const Size(150, 4)),
        ],
      );
      expect(
        tester.getRect(
          find.descendant(
            of: find.byType(Expanded),
            matching: find.byType(DecoratedBox),
          ),
        ),
        Rect.fromLTWH(
          left + 200,
          tester.getTopLeft(find.byType(StageBar)).dy,
          200,
          4,
        ),
      );
    },
  );

  group('Progress drawer', () {
    Workflow workflow(String id, String name, List<String> stages) => Workflow(
      id: id,
      name: name,
      stages: [
        for (final (i, s) in stages.indexed)
          Stage(id: '$id$i', name: s, colour: Vault.stageColours[i]),
      ],
      ownedStageId: '${id}1',
      finishedStageId: '$id${stages.length - 1}',
    );
    WorkflowProgress progress(Workflow w, Map<int, int> modelsAt) {
      final batches = [
        for (final MapEntry(key: i, value: n) in modelsAt.entries)
          Batch(
            id: '${w.id}u$i',
            collectionId: 'c',
            stageId: w.stages[i].id,
            name: 'Unit',
            modelCount: n,
          ),
      ];
      return WorkflowProgress(
        w,
        groupByStage(w, batches),
        progressOf(w, batches),
      );
    }

    final starter = workflow('a', 'Starter', [
      'Wishlist',
      'Unassembled',
      'Primed',
      'Done',
    ]);
    final killTeam = workflow('b', 'Kill Team', ['Wishlist', 'Primed', 'Done']);
    final workflows = [
      progress(starter, {0: 5, 1: 10, 3: 2}),
      progress(killTeam, {1: 4, 2: 1}),
    ];

    /// The texts of the [i]th Workflow's breakdown, in order.
    List<String?> breakdown(WidgetTester tester, int i) => [
      for (final t in tester.widgetList<Text>(
        find.descendant(
          of: find.byType(StageBreakdown).at(i),
          matching: find.byType(Text),
        ),
      ))
        t.data,
    ];

    testWidgets('leaves out a band without Stages', (tester) async {
      final w = Workflow(
        id: 'x',
        name: 'Painted only',
        stages: const [Stage(id: 'x0', name: 'Painted', colour: '#FF7B7B')],
        ownedStageId: 'x0',
        finishedStageId: 'x0',
      );
      await tester.pumpWidget(
        MaterialApp(home: Material(child: StageBreakdown(progress(w, {0: 3})))),
      );

      expect(breakdown(tester, 0), [
        'Painted only', '3 / 3 finished · 100%', //
        'Finished', 'Painted', '3', '100%',
      ]);
    });

    Future<void> pump(WidgetTester tester, int count) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: ProgressDrawer(
            count: count,
            noun: 'Collection',
            workflows: workflows,
          ),
        ),
      ),
    );

    testWidgets('collapsed, shows the totals over every Workflow and one bar', (
      tester,
    ) async {
      await pump(tester, 2);

      expect(
        find.text('2 Collections · 17 owned · 3 finished · 5 wanted'),
        findsOneWidget,
      );
      expect(find.byType(StageBar), findsOneWidget);
      expect(find.byType(StageBreakdown), findsNothing);
    });

    testWidgets(
      'dragged up, breaks each Workflow down into Wanted / Owned / Finished Stages with count, bar and share of owned; dragged down, collapses',
      (tester) async {
        // Tall enough to build every Stage row of the sheet's lazy list.
        tester.view.physicalSize = const Size(2400, 4800);
        addTearDown(tester.view.reset);
        await pump(tester, 2);
        await tester.fling(find.byType(StageBar), const Offset(0, -200), 1000);
        await tester.pumpAndSettle();

        expect(find.text('Starter'), findsOneWidget);
        expect(find.text('Kill Team'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('Starter')).dy,
          lessThan(tester.getTopLeft(find.text('Kill Team')).dy),
        );
        // Wishlist is before the Owned Stage, Primed in Starter has no models: still listed, without a %.
        expect(breakdown(tester, 0), [
          'Starter', '2 / 12 finished · 17%', //
          'Wanted', 'Wishlist', '5', //
          'Owned', 'Unassembled', '10', '83%', 'Primed', '0', //
          'Finished', 'Done', '2', '17%',
        ]);
        expect(breakdown(tester, 1), [
          'Kill Team', '1 / 5 finished · 20%', //
          'Wanted', 'Wishlist', '0', //
          'Owned', 'Primed', '4', '80%', //
          'Finished', 'Done', '1', '20%',
        ]);
        expect(find.byType(Divider), findsOneWidget);
        // Bars against the Workflow's largest Stage; the wanted one outlined; none for an empty Stage.
        final bars = [
          for (final b in tester.widgetList<FractionallySizedBox>(
            find.descendant(
              of: find.byType(StageBreakdown).first,
              matching: find.byType(FractionallySizedBox),
            ),
          ))
            (
              b.widthFactor,
              ((b.child! as DecoratedBox).decoration as BoxDecoration).color,
            ),
        ];
        expect(bars, [
          (0.5, null),
          (1.0, stageColour(Vault.stageColours[1])),
          (0.2, stageColour(Vault.stageColours[3])),
        ]);

        await tester.fling(find.byType(StageBar), const Offset(0, 200), 1000);
        await tester.pumpAndSettle();
        expect(find.byType(StageBreakdown), findsNothing);
      },
    );

    testWidgets('is hidden with nothing to count', (tester) async {
      await pump(tester, 0);

      expect(find.byType(StageBar), findsNothing);
      expect(find.textContaining('owned'), findsNothing);
      expect(tester.getSize(find.byType(ProgressDrawer)).height, 0);
    });
  });
}
