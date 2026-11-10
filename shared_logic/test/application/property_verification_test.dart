import 'package:riverpod/riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:test/test.dart';

/// Tests for the unified property-verification workflow's shared layer:
/// entity JSON mapping (backend payload shapes), the live repository's
/// path/verb mapping, and the [AdminController] review-workspace behaviour
/// (filters, busy/notice handling, demo-mode unavailability).
void main() {
  group('entity JSON mapping', () {
    test('PropertyVerification reads the backend payload defensively', () {
      final v = PropertyVerification.fromJson({
        'verification_id': 'v-1',
        'property_id': 12,
        'listing_status': 'verified',
        'ownership_status': 'pending',
        'submitted_by': 'u-1',
        'reviewed_by': null,
        'publication_eligible': false,
        'latest_note': null,
        'version': 3,
        'submitted_at': '2026-11-09T01:02:03+00:00',
        'updated_at': '2026-11-09T04:05:06+00:00',
      });
      expect(v.verificationId, 'v-1');
      expect(v.propertyId, 12);
      expect(v.listingStatus, PropertyVerificationStatus.verified);
      expect(v.ownershipStatus, PropertyVerificationStatus.pending);
      expect(v.publicationEligible, isFalse);
      expect(v.version, 3);
      expect(v.statuses.statusOf(VerificationDimension.ownership),
          PropertyVerificationStatus.pending);
    });

    test('unknown status wire names fall back to not_submitted', () {
      final v = PropertyVerification.fromJson({
        'property_id': 1,
        'listing_status': 'mystery',
        'ownership_status': null,
      });
      expect(v.listingStatus, PropertyVerificationStatus.notSubmitted);
      expect(v.ownershipStatus, PropertyVerificationStatus.notSubmitted);
    });

    test('copyWith keeps identity fields and can clear notes', () {
      final v = PropertyVerification.fromJson({
        'verification_id': 'v-1',
        'property_id': 7,
        'listing_status': 'information_requested',
        'ownership_status': 'verified',
        'latest_note': 'send the deed',
        'publication_eligible': true,
      });
      final cleared = v.copyWith(clearLatestNote: true, listingStatus: PropertyVerificationStatus.pending);
      expect(cleared.verificationId, 'v-1');
      expect(cleared.latestNote, isNull);
      expect(cleared.listingStatus, PropertyVerificationStatus.pending);
      expect(cleared.ownershipStatus, PropertyVerificationStatus.verified);
    });

    test('VerificationQueuePage maps items, totals and faceted counts', () {
      final page = VerificationQueuePage.fromJson({
        'items': [
          {
            'property_id': 5,
            'title': 'Corner shoplot',
            'listing_status': 'pending',
            'ownership_status': 'verified',
            'publication_eligible': false,
            'price': 4500.0,
          },
        ],
        'total': 41,
        'offset': 20,
        'limit': 20,
        'counts': {
          'listing': {'pending': 12, 'verified': 3},
          'ownership': {'verified': 9, 'rejected': 1},
        },
      });
      expect(page.items, hasLength(1));
      expect(page.items.single.displayName, 'Corner shoplot');
      expect(page.items.single.monthlyRent, 4500.0);
      expect(page.total, 41);
      expect(page.countOf(VerificationDimension.listing, PropertyVerificationStatus.pending), 12);
      expect(page.countOf(VerificationDimension.ownership, PropertyVerificationStatus.rejected), 1);
      expect(page.countOf(VerificationDimension.listing, PropertyVerificationStatus.underReview), isNull);
    });

    test('VerificationDetail maps owner, documents and history; absence stays null', () {
      final d = VerificationDetail.fromJson({
        'property': {'property_id': 5, 'title': 'Corner shoplot'},
        'owner': null,
        'verification': {'property_id': 5},
        'documents': [
          {
            'document_id': 'doc-1',
            'verification_type': 'ownership',
            'document_type': 'Deed',
            'file_size': 1024,
            'status': 'active',
          },
        ],
        'history': [
          {
            'audit_id': 'a-1',
            'action': 'listing_information_requested',
            'reason': 'photos unclear',
          },
        ],
      });
      expect(d.owner, isNull);
      expect(d.documents.single.verificationType, VerificationDimension.ownership);
      expect(d.documents.single.isActive, isTrue);
      expect(d.history.single.label, 'Listing Information Requested');
      expect(d.history.single.dimension, VerificationDimension.listing);
    });

    test('VerificationQueueFilters.toQuery composes only set fields', () {
      const filters = VerificationQueueFilters(
        q: 'bistro',
        ownershipStatus: PropertyVerificationStatus.verified,
        state: 'Selangor',
        offset: 40,
        limit: 20,
      );
      expect(filters.toQuery(), {
        'q': 'bistro',
        'ownership_status': 'verified',
        'state': 'Selangor',
        'sort': 'submitted_at',
        'order': 'desc',
        'offset': '40',
        'limit': '20',
      });
    });
  });

  group('ApiPropertyVerificationRepository paths', () {
    late _RecordingClient client;
    late ApiPropertyVerificationRepository repo;

    setUp(() {
      client = _RecordingClient();
      repo = ApiPropertyVerificationRepository(client);
    });

    test('submitter status reads the owner-scoped route', () async {
      await repo.statusForProperty('9');
      expect(client.calls.single.$1, '/api/v1/properties/9/verification');
    });

    test('upload sends multipart to the documents route with form fields', () async {
      await repo.uploadDocument(
        propertyId: '9',
        upload: VerificationDocumentUpload(
          dimension: VerificationDimension.ownership,
          documentType: 'Deed',
          filename: 'deed.pdf',
          bytes: [1, 2, 3],
          contentType: 'application/pdf',
        ),
      );
      final call = client.uploads.single;
      expect(call.$1, '/api/v1/properties/9/verification/documents');
      expect(call.$2['verification_type'], 'ownership');
      expect(call.$2['document_type'], 'Deed');
      expect(call.$3, 'file');
      expect(call.$4, 'deed.pdf');
    });

    test('decisions POST the per-dimension staff routes with payloads', () async {
      await repo.startReview('5', VerificationDimension.listing);
      await repo.approve('5', VerificationDimension.ownership);
      await repo.reject('5', VerificationDimension.listing, 'blurry photos');
      await repo.requestInformation('5', VerificationDimension.ownership, 'send deed');

      expect(
        client.calls.map((c) => c.$1),
        [
          '/api/v1/staff/properties/5/verification/start-review',
          '/api/v1/staff/properties/5/verification/approve',
          '/api/v1/staff/properties/5/verification/reject',
          '/api/v1/staff/properties/5/verification/request-information',
        ],
      );
      expect(client.calls[2].$2, {
        'dimension': 'listing',
        'reason': 'blurry photos',
      });
      expect(client.calls[3].$2, {
        'dimension': 'ownership',
        'note': 'send deed',
      });
    });

    test('queue passes the filter query through', () async {
      await repo.adminQueue(
        const VerificationQueueFilters(
          q: 'bistro',
          listingStatus: PropertyVerificationStatus.pending,
          sort: 'title',
          order: 'asc',
          offset: 20,
        ),
      );
      final call = client.calls.single;
      expect(call.$1, '/api/v1/staff/properties/');
      expect(call.$2, {
        'q': 'bistro',
        'listing_status': 'pending',
        'sort': 'title',
        'order': 'asc',
        'offset': '20',
        'limit': '20',
      });
    });
  });

  group('Admin review workspace (controller)', () {
    late ProviderContainer container;
    late _FakeReviewRepo repo;
    late ProviderSubscription<AdminState> _keepAlive;

    setUp(() {
      repo = _FakeReviewRepo();
      container = ProviderContainer(
        overrides: [
          verificationServiceProvider.overrideWithValue(
            VerificationService(_FakeVerificationRepo()),
          ),
          propertyServiceProvider.overrideWithValue(
            PropertyService(_FakePropertyRepo()),
          ),
          userRepositoryProvider.overrideWithValue(_FakeUserRepo()),
          tourServiceProvider.overrideWithValue(TourService(_FakeTourRepo())),
          propertyVerificationRepositoryProvider.overrideWithValue(repo),
        ],
      );
      // Keep the autoDispose admin provider alive across the awaited steps so
      // one controller instance serves the whole test.
      _keepAlive = container.listen<AdminState>(adminNotifierProvider, (_, _) {});
    });

    tearDown(() {
      _keepAlive.close();
      container.dispose();
    });

    AdminNotifier notifier() => container.read(adminNotifierProvider.notifier);
    AdminState state() => container.read(adminNotifierProvider);

    test('loadReviewPage stores the server page and its filters', () async {
      await notifier().loadReviewPage();
      expect(state().reviewPage, isNotNull);
      expect(state().reviewPage!.total, 1);
      expect(state().error, isNull);
    });

    test('setReviewFilters composes server-side and resets nothing else', () async {
      await notifier().loadReviewPage();
      await notifier().setReviewFilters(
        state().reviewFilters.copyWith(
          q: 'bistro',
          ownershipStatus: PropertyVerificationStatus.verified,
        ),
      );
      expect(repo.filters!.q, 'bistro');
      expect(
        repo.filters!.ownershipStatus,
        PropertyVerificationStatus.verified,
      );
      expect(state().reviewFilters.q, 'bistro');
    });

    test('approveDimension sets busy, succeeds with a notice, refreshes', () async {
      await notifier().loadReviewDetail('5');
      await notifier().approveDimension(
        '5',
        VerificationDimension.listing,
      );
      expect(state().busyAction, isNull);
      expect(state().reviewNotice, 'Listing accuracy: approved.');
      expect(state().error, isNull);
      expect(repo.approved.single, 'listing');
      // The page was refreshed once, and the open detail was reloaded.
      expect(repo.queueCalls, 1);
      expect(repo.detailCalls, 2);
    });

    test('a failing decision surfaces the backend message, not a fake success',
        () async {
      repo.failNext = StateError('409 Conflict: decision already recorded.');
      await notifier().approveDimension(
        '5',
        VerificationDimension.ownership,
      );
      expect(state().error, contains('409'));
      expect(state().busyAction, isNull);
      expect(state().reviewNotice, isNull);
    });

    test('demo-mode builds (no repository) fail loudly, never silently', () async {
      final demoContainer = ProviderContainer(
        overrides: [
          verificationServiceProvider.overrideWithValue(
            VerificationService(_FakeVerificationRepo()),
          ),
          propertyServiceProvider.overrideWithValue(
            PropertyService(_FakePropertyRepo()),
          ),
          userRepositoryProvider.overrideWithValue(_FakeUserRepo()),
          tourServiceProvider.overrideWithValue(TourService(_FakeTourRepo())),
        ],
      );
      addTearDown(demoContainer.dispose);
      final demo = demoContainer.read(adminNotifierProvider.notifier);
      await demo.loadReviewPage();
      expect(
        demoContainer.read(adminNotifierProvider).error,
        isNotNull,
      );
    });
  });
}

typedef _Call = (String path, Map<String, dynamic> body);
typedef _Upload = (
  String path,
  Map<String, String> fields,
  String fileField,
  String filename,
);

class _RecordingClient implements ApiClient {
  final List<_Call> calls = [];
  final List<_Upload> uploads = [];
  final List<String> downloads = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    calls.add((path, query ?? const {}));
    return const {};
  }

  @override
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) async {
    calls.add((path, body));
    return const {};
  }

  @override
  Future<Map<String, dynamic>> patch(String path, Map<String, dynamic> body) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> delete(String path) => throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> uploadMultipart(
    String path, {
    required Map<String, String> fields,
    required String fileField,
    required String filename,
    required List<int> bytes,
    required String contentType,
  }) async {
    uploads.add((path, fields, fileField, filename));
    return const {};
  }

  @override
  Future<List<int>> downloadBinary(String path) async {
    downloads.add(path);
    return const [1, 2, 3];
  }
}

class _FakeReviewRepo implements PropertyVerificationRepository {
  VerificationQueueFilters? filters;
  final List<String> approved = [];
  int queueCalls = 0;
  int detailCalls = 0;
  Object? failNext;

  void _maybeFail() {
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
  }

  @override
  Future<VerificationQueuePage> adminQueue(
    VerificationQueueFilters filters,
  ) async {
    _maybeFail();
    queueCalls += 1;
    this.filters = filters;
    return const VerificationQueuePage(
      items: [],
      total: 1,
      offset: 0,
      limit: 20,
    );
  }

  @override
  Future<VerificationDetail> adminDetail(String propertyId) async {
    _maybeFail();
    detailCalls += 1;
    return VerificationDetail(
      property: VerificationProperty(
        propertyId: int.parse(propertyId),
        title: 'Corner shoplot',
      ),
      verification: const PropertyVerification(
        verificationId: 'v',
        propertyId: 5,
        listingStatus: PropertyVerificationStatus.pending,
        ownershipStatus: PropertyVerificationStatus.pending,
        submittedBy: 'u',
        publicationEligible: false,
        version: 1,
      ),
    );
  }

  @override
  Future<PropertyVerification> approve(
    String propertyId,
    VerificationDimension dimension,
  ) async {
    _maybeFail();
    approved.add(dimension.wire);
    return const PropertyVerification(
      verificationId: 'v',
      propertyId: 5,
      listingStatus: PropertyVerificationStatus.verified,
      ownershipStatus: PropertyVerificationStatus.pending,
      submittedBy: 'u',
      publicationEligible: false,
      version: 2,
    );
  }

  @override
  Future<List<int>> downloadDocument(String documentId) =>
      throw UnimplementedError();

  @override
  Future<PropertyVerification> reject(
    String propertyId,
    VerificationDimension dimension,
    String reason,
  ) => throw UnimplementedError();

  @override
  Future<PropertyVerification> requestInformation(
    String propertyId,
    VerificationDimension dimension,
    String note,
  ) => throw UnimplementedError();

  @override
  Future<VerificationStatusView> statusForProperty(String propertyId) =>
      throw UnimplementedError();

  @override
  Future<PropertyVerification> submit(String propertyId) =>
      throw UnimplementedError();

  @override
  Future<VerificationDocument> uploadDocument({
    required String propertyId,
    required VerificationDocumentUpload upload,
  }) => throw UnimplementedError();

  @override
  Future<PropertyVerification> startReview(
    String propertyId,
    VerificationDimension dimension,
  ) => throw UnimplementedError();
}

class _FakeVerificationRepo implements VerificationRepository {
  @override
  Future<List<CommercialProperty>> getPendingQueue() async => [];

  @override
  Future<void> reject(String propertyId, String reason) async {}

  @override
  Future<void> verify(String propertyId) async {}
}

class _FakePropertyRepo implements PropertyRepository {
  @override
  Future<List<CommercialProperty>> getProperties() async => [];

  @override
  Future<CommercialProperty?> getPropertyById(String id) async => null;

  @override
  Future<List<CommercialProperty>> getPropertiesByOwner(String ownerId) async => [];

  @override
  Future<CommercialProperty> createProperty(CommercialProperty property) =>
      throw UnimplementedError();

  @override
  Future<void> updateProperty(CommercialProperty property) async {}

  @override
  Future<void> submitForVerification(String id) async {}

  @override
  Future<void> updateVerification(String id, VerificationStatus status) async {}
}

class _FakeUserRepo implements UserRepository {
  @override
  Future<List<SitewiseUser>> getUsers() async => [];

  @override
  Future<SitewiseUser?> getUserById(String id) async => null;
}

class _FakeTourRepo implements TourRepository {
  @override
  Future<VirtualTour> createDraft({
    required String propertyId,
    required String title,
    required int frameCount,
  }) => throw UnimplementedError();

  @override
  Future<void> deleteTour(String id) async {}

  @override
  Future<VirtualTour?> tourById(String id) async => null;

  @override
  Future<VirtualTour?> getTourByProperty(String propertyId) async => null;

  @override
  Future<List<VirtualTour>> getToursByOwner(String ownerId) async => [];

  @override
  Future<List<VirtualTour>> pendingTours() async => [];

  @override
  Future<void> updateTour(VirtualTour tour) async {}
}
