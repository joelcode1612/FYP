import 'package:flutter/material.dart';

/// Single source of truth for the Sitewise visual language.
/// Tokens taken from the HTML prototype (Phase 5 of the brief).
/// Pages must consume [SitewiseColors]/[Theme.of] — never hardcode hexes.

abstract final class SitewiseColors {
  static const Color ink = Color(0xFF10151F);
  static const Color action = Color(0xFF2F6FED);
  static const Color accent = Color(0xFF1D4ED8);
  static const Color background = Color(0xFFF6F7F9);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color border = Color(0xFFE4E7EC);
  static const Color muted = Color(0xFF667085);
  static const Color overline = Color(0xFF98A2B3);
  static const Color success = Color(0xFF0E9F6E);
  static const Color warning = Color(0xFFB54708);
  static const Color danger = Color(0xFFD92D20);
  static const Color geoWash = Color(0xFFEAF1FE);
  static const Color geoBorder = Color(0xFFCFE0FD);
}

abstract final class SitewiseSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double radius = 12;
}

/// The score → colour ramp, in one place.
///
/// DESIGN.md §7.10 states this ramp is "shared by the bar and the ring". It was
/// previously inlined as an if-chain inside each widget that needed it, so the
/// thresholds could drift apart between the hero ring, the progress bar and the
/// property-card score chip. Anything that colours a 0–100 score must call
/// [colorFor] rather than re-deriving the thresholds.
abstract final class SitewiseScoreRamp {
  /// ≥ this is `success` — a strong location.
  static const double good = 75;

  /// ≥ this is `action` — a reasonable location.
  static const double fair = 55;

  /// ≥ this is `warning` — a weak location. Below it is `danger`.
  static const double weak = 40;

  static Color colorFor(double score) {
    if (score >= good) return SitewiseColors.success;
    if (score >= fair) return SitewiseColors.action;
    if (score >= weak) return SitewiseColors.warning;
    return SitewiseColors.danger;
  }

  /// Short qualitative label for the same bands, for use beside a score.
  static String labelFor(double score) {
    if (score >= good) return 'Strong';
    if (score >= fair) return 'Reasonable';
    if (score >= weak) return 'Weak';
    return 'Poor';
  }
}

/// Centralised Material theme. Display headings prefer Sora, body prefers
/// IBM Plex Sans; both gracefully fall back to the platform default when the
/// font assets are not bundled.
ThemeData sitewiseTheme() {
  const displayFamily = 'Sora';
  const bodyFamily = 'IBM Plex Sans';

  final colorScheme = ColorScheme.fromSeed(
    seedColor: SitewiseColors.action,
    primary: SitewiseColors.action,
    onPrimary: Colors.white,
    secondary: SitewiseColors.accent,
    surface: SitewiseColors.surface,
    error: SitewiseColors.danger,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: SitewiseColors.background,
    fontFamily: bodyFamily,
    appBarTheme: const AppBarTheme(
      backgroundColor: SitewiseColors.ink,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: SitewiseColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SitewiseSpacing.radius),
        side: const BorderSide(color: SitewiseColors.border),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: SitewiseColors.geoWash,
      side: const BorderSide(color: SitewiseColors.geoBorder),
      labelStyle: const TextStyle(color: SitewiseColors.ink, fontSize: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: SitewiseColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: SitewiseColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: SitewiseColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: SitewiseColors.action, width: 1.6),
      ),
      labelStyle: const TextStyle(color: SitewiseColors.muted),
      hintStyle: const TextStyle(color: SitewiseColors.muted),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: SitewiseColors.action,
        foregroundColor: Colors.white,
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: SitewiseColors.ink,
        minimumSize: const Size(48, 48),
        side: const BorderSide(color: SitewiseColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: SitewiseColors.surface,
      selectedItemColor: SitewiseColors.action,
      unselectedItemColor: SitewiseColors.muted,
      type: BottomNavigationBarType.fixed,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: SitewiseColors.ink,
      contentTextStyle: TextStyle(color: Colors.white),
    ),
  );

  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      displayLarge: base.textTheme.displayLarge?.copyWith(
        fontFamily: displayFamily,
        color: SitewiseColors.ink,
      ),
      displayMedium: base.textTheme.displayMedium?.copyWith(
        fontFamily: displayFamily,
        color: SitewiseColors.ink,
      ),
      displaySmall: base.textTheme.displaySmall?.copyWith(
        fontFamily: displayFamily,
        color: SitewiseColors.ink,
      ),
      headlineMedium: base.textTheme.headlineMedium?.copyWith(
        fontFamily: displayFamily,
        color: SitewiseColors.ink,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontFamily: displayFamily,
        color: SitewiseColors.ink,
      ),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(
        color: SitewiseColors.ink,
      ),
      bodySmall: base.textTheme.bodySmall?.copyWith(
        color: SitewiseColors.muted,
      ),
    ),
  );
}
