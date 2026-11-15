import 'package:shared_logic/shared_logic.dart';

/// The role gate for the mobile app.
///
/// `AppRole` keeps every role because `fyp_jaspr_web` and the seeded demo
/// accounts resolve them; this maps a role onto navigation the mobile app
/// can actually perform, so no screen has to know which workspaces shipped.

/// The mobile workspaces this build can actually open.
///
/// Entrepreneur and Owner / Agent are mobile; Admin remains the Jaspr web
/// portal. `null` means "this role has no mobile route".
String? mobileHomeRouteFor(AppRole role) => switch (role) {
  AppRole.entrepreneur => role.homeRoute,
  // Owners and agents share one provider workspace. The backend role stays
  // `agent`; the label is public-facing only.
  AppRole.owner || AppRole.agent => '/provider',
  AppRole.admin => null,
};

/// Shown wherever a web-only account reaches the mobile app.
String mobileUnsupportedRoleMessage(AppRole role) =>
    '${role.label} works from the SiteWise Staff Web Portal, not the mobile '
    'app, and signing in there requires multi-factor authentication. '
    'Open the portal on a computer, or use a Property Owner / Agent or '
    'F&B Entrepreneur account here.';

/// The workspace a mobile route belongs to, or `null` when the route is shared.
///
/// Two workspaces exist on mobile and they must not overlap: property
/// management (`/provider...`) and discovery/assessment (`/entrepreneur...`).
/// A route that belongs to neither is shared work — the 360° capture flow and
/// the tour preview are used by both, so they are deliberately role-neutral.
///
/// This is a *presentation* boundary. It decides which shell a route may paint;
/// it never grants data access. Every API call behind these routes is still
/// authorized by the backend against the caller's ownership or assignment.
String? mobileWorkspaceForRoute(String route) {
  final path = Uri.parse(route).path;
  if (path == '/provider' || path.startsWith('/provider/')) return '/provider';
  if (path == '/entrepreneur' || path.startsWith('/entrepreneur/')) {
    return '/entrepreneur';
  }
  return null;
}

/// Whether [role] may open [route] at all.
///
/// Without this an Entrepreneur could navigate straight to `/provider/listings`
/// and get a rendered shell over an inbox that answers 403 — an empty screen
/// that looks like a bug rather than a boundary. The guard now refuses the
/// route instead, and the backend refusal stays as the second, authoritative
/// line of defence.
bool canEnterMobileRoute(AppRole role, String route) {
  final workspace = mobileWorkspaceForRoute(route);
  if (workspace == null) return true;
  return mobileHomeRouteFor(role) == workspace;
}

/// Roles that can be entered on mobile, in the shared enum's order.
List<AppRole> get mobileSupportedRoles =>
    AppRole.values.where((role) => mobileHomeRouteFor(role) != null).toList(
      growable: false,
    );

/// Whether this verified session still owes a second factor before its
/// workspace can be opened.
///
/// Only an **agent** is staff on mobile: the backend's
/// `require_property_owner` / `get_staff_user` demand `aal2` for staff roles,
/// while a Property Owner is an `entrepreneur` and needs no second factor.
/// Administrators have no mobile route at all, so their existing web MFA flow
/// is untouched.
///
/// The decision comes from the server-verified `aal` claim echoed by
/// `GET /api/v1/auth/me` — never from a local boolean. An unknown level is
/// treated as NOT satisfied (fail closed): the MFA screen then asks Supabase
/// directly and finishes immediately when the session is in fact elevated.
bool requiresStaffMfa(SitewiseUser user) =>
    user.role == AppRole.agent && !user.hasStaffAssurance;

/// The FIRST route to open after a trusted authentication succeeds.
///
/// Entrepreneur -> dashboard. Agent with `aal1` -> the existing authenticator
/// screen, which hands off to the dashboard once Supabase has issued an
/// elevated session. Agent with `aal2` -> dashboard with no repeated MFA
/// prompt. Returns null for a role with no mobile workspace (Administrator).
String? authLandingRouteFor(SitewiseUser user) {
  final home = mobileHomeRouteFor(user.role);
  if (home == null) return null;
  return requiresStaffMfa(user) ? '/provider/mfa' : home;
}
