import '../../domain/entities/commercial_property.dart';
import '../../domain/entities/user.dart';
import '../../domain/entities/virtual_tour.dart';

/// State for the admin flow (dashboard, users, verification, listings).
///
/// Replaces the mutable public fields on the Flutter `AdminViewModel`
/// (`fyp_mobile_app/lib/application/viewmodels/admin_viewmodel.dart`).
class AdminState {
  final bool loading;
  final String? error;
  final List<SitewiseUser> users;

  /// Properties awaiting verification.
  final List<CommercialProperty> queue;
  final List<CommercialProperty> listings;

  /// Tours awaiting verification.
  final List<VirtualTour> pendingTours;

  /// Free-text admin query, matched across listings and users. Drives Home's
  /// unified search entry point.
  final String query;

  const AdminState({
    this.loading = false,
    this.error,
    this.users = const [],
    this.queue = const [],
    this.listings = const [],
    this.pendingTours = const [],
    this.query = '',
  });

  AdminState copyWith({
    bool? loading,
    String? error,
    bool clearError = false,
    List<SitewiseUser>? users,
    List<CommercialProperty>? queue,
    List<CommercialProperty>? listings,
    List<VirtualTour>? pendingTours,
    String? query,
  }) {
    return AdminState(
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      users: users ?? this.users,
      queue: queue ?? this.queue,
      listings: listings ?? this.listings,
      pendingTours: pendingTours ?? this.pendingTours,
      query: query ?? this.query,
    );
  }
}
