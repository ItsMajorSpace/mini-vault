import 'dart:math';

import 'package:domain_core/domain_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/stage_strip.dart';
import 'package:mini_vault/theme.dart';

void main() {
  testWidgets('app theme is dark with stencil headings and rust deletes', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: grimdarkTheme,
        home: Scaffold(
          appBar: AppBar(title: const Text('Collections')),
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {},
              style: destructive(context),
              child: const Text('Delete'),
            ),
          ),
        ),
      ),
    );

    final theme = Theme.of(tester.element(find.text('Delete')));
    expect(theme.brightness, Brightness.dark);
    final t = theme.textTheme;
    for (final s in [
      t.displayLarge,
      t.displayMedium,
      t.displaySmall,
      t.headlineLarge,
      t.headlineMedium,
      t.headlineSmall,
      t.titleLarge,
    ]) {
      expect(s!.fontFamily, stencilFont);
    }
    for (final s in [
      t.titleMedium,
      t.titleSmall,
      t.bodyLarge,
      t.bodyMedium,
      t.labelLarge,
    ]) {
      expect(s!.fontFamily, isNot(stencilFont));
    }
    expect(
      tester
          .widget<RichText>(
            find.descendant(
              of: find.byType(AppBar),
              matching: find.byType(RichText),
            ),
          )
          .text
          .style!
          .fontFamily,
      stencilFont,
    );
    expect(
      tester
          .widget<RichText>(
            find.descendant(
              of: find.byType(TextButton),
              matching: find.byType(RichText),
            ),
          )
          .text
          .style!
          .color,
      theme.colorScheme.error,
    );
  });

  testWidgets('FAB is solid amber with a gunmetal icon', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: grimdarkTheme,
        home: Scaffold(
          floatingActionButton: FloatingActionButton(
            onPressed: () {},
            child: const Icon(Icons.add),
          ),
        ),
      ),
    );

    final scheme = grimdarkTheme.colorScheme;
    final material = tester.widget<Material>(
      find.descendant(
        of: find.byType(FloatingActionButton),
        matching: find.byType(Material),
      ),
    );
    expect(material.color, scheme.primary);
    expect(scheme.primary, const Color(0xFFFFA000));
    expect(
      IconTheme.of(tester.element(find.byIcon(Icons.add))).color,
      scheme.onPrimary,
    );
  });

  /// WCAG 2 relative luminance of an sRGB colour.
  double luminance(Color c) {
    double channel(double v) =>
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(c.r) +
        0.7152 * channel(c.g) +
        0.0722 * channel(c.b);
  }

  double ratio(Color a, Color b) {
    final (x, y) = (luminance(a), luminance(b));
    return (max(x, y) + 0.05) / (min(x, y) + 0.05);
  }

  testWidgets('light Stage strips are outlined on a light Theme', (
    tester,
  ) async {
    final light = AppTheme.fantasy.data(Brightness.light);
    const stage = Stage(id: 's', name: 'Done', colour: '#F2F2F2');
    await tester.pumpWidget(
      MaterialApp(
        theme: light,
        home: const StageStrip(
          Workflow(
            id: 'w',
            name: 'Standard',
            stages: [stage],
            ownedStageId: 's',
            finishedStageId: 's',
          ),
        ),
      ),
    );
    final segment = tester.widget<Container>(
      find.descendant(
        of: find.byKey(const ValueKey('s')),
        matching: find.byType(Container),
      ),
    );
    expect(
      (segment.decoration! as BoxDecoration).border,
      Border.all(color: light.colorScheme.outline, width: 0.5),
    );
  });

  test('WCAG contrast matches the published reference values', () {
    expect(ratio(const Color(0xFF000000), const Color(0xFFFFFFFF)), 21);
    expect(
      ratio(const Color(0xFF767676), const Color(0xFFFFFFFF)),
      closeTo(4.54, 0.01),
    );
  });

  for (final preset in AppTheme.values) {
    for (final brightness in Brightness.values) {
      test(
        '${preset.label} ${brightness.name}: text reaches AA (>= 4.5:1)',
        () {
          final s = preset.data(brightness).colorScheme;
          expect(s.brightness, brightness);

          // Cards, menus and dialogs sit on the containers.
          final backgrounds = {
            'surface': s.surface,
            'surfaceContainerLowest': s.surfaceContainerLowest,
            'surfaceContainerLow': s.surfaceContainerLow,
            'surfaceContainer': s.surfaceContainer,
            'surfaceContainerHigh': s.surfaceContainerHigh,
            'surfaceContainerHighest': s.surfaceContainerHighest,
          };
          for (final MapEntry(key: on, value: bg) in backgrounds.entries) {
            for (final (name, fg) in [
              ('onSurface', s.onSurface),
              ('onSurfaceVariant', s.onSurfaceVariant),
              ('primary', s.primary),
              ('error', s.error),
            ]) {
              expect(
                ratio(fg, bg),
                greaterThanOrEqualTo(4.5),
                reason: '$name on $on',
              );
            }
          }
          expect(ratio(s.onPrimary, s.primary), greaterThanOrEqualTo(4.5));
          expect(ratio(s.onError, s.error), greaterThanOrEqualTo(4.5));
        },
      );
    }
  }
}
