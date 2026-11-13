import 'package:domain_core/domain_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
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

  test(
    'every Stage colour swatch reaches AA contrast (>= 4.5:1) on gunmetal',
    () {
      final background = grimdarkTheme.colorScheme.surface.computeLuminance();
      expect(Vault.stageColours, hasLength(16));
      for (final c in Vault.stageColours) {
        final l = stageColour(c).computeLuminance();
        expect(
          (l + 0.05) / (background + 0.05),
          greaterThanOrEqualTo(4.5),
          reason: c,
        );
      }
    },
  );
}
