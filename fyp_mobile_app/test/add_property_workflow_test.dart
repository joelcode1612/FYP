import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/application/providers.dart';
import 'package:fyp/application/services/service_locator.dart';
import 'package:fyp/core/config/mobile_config.dart';
import 'package:fyp/presentation/mobile/entrepreneur/pages/sitewise_add_property_mobile_page.dart';
import 'package:shared_logic/shared_logic.dart';

/// Real Add Property workflow (converted from the presentation preview).
///
/// Covers the removal of every preview-only artefact, the empty-form rule,
/// and the Save Draft / Submit for Verification server paths against fakes
/// (the backend contract itself is covered by the pytest suite in
/// backend/tests/api/test_owner_listing_drafts.py).
void main() {
  late _FakeOwnerListings fakeListings;
  late _FakeVerification fakeVerification;

  setUp(() {
    MobileConfig.overrideUsesLiveApi = true;
    fakeListings = _FakeOwnerListings();
    fakeVerification = _FakeVerification();
    ServiceLocator.ownerListings = fakeListings;
    ServiceLocator.propertyVerification = fakeVerification;
  });

  tearDown(() {
    MobileConfig.overrideUsesLiveApi = null;
    ServiceLocator.ownerListings =
        ApiOwnerListingRepository(ServiceLocator.apiClient);
    ServiceLocator.propertyVerification =
        ApiPropertyVerificationRepository(ServiceLocator.apiClient);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: sitewiseOverrides(),
        child: const MaterialApp(home: SitewiseAddPropertyMobilePage()),
      ),
    );
    await tester.pump();
  }

  Future<void> tapContinue(WidgetTester tester) async {
    // The step-4 footer relabels the primary button.
    final button = tester.any(find.text('Continue →'))
        ? find.text('Continue →')
        : find.text('Review & finish');
    if (!tester.any(button)) {
      debugPrint('CONTINUE MISSING. visible texts:');
      for (final element in find.byType(Text).evaluate()) {
        final widget = element.widget as Text;
        debugPrint('  T: "${widget.data}"');
      }
      fail('Continue button missing');
    }
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Future<void> completeWizard(WidgetTester tester) async {
    // Step 1 (fields in DOM order: name, rent, area, description).
    await tester.enterText(find.byType(TextField).at(0), 'Test shoplot');
    await tester.enterText(find.byType(TextField).at(1), '7800');
    await tester.enterText(find.byType(TextField).at(2), '1680');
    await tapContinue(tester);
    // Step 2 (address, state, city/district, postcode, latitude, longitude).
    final locationFields = find.byType(TextField);
    expect(locationFields, findsNWidgets(6));
    await tester.enterText(locationFields.at(0), 'Jalan Test 1');
    await tester.enterText(locationFields.at(1), 'Selangor');
    await tester.enterText(locationFields.at(2), 'Subang Jaya');
    await tester.enterText(locationFields.at(3), '47500');
    await tester.enterText(locationFields.at(4), '3.0722');
    await tester.enterText(locationFields.at(5), '101.6065');
    await tapContinue(tester);
    // Step 3 (photos — optional) and step 4 (review).
    await tapContinue(tester);
    await tapContinue(tester);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'loads with no preview labels, no removed sections and no sample data',
    (tester) async {
      await pumpPage(tester);

      // Preview-only artefacts are gone.
      for (final banned in <String>[
        'Presentation preview',
        'UI preview — not saved',
        'Not connected in this preview',
        'Go to My Properties (preview)',
        'Preview the confirmation screen',
        'PROPERTY SNAPSHOT',
        'Your draft at a glance',
        'Built for your SiteWise workflow',
        'Submission confirmation design',
      ]) {
        expect(find.text(banned), findsNothing, reason: banned);
      }

      // No fictional sample property values.
      expect(find.text('SS15 Corner Retail'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is TextField && w.controller?.text == '7800',
        ),
        findsNothing,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is TextField && w.controller?.text == '1680',
        ),
        findsNothing,
      );

      // The five steps are still present.
      expect(find.text('Property details'), findsOneWidget);
      expect(find.text('Step 1 of 5'), findsOneWidget);
    },
  );

  testWidgets(
    'Save Draft persists through the repository once and reports the ID',
    (tester) async {
      await pumpPage(tester);
      await completeWizard(tester);

      // Reaching the confirmation step autosaves.
      expect(fakeListings.createCalls, 1);
      expect(fakeListings.updateCalls, 0);
      expect(fakeListings.savedNames.single, 'Test shoplot');
      expect(find.textContaining('Draft saved to Sitewise (ID 501)'), findsOneWidget);
      expect(find.text('501'), findsWidgets); // real backend-assigned ID

      // Saving again UPDATES the same row — no duplicate.
      await tester.tap(find.text('Save draft'));
      await tester.pumpAndSettle();
      expect(fakeListings.createCalls, 1);
      expect(fakeListings.updateCalls, 1);
    },
  );

  testWidgets(
    'incomplete submission is refused and the backend reason is shown',
    (tester) async {
      await pumpPage(tester);
      await completeWizard(tester);

      // The fake submit mirrors the backend: no ownership evidence -> 409.
      await tester.tap(find.text('Submit for verification'));
      await tester.pumpAndSettle();

      expect(fakeVerification.submitCalls, 1);
      expect(find.textContaining('Upload at least one ownership'), findsOneWidget);
      // The record stays a draft — never silently published or approved.
      expect(fakeListings.createCalls, 1);
      expect(fakeVerification.evidenceUploaded, isFalse);
    },
  );

  testWidgets(
    'submission with evidence moves the record to pending',
    (tester) async {
      fakeVerification.evidenceUploaded = true;
      await pumpPage(tester);
      await completeWizard(tester);
      await tester.tap(find.text('Submit for verification'));
      await tester.pumpAndSettle();

      expect(fakeVerification.submitCalls, 1);
      expect(find.text('Submitted for verification'), findsOneWidget);
      expect(fakeVerification.submitCreatedPending, isTrue);
      // Both lifecycle actions stay available; nothing is auto-published.
      expect(find.text('Go to My Properties'), findsOneWidget);
    },
  );

  testWidgets(
    'first step blocks Continue until the property is named',
    (tester) async {
      await pumpPage(tester);
      await tapContinue(tester); // name empty -> validation blocks
      expect(find.textContaining('Enter a property name'), findsOneWidget);
    },
  );
}

class _FakeOwnerListings implements ApiOwnerListingRepository {
  int createCalls = 0;
  int updateCalls = 0;
  final List<String> savedNames = <String>[];
  bool submitCreatedPending = false;

  @override
  Future<OwnerListing> createDraft(Map<String, dynamic> fields) async {
    createCalls++;
    savedNames.add('${fields['name']}');
    return _record('501', fields);
  }

  @override
  Future<OwnerListing> updateDraft(String id, Map<String, dynamic> fields) async {
    updateCalls++;
    return _record(id, fields);
  }

  OwnerListing _record(String id, Map<String, dynamic> fields) => OwnerListing(
        id: id,
        name: '${fields['name'] ?? ''}',
        verificationStatus: 'draft',
        address: fields['address'] as String?,
        city: fields['city'] as String?,
        state: fields['state'] as String?,
        rentalPrice: fields['rental_price'] as double?,
        sizeSqft: fields['size_sqft'] as double?,
      );

  @override
  Future<OwnerListing> getListing(String id) async =>
      _record(id, {'name': 'Resumed'});

  @override
  Future<List<OwnerListing>> myListings() async => const <OwnerListing>[];

  @override
  Future<OwnerListingPhoto> uploadPhoto({
    required String listingId,
    required String filename,
    required List<int> bytes,
    required String contentType,
    String caption = '',
    bool isPrimary = false,
  }) async =>
      const OwnerListingPhoto(
        id: 1,
        url: 'https://example.test/photo.png',
        caption: '',
        isPrimary: true,
      );

  @override
  Future<List<OwnerListingPhoto>> photos(String listingId) async =>
      const <OwnerListingPhoto>[];

  @override
  Future<void> deletePhoto(String listingId, int photoId) async {}

  @override
  Future<void> setPrimaryPhoto(String listingId, int photoId) async {}
}

class _FakeVerification implements ApiPropertyVerificationRepository {
  int submitCalls = 0;
  bool evidenceUploaded = false;
  bool submitCreatedPending = false;

  @override
  Future<PropertyVerification> submit(String propertyId) async {
    submitCalls++;
    if (!evidenceUploaded) {
      // The exact backend conflict sentence (migrated workflow rule).
      throw const ValidationFailure(
        'Upload at least one ownership or authorisation document '
        'before submitting for verification.',
      );
    }
    submitCreatedPending = true;
    return const PropertyVerification(
      verificationId: 'v-1',
      propertyId: 501,
      listingStatus: PropertyVerificationStatus.pending,
      ownershipStatus: PropertyVerificationStatus.pending,
      submittedBy: 'owner',
      publicationEligible: false,
      version: 1,
    );
  }

  @override
  Future<VerificationStatusView> statusForProperty(String propertyId) async {
    throw UnimplementedError();
  }

  @override
  Future<VerificationDocument> uploadDocument({
    required String propertyId,
    required VerificationDocumentUpload upload,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<List<int>> downloadDocument(String documentId) async =>
      <int>[];

  @override
  Future<VerificationQueuePage> adminQueue(
    VerificationQueueFilters filters,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<VerificationDetail> adminDetail(String propertyId) async {
    throw UnimplementedError();
  }

  @override
  Future<PropertyVerification> startReview(
    String propertyId,
    VerificationDimension dimension,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<PropertyVerification> approve(
    String propertyId,
    VerificationDimension dimension,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<PropertyVerification> reject(
    String propertyId,
    VerificationDimension dimension,
    String reason,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<PropertyVerification> requestInformation(
    String propertyId,
    VerificationDimension dimension,
    String note,
  ) async {
    throw UnimplementedError();
  }
}
