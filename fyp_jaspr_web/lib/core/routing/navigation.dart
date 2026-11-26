/// Sidebar navigation, ported from
/// `lib/presentation/web/shell/web_navigation.dart`.
///
/// The Flutter version stores an `IconData` per destination. Jaspr has no such
/// type, so the Material Symbols *name* is stored instead and `Icon` renders it
/// as `<span class="ms">`. Everything else — routes, labels, the per-role
/// grouping — is a direct port.
library;

import 'package:sitewise_jaspr_web/core/config/site_content.dart';

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
    // The five primary Admin destinations. Surveys and Profile are not
    // sidebar entries: Profile is reached through the avatar menu
    // (`topbar_controls.dart`), and Surveys and Campaigns keep their
    // registered routes, pages and audit reads for direct links. Removing an
    // entry here changes navigation only — the router guard still authorizes
    // every `/admin/*` route independently.
    WebDestination(route: '/admin/agents', icon: 'badge', label: 'Agents'),
    WebDestination(
      route: '/admin/listings',
      icon: 'business',
      label: 'Listings',
    ),
  ],
  // The Agent web workspace is retired: property management is the Flutter
  // Owner / Agent app. No destinations means the shell renders no sidebar for
  // a role that no longer has web pages.
  AppRole.agent => const [],
  // The Owner web workspace is retired with it. Owners sign in to the SAME
  // Flutter Provider workspace as agents — the two are one mobile product, and
  // the split between them is decided server-side (ownership vs assignment),
  // not by a second web UI. The `/owner/*` routes survive as explanatory
  // redirects (see `app.dart`) so an old bookmark states where the work moved
  // instead of 404ing, but nothing is reachable from here.
  AppRole.owner => const [],
  AppRole.entrepreneur => const [
    WebDestination(route: '/entrepreneur', icon: 'home', label: 'Home'),
    // Discovery is ONE destination. Explore and Recommendations used to be two
    // entries for the same job; the recommendation search now carries browsing
    // (no-criteria searches are plain catalogue browses), so Explore is gone
    // from the sidebar. Its route survives as a redirect — see
    // `Router.redirect` in app.dart — so old links keep working.
    WebDestination(
      route: '/entrepreneur/recommendations',
      icon: 'recommend',
      label: 'Recommendations',
    ),
    // The **Assessment** destination. Since PROJECT1 v1.5 this opens the
    // four-step research flow at `/entrepreneur/assessments`: the assessment
    // overview list, then Steps 1–4. It no longer points at the read-only
    // report index (`/entrepreneur/assessment-list`), which remains reachable
    // by URL but is not a top-bar entry.
    WebDestination(
      route: '/entrepreneur/assessments',
      icon: 'fact_check',
      label: 'Assessment',
    ),
    // "M2 research" and "Report" are no longer top-bar destinations (owner
    // request). Both routes stay registered in `app.dart`, so an existing
    // bookmark still resolves to the same screen — they simply have no pill of
    // their own, the same treatment `/entrepreneur/activity-history` and
    // `/entrepreneur/explore` already get. The report is still reachable from
    // every assessment: "View report" on a card, and in the details panel.
    // ONE history destination. `/entrepreneur/activity-history` and
    // `/entrepreneur/assessments/history` both mounted `ActivityHistoryView`
    // (the same `M2ActivityPanel`), so the sidebar carried two pills that
    // opened the identical screen. The surviving entry is the one nested under
    // Assessment, because it carries the real breadcrumb
    // (`Assessment › Assessment history`) that the orphan route never had.
    // `/entrepreneur/activity-history` stays registered in `app.dart`, so an
    // old bookmark still resolves — it simply has no pill of its own.
    WebDestination(
      route: '/entrepreneur/assessments/history',
      icon: 'history',
      label: 'History',
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
    // My Properties is GONE from this workspace. Listing management is the
    // Provider (Owner / Agent) job and lives in the Flutter app; an
    // entrepreneur browsing the catalogue has no listings to manage, so the
    // destination was an empty surface that also implied an authority the
    // role does not hold. `/entrepreneur/my-properties` and
    // `/entrepreneur/add-property` stay registered as denied redirects.
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
    // Preferences is a drill-in from "Profile & preferences" (and from the
    // shortlist), not a child of Home. Mapping it to '/entrepreneur' lit up the
    // Home pill while the preferences form was on screen.
    '/entrepreneur/preferences': '/entrepreneur/profile',
    // Discovery moved to Recommendations. Every retired discovery route now
    // highlights that one pill, so a deep link still shows where you are.
    '/entrepreneur/explore': '/entrepreneur/recommendations',
    '/entrepreneur/map': '/entrepreneur/recommendations',
    '/entrepreneur/property-detail': '/entrepreneur/recommendations',
    '/entrepreneur/property-analysis': '/entrepreneur/recommendations',
    '/entrepreneur/assessment': '/entrepreneur/assessments',
    '/entrepreneur/assessments/history': '/entrepreneur/assessments/history',
    // The orphan duplicate. `/entrepreneur/activity-history` renders the same
    // `ActivityHistoryView` as the entry above, so a bookmark to it must light
    // that surviving pill rather than leave the sidebar with nothing selected.
    '/entrepreneur/activity-history': '/entrepreneur/assessments/history',
    '/entrepreneur/tour': '/entrepreneur/recommendations',
    // A generated report is read THROUGH the Report destination. It used to
    // highlight Recommendations, which meant opening a report lit a tab the
    // reader had not come from — the selector gate existed precisely to stop
    // that, so every report surface now resolves back to it.
    '/entrepreneur/report': '/entrepreneur/cafe-report',
    // The report shell is now reached from the selector gate; both URLs keep
    // the Report pill lit so the sidebar matches what is on screen.
    '/entrepreneur/cafe-report/view': '/entrepreneur/cafe-report',
    // The standalone report directory is not a sidebar entry. Opening a row
    // from it and pressing Back must not leave the pill pointing at a route
    // the sidebar cannot select, so it resolves to the gate as well.
    '/entrepreneur/reports': '/entrepreneur/cafe-report',
    '/entrepreneur/explanation': '/entrepreneur/recommendations',
    // Listing management is retired from this workspace entirely, so the two
    // routes that used to sit under My Properties have no pill to light up.
    // They no longer resolve (see the denied redirects in `app.dart`); these
    // entries only keep a stale cached shell from selecting nothing.
    '/entrepreneur/my-properties': '/entrepreneur',
    '/entrepreneur/add-property': '/entrepreneur',
    '/admin/user-detail': '/admin/users',
    '/admin/listing-detail': '/admin/listings',
    '/admin/agent-detail': '/admin/agents',
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
    '/entrepreneur/property-analysis': 'Location analysis',
    '/entrepreneur/tour': '360° Tour',
    '/entrepreneur/reports': 'Reports',
    '/entrepreneur/report': 'Suitability Report',
    '/entrepreneur/explanation': 'Why this score',
    '/admin/user-detail': 'User',
    '/admin/verification-detail': 'Verification',
    '/admin/listing-detail': 'Listing',
  };
  if (names.containsKey(route)) return names[route]!;
  final segment = route.split('/').where((s) => s.isNotEmpty).lastOrNull;
  if (segment == null) return 'Page';
  return segment
      .replaceAll('-', ' ')
      .replaceAllMapped(RegExp(r'\b\w'), (m) => m.group(0)!.toUpperCase());
}
