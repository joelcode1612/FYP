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

  const SitewiseUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.status,
    required this.location,
    required this.joinedAt,
  });
}
