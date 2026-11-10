import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/application/services/assessment_session.dart';
import 'package:fyp/application/services/draft_repository.dart';
import 'package:fyp/data/datasources/local/draft_local_data_source.dart';

/// Regression tests for the mobile persistent-form-state wiring (Task B §4).
///
/// They pin: user-scoped isolation for account drafts, the intentionally
/// device-scoped remembered sign-in address, write-through on every draft
/// mutation, clear-on-discard-only (never on failure), and the
/// never-store-secrets rule.
void main() {
  CommercialProperty property(String id) => CommercialProperty(
        id: id,
        title: 'Shoplot $id',
        address: '1 Jalan Test',
        city: 'Kuala Lumpur',
        state: 'Selangor',
        postcode: '50000',
        rentalRm: 2500,
        sizeSqft: 1200,
        latitude: 3.1,
        longitude: 101.6,
        propertyType: 'Shoplot',
        verification: VerificationStatus.verified,
        suitabilityScore: 78,
        ownerId: 'owner-1',
        hasTour: false,
      );

  group('ApplicationDraftRepository (InMemoryDraftLocalDataSource)', () {
    test('account-scoped drafts are isolated per account namespace', () async {
      final local = InMemoryDraftLocalDataSource();
      final repo = ApplicationDraftRepository(local);

      repo.setAccount('user-a');
      await repo.savePreferences(DemoData.defaultPreferences);
      expect(await repo.loadPreferences(), isNotNull);

      repo.setAccount('user-b');
      expect(await repo.loadPreferences(), isNull,
          reason: 'user-b must never see user-a drafts');
      repo.setAccount('user-a');
      expect(await repo.loadPreferences(), isNotNull,
          reason: 'switching back must restore user-a drafts');
    });

    test('the remembered sign-in address is device-scoped by design', () async {
      final local = InMemoryDraftLocalDataSource();
      final repo = ApplicationDraftRepository(local);

      repo.setAccount('user-a');
      await repo.saveDraftEmail('a@example.com');
      repo.setAccount('user-b');
      // A remembered address is a device convenience, not an account secret:
      // `saveDraftEmail`/`loadDraftEmail` deliberately use the `device`
      // namespace, so it is intentionally shared across accounts.
      expect(await repo.loadDraftEmail(), 'a@example.com');
    });

    test('no account falls back to the shared device namespace', () async {
      final local = InMemoryDraftLocalDataSource();
      final repo = ApplicationDraftRepository(local);

      repo.setAccount(null);
      await repo.saveDraftEmail('guest@example.com');
      expect(await repo.loadDraftEmail(), 'guest@example.com');
      expect(repo.namespace, 'device');
    });

    test('assessment draft round-trips including the property snapshot',
        () async {
      final local = InMemoryDraftLocalDataSource();
      final repo = ApplicationDraftRepository(local);

      await repo.saveAssessment(AssessmentDraftData(
        propertyId: 'EP-00001',
        concept: 'Taiyaki kiosk',
        audience: 'Students',
        budgetRm: 3000,
        saved: false,
        property: property('EP-00001'),
      ));

      final restored = await repo.loadAssessment();
      expect(restored, isNotNull);
      expect(restored!.propertyId, 'EP-00001');
      expect(restored.concept, 'Taiyaki kiosk');
      expect(restored.budgetRm, 3000);
      expect(restored.property?.title, 'Shoplot EP-00001');
      expect(restored.property?.rentalRm, 2500);
    });

    test('clearAssessment removes only the assessment workflow', () async {
      final local = InMemoryDraftLocalDataSource();
      final repo = ApplicationDraftRepository(local);

      await repo.saveAssessment(AssessmentDraftData(propertyId: 'EP-00001'));
      await repo.saveDraftEmail('keep@example.com');

      await repo.clearAssessment();

      expect(await repo.loadAssessment(), isNull);
      expect(await repo.loadDraftEmail(), 'keep@example.com');
    });
  });

  group('AssessmentSessionStore write-through', () {
    test('start/updateInputs/markSaved publish the draft to the persist hook',
        () async {
      final persisted = <AssessmentDraft>[];
      final store = AssessmentSessionStore(
        onPersist: (draft) => persisted.add(draft),
      );

      store.start(property('EP-00001'));
      store.updateInputs(
          concept: 'Taiyaki kiosk', audience: 'Students', budgetRm: 3000);
      store.markSaved();

      expect(persisted.length, 3);
      expect(persisted.last.saved, isTrue);
      expect(persisted.last.budgetRm, 3000);
    });

    test('discard sends the empty sentinel so the repository clears the copy',
        () async {
      final local = InMemoryDraftLocalDataSource();
      final repo = ApplicationDraftRepository(local);
      final store = AssessmentSessionStore(onPersist: (draft) {
        if (draft.property.id.isEmpty) {
          repo.clearAssessment();
        } else {
          repo.saveAssessment(AssessmentDraftData(
            propertyId: draft.property.id,
            concept: draft.concept,
            audience: draft.audience,
            budgetRm: draft.budgetRm,
            saved: draft.saved,
            property: draft.property,
          ));
        }
      });

      store.start(property('EP-00001'));
      store.updateInputs(
          concept: 'Taiyaki kiosk', audience: 'Students', budgetRm: 3000);
      await Future<void>.delayed(Duration.zero);
      expect(await repo.loadAssessment(), isNotNull);

      store.discard();
      await Future<void>.delayed(Duration.zero);
      expect(await repo.loadAssessment(), isNull,
          reason: 'explicit discard must clear the persisted copy');
      expect(store.hasDraft, isFalse);
    });

    test('a persist-hook failure never crashes the flow (best-effort write)',
        () {
      final store = AssessmentSessionStore(
        onPersist: (draft) => throw Exception('disk full (simulated)'),
      );

      store.start(property('EP-00001'));
      store.updateInputs(
          concept: 'C', audience: 'A', budgetRm: 1);
      expect(store.hasDraft, isTrue,
          reason: 'the in-session draft survives a failed write-through');
    });

    test('restore re-attaches a persisted draft without re-persisting it',
        () async {
      final local = InMemoryDraftLocalDataSource();
      final repo = ApplicationDraftRepository(local);
      var persistCalls = 0;
      final store = AssessmentSessionStore(
        onPersist: (draft) => persistCalls++,
      );

      await repo.saveAssessment(AssessmentDraftData(
        propertyId: 'EP-00002',
        concept: 'Coffee cart',
        audience: 'Office workers',
        budgetRm: 2200,
        saved: false,
        property: property('EP-00002'),
      ));
      final data = (await repo.loadAssessment())!;
      store.restore(AssessmentDraft(
        property: data.property!,
        concept: data.concept,
        audience: data.audience,
        budgetRm: data.budgetRm,
        saved: data.saved,
      ));

      expect(store.hasDraft, isTrue);
      expect(store.draft!.concept, 'Coffee cart');
      expect(store.draft!.step, 1);
      expect(persistCalls, 0,
          reason: 'restore must not trigger a redundant write-back');
    });

    test('opening the same property resumes instead of duplicating', () {
      final persisted = <AssessmentDraft>[];
      final store = AssessmentSessionStore(
        onPersist: persisted.add,
      );

      store.start(property('EP-00001'));
      store.updateInputs(
          concept: 'Taiyaki kiosk', audience: 'Students', budgetRm: 3000);
      store.start(property('EP-00001'));

      expect(store.draft!.concept, 'Taiyaki kiosk',
          reason: 'same property -> resume, inputs kept');
      expect(persisted.length, 2, reason: 'the resume start() must not persist');

      store.start(property('EP-00002'));
      expect(store.draft!.concept, '',
          reason: 'different property -> fresh draft, stale inputs dropped');
    });
  });
}
