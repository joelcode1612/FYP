import 'package:flutter/material.dart';

/// The single type family of the new design.
///
/// The previous system used two families (Sora for display, IBM Plex Sans for
/// body). The new design's `theme.css` sets `--font: 'Archivo'` and differentiates
/// headings by weight (700–900) rather than by family.
///
/// The font file is **not** bundled in this repository. Until it is added under
/// `assets/fonts/` and declared in `pubspec.yaml`, every `Text` falls back to the
/// platform default — Roboto on Android — which is exactly the behaviour the old
/// 'Sora' / 'IBM Plex Sans' names already had. Centralising the name here means
/// adding the asset later is a one-line `pubspec.yaml` change with no Dart edits.
const String kFontFamily = 'Archivo';

/// Single source of truth for the Sitewise visual language.
///
/// Token values are taken from the new UI design's `sitewise-roles/theme.css`
/// `:root` block. Every existing token *name* is preserved — only the values
/// changed — because the tokens are referenced from 51+ files and a rename would
/// be a breaking change for no visual gain.
///
/// Mapping from the new design (CSS custom property → this file):
///
/// | CSS              | here          |
/// |------------------|---------------|
/// | `--bg`           | `background`  |
/// | `--paper`        | `paper`       |
/// | `--surface`      | `surface`     |
/// | `--ink`          | `ink`         |
/// | `--text`         | `text`        |
/// | `--muted`        | `muted`       |
/// | `--stone`        | `overline`    |
/// | `--terracotta`   | `action`      |
/// | `--accent`       | `accent`      |
/// | `--teal` / `--det` | `success`   |
/// | `--det-bg`       | `successWash` |
/// | `--warn`         | `warning`     |
/// | `--warn-bg`      | `warningWash` |
/// | `--danger`       | `danger`      |
/// | `--danger-bg`    | `dangerWash`  |
/// | `--info-bg`      | `infoWash`    |
/// | `--line`         | `border`      |
/// | `--line-strong`  | `borderStrong`|
/// | `--r-sm/md/lg/xl`| `radius*`     |
///
/// `--line` is `rgba(15,23,42,.10)`, which composites over white to `#E7E8EA`.
/// That value is stored rather than the `rgba()` literal because this token is
/// used as a `BorderSide` colour, where an explicit colour is clearer than a
/// translucent one that then has to be reasoned about against each background.
abstract final class SitewiseColors {
  static const Color ink = Color(0xFF0B0F19);
  static const Color action = Color(0xFF1D4ED8);
  static const Color accent = Color(0xFF3B82F6);
  /// Page canvas. Pure white for the mobile refresh — the previous light-blue
  /// wash made every screen read as tinted rather than white.
  static const Color background = Color(0xFFFFFFFF);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color border = Color(0xFFE7E8EA);
  static const Color muted = Color(0xFF64748B);
  static const Color overline = Color(0xFF94A3B8);
  static const Color success = Color(0xFF0D9488);
  static const Color warning = Color(0xFFB45309);
  static const Color danger = Color(0xFFDC2626);

  /// Second canvas, between `background` and `surface`.
  /// Now white too: no cream / beige / tinted page surfaces anywhere.
  static const Color paper = Color(0xFFFFFFFF);

  /// Body copy. Distinct from `ink` so headings can stay near-black while body
  /// text sits at the design's `--text`.
  static const Color text = Color(0xFF1E293B);

  /// Washed backgrounds for status pills. The new design pairs every status
  /// colour with a tinted surface; these are those tints.
  static const Color successWash = Color(0xFFD1FAE5);
  static const Color warningWash = Color(0xFFFEF3C7);
  static const Color dangerWash = Color(0xFFFEE2E2);
  static const Color infoWash = Color(0xFFDBEAFE);

  /// Emphasised divider — the design's `--line-strong`.
  static const Color borderStrong = Color(0xFFCBD5E1);

  /// Kept from the previous token set: the geospatial callout pairing, which the
  /// new design expresses as `--info-bg` / `--accent`. The old values are still
  /// used by the map and location panels.
  static const Color geoWash = Color(0xFFDBEAFE);
  static const Color geoBorder = Color(0xFFBFDBFE);
}

/// Border radii, matching the new design's `--r-sm/md/lg/xl`.
///
/// `radius` is kept as the canonical card radius and now equals `--r-md`.
abstract final class SitewiseSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;

  /// Canonical card/control radius (`--r-md`).
  static const double radius = 12;

  /// Small controls (`--r-sm`).
  static const double radiusSm = 10;

  /// Cards (`--r-lg`).
  static const double radiusLg = 16;

  /// Large containers (`--r-xl`).
  static const double radiusXl = 20;
}

/// Elevation.
///
/// The previous design system deliberately forbade shadows (DESIGN.md §5). The
/// new design introduces them as tokens, so they are defined here rather than
/// as inline `BoxShadow` literals — which is the same untokenised-value problem
/// the audit's C-08 finding calls out.
abstract final class SitewiseShadows {
  /// `--shadow-sm: 0 12px 32px rgba(15,23,42,.05)`
  static const List<BoxShadow> cardSm = [
    BoxShadow(color: Color(0x0D0F172A), blurRadius: 32, offset: Offset(0, 12)),
  ];

  /// `--shadow: 0 24px 80px rgba(15,23,42,.08)`
  static const List<BoxShadow> card = [
    BoxShadow(color: Color(0x140F172A), blurRadius: 80, offset: Offset(0, 24)),
  ];
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

/// Centralised Material theme.
///
/// The new design uses a **single** family — Archivo, weights 400–900 — for both
/// display and body, where the previous system split Sora (display) from IBM
/// Plex Sans (body). Both names resolve to the platform default when the font
/// asset is not bundled, exactly as before; see [kFontFamily] and the note in
/// `pubspec.yaml`.
ThemeData sitewiseTheme() {
  const displayFamily = kFontFamily;
  const bodyFamily = kFontFamily;

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
      // White header with dark ink content — a dark AppBar would break the
      // pure-white theme and clash with the shared MobileTopBar lockup.
      backgroundColor: SitewiseColors.surface,
      foregroundColor: SitewiseColors.ink,
      surfaceTintColor: SitewiseColors.surface,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: SitewiseColors.surface,
      // The new design introduces a soft shadow alongside the existing 1px
      // border. Previously `elevation: 0` with no shadow at all.
      elevation: 0,
      shadowColor: const Color(0x140F172A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SitewiseSpacing.radiusLg),
        side: const BorderSide(color: SitewiseColors.border),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: SitewiseColors.geoWash,
      side: const BorderSide(color: SitewiseColors.geoBorder),
      labelStyle: const TextStyle(color: SitewiseColors.ink, fontSize: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SitewiseSpacing.xl),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: SitewiseColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(SitewiseSpacing.radiusSm),
        borderSide: const BorderSide(color: SitewiseColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(SitewiseSpacing.radiusSm),
        borderSide: const BorderSide(color: SitewiseColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(SitewiseSpacing.radiusSm),
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SitewiseSpacing.radiusSm),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: SitewiseColors.ink,
        minimumSize: const Size(48, 48),
        side: const BorderSide(color: SitewiseColors.borderStrong),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SitewiseSpacing.radiusSm),
        ),
      ),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: SitewiseColors.surface,
      selectedItemColor: SitewiseColors.action,
      unselectedItemColor: SitewiseColors.muted,
      type: BottomNavigationBarType.fixed,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: SitewiseColors.surface,
      contentTextStyle: TextStyle(color: SitewiseColors.ink),
      elevation: 0,
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
