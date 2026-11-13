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
      final units = [
        for (final MapEntry(key: i, value: n) in modelsAt.entries)
          Unit(
            id: '${w.id}u$i',
            collectionId: 'c',
            stageId: w.stages[i].id,
            name: 'Unit',
            modelCount: n,
            notes: '',
          ),
      ];
      return WorkflowProgress(w, groupByStage(w, units), progressOf(w, units));
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

    Future<void> pump(WidgetTester tester, int count) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const SizedBox.expand(),
          bottomSheet: ProgressDrawer(
            count: count,
            noun: 'Collection',
            workflows: workflows,
          ),
        ),
      ),
    );

    /// The listed Stages, per Workflow, as "Stage models".
    List<String> listed(WidgetTester tester) => [
      for (final t in tester.widgetList<ListTile>(find.byType(ListTile)))
        '${((t.title! as Text).data)} ${(t.trailing! as Text).data}',
    ];

    testWidgets('collapsed, shows the totals over every Workflow and one bar', (
      tester,
    ) async {
      await pump(tester, 2);

      expect(
        find.text('2 Collections · 17 owned · 3 finished · 5 wanted'),
        findsOneWidget,
      );
      expect(find.byType(StageBar), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
    });

    testWidgets(
      'dragged up, lists each Workflow\'s every Stage apart, even where names match; dragged down, collapses',
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
        // Wishlist is before the Owned Stage, Primed in Starter has no models.
        expect(listed(tester), [
          'Wishlist 5',
          'Unassembled 10',
          'Primed 0',
          'Done 2',
          'Wishlist 0',
          'Primed 4',
          'Done 1',
        ]);

        await tester.fling(find.byType(StageBar), const Offset(0, 200), 1000);
        await tester.pumpAndSettle();
        expect(find.byType(ListTile), findsNothing);
      },
    );

    testWidgets('is hidden with nothing to count', (tester) async {
      await pump(tester, 0);

      expect(find.byType(StageBar), findsNothing);
      expect(find.textContaining('owned'), findsNothing);
      expect(tester.getSize(find.byType(BottomSheet)).height, 0);
    });
  });
}
