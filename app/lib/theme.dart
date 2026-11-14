import 'dart:io';

import 'package:material_ui/material_ui.dart';

/// Stencil font bundled in assets/fonts, used for Grimdark's headings.
const stencilFont = 'BlackOpsOne';

/// Roman capitals bundled in assets/fonts, used for Fantasy's headings.
const cinzelFont = 'Cinzel';

/// [TextTheme.titleSmall] in the theme's heading font, for section headers built on body-sized styles.
TextStyle? heading(BuildContext context) {
  final t = Theme.of(context).textTheme;
  return t.titleSmall?.copyWith(fontFamily: t.titleLarge?.fontFamily);
}

/// A Stage colour, stored as `#RRGGBB`.
Color stageColour(String hex) =>
    Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));

/// Rust foreground for destructive actions (delete, remove, sign out).
/// Disabled buttons keep the default greyed-out colour.
ButtonStyle destructive(BuildContext context) =>
    TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error);

/// The preset looks a device can pick between: a colour scheme plus a heading font. Stage colours are the user's
/// and stay as set, so every preset is dark enough for them.
enum AppTheme {
  /// Industrial grimdark: gunmetal background, steel panels, amber accent, rust for destructive actions.
  grimdark(
    'Grimdark',
    stencilFont,
    background: Color(0xFF1C1F22),
    accent: Color(0xFFFFA000),
    // Rust light enough for AA (>= 4.5:1) on gunmetal and the dialog steel.
    error: Color(0xFFF4876A),
    text: Color(0xFFE4E6E8),
    mutedText: Color(0xFFB0B7BD),
    containers: [
      Color(0xFF16191B),
      Color(0xFF23272B),
      Color(0xFF2B3035),
      Color(0xFF31373C),
      Color(0xFF3A4046),
    ],
    outline: Color(0xFF6B737A),
  ),

  /// Fantasy: deep forest background, parchment text, gold accent, roman capitals.
  fantasy(
    'Fantasy',
    cinzelFont,
    background: Color(0xFF17231B),
    accent: Color(0xFFD9B44A),
    error: Color(0xFFF2907C),
    text: Color(0xFFF1E8D0),
    mutedText: Color(0xFFC9BFA3),
    containers: [
      Color(0xFF111A14),
      Color(0xFF1E2C22),
      Color(0xFF25352A),
      Color(0xFF2B3D30),
      Color(0xFF33473A),
    ],
    outline: Color(0xFF7A8A72),
  );

  const AppTheme(
    this.label,
    this.headingFont, {
    required this.background,
    required this.accent,
    required this.error,
    required this.text,
    required this.mutedText,
    required this.containers,
    required this.outline,
  });

  final String label;
  final String headingFont;
  final Color background;
  final Color accent;
  final Color error;
  final Color text;
  final Color mutedText;

  /// surfaceContainerLowest to surfaceContainerHighest.
  final List<Color> containers;
  final Color outline;

  ThemeData get data {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: Brightness.dark,
        ).copyWith(
          primary: accent,
          onPrimary: background,
          secondary: accent,
          onSecondary: background,
          tertiary: accent,
          onTertiary: background,
          error: error,
          onError: background,
          surface: background,
          onSurface: text,
          onSurfaceVariant: mutedText,
          surfaceContainerLowest: containers[0],
          surfaceContainerLow: containers[1],
          surfaceContainer: containers[2],
          surfaceContainerHigh: containers[3],
          surfaceContainerHighest: containers[4],
          outline: outline,
          outlineVariant: containers[4],
        );
    final base = ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: accent,
        foregroundColor: background,
      ),
    );
    final t = base.textTheme;
    TextStyle? h(TextStyle? s) => s?.copyWith(fontFamily: headingFont);
    return base.copyWith(
      textTheme: t.copyWith(
        displayLarge: h(t.displayLarge),
        displayMedium: h(t.displayMedium),
        displaySmall: h(t.displaySmall),
        headlineLarge: h(t.headlineLarge),
        headlineMedium: h(t.headlineMedium),
        headlineSmall: h(t.headlineSmall),
        titleLarge: h(t.titleLarge),
      ),
    );
  }
}

/// The default look.
final ThemeData grimdarkTheme = AppTheme.grimdark.data;

/// This device's picked [AppTheme], kept in [file]. Not synced: each device keeps its own.
class ThemeSetting extends ValueNotifier<AppTheme> {
  ThemeSetting._(this.file, super.value);

  final File file;

  /// The theme saved in [file], or Grimdark when none is.
  static Future<ThemeSetting> load(File file) async {
    final saved = await file.exists() ? await file.readAsString() : '';
    return ThemeSetting._(
      file,
      AppTheme.values.asNameMap()[saved.trim()] ?? AppTheme.grimdark,
    );
  }

  Future<void> pick(AppTheme theme) async {
    value = theme;
    await file.writeAsString(theme.name);
  }
}
