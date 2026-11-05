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
abstract final class SitewiseM3 {
  // Surfaces -----------------------------------------------------------------
  static const Color bg = Color(0xFFE8EEF6);
  static const Color paper = Color(0xFFF7F9FF);
  static const Color surface = Color(0xFFFFFFFF);

  // Ink ----------------------------------------------------------------------
  static const Color ink = Color(0xFF173E73);
  static const Color text = Color(0xFF273B59);
  static const Color muted = Color(0xFF51647E);
  static const Color stone = Color(0xFF70839E);

  // Brand --------------------------------------------------------------------
  static const Color primary = Color(0xFF1D4ED8);
  static const Color accent = Color(0xFF376BF1);
  static const Color primaryHover = Color(0xFF1746C4);
  static const Color quiet = Color(0xFFE7EEFF);
  static const Color quietStrong = Color(0xFFDBE7FF);
  static const Color brandBorder = Color(0xFFD0DEFF);
  static const Color line = Color(0xFFDAE4F2);
  static const Color soft = Color(0xFFEDF3FC);
  static const Color divider = Color(0xFFE2EAF4);

  // Status -------------------------------------------------------------------
  static const Color green = Color(0xFF086A60);
  static const Color greenWash = Color(0xFFDDF7EE);
  static const Color amber = Color(0xFF92550D);
  static const Color amberWash = Color(0xFFFFF3D9);

  // Home feature card --------------------------------------------------------
  static const Color featureStart = Color(0xFFE3EDFF);
  static const Color featureMid = Color(0xFFDCEAFF);
  static const Color featureEnd = Color(0xFFF4F8FF);
  static const Color featureBorder = Color(0xFFC9DAFE);
  static const Color featureTitle = Color(0xFF46648B);
  static const Color kickerText = Color(0xFF174BB1);

  // Metric tiles -------------------------------------------------------------
  static const Color metricBlueBg = Color(0xFFEAF1FF);
  static const Color metricBlueBorder = Color(0xFFD9E5FC);
  static const Color metricTealBg = Color(0xFFEEF9F8);
  static const Color metricTealBorder = Color(0xFFD8F0ED);
  static const Color metricValue = Color(0xFF174A9E);
  static const Color metricIconBg = Color(0xFFD7E5FF);
  static const Color metricTealIconBg = Color(0xFFD3F2EB);
  static const Color metricTealIcon = Color(0xFF0B7167);

  // Notes / banners / rows ---------------------------------------------------
  static const Color noteBg = Color(0xFFF2F7FF);
  static const Color noteBorder = Color(0xFFCCE1F8);
  static const Color noteText = Color(0xFF345B89);
  static const Color bannerBg = Color(0xFFEAF1FF);
  static const Color bannerBorder = Color(0xFFD6E5FF);
  static const Color bannerText = Color(0xFF315883);
  static const Color rowBorder = Color(0xFFE1E9F5);
  static const Color rowIconBg = Color(0xFFE9F0FF);
  static const Color rowTitle = Color(0xFF203E69);
  static const Color rowDesc = Color(0xFF60758D);
  static const Color circleBtnBg = Color(0xFFEEF3FD);
  static const Color circleBtnBorder = Color(0xFFE5EBF6);
  static const Color circleBtnIcon = Color(0xFF315B9D);
  static const Color brandTag = Color(0xFF5B7191);
  static const Color overline = Color(0xFF637BA0);

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
    color: Color(0xFF526781),
  );
}
