import 'package:flutter/material.dart';

/// Material 3 refresh tokens ported from
/// `Sitewise_Mobile_Material3_Mock_Data.html` (the "SITEWISE MATERIAL 3
/// REFRESH" block).
///
/// These live in a **separate** class from [SitewiseColors] on purpose:
/// [SitewiseColors] is referenced from 50+ screens across every role, and
/// changing its values would silently restyle the admin and owner workspaces.
/// The post-sign-in entrepreneur experience opts into this palette explicitly
/// by importing this file; the shared app shell (top bar / bottom nav) uses it
/// too, since chrome is a design-system concern rather than a role concern.
///
/// Colour names mirror the CSS custom properties so a future change to the
/// HTML reference can be diffed directly against this file.
///
/// WHITE THEME (mobile profile/navigation refresh): every *surface* token is
/// pure `#FFFFFF`; ink is dark navy `#0B0F19`, secondary text `#64748B`, the
/// single interactive blue is the existing `SitewiseColors.action` token
/// (`#1D4ED8`), light-blue icon washes are `#DBEAFE` and hairlines are
/// `#E7E8EA`. No cream / beige / tinted-page / dark surfaces remain. The token
/// NAMES are unchanged so the 50+ screens that reference them need no edits.
abstract final class SitewiseM3 {
  // Surfaces -----------------------------------------------------------------
  static const Color bg = Color(0xFFFFFFFF);
  static const Color paper = Color(0xFFFFFFFF);
  static const Color surface = Color(0xFFFFFFFF);

  // Ink ----------------------------------------------------------------------
  static const Color ink = Color(0xFF0B0F19);
  static const Color text = Color(0xFF0B0F19);
  static const Color muted = Color(0xFF64748B);
  static const Color stone = Color(0xFF64748B);

  // Brand --------------------------------------------------------------------
  static const Color primary = Color(0xFF1D4ED8);
  static const Color accent = Color(0xFF1D4ED8);
  static const Color primaryHover = Color(0xFF1746C4);
  static const Color quiet = Color(0xFFDBEAFE);
  static const Color quietStrong = Color(0xFFDBEAFE);
  static const Color brandBorder = Color(0xFFE7E8EA);
  static const Color line = Color(0xFFE7E8EA);
  static const Color soft = Color(0xFFFFFFFF);
  static const Color divider = Color(0xFFE7E8EA);

  // Status -------------------------------------------------------------------
  static const Color green = Color(0xFF086A60);
  static const Color greenWash = Color(0xFFDDF7EE);
  static const Color amber = Color(0xFF92550D);
  static const Color amberWash = Color(0xFFFFF3D9);

  // Home feature card — flat white with a hairline border, no gradient wash.
  static const Color featureStart = Color(0xFFFFFFFF);
  static const Color featureMid = Color(0xFFFFFFFF);
  static const Color featureEnd = Color(0xFFFFFFFF);
  static const Color featureBorder = Color(0xFFE7E8EA);
  static const Color featureTitle = Color(0xFF0B0F19);
  static const Color kickerText = Color(0xFF1D4ED8);

  // Metric tiles -------------------------------------------------------------
  static const Color metricBlueBg = Color(0xFFFFFFFF);
  static const Color metricBlueBorder = Color(0xFFE7E8EA);
  static const Color metricTealBg = Color(0xFFFFFFFF);
  static const Color metricTealBorder = Color(0xFFE7E8EA);
  static const Color metricValue = Color(0xFF0B0F19);
  static const Color metricIconBg = Color(0xFFDBEAFE);
  static const Color metricTealIconBg = Color(0xFFDBEAFE);
  static const Color metricTealIcon = Color(0xFF1D4ED8);

  // Notes / banners / rows ---------------------------------------------------
  static const Color noteBg = Color(0xFFFFFFFF);
  static const Color noteBorder = Color(0xFFE7E8EA);
  static const Color noteText = Color(0xFF64748B);
  static const Color bannerBg = Color(0xFFFFFFFF);
  static const Color bannerBorder = Color(0xFFE7E8EA);
  static const Color bannerText = Color(0xFF0B0F19);
  static const Color rowBorder = Color(0xFFE7E8EA);
  static const Color rowIconBg = Color(0xFFDBEAFE);
  static const Color rowTitle = Color(0xFF0B0F19);
  static const Color rowDesc = Color(0xFF64748B);
  static const Color circleBtnBg = Color(0xFFDBEAFE);
  static const Color circleBtnBorder = Color(0xFFE7E8EA);
  static const Color circleBtnIcon = Color(0xFF1D4ED8);
  static const Color brandTag = Color(0xFF64748B);
  static const Color overline = Color(0xFF64748B);

  // Radii --------------------------------------------------------------------
  static const double radiusCard = 22;
  static const double radiusFeature = 26;
  static const double radiusMetric = 22;
  static const double radiusRow = 19;
  static const double radiusField = 15;
  static const double radiusCircle = 15;
  static const double radiusPill = 999;

  /// Reference `.content` horizontal inset (21px desktop / 19px phone).
  static const double gutter = 20;

  /// Reference bottom-nav row height.
  static const double tabHeight = 63;

  /// Reference `.tab-indicator` pill.
  static const double indicatorWidth = 61;
  static const double indicatorHeight = 33;

  /// Bottom-nav glyph colours, kept at the values the Material 3 reference
  /// sheet specifies. They differ from [primary] and [muted] by a shade, so
  /// they are tokens of their own instead of being re-pointed at those.
  static const Color navActive = Color(0xFF1D4ED8);
  static const Color navInactive = Color(0xFF64748B);

  // Floating bottom dock -----------------------------------------------------
  // Ported from `style-guide.md` §4.4 "Desktop nav pill" — the documented
  // recipe for a floating, pill-shaped navigation surface: 14px side inset
  // (§1.5), radius 999 (§4.9), translucent white + 8% ink hairline border and
  // the two-stage shadow below. The dock reuses [tabHeight] rather than a new
  // height, and the pill reuses [indicatorWidth] / [indicatorHeight].
  static const double dockSideInset = 14;

  /// Breathing room below the dock, added on top of the system inset so the
  /// surface never sits under the home indicator / gesture bar.
  static const double dockBottomInset = 10;

  /// Sliding pill behind the active glyph — same geometry as [indicatorWidth]
  /// and [indicatorHeight], restated so the dock reads as one concept.
  static const double dockPillWidth = indicatorWidth;
  static const double dockPillHeight = indicatorHeight;

  /// Tracks the icon band of `_DockTab`: the tab column is 33 + 2 + 12 tall
  /// and centred in [tabHeight], so the band starts 8px below the top.
  static const double dockPillTop = 8;

  /// One duration and curve family for every dock transition, so the pill,
  /// glyph lift and label fade read as a single move rather than four.
  static const Duration dockMotion = Duration(milliseconds: 320);

  /// Opaque pure white — no cream, tint or translucency over a coloured page.
  static const Color dockSurface = Color(0xFFFFFFFF);

  /// §4.4 hairline, retuned to the shared card border token.
  static const Color dockBorder = Color(0xFFE7E8EA);

  /// §4.4 two-stage shadow: `0 1px 2px rgba(15,23,42,0.04)` and
  /// `0 12px 32px rgba(15,23,42,0.08)`.
  ///
  /// Note the tension with §4.8 "Never add a shadow to a … navigation bar at
  /// rest": this dock is a floating pill surface, so it follows §4.4, which is
  /// the section that actually specifies it. Empty this list to obey §4.8.
  static const List<BoxShadow> dockShadows = [
    BoxShadow(
      color: Color(0x0A0F1729),
      blurRadius: 2,
      offset: Offset(0, 1),
    ),
    BoxShadow(
      color: Color(0x140F1729),
      blurRadius: 32,
      offset: Offset(0, 12),
    ),
  ];
}

/// Typography helpers matching the reference's type scale. Keeping these here
/// avoids six copies of the same magic numbers across the new screens.
abstract final class SitewiseM3Type {
  static const TextStyle eyebrow = TextStyle(
    fontFamily: 'Archivo',
    fontSize: 10,
    fontWeight: FontWeight.w800,
    letterSpacing: 1.2,
    color: SitewiseM3.primary,
  );

  static const TextStyle h1 = TextStyle(
    fontFamily: 'Archivo',
    fontSize: 29,
    fontWeight: FontWeight.w800,
    height: 1.16,
    letterSpacing: -0.81,
    color: SitewiseM3.ink,
  );

  static const TextStyle h2 = TextStyle(
    fontFamily: 'Archivo',
    fontSize: 17,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.48,
    color: SitewiseM3.ink,
  );

  static const TextStyle lead = TextStyle(
    fontFamily: 'Archivo',
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.6,
    color: SitewiseM3.muted,
  );
}
