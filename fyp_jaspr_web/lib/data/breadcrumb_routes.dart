/// Centralised route → breadcrumb configuration for the authenticated
/// workspaces.
///
/// [AppLayout] renders one global breadcrumb trail below the pill nav on
/// every page. The trail is derived here — in one place — from the same
/// vocabulary the rest of the shell uses:
///
/// * the first crumb is always **Home**, linked to the role's own home route
///   (`AppRole.homeRoute`), so the trail is the same shape for entrepreneur,
///   admin, agent and owner;
/// * drill-in routes name the section they belong to. Section choices mirror
///   `parentShellRoute` in `navigation.dart` — the section the pill nav
///   highlights is the section the breadcrumb names — so the two never
///   disagree about where a page lives;
/// * the final crumb is the current page (unlinked, `aria-current="page"`).
///
/// ## Aliased detail pages
///
/// Some detail pages pass their **parent section's route** as `currentRoute`
/// (so the pill nav highlights it): admin user detail passes `/admin/users`,
/// admin listing detail passes `/admin/listings`, agent listing detail passes
/// `/agent/listings`, and the property-registration views pass
/// `/entrepreneur/add-property`. For those the page's own `title` (already
/// flowing into [AppLayout] for the page head) becomes the current crumb —
/// `pageTitle: true` below — while the registered section becomes an
/// intermediate link. An unknown route falls back to
/// `titleForRoute`, so a page added tomorrow still gets an honest trail
/// without touching this file.
library;

import 'package:shared_logic/shared_logic.dart' show AppRole, AppRoleLabel;

import '../components/app_breadcrumbs.dart';
import 'navigation.dart';

/// One registry entry: the trail *after* the leading Home crumb.
class _TrailSpec {
  /// Current-page label. Ignored when [usePageTitle] is set and a page title
  /// was supplied.
  final String label;

  /// Route of the intermediate (linked) section crumb, or null when the page
  /// is a top-level destination itself.
  final String? sectionRoute;

  /// For detail views aliased onto a section route: take the current crumb's
  /// label from the page title instead of the registry, because the route
  /// alone cannot distinguish the section page from its drill-ins.
  final bool usePageTitle;

  const _TrailSpec(this.label, {this.sectionRoute, this.usePageTitle = false});
}

const Map<String, _TrailSpec> _trails = {
  // --- Entrepreneur -----------------------------------------------------
  // Retired discovery route: `/entrepreneur/explore` redirects to
  // Recommendations in `app.dart`. Kept so a crumb resolved mid-redirect still
  // has a label.
  '/entrepreneur/explore': _TrailSpec('Recommendations'),
  '/entrepreneur/map': _TrailSpec('Map view', sectionRoute: '/entrepreneur/recommendations'),
  '/entrepreneur/property-detail':
      _TrailSpec('Property details', sectionRoute: '/entrepreneur/recommendations'),
  '/entrepreneur/property-analysis':
      _TrailSpec('Location analysis', sectionRoute: '/entrepreneur/recommendations'),
  '/entrepreneur/assessment':
      _TrailSpec('Assessment workspace', sectionRoute: '/entrepreneur/recommendations'),
  // The workspace is now the main Assessments destination; the history list
  // hangs off it as a sibling section.
  '/entrepreneur/assessments': _TrailSpec('Location assessment'),
  '/entrepreneur/assessments/history': _TrailSpec('History'),
  '/entrepreneur/reports': _TrailSpec('Reports'),
  '/entrepreneur/report':
      _TrailSpec('Suitability report', sectionRoute: '/entrepreneur/reports'),
  '/entrepreneur/tour': _TrailSpec('360° tour', sectionRoute: '/entrepreneur/recommendations'),
  '/entrepreneur/explanation':
      _TrailSpec('Why this score', sectionRoute: '/entrepreneur/recommendations'),
  '/entrepreneur/recommendations': _TrailSpec('Recommendations'),
  '/entrepreneur/compare': _TrailSpec('Compare'),
  '/entrepreneur/saved': _TrailSpec('Saved'),
  '/entrepreneur/my-properties': _TrailSpec('My Properties'),
  // The registration wizard (and its draft-saved view) render their own
  // styled in-page breadcrumb, so AppLayout suppresses the global one there;
  // the spec is kept so the mapping stays explicit and `titleForRoute`
  // fallbacks never fire for it.
  '/entrepreneur/add-property': _TrailSpec(
    'Register a property',
    sectionRoute: '/entrepreneur/my-properties',
    usePageTitle: true,
  ),
  '/entrepreneur/preferences':
      _TrailSpec('Preferences', sectionRoute: '/entrepreneur/profile'),
  '/entrepreneur/profile': _TrailSpec('Profile'),

  // --- Admin --------------------------------------------------------------
  '/admin/users': _TrailSpec('Users', usePageTitle: true),
  '/admin/user-detail': _TrailSpec('User detail', sectionRoute: '/admin/users'),
  '/admin/listings': _TrailSpec('Listings', usePageTitle: true),
  '/admin/listing-detail':
      _TrailSpec('Listing detail', sectionRoute: '/admin/listings'),
  '/admin/agents': _TrailSpec('Agents'),
  '/admin/surveys': _TrailSpec('Surveys'),
  // Not in the navbar any more, but the routes (and the audit data behind
  // them) stay live for direct links — they still earn a breadcrumb.
  '/admin/campaigns': _TrailSpec('Campaigns'),
  '/admin/activity': _TrailSpec('Activity'),
  '/admin/profile': _TrailSpec('Profile'),

  // --- Agent ---------------------------------------------------------------
  '/agent/listings': _TrailSpec('Assigned listings', usePageTitle: true),
  '/agent/property-detail':
      _TrailSpec('Listing', sectionRoute: '/agent/listings'),
  '/agent/enquiries': _TrailSpec('Enquiries'),
  '/agent/performance': _TrailSpec('Performance'),
  '/agent/profile': _TrailSpec('Profile'),

  // --- Owner (legacy links resolve into entrepreneur; routes stay live) ----
  '/owner/properties': _TrailSpec('My Properties'),
  '/owner/property-detail':
      _TrailSpec('Property', sectionRoute: '/owner/properties'),
  '/owner/add-property': _TrailSpec(
    'Add Property',
    sectionRoute: '/owner/properties',
    usePageTitle: true,
  ),
  '/owner/tours': _TrailSpec('360° Tours'),
  '/owner/tour-preview': _TrailSpec('Tour preview', sectionRoute: '/owner/tours'),
  '/owner/profile': _TrailSpec('Profile'),
};

/// Builds the breadcrumb trail for one authenticated page.
///
/// Returns an empty list when no trail should render: the role's home page
/// (a lone "Home" crumb says nothing) or any route the registry and the
/// fallback both decline.
List<BreadcrumbItem> breadcrumbTrailFor({
  required AppRole role,
  required String currentRoute,
  String? pageTitle,
}) {
  final home = role.homeRoute;
  if (currentRoute == home || currentRoute.isEmpty) return const [];

  final items = <BreadcrumbItem>[BreadcrumbItem(label: 'Home', route: home)];

  final spec = _trails[currentRoute];
  if (spec == null) {
    // Unregistered route: an honest two-crumb trail from the shell's own
    // title table rather than no trail at all.
    items.add(BreadcrumbItem.current(titleForRoute(currentRoute)));
    return items;
  }

  final section = spec.sectionRoute;
  if (section != null) {
    items.add(BreadcrumbItem(label: titleForRoute(section), route: section));
  }

  final label = spec.usePageTitle && pageTitle != null && pageTitle.isNotEmpty
      ? pageTitle
      : spec.label;
  items.add(BreadcrumbItem.current(label));
  // Aliased detail view (a drill-in that reuses its section's route): when
  // the page title differs from the registered section label, the section
  // itself becomes an intermediate link so the trail still reads
  // "Home > Users > User detail" instead of jumping straight to the record.
  if (spec.usePageTitle &&
      spec.sectionRoute == null &&
      label != spec.label &&
      pageTitle != null &&
      pageTitle.isNotEmpty) {
    items.insert(
      items.length - 1,
      BreadcrumbItem(label: spec.label, route: currentRoute),
    );
  }
  return items;
}
