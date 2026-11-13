import 'package:material_ui/material_ui.dart';

/// Stencil font bundled in assets/fonts, used for headings only.
const stencilFont = 'BlackOpsOne';

const _gunmetal = Color(0xFF1C1F22);
const _amber = Color(0xFFFFA000);
// Rust light enough for AA (>= 4.5:1) on gunmetal and the dialog steel.
const _rust = Color(0xFFF4876A);

/// A Stage colour, stored as `#RRGGBB`.
Color stageColour(String hex) =>
    Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));

/// Rust foreground for destructive actions (delete, remove, sign out).
/// Disabled buttons keep the default greyed-out colour.
ButtonStyle destructive(BuildContext context) =>
    TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error);

/// Industrial grimdark: gunmetal background, steel panels, amber accent,
/// rust for destructive actions. Dark only.
final ThemeData grimdarkTheme = () {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: _amber,
        brightness: Brightness.dark,
      ).copyWith(
        primary: _amber,
        onPrimary: _gunmetal,
        secondary: _amber,
        onSecondary: _gunmetal,
        tertiary: _amber,
        onTertiary: _gunmetal,
        error: _rust,
        onError: _gunmetal,
        surface: _gunmetal,
        onSurface: const Color(0xFFE4E6E8),
        onSurfaceVariant: const Color(0xFFB0B7BD),
        surfaceContainerLowest: const Color(0xFF16191B),
        surfaceContainerLow: const Color(0xFF23272B),
        surfaceContainer: const Color(0xFF2B3035),
        surfaceContainerHigh: const Color(0xFF31373C),
        surfaceContainerHighest: const Color(0xFF3A4046),
        outline: const Color(0xFF6B737A),
        outlineVariant: const Color(0xFF3A4046),
      );
  final base = ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: _gunmetal,
  );
  TextStyle? stencil(TextStyle? s) => s?.copyWith(fontFamily: stencilFont);
  final t = base.textTheme;
  return base.copyWith(
    textTheme: t.copyWith(
      displayLarge: stencil(t.displayLarge),
      displayMedium: stencil(t.displayMedium),
      displaySmall: stencil(t.displaySmall),
      headlineLarge: stencil(t.headlineLarge),
      headlineMedium: stencil(t.headlineMedium),
      headlineSmall: stencil(t.headlineSmall),
      titleLarge: stencil(t.titleLarge),
      titleMedium: stencil(t.titleMedium),
      titleSmall: stencil(t.titleSmall),
    ),
  );
}();
