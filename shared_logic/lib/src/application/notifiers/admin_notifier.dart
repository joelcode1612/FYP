import 'package:riverpod/riverpod.dart';

import '../../domain/entities/commercial_property.dart';
import '../../domain/entities/property_verification.dart';
import '../../domain/entities/user.dart';
import '../../domain/entities/virtual_tour.dart';
import '../controllers/admin_controller.dart';
import '../states/admin_state.dart';
import 'providers.dart';

/// Notifier facade over [AdminController].
///
/// Every transition lives in the controller; this class only mirrors it into
/// the provider, which is why the query/count rules cannot drift between the
/// mobile and web apps.
class AdminNotifier extends Notifier<AdminState> {
  late AdminController _controller;

  @override
  AdminState build() {
    _controller = AdminController(
      verification: ref.watch(verificationServiceProvider),
      properties: ref.watch(propertyServiceProvider),
      users: ref.watch(userRepositoryProvider),
      tours: ref.watch(tourServiceProvider),
      reviews: ref.watch(adminPropertyReviewServiceProvider),
    );
    _controller.addListener(_publish);
    ref.onDispose(() {
      _controller.removeListener(_publish);
      _controller.dispose();
    });
    return _controller.state;
  }

  // Read-only projections of the current state, mirroring the field names the
  // old viewmodels exposed, so existing UI code reads the same (`loading`,
  // `queue`, ...) while all writes go through methods that publish a new
  // immutable [AdminState].
  bool get loading => state.loading;

  String? get error => state.error;

  List<SitewiseUser> get users => state.users;

  List<CommercialProperty> get queue => state.queue;

  List<CommercialProperty> get listings => state.listings;

  List<VirtualTour> get pendingTours => state.pendingTours;

  String get query => state.query;

  /// Listings (including queue items) narrowed by [query].
  List<CommercialProperty> get filteredListings => _controller.filteredListings;

  /// Users narrowed by [query].
  List<SitewiseUser> get filteredUsers => _controller.filteredUsers;

  /// Listings per verification status — real counts from [listings].
  int countByStatus(VerificationStatus status) =>
      _controller.countByStatus(status);

  /// Users marked pending — the real onboarding queue size.
  int get pendingUsers => _controller.pendingUsers;

  Future<void> loadDashboard() => _controller.loadDashboard();

  Future<void> loadUsers() => _controller.loadUsers();

  Future<void> loadPendingTours() => _controller.loadPendingTours();

  void setQuery(String value) => _controller.setQuery(value);

  Future<void> approve(String id) => _controller.approve(id);

  Future<void> reject(String id, String reason) => _controller.reject(id, reason);

  Future<void> approveTour(String id) => _controller.approveTour(id);

  Future<void> rejectTour(String id) => _controller.rejectTour(id);

  // -- Unified property-verification review workspace -----------------------

  VerificationQueuePage? get reviewPage => state.reviewPage;

  VerificationQueueFilters get reviewFilters => state.reviewFilters;

  VerificationDetail? get reviewDetail => state.reviewDetail;

  String? get busyAction => state.busyAction;

  String? get reviewNotice => state.reviewNotice;

  /// Faceted server-side count for one dimension/status pair.
  int? reviewCountOf(
    VerificationDimension dimension,
    PropertyVerificationStatus status,
  ) => _controller.reviewCountOf(dimension, status);

  // -- Authoritative dashboard totals ---------------------------------------

  VerificationQueuePage? get verificationSummary =>
      _controller.verificationSummary;

  String? get summaryError => _controller.summaryError;

  Future<void> loadVerificationSummary() =>
      _controller.loadVerificationSummary();

  Future<void> loadReviewPage({VerificationQueueFilters? filters}) =>
      _controller.loadReviewPage(filters: filters);

  Future<void> setReviewFilters(VerificationQueueFilters filters) =>
      _controller.setReviewFilters(filters);

  Future<void> loadReviewDetail(String propertyId) =>
      _controller.loadReviewDetail(propertyId);

  void closeReviewDetail() => _controller.closeReviewDetail();

  void clearReviewNotice() => _controller.clearReviewNotice();

  Future<void> startDimensionReview(
    String propertyId,
    VerificationDimension dimension,
  ) => _controller.startDimensionReview(propertyId, dimension);

  Future<void> approveDimension(
    String propertyId,
    VerificationDimension dimension,
  ) => _controller.approveDimension(propertyId, dimension);

  Future<void> rejectDimension(
    String propertyId,
    VerificationDimension dimension,
    String reason,
  ) => _controller.rejectDimension(propertyId, dimension, reason);

  Future<void> requestInformation(
    String propertyId,
    VerificationDimension dimension,
    String note,
  ) => _controller.requestInformation(propertyId, dimension, note);

  void _publish(AdminState next) => state = next;
}

/// Page-scoped: destroyed once no screen is watching it anymore.
final adminNotifierProvider =
    NotifierProvider.autoDispose<AdminNotifier, AdminState>(AdminNotifier.new);
