import 'package:shared_logic/shared_logic.dart';
import 'package:test/test.dart';

/// Dashboard verification totals (spec 4 + 12).
///
/// The dashboard must read the same authoritative aggregates the Listings
/// queue reads, must not disturb that page's filters, and must keep its own
/// failure isolated from the rest of the dashboard.
void main() {
  VerificationQueuePage page({
    required int total,
    Map<PropertyVerificationStatus, int> listing = const {},
    Map<PropertyVerificationStatus, int> ownership = const {},
  }) => VerificationQueuePage(
    items: const [],
    total: total,
    offset: 0,
    limit: 1,
    counts: {
      VerificationDimension.listing: listing,
      VerificationDimension.ownership: ownership,
    },
  );

  AdminController controller(_QueueRepo repo) => AdminController(
    verification: VerificationService(_Unused()),
    properties: PropertyService(_Unused()),
    users: _Users(),
    tours: TourService(_Unused()),
    reviews: AdminPropertyReviewService(repo),
  );

  test('summary requests one row but keeps the server-side totals', () async {
    final repo = _QueueRepo(
      (_) async => page(
        total: 1187,
        listing: {
          PropertyVerificationStatus.pending: 4,
          PropertyVerificationStatus.underReview: 2,
          PropertyVerificationStatus.verified: 9,
          PropertyVerificationStatus.rejected: 1,
        },
        ownership: {
          PropertyVerificationStatus.pending: 3,
          PropertyVerificationStatus.rejected: 2,
        },
      ),
    );
    final admin = controller(repo);
    await admin.loadVerificationSummary();

    expect(repo.calls.single.limit, 1);
    expect(admin.summaryError, isNull);
    final summary = admin.verificationSummary!;
    expect(summary.total, 1187);
    expect(summary.countOf(VerificationDimension.listing, PropertyVerificationStatus.pending), 4);
    expect(
      summary.countOf(VerificationDimension.ownership, PropertyVerificationStatus.pending),
      3,
    );
    // An absent facet key is a real zero once a page has arrived.
    expect(
      summary.countOf(VerificationDimension.ownership, PropertyVerificationStatus.verified),
      isNull,
    );
  });

  test('a summary failure is isolated from the dashboard error state', () async {
    final repo = _QueueRepo((_) async => throw StateError('queue unavailable'));
    final admin = controller(repo);
    await admin.loadUsers();
    await admin.loadVerificationSummary();

    expect(admin.summaryError, contains('queue unavailable'));
    expect(admin.error, isNull);
    expect(admin.users, hasLength(1));
    expect(admin.verificationSummary, isNull);
  });

  test('a failed refresh keeps the last confirmed totals visible', () async {
    var fail = false;
    final repo = _QueueRepo(
      (_) async => fail ? throw StateError('refresh failed') : page(total: 12),
    );
    final admin = controller(repo);
    await admin.loadVerificationSummary();
    fail = true;
    await admin.loadVerificationSummary();

    expect(admin.verificationSummary!.total, 12);
    expect(admin.summaryError, contains('refresh failed'));
  });

  test('the dashboard summary cannot reset the Listings page filters', () async {
    final repo = _QueueRepo((_) async => page(total: 5));
    final admin = controller(repo);
    await admin.loadReviewPage(
      filters: const VerificationQueueFilters(
        listingStatus: PropertyVerificationStatus.pending,
        limit: 25,
      ),
    );
    final before = admin.reviewFilters;
    await admin.loadVerificationSummary();

    expect(admin.reviewFilters.listingStatus, before.listingStatus);
    expect(admin.reviewFilters.limit, 25);
    expect(admin.reviewPage, isNotNull);
    expect(admin.verificationSummary, isNotNull);
    // The summary asked for its own single row, not the page's 25.
    expect(repo.calls.last.limit, 1);
  });

  test('a build without the review workspace reports unavailability', () async {
    final admin = AdminController(
      verification: VerificationService(_Unused()),
      properties: PropertyService(_Unused()),
      users: _Users(),
      tours: TourService(_Unused()),
    );
    await admin.loadVerificationSummary();
    expect(admin.verificationSummary, isNull);
    expect(admin.summaryError, isNotNull);
    expect(admin.error, isNull);
  });
}

class _QueueRepo implements PropertyVerificationRepository {
  _QueueRepo(this._respond);

  final Future<VerificationQueuePage> Function(VerificationQueueFilters) _respond;
  final List<VerificationQueueFilters> calls = [];

  @override
  Future<VerificationQueuePage> adminQueue(VerificationQueueFilters filters) {
    calls.add(filters);
    return _respond(filters);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not used by these tests');
}

class _Users implements UserRepository {
  @override
  Future<List<SitewiseUser>> getUsers() async => [
    SitewiseUser(
      id: 'u1',
      name: 'Owner',
      email: 'owner@example.test',
      role: AppRole.entrepreneur,
      status: 'Active',
      location: '',
      joinedAt: DateTime.utc(2026, 1, 1),
      listingCount: 2,
    ),
  ];

  @override
  Future<SitewiseUser?> getUserById(String id) async => null;
}

/// Every other port is unused here; touching one is a test bug, not a fallback.
class _Unused implements VerificationRepository, PropertyRepository, TourRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not used by these tests');
}