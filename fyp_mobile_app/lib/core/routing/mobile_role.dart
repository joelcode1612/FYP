import 'package:shared_logic/shared_logic.dart';

/// Mobile workspace routes.
const String _providerHome = '/provider';
const String _entrepreneurHome = '/entrepreneur';
const String providerOnboardingRoute = '/provider/onboarding';

/// Routes restricted to property owners.
const Set<String> _ownerOnlyRoutes = {
  '/provider/add-property',
  '/provider/requests',
};

/// Routes restricted to property agents.
const Set<String> _agentOnlyRoutes = {
  '/provider/tasks',
  '/provider/inspection',
  '/provider/verification',
  '/provider/submission-success',
  '/owner/capture',
};

/// Shared authenticated routes.
const Set<String> _sharedRoutes = {'/onboarding', '/tour-preview'};

/// Public authentication and entry routes.
const Set<String> _publicRoutes = {
  '/',
  '/landing',
  '/auth',
  '/signup',
  '/forgot-password',
};

/// Whether the role belongs to the Provider workspace.
bool _isProviderRole(AppRole role) =>
    role == AppRole.owner || role == AppRole.agent;

/// Resolve a route path safely.
String? _routePath(String route) {
  final uri = Uri.tryParse(route);
  if (uri == null) {
    return null;
  }

  return uri.path;
}

/// Return the mobile home route for a supported role.
String? mobileHomeRouteFor(AppRole role) => switch (role) {
  AppRole.entrepreneur => _entrepreneurHome,
  AppRole.owner || AppRole.agent => _providerHome,
  AppRole.admin => null,
};

/// Explain why a web-only account cannot enter mobile.
String mobileUnsupportedRoleMessage(AppRole role) =>
    '${role.label} is available through the '
    'SiteWise Web Portal. Please sign in using '
    'the web application.';

/// Identify the workspace responsible for a route.
String? mobileWorkspaceForRoute(String route) {
  final path = _routePath(route);

  if (path == null) {
    return null;
  }

  // Legacy capture path belongs to the Agent workspace.
  if (path == '/owner/capture') {
    return _providerHome;
  }

  if (path == _providerHome || path.startsWith('$_providerHome/')) {
    return _providerHome;
  }

  if (path == _entrepreneurHome || path.startsWith('$_entrepreneurHome/')) {
    return _entrepreneurHome;
  }

  return null;
}

/// Determine whether a role may enter a mobile route.
///
/// Backend authorization remains authoritative for all data
/// access, property mutations and inspection operations.
bool canEnterMobileRoute(AppRole role, String route) {
  final path = _routePath(route);

  if (path == null) {
    return false;
  }

  if (_publicRoutes.contains(path)) {
    return true;
  }

  // Administrator has no authenticated mobile workspace.
  if (mobileHomeRouteFor(role) == null) {
    return false;
  }

  if (_ownerOnlyRoutes.contains(path)) {
    return role == AppRole.owner;
  }

  if (_agentOnlyRoutes.contains(path)) {
    return role == AppRole.agent;
  }

  if (_sharedRoutes.contains(path)) {
    return true;
  }

  final workspace = mobileWorkspaceForRoute(path);

  return workspace != null && mobileHomeRouteFor(role) == workspace;
}

/// Roles supported by the mobile application.
List<AppRole> get mobileSupportedRoles => AppRole.values
    .where((role) => mobileHomeRouteFor(role) != null)
    .toList(growable: false);

/// Provider accounts require verified MFA assurance.
bool requiresStaffMfa(SitewiseUser user) =>
    _isProviderRole(user.role) && !user.hasStaffAssurance;

/// Determine the first route after authentication.
String? authLandingRouteFor(SitewiseUser user) {
  final home = mobileHomeRouteFor(user.role);

  if (home == null) {
    return null;
  }

  if (user.isPendingProvider) {
    return requiresStaffMfa(user) ? '/provider/mfa' : providerOnboardingRoute;
  }

  if (requiresStaffMfa(user)) {
    return '/provider/mfa';
  }

  return home;
}
