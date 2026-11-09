import '../../domain/entities/commercial_property.dart';
import '../../domain/entities/property_verification.dart';
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

  // -- Unified property-verification review workspace ------------------------
  //
  // Server-backed additions: the queue is one page of the SQL projection
  // (filters compose server-side), so the web listings page renders exactly
  // what the backend filtered/sorted/paginated — never a client-side subset.

  /// One page of the administrator review queue; `null` until first load.
  final VerificationQueuePage? reviewPage;

  /// Filters composing the current [reviewPage] request.
  final VerificationQueueFilters reviewFilters;

  /// Currently open review detail; `null` when nothing (or not yet) loaded.
  final VerificationDetail? reviewDetail;

  /// Label of the review operation in flight (`Approve`, `Reject`…), so the
  /// UI can disable and re-enable the matching controls. `null` = idle.
  final String? busyAction;

  /// Success feedback for the last completed review operation; cleared by
  /// the next operation or `clearReviewNotice`.
  final String? reviewNotice;

  const AdminState({
    this.loading = false,
    this.error,
    this.users = const [],
    this.queue = const [],
    this.listings = const [],
    this.pendingTours = const [],
    this.query = '',
    this.reviewPage,
    this.reviewFilters = const VerificationQueueFilters(),
    this.reviewDetail,
    this.busyAction,
    this.reviewNotice,
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
    VerificationQueuePage? reviewPage,
    VerificationQueueFilters? reviewFilters,
    VerificationDetail? reviewDetail,
    bool clearReviewDetail = false,
    String? busyAction,
    bool clearBusyAction = false,
    String? reviewNotice,
    bool clearReviewNotice = false,
  }) {
    return AdminState(
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      users: users ?? this.users,
      queue: queue ?? this.queue,
      listings: listings ?? this.listings,
      pendingTours: pendingTours ?? this.pendingTours,
      query: query ?? this.query,
      reviewPage: reviewPage ?? this.reviewPage,
      reviewFilters: reviewFilters ?? this.reviewFilters,
      reviewDetail: clearReviewDetail ? null : (reviewDetail ?? this.reviewDetail),
      busyAction: clearBusyAction ? null : (busyAction ?? this.busyAction),
      reviewNotice: clearReviewNotice
          ? null
          : (reviewNotice ?? this.reviewNotice),
    );
  }
}
