import 'package:shared_logic/shared_logic.dart';

import '../../core/utils/capture_log.dart';
import '../../data/datasources/local/capture_frame_store.dart';
import '../../data/datasources/local/draft_local_data_source.dart';
import '../../data/datasources/local/onboarding_local_data_source.dart';
import '../../data/datasources/local/opencv_panorama_stitcher_stub.dart'
    if (dart.library.io) '../../data/datasources/local/opencv_panorama_stitcher.dart';
import '../../data/repositories/mobile_api_client.dart';
import '../../data/repositories/onboarding_repository_impl.dart';
import '../../data/repositories/supabase_auth_repository.dart';
import 'ar_capture_service.dart';
import 'assessment_session.dart';
import 'capture_session_store.dart';
import 'draft_repository.dart';
import 'panorama_capture_service.dart';
import 'panorama_generation_service.dart';

/// Construction site for the platform-bound pieces: repositories, capture
/// services and file stores. Pages resolve *services* from here; all state
/// (auth, app-wide UI state, per-role dashboards) flows through Riverpod
/// providers declared in `shared_logic` and overridden at the composition
/// root by `application/providers.dart`, so the locator holds no state
/// singletons and nothing here needs swapping when tests substitute fakes.
///
/// The application-layer services (property, tour, auth, ...) live in
/// `shared_logic` so the Jaspr web app can instantiate the same
/// implementations from its own locator. Only platform-bound pieces
/// (AR, OpenCV, file stores, onboarding persistence) remain in this app.
abstract final class ServiceLocator {
  static final PropertyRepositoryImpl propertyRepo = PropertyRepositoryImpl();
  static final RecommendationRepositoryImpl recommendationRepo =
      RecommendationRepositoryImpl();
  static final TourRepositoryImpl tourRepo = TourRepositoryImpl();

  /// Bearer-aware transport for the shared API repositories. Constructed
  /// lazily-on-read (cheap: one HttpClient total) and only consumed when
  /// `MobileConfig.usesLiveApi` gates the live provider overrides on — a
  /// demo build never touches the network through it.
  static final MobileApiClient apiClient = MobileApiClient();

  /// Owner Add-Property lifecycle (PostgreSQL drafts, photos, My Properties).
  /// Non-final so widget tests can substitute an in-memory fake; a demo build
  /// never calls it because the Add Property page gates on the live config.
  static ApiOwnerListingRepository ownerListings =
      ApiOwnerListingRepository(apiClient);

  /// The existing property-verification transport (evidence upload, submit,
  /// status) — the SAME subsystem the Admin review queue reads.
  static ApiPropertyVerificationRepository propertyVerification =
      ApiPropertyVerificationRepository(apiClient);

  /// Mobile first-run onboarding persistence. Non-final so tests can swap in
  /// [InMemoryOnboardingLocalDataSource].
  static OnboardingRepositoryImpl onboardingRepo = OnboardingRepositoryImpl(
    FileOnboardingLocalDataSource(),
  );

  /// Authentication. Supabase Auth for the credentials, SiteWise for the
  /// role. Non-final so tests can inject a fake repository before
  /// `sitewiseOverrides()` reads it.
  static AuthService auth = AuthService(SupabaseAuthRepository());

  static final PropertyService properties = PropertyService(propertyRepo);
  static final RecommendationService recommendations = RecommendationService(
    recommendationRepo,
  );
  static final CaptureFrameStore frameStore = CaptureFrameStore();
  static final CaptureSessionStore captureSessions = CaptureSessionStore();

  /// Frame cleanup stays wired here: capture files live on the device, so the
  /// shared service takes only the purge hook, not the store itself.
  static final TourService tourService = TourService(
    tourRepo,
    purgeFrames: frameStore.deleteTour,
  );
  static final PanoramaGenerationService panoramas = PanoramaGenerationService(
    OpenCvPanoramaStitcher(),
    tourRepo,
  );

  static BusinessPreferences preferences = DemoData.defaultPreferences;

  /// Production draft store. Kept as the reset target for widget tests, which
  /// swap [drafts] for an in-memory implementation because the file store
  /// needs a platform channel that the test binding does not answer.
  static final ApplicationDraftRepository productionDrafts =
      ApplicationDraftRepository(FileDraftLocalDataSource());

  /// User-scoped draft persistence (preferences, assessment draft, remembered
  /// sign-in address). Non-sensitive data only — never passwords or tokens.
  /// Non-final so tests can inject a fake data source, exactly as they do for
  /// [onboardingRepo] and [auth].
  static ApplicationDraftRepository drafts = productionDrafts;

  /// Single assessment draft. Every mutation is written through to
  /// [drafts] (§4 of the brief), so an interrupted app resumes the flow
  /// instead of discarding typed work. Discard clears both copies.
  static final AssessmentSessionStore assessmentSession =
      AssessmentSessionStore(
        onPersist: (draft) {
          if (draft.property.id.isEmpty) {
            // Discard sentinel — clear the persisted copy.
            drafts.clearAssessment();
          } else {
            drafts.saveAssessment(
              AssessmentDraftData(
                propertyId: draft.property.id,
                concept: draft.concept,
                audience: draft.audience,
                budgetRm: draft.budgetRm,
                saved: draft.saved,
                property: draft.property,
              ),
            );
          }
        },
      );

  /// Upper bound on the boot-time draft read.
  ///
  /// `path_provider` answers through a platform channel. If that channel is
  /// unavailable (widget tests, an unsupported platform, a stuck plugin) the
  /// read can stay pending forever, and the startup gate — which deliberately
  /// holds the splash until drafts are rehydrated — would never navigate.
  /// Drafts are best-effort convenience data, so a stalled read must degrade
  /// to session-only state instead of blocking the app.
  static const Duration draftRestoreTimeout = Duration(seconds: 2);

  /// Boot-time draft restore. Runs once after the locator is first touched:
  /// rehydrates the entrepreneur's saved preferences and any in-progress
  /// assessment draft. Never throws and always completes within
  /// [draftRestoreTimeout] — a corrupt, missing or stalled draft degrades to
  /// the previous session-only behaviour, it must not block startup.
  static Future<void> restoreDrafts() =>
      _restoreDrafts().timeout(draftRestoreTimeout, onTimeout: () {});

  static Future<void> _restoreDrafts() async {
    try {
      final saved = await drafts.loadPreferences();
      if (saved != null && saved.businessType.isNotEmpty) {
        preferences = saved;
      }
    } catch (_) {
      // Keep [DemoData.defaultPreferences]; drafts must never break startup.
    }
    try {
      final data = await drafts.loadAssessment();
      final property = data?.property;
      // Restore only when the persisted snapshot carries the listing — an
      // id without its property would render an empty ghost draft.
      if (data != null && property != null && data.propertyId.isNotEmpty) {
        assessmentSession.restore(
          AssessmentDraft(
            property: property,
            concept: data.concept,
            audience: data.audience,
            budgetRm: data.budgetRm,
            saved: data.saved,
          ),
        );
      }
    } catch (_) {
      // No restored draft — the flow simply starts fresh.
    }
  }

  /// Re-scopes draft storage to the signed-in account (or back to `device`
  /// on sign-out). Called from the auth-state listeners in providers.dart.
  static void scopeDraftsToAccount(String? userId) =>
      drafts.setAccount(userId);

  /// Fresh panorama session over the 26 local capture targets.
  static PanoramaCaptureService newPanoramaCaptureService([
    CaptureConfig config = const CaptureConfig(),
  ]) {
    CaptureLog.enabled = config.enableLogs;
    return PanoramaCaptureService(CaptureTargetDataSource.targets, config);
  }

  /// Fresh AR plugin boundary (stateful per capture screen — never shared).
  static ArCaptureService newArCaptureService() => ArCaptureService();
}
