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

  const SitewiseUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.status,
    required this.location,
    required this.joinedAt,
    this.listingCount,
  });
}
