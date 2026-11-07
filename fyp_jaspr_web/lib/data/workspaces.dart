import 'package:shared_logic/shared_logic.dart';

import 'auth_service.dart';

/// Presentation-only view of backend-assigned workspace capabilities.
/// No permissions are read from (or granted through) a browser cookie.
/// Every protected URL and API is independently authorized by FastAPI.
abstract final class Workspaces {
  /// Kept for compatibility with the persisted UI-state shape. Always empty:
  /// UI preferences must not be treated as access grants.
  static Set<String> get granted => <String>{};
  static void seed(Set<String> ignored) {}

  static AppRole? get primary {
    final name = WebAuth.profile?['role'] as String?;
    final canonical = switch (name) {
      'administrator' => 'admin',
      'property_owner' || 'user' => 'entrepreneur',
      _ => name,
    };
    for (final role in AppRole.values) {
      if (role.name == canonical && role != AppRole.owner) return role;
    }
    return null;
  }

  /// A primary workspace is always shown; an administrator may also use the
  /// agent / entrepreneur interface as permitted by the existing backend
  /// policy. These are UX options, NOT proof of API authorization.
  static List<AppRole> get openable {
    final assigned = primary;
    if (assigned == null) return [];
    return [
      assigned,
      if (assigned == AppRole.admin) AppRole.agent,
      if (assigned == AppRole.admin) AppRole.entrepreneur,
    ];
  }

  static bool canOpen(AppRole role) => openable.contains(role);
  static bool isDemoGrant(AppRole role) => false;

  /// Retained as an explicit failure for any older widget that still invokes
  /// client-side role escalation. Implement verified ownership through an API.
  static void grant(AppRole role) =>
      throw UnsupportedError('Workspace access requires backend authorization.');
  static void revoke(AppRole role) {}
}
