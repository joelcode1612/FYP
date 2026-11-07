import 'package:shared_logic/shared_logic.dart';

/// The role gate for the mobile app.
///
/// `AppRole` keeps every role because `fyp_jaspr_web` and the seeded demo
/// accounts resolve them; this maps a role onto navigation the mobile app
/// can actually perform, so no screen has to know which workspaces shipped.

/// The only mobile workspace is the Entrepreneur one — Admin, Property Owner
/// and Agent are web interfaces. `null` means "this role has no mobile route".
String? mobileHomeRouteFor(AppRole role) =>
    role == AppRole.entrepreneur ? role.homeRoute : null;

/// Shown wherever a web-only account reaches the mobile app.
String mobileUnsupportedRoleMessage(AppRole role) =>
    '${role.label} works from the SiteWise Staff Web Portal, not the mobile '
    'app, and signing in there requires multi-factor authentication. '
    'Open the portal on a computer, or use an F&B Entrepreneur account here.';

/// Roles that can be entered on mobile, in the shared enum's order.
List<AppRole> get mobileSupportedRoles =>
    AppRole.values.where((role) => mobileHomeRouteFor(role) != null).toList(
      growable: false,
    );
