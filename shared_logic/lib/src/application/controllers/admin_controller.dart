import '../../domain/entities/app_role.dart';
import '../../domain/entities/commercial_property.dart';
import '../../domain/entities/property_verification.dart';
import '../../domain/entities/user.dart';
import '../../domain/entities/virtual_tour.dart';
import '../../domain/repositories/admin_repositories.dart';
import '../../core/network/api_client.dart';
import '../services/property_service.dart';
import '../services/property_verification_service.dart';
import '../services/tour_service.dart';
import '../services/verification_service.dart';
import '../states/admin_state.dart';
import 'state_controller.dart';

/// Admin dashboard/users/verification flow, without `package:bloc`.
///
/// [AdminCubit] adapts this class to a `Stream`; the Jaspr `AdminViewModel`
/// adapts the same instance to a `ChangeNotifier`. The query and count rules
/// are business behaviour and exist in one place.
///
/// Faithful to the cubit's quirks: `setQuery` only changes view state
/// (filtering is derived at read time), `loadPendingTours` does not toggle the
/// [loading] flag, and a failed load surfaces `error` without clearing
/// previously loaded lists.
class AdminController extends StateController<AdminState> {
  final VerificationService _verification;
  final PropertyService _properties;
  final UserRepository _users;
  final TourService _tours;

  /// Live unified property-verification review workspace. `null` in
  /// demo-data builds, where the workspace is unavailable by design.
  final AdminPropertyReviewService? _reviews;

  AdminController({
    required VerificationService verification,
    required PropertyService properties,
    required UserRepository users,
    required TourService tours,
    AdminPropertyReviewService? reviews,
  }) : _verification = verification,
       _properties = properties,
       _users = users,
       _tours = tours,
       _reviews = reviews,
       super(const AdminState());

  bool get loading => state.loading;

  String? get error => state.error;

  List<SitewiseUser> get users => state.users;

  List<CommercialProperty> get queue => state.queue;

  List<CommercialProperty> get listings => state.listings;

  List<VirtualTour> get pendingTours => state.pendingTours;

  String get query => state.query;

  /// Listings (including queue items) narrowed by [query].
  List<CommercialProperty> get filteredListings {
    if (state.query.isEmpty) return state.listings;
    final q = state.query.toLowerCase();
    return state.listings
        .where(
          (p) =>
              '${p.title} ${p.city} ${p.state} ${p.address} '
                      '${p.propertyType} ${p.ownerId}'
                  .toLowerCase()
                  .contains(q),
        )
        .toList();
  }

  /// Users narrowed by [query].
  List<SitewiseUser> get filteredUsers {
    if (state.query.isEmpty) return state.users;
    final q = state.query.toLowerCase();
    return state.users
        .where(
          (u) => '${u.name} ${u.email} ${u.role.label} ${u.location}'
              .toLowerCase()
              .contains(q),
        )
        .toList();
  }

  /// Listings per verification status — real counts from [listings].
  int countByStatus(VerificationStatus status) =>
      state.listings.where((p) => p.verification == status).length;

  /// Users marked pending — the real onboarding queue size.
  int get pendingUsers => state.users.where((u) => u.status == 'Pending').length;

  Future<void> loadDashboard() async {
    setState(state.copyWith(loading: true, clearError: true));
    try {
      final queue = await _verification.queue();
      final listings = await _properties.listings();
      final users = await _users.getUsers();
      setState(
        state.copyWith(
          queue: queue,
          listings: listings,
          users: users,
          loading: false,
        ),
      );
    } catch (e) {
      setState(state.copyWith(error: e.toString(), loading: false));
    }
  }

  Future<void> loadUsers() async {
    setState(state.copyWith(loading: true, clearError: true));
    try {
      final users = await _users.getUsers();
      setState(state.copyWith(users: users, loading: false));
    } catch (e) {
      setState(state.copyWith(error: e.toString(), loading: false));
    }
  }

  Future<void> loadPendingTours() async {
    try {
      final pendingTours = await _tours.pendingTours();
      setState(state.copyWith(pendingTours: pendingTours));
    } catch (e) {
      setState(state.copyWith(error: e.toString()));
    }
  }

  void setQuery(String value) => setState(state.copyWith(query: value));

  Future<void> approve(String id) async {
    await _verification.approve(id);
    await loadDashboard();
  }

  Future<void> reject(String id, String reason) async {
    await _verification.reject(id, reason);
    await loadDashboard();
  }

  Future<void> approveTour(String id) async {
    await _tours.approveTour(id);
    await loadPendingTours();
  }

  Future<void> rejectTour(String id) async {
    await _tours.rejectTour(id);
    await loadPendingTours();
  }

  // -- Unified property-verification review workspace -----------------------

  VerificationQueuePage? get reviewPage => state.reviewPage;

  VerificationQueueFilters get reviewFilters => state.reviewFilters;

  VerificationDetail? get reviewDetail => state.reviewDetail;

  String? get busyAction => state.busyAction;

  String? get reviewNotice => state.reviewNotice;

  /// Faceted status count for one dimension, straight from the last loaded
  /// server page (`null` = that status has no entry server-side).
  int? reviewCountOf(
    VerificationDimension dimension,
    PropertyVerificationStatus status,
  ) => state.reviewPage?.countOf(dimension, status);

  bool get _reviewUnavailable => _reviews == null;

  void _setReviewError(Object e) =>
      setState(state.copyWith(error: e.toString()));

  // -- Authoritative dashboard totals ---------------------------------------

  VerificationQueuePage? get verificationSummary => state.verificationSummary;

  String? get summaryError => state.summaryError;

  /// Unfiltered verification totals from the same SQL projection the Listings
  /// queue reads. `total` and both dimensions' status facets are separate
  /// server-side aggregates, so they do not depend on the page size — one
  /// row is requested and the numbers still cover every operational property.
  ///
  /// Separate from [reviewPage] on purpose: the Listings page owns that
  /// field's filters and offset, and a dashboard refresh must not reset them.
  /// Failures land in [summaryError] only, so the rest of the dashboard keeps
  /// rendering, and a failed refresh keeps the previous totals visible.
  Future<void> loadVerificationSummary() async {
    if (_reviewUnavailable) {
      setState(
        state.copyWith(summaryError: const DemoModeFailure().toString()),
      );
      return;
    }
    setState(state.copyWith(clearSummaryError: true));
    try {
      final page = await _reviews!.queue(
        const VerificationQueueFilters(limit: 1),
      );
      setState(state.copyWith(verificationSummary: page));
    } catch (e) {
      setState(state.copyWith(summaryError: e.toString()));
    }
  }

  /// Loads (or reloads) one queue page with the current filters. When
  /// [filters] is given it replaces the stored ones and the offset resets.
  Future<void> loadReviewPage({VerificationQueueFilters? filters}) async {
    if (_reviewUnavailable) {
      _setReviewError(const DemoModeFailure());
      return;
    }
    final effective =
        (filters ?? state.reviewFilters).copyWith(
          offset: filters != null ? 0 : state.reviewFilters.offset,
        );
    setState(
      state.copyWith(
        loading: true,
        clearError: true,
        reviewFilters: effective,
      ),
    );
    try {
      final page = await _reviews!.queue(effective);
      setState(state.copyWith(reviewPage: page, loading: false));
    } catch (e) {
      setState(state.copyWith(error: e.toString(), loading: false));
    }
  }

  /// Applies new filters (or pagination) and reloads the queue page.
  Future<void> setReviewFilters(VerificationQueueFilters filters) async {
    if (_reviewUnavailable) {
      _setReviewError(const DemoModeFailure());
      return;
    }
    final previous = state.reviewFilters;
    setState(state.copyWith(reviewFilters: filters, clearError: true));
    try {
      final page = await _reviews!.queue(filters);
      setState(state.copyWith(reviewPage: page));
    } catch (e) {
      // Keep the applied filters visible; the error names the failure.
      setState(state.copyWith(error: e.toString()));
      await loadReviewPage(filters: previous);
    }
  }

  Future<void> loadReviewDetail(String propertyId) async {
    if (_reviewUnavailable) {
      _setReviewError(const DemoModeFailure());
      return;
    }
    setState(state.copyWith(loading: true, clearError: true));
    try {
      final detail = await _reviews!.detail(propertyId);
      setState(state.copyWith(reviewDetail: detail, loading: false));
    } catch (e) {
      setState(
        state.copyWith(
          error: e.toString(),
          loading: false,
          clearReviewDetail: true,
        ),
      );
    }
  }

  void closeReviewDetail() =>
      setState(state.copyWith(clearReviewDetail: true));

  void clearReviewNotice() =>
      setState(state.copyWith(clearReviewNotice: true));

  /// Runs one review operation with busy/notice handling, then refreshes
  /// the queue page (and the open detail, if any).
  Future<void> _runReview(
    String busyLabel,
    Future<Object?> Function(AdminPropertyReviewService reviews) operation,
    String Function(Object? result) noticeFor,
  ) async {
    if (_reviewUnavailable) {
      _setReviewError(const DemoModeFailure());
      return;
    }
    setState(state.copyWith(busyAction: busyLabel, clearError: true));
    try {
      final result = await operation(_reviews!);
      setState(
        state.copyWith(
          clearBusyAction: true,
          reviewNotice: noticeFor(result),
        ),
      );
      await loadReviewPage();
      if (state.reviewDetail != null) {
        await loadReviewDetail('${state.reviewDetail!.property.propertyId}');
      }
    } catch (e) {
      setState(state.copyWith(error: e.toString(), clearBusyAction: true));
    }
  }

  Future<void> startDimensionReview(
    String propertyId,
    VerificationDimension dimension,
  ) => _runReview(
    'Start review',
    (reviews) => reviews.startReview(propertyId, dimension),
    (_) => '${dimension.label}: review started.',
  );

  Future<void> approveDimension(
    String propertyId,
    VerificationDimension dimension,
  ) => _runReview(
    'Approve',
    (reviews) => reviews.approve(propertyId, dimension),
    (_) => '${dimension.label}: approved.',
  );

  Future<void> rejectDimension(
    String propertyId,
    VerificationDimension dimension,
    String reason,
  ) => _runReview(
    'Reject',
    (reviews) => reviews.reject(propertyId, dimension, reason),
    (_) => '${dimension.label}: rejected.',
  );

  Future<void> requestInformation(
    String propertyId,
    VerificationDimension dimension,
    String note,
  ) => _runReview(
    'Request information',
    (reviews) => reviews.requestInformation(propertyId, dimension, note),
    (_) => '${dimension.label}: information requested.',
  );
}
