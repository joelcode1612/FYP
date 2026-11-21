import 'app_role.dart';

/// Domain user. Pure Dart — no Flutter imports.
class SitewiseUser {
  final String id;
  final String name;
  final String email;
  final AppRole role;
  final String status; // e.g. Active, Pending, Suspended
  final String location;
  final DateTime joinedAt;

  /// Operational listings this account owns, counted server-side from
  /// `fyp.rental_properties.owner_user_id`. Null means the count was not
  /// supplied, which must render as unknown rather than as zero.
  final int? listingCount;

  /// Server-verified authentication assurance level (`aal1` / `aal2`), read
  /// from the signed Supabase token by `GET /api/v1/auth/me` — never from a
  /// local flag. Null when the identity came from a source that does not
  /// report it (demo data, cached models); callers must treat null as
  /// "unknown", not as "verified".
  ///
  /// This is a routing input only. FastAPI re-checks `aal2` from the token on
  /// every protected staff operation, so a stale client value can never grant
  /// access to a listing.
  final String? assuranceLevel;

  const SitewiseUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.status,
    required this.location,
    required this.joinedAt,
    this.listingCount,
    this.assuranceLevel,
  });

  /// The session already carries the assurance staff routes require.
  bool get hasStaffAssurance => assuranceLevel == 'aal2';
}
