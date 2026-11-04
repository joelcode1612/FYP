import 'package:shared_logic/shared_logic.dart';

import 'auth_service.dart';

/// Which workspaces the signed-in account may open.
///
/// ## Why this exists as its own file
///
/// The brief asks for a workspace switcher for users who hold both the
/// entrepreneur and property-owner capability. The backend cannot express that
/// yet: `/api/me` returns one profile row with one `role`, and the schema's
/// `CHECK (role IN ('entrepreneur','owner','admin'))` rejects anything else. So
/// the switcher has to read from somewhere the frontend controls.
///
/// ## What is and is not true here
///
/// [primary] is the server-assigned role — the only capability that is real.
/// Anything else in [openable] arrived through the in-session access request on
/// the entrepreneur profile page, is shown with a "demo" label, and is **not**
/// persisted: it lives for the page's Dart isolate and is gone on reload,
/// because no server-side decision has agreed to it. A grant here never widens
/// what the API will answer — every data call still carries the real token.
abstract final class Workspaces {
  static final Set<AppRole> _granted = {};

  /// The role the backend assigned to this session, or null when signed out.
  static AppRole? get primary {
    final name = WebAuth.profile?['role'] as String?;
    if (name == null) return null;
    for (final role in AppRole.values) {
      if (role.name == name) return role;
    }
    return null;
  }

  /// Every workspace the account can reach, in enum order.
  ///
  /// One entry for a normal signed-in user — which is the honest answer today,
  /// and exactly what the switcher should show.
  static List<AppRole> get openable {
    final assigned = primary;
    return [
      for (final role in AppRole.values)
        if (role == assigned || _granted.contains(role)) role,
    ];
  }

  static bool canOpen(AppRole role) =>
      role == primary || _granted.contains(role);

  /// True when [role] was added by the demo request rather than the backend.
  static bool isDemoGrant(AppRole role) =>
      _granted.contains(role) && role != primary;

  static void grant(AppRole role) => _granted.add(role);

  static void revoke(AppRole role) => _granted.remove(role);
}
