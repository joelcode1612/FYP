/// Sidebar navigation, ported from
/// `lib/presentation/web/shell/web_navigation.dart`.
///
/// The Flutter version stores an `IconData` per destination. Jaspr has no such
/// type, so the Material Symbols *name* is stored instead and `Icon` renders it
/// as `<span class="ms">`. Everything else — routes, labels, the per-role
/// grouping — is a direct port.
library;

import 'site_content.dart';

class WebDestination {
  final String route;
  final String icon;
  final String label;

  const WebDestination({
    required this.route,
    required this.icon,
    required this.label,
  });
}

/// The role line under the wordmark, matching the source lockup
/// ("ENTREPRENEUR WORKSPACE", "OWNER WORKSPACE", …). Rendered uppercase by
/// `.brand__sub`, so the stored value is sentence case.
String workspaceLabelFor(AppRole role) => switch (role) {
  AppRole.admin => 'Admin workspace',
  AppRole.owner => 'Owner workspace',
  AppRole.entrepreneur => 'Entrepreneur workspace',
  AppRole.agent => 'Agent workspace',
};

/// Desktop sidebar destinations per role. The web tree is the only consumer —
/// the mobile tree keeps its own bottom-navigation destinations in Flutter.
List<WebDestination> webDestinationsFor(AppRole role) => switch (role) {
  AppRole.admin => const [
    WebDestination(route: '/admin', icon: 'dashboard', label: 'Dashboard'),
    // `people`, not `group`: the mobile bottom nav uses Icons.people_outline,
    // and Material Symbols renders `group` and `people` as different glyphs.
    WebDestination(route: '/admin/users', icon: 'people', label: 'Users'),
    // The five-screen operations suite: Ownership → Agents → Verification →
    // Campaigns → Activity → Surveys. Kept as separate sidebar/pill entries
    // (no merged mega-menu), because each screen has its own route and its
    // own audience among the admin tabs.
    WebDestination(
      route: '/admin/ownership',
      icon: 'fact_check',
      label: 'Ownership',
    ),
    WebDestination(route: '/admin/agents', icon: 'badge', label: 'Agents'),
    WebDestination(
      route: '/admin/verification',
      icon: 'verified',
      label: 'Verification',
    ),
    WebDestination(
      route: '/admin/campaigns',
      icon: 'campaign',
      label: 'Campaigns',
    ),
    WebDestination(
      route: '/admin/activity',
      icon: 'history',
      label: 'Activity',
    ),
    WebDestination(
      route: '/admin/surveys',
      icon: 'how_to_vote',
      label: 'Surveys',
    ),
    WebDestination(
      route: '/admin/listings',
      icon: 'business',
      label: 'Listings',
    ),
    WebDestination(route: '/admin/profile', icon: 'person', label: 'Profile'),
  ],
  AppRole.agent => const [
    WebDestination(route: '/agent', icon: 'dashboard', label: 'Dashboard'),
    WebDestination(
      route: '/agent/listings',
      icon: 'business',
      label: 'Assigned Listings',
    ),
    WebDestination(route: '/agent/enquiries', icon: 'mail', label: 'Enquiries'),
    WebDestination(
      route: '/agent/performance',
      icon: 'monitoring',
      label: 'Performance',
    ),
    WebDestination(route: '/agent/profile', icon: 'person', label: 'Profile'),
  ],
  AppRole.owner => const [
    WebDestination(route: '/owner', icon: 'home', label: 'Home'),
    WebDestination(
      route: '/owner/properties',
      icon: 'store',
      label: 'My Properties',
    ),
    WebDestination(
      route: '/owner/add-property',
      icon: 'add_business',
      label: 'Add Property',
    ),
    WebDestination(route: '/owner/tours', icon: '360', label: '360° Tours'),
    WebDestination(route: '/owner/profile', icon: 'person', label: 'Profile'),
  ],
  AppRole.entrepreneur => const [
    WebDestination(route: '/entrepreneur', icon: 'home', label: 'Home'),
    WebDestination(
      route: '/entrepreneur/explore',
      icon: 'explore',
      label: 'Explore',
    ),
    WebDestination(route: '/entrepreneur/map', icon: 'map', label: 'Map'),
    WebDestination(
      route: '/entrepreneur/recommendations',
      icon: 'auto_awesome',
      label: 'Recommendations',
    ),
    // Saved location assessments. The workspace itself is a drill-in from a
    // property, so it has no nav entry of its own; this is where the records
    // are collected and reopened.
    WebDestination(
      route: '/entrepreneur/assessments',
      icon: 'fact_check',
      label: 'Assessments',
    ),
    WebDestination(
      route: '/entrepreneur/compare',
      icon: 'compare_arrows',
      label: 'Compare',
    ),
    WebDestination(
      route: '/entrepreneur/saved',
      icon: 'bookmark',
      label: 'Saved',
    ),
    WebDestination(
      route: '/entrepreneur/my-properties',
      icon: 'storefront',
      label: 'My Properties',
    ),
    WebDestination(
      route: '/entrepreneur/profile',
      icon: 'person',
      label: 'Profile',
    ),
  ],
};

/// Maps a route to the shell entry that should appear selected.
///
/// Ported from `parentShellRoute` in the Flutter `presentation_environment.dart`:
/// detail and capture routes highlight their parent section, so the sidebar
/// still shows where you are when you drill into a record.
String parentShellRoute(String route) {
  const parents = {
    '/entrepreneur/preferences': '/entrepreneur',
    '/entrepreneur/property-detail': '/entrepreneur/explore',
    '/entrepreneur/assessment': '/entrepreneur/explore',
    '/entrepreneur/tour': '/entrepreneur/explore',
    '/entrepreneur/report': '/entrepreneur/explore',
    '/entrepreneur/explanation': '/entrepreneur/recommendations',
    '/entrepreneur/my-properties': '/entrepreneur/my-properties',
    '/entrepreneur/add-property': '/entrepreneur/my-properties',
    '/admin/user-detail': '/admin/users',
    '/admin/verification-detail': '/admin/verification',
    '/admin/listing-detail': '/admin/listings',
    '/admin/agent-detail': '/admin/agents',
    '/agent/property-detail': '/agent/listings',
    '/owner/property-detail': '/owner/properties',
    '/owner/tour-preview': '/owner/tours',
    '/owner/capture': '/owner/tours',
  };
  return parents[route] ?? route;
}

/// Derives the active role from the URL path.
///
/// In the Flutter tree the role lives in the shared `AppNotifier` and pages
/// receive it as a parameter. Here the URL is the single source of truth: the sidebar, the
/// topbar controls and the page body all read the role from the path they were
/// rendered for, so they can never disagree — including after a role switch,
/// which is just a navigation to the other role's home route.
AppRole roleForPath(String path) {
  if (path.startsWith('/admin')) return AppRole.admin;
  if (path.startsWith('/agent')) return AppRole.agent;
  if (path.startsWith('/owner')) return AppRole.owner;
  return AppRole.entrepreneur;
}

/// Human-readable topbar title for any route, including detail routes that
/// are not sidebar entries. Falls back to a prettified path segment.
String titleForRoute(String route) {
  for (final role in AppRole.values) {
    for (final d in webDestinationsFor(role)) {
      if (d.route == route) return d.label;
    }
  }
  final names = const {
    '/entrepreneur/preferences': 'Preferences',
    '/entrepreneur/property-detail': 'Property',
    '/entrepreneur/tour': '360° Tour',
    '/entrepreneur/report': 'Suitability Report',
    '/entrepreneur/explanation': 'Why this score',
    '/admin/user-detail': 'User',
    '/admin/verification-detail': 'Verification',
    '/admin/listing-detail': 'Listing',
    '/owner/property-detail': 'Property',
    '/owner/tour-preview': '360° Tour',
  };
  if (names.containsKey(route)) return names[route]!;
  final segment = route.split('/').where((s) => s.isNotEmpty).lastOrNull;
  if (segment == null) return 'Page';
  return segment
      .replaceAll('-', ' ')
      .replaceAllMapped(RegExp(r'\b\w'), (m) => m.group(0)!.toUpperCase());
}
