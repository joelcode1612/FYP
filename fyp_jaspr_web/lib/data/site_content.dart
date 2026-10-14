/// Sitewise content, ported from
/// `lib/presentation/shared/landing/landing_content.dart` in the Flutter app.
///
/// The only structural change is icons: Flutter stores an `IconData`, which is
/// a Flutter type with no web equivalent. Here the same glyph is held as its
/// Material Symbols *name* (`'storefront'`), rendered by `<span class="ms">`.
/// Keeping the name rather than a code point means this file stays readable
/// and stays comparable with the Flutter original.
library;

// The role enum now comes from the shared package rather than being declared
// here. `shared_logic` is the single source of truth for it, so the Flutter app
// and this one can never disagree about which roles exist or what their home
// routes are. Re-exported so files that already import this library keep working.
//
// `AppRoleLabel` must be listed too: `label` and `homeRoute` live on an
// extension, not on the enum, so `show AppRole` alone would leave `role.label`
// unresolved.
export 'package:shared_logic/shared_logic.dart' show AppRole, AppRoleLabel;

// --- Landing copy -----------------------------------------------------------

abstract final class LandingContent {
  static const String eyebrow = 'Evidence-based F&B location decisions';
  static const String heroTitleA = 'Choose your next ';
  static const String heroTitleEm = 'F&B location';
  static const String heroTitleB = ' with better evidence.';
  static const String heroLead =
      'Sitewise brings your business preferences, commercial property '
      'information and geospatial signals together so you can discover, '
      'compare and understand suitable locations.';
  static const String heroPrimary = 'Find a Suitable Location';
  static const String heroSecondary = 'See How It Works';
  static const String heroNote =
      'Recommendations are explained through clear location factors — '
      'you make the final decision.';

  /// In-page anchors. On the web these are plain `#id` links, so the smooth
  /// scroll needs no JavaScript at all — the Flutter version needed a
  /// `GlobalKey` plus `Scrollable.ensureVisible` per target.
  static const List<(String label, String anchor)> navLinks = [
    ('How It Works', 'how'),
    ('Location Intelligence', 'geo'),
    ('Recommendations', 'recs'),
    ('360° Tours', 'tour'),
  ];

  static const List<RoleCardData> roles = [
    RoleCardData(
      icon: 'storefront',
      title: 'F&B Entrepreneurs',
      body:
          'Define your business preferences, explore verified commercial '
          'properties, compare locations, review suitability factors and '
          'inspect available 360° tours.',
      linkLabel: 'Explore suitable locations',
      route: '/entrepreneur',
    ),
    RoleCardData(
      icon: 'business',
      title: 'Commercial Property Owners',
      body:
          'Present commercial rental properties with structured details, '
          'availability information and immersive 360° tours for '
          'entrepreneurs evaluating a shortlist.',
      linkLabel: 'See property presentation',
      route: '/owner/tours',
    ),
  ];

  static const List<StepData> steps = [
    StepData(
      num: '01',
      title: 'Define your business',
      body:
          'Set your F&B concept, target customers, budget, size and operating '
          'preferences.',
    ),
    StepData(
      num: '02',
      title: 'Analyse the location',
      body:
          'Review population, accessibility, competition and nearby '
          'demand-generating places.',
    ),
    StepData(
      num: '03',
      title: 'Compare properties',
      body:
          'See how candidate properties fit your stated requirements and '
          'location conditions.',
    ),
    StepData(
      num: '04',
      title: 'Understand why',
      body:
          'Review the factors behind each recommendation before deciding which '
          'sites to visit.',
    ),
  ];

  static const List<FeatureData> features = [
    FeatureData(
      icon: 'groups',
      title: 'Population context',
      body:
          'Understand the residential and population environment around the '
          'candidate area.',
    ),
    FeatureData(
      icon: 'alt_route',
      title: 'Accessibility',
      body:
          'Consider road access, public transport and the practical reach of '
          'the location.',
    ),
    FeatureData(
      icon: 'storefront',
      title: 'Competition & demand',
      body:
          'Review nearby F&B presence and demand generators that can influence '
          'the catchment.',
    ),
    FeatureData(
      icon: 'home_work',
      title: 'Property-level context',
      body:
          'Connect location signals with rent, floor area, frontage and other '
          'property details.',
    ),
  ];

  // --- Worked example (the "explainable recommendation" panel) --------------

  static const String assessmentProperty = 'Artisan Brew Corner Lot';
  static const int assessmentScore = 86;

  static const List<DriverData> drivers = [
    DriverData(
      title: 'Strong daytime demand',
      body:
          'Nearby offices and education-related activity support daytime '
          'demand.',
      tradeoff: false,
    ),
    DriverData(
      title: 'Good accessibility',
      body:
          'Road and public transport access contribute positively to the '
          'location context.',
      tradeoff: false,
    ),
    DriverData(
      title: 'Trade-off: Moderate café competition',
      body: 'Existing F&B presence nearby may increase competitive pressure.',
      tradeoff: true,
    ),
  ];

  static const List<(String label, int pct)> weights = [
    ('Morning pedestrian activity', 35),
    ('Direct competition', 25),
    ('Premise suitability', 20),
    ('Rent fit', 20),
  ];

  static const List<(String k, String v)> siteProfile = [
    ('Location', 'SS15, Subang Jaya'),
    ('Monthly rent', 'RM 7,000 – RM 8,000'),
    ('Floor area', '1,200 sq ft'),
    ('Frontage', 'Corner retail lot'),
    ('Transport', 'Good'),
    ('360° tour', 'Available'),
  ];

  static const String ctaTitle =
      'Make your next F&B location decision with better evidence.';
  static const String ctaBody =
      'Start with your business preferences, explore available commercial '
      'properties, and understand the location factors before deciding which '
      'sites deserve a closer look.';
}

// --- Landing value types ----------------------------------------------------

class RoleCardData {
  final String icon;
  final String title;
  final String body;
  final String linkLabel;
  final String route;

  const RoleCardData({
    required this.icon,
    required this.title,
    required this.body,
    required this.linkLabel,
    required this.route,
  });
}

class StepData {
  final String num;
  final String title;
  final String body;

  const StepData({required this.num, required this.title, required this.body});
}

class FeatureData {
  final String icon;
  final String title;
  final String body;

  const FeatureData({
    required this.icon,
    required this.title,
    required this.body,
  });
}

class DriverData {
  final String title;
  final String body;
  final bool tradeoff;

  const DriverData({
    required this.title,
    required this.body,
    required this.tradeoff,
  });
}

// --- Roles ------------------------------------------------------------------
//
// `AppRole` is no longer declared here. It is re-exported at the top of this
// file from `package:shared_logic`, which both the Flutter app and this one
// depend on. Previously this file carried its own copy, which is exactly the
// kind of duplication the shared package exists to remove — and it had already
// drifted (the local copy said 'Commercial Property Owner' where the shared one
// says 'Property Owner').
