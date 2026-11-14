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

/// The thin outline around a Stage colour swatch or strip, so light Stage colours show on light backgrounds.
Border stageOutline(BuildContext context) =>
    Border.all(color: Theme.of(context).colorScheme.outline, width: 0.5);

/// Rust foreground for destructive actions (delete, remove, sign out).
/// Disabled buttons keep the default greyed-out colour.
ButtonStyle destructive(BuildContext context) =>
    TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error);

/// A Theme's colours in one Brightness.
typedef Palette = ({
  Color background,
  Color accent,
  Color error,
  Color text,
  Color mutedText,

  /// surfaceContainerLowest to surfaceContainerHighest.
  List<Color> containers,
  Color outline,
});

/// The Themes a device can pick between: a heading font plus a light and a dark [Palette]. Stage colours are the
/// user's and stay as set; their swatches carry [stageOutline] instead.
enum AppTheme {
  /// Industrial grimdark: gunmetal (light: pale concrete) with steel panels, amber accent, rust for destructive actions.
  grimdark(
    'Grimdark',
    stencilFont,
    dark: (
      background: Color(0xFF1C1F22),
      accent: Color(0xFFFFA000),
      // Rust light enough for AA (>= 4.5:1) on gunmetal and every steel container.
      error: Color(0xFFF6937A),
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
    light: (
      background: Color(0xFFE3E6E8),
      accent: Color(0xFF7F3D00),
      error: Color(0xFF922610),
      text: Color(0xFF1C1F22),
      mutedText: Color(0xFF3E454B),
      containers: [
        Color(0xFFF2F4F5),
        Color(0xFFDCE0E3),
        Color(0xFFD4D9DD),
        Color(0xFFCCD2D6),
        Color(0xFFC8CDD1),
      ],
      outline: Color(0xFF6B737A),
    ),
  ),

  /// Fantasy: deep forest and parchment, antique gold accent, oxblood for destructive actions, roman capitals.
  fantasy(
    'Fantasy',
    cinzelFont,
    dark: (
      background: Color(0xFF17231B),
      accent: Color(0xFFD9B44A),
      error: Color(0xFFF49C8A),
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
    ),
    light: (
      background: Color(0xFFF1E8D0),
      accent: Color(0xFF634900),
      error: Color(0xFF86201C),
      text: Color(0xFF17311F),
      mutedText: Color(0xFF3D4A36),
      containers: [
        Color(0xFFF8F2E2),
        Color(0xFFEADFC2),
        Color(0xFFE3D7B7),
        Color(0xFFDCCFAC),
        Color(0xFFD8CBA8),
      ],
      outline: Color(0xFF7D735A),
    ),
  );

  const AppTheme(
    this.label,
    this.headingFont, {
    required this.dark,
    required this.light,
  });

  final String label;
  final String headingFont;
  final Palette dark;
  final Palette light;

  ThemeData data(Brightness brightness) {
    final (
      :background,
      :accent,
      :error,
      :text,
      :mutedText,
      :containers,
      :outline,
    ) = brightness == Brightness.dark
        ? dark
        : light;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
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
final ThemeData grimdarkTheme = AppTheme.grimdark.data(Brightness.dark);

/// This device's picked [AppTheme] and Brightness, kept in [file] and `brightness.txt` beside it. Not synced: each
/// device keeps its own.
class ThemeSetting extends ChangeNotifier {
  ThemeSetting._(this.file, this.theme, this.brightness);

  final File file;
  AppTheme theme;

  /// [ThemeMode.system] follows the device's own Brightness.
  ThemeMode brightness;

  File get _brightnessFile => File('${file.parent.path}/brightness.txt');

  /// The Theme and Brightness saved beside [file], or Grimdark and System when none are.
  static Future<ThemeSetting> load(File file) async {
    Future<String> read(File f) async =>
        await f.exists() ? (await f.readAsString()).trim() : '';
    final brightness = File('${file.parent.path}/brightness.txt');
    return ThemeSetting._(
      file,
      AppTheme.values.asNameMap()[await read(file)] ?? AppTheme.grimdark,
      ThemeMode.values.asNameMap()[await read(brightness)] ?? ThemeMode.system,
    );
  }

  Future<void> pick(AppTheme theme) async {
    this.theme = theme;
    notifyListeners();
    await file.writeAsString(theme.name);
  }

  Future<void> pickBrightness(ThemeMode brightness) async {
    this.brightness = brightness;
    notifyListeners();
    await _brightnessFile.writeAsString(brightness.name);
  }
}
