import 'package:shared_logic/shared_logic.dart';

import '../../core/utils/capture_log.dart';
import '../../data/datasources/local/capture_frame_store.dart';
import '../../data/datasources/local/onboarding_local_data_source.dart';
import '../../data/datasources/local/opencv_panorama_stitcher_stub.dart'

    if (dart.library.io) '../../data/datasources/local/opencv_panorama_stitcher.dart';
import '../../data/repositories/auth_repository_impl.dart';
import '../../data/repositories/onboarding_repository_impl.dart';
import 'ar_capture_service.dart';
import 'capture_session_store.dart';
import 'panorama_capture_service.dart';
import 'panorama_generation_service.dart';

/// Minimal hand-rolled locator (no third-party DI package in pubspec).
/// Wired once in main(); pages resolve cubits/services from here.
///
/// The application-layer services (property, tour, auth, ...) and the shared
/// cubits now live in `shared_logic` so the Jaspr web app can instantiate the
/// same implementations from its own locator. Only platform-bound pieces
/// (AR, OpenCV, file stores, onboarding persistence) remain in this app.
abstract final class ServiceLocator {
  static final PropertyRepositoryImpl propertyRepo = PropertyRepositoryImpl();
  static final RecommendationRepositoryImpl recommendationRepo =
      RecommendationRepositoryImpl();
  static final VerificationRepositoryImpl verificationRepo =
      VerificationRepositoryImpl(propertyRepo);
  static final UserRepositoryImpl userRepo = UserRepositoryImpl();
  static final TourRepositoryImpl tourRepo = TourRepositoryImpl();

  /// Mobile first-run onboarding persistence. Non-final so tests can swap in
  /// [InMemoryOnboardingLocalDataSource].
  static OnboardingRepositoryImpl onboardingRepo = OnboardingRepositoryImpl(
    FileOnboardingLocalDataSource(),
  );

  /// Authentication (demo/local today; Supabase-ready contract). Non-final so
  /// tests can inject a fake repository.
  static AuthService auth = AuthService(AuthRepositoryImpl());

  static final PropertyService properties = PropertyService(propertyRepo);
  static final RecommendationService recommendations = RecommendationService(
    recommendationRepo,
  );
  static final VerificationService verification = VerificationService(
    verificationRepo,
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

  /// Fresh entrepreneur browsing cubit (shared logic).
  ///
  /// The use cases and the initial preferences are constructor-injected — the
  /// cubit never touches this locator. The `onPreferencesUpdated` callback
  /// preserves the old viewmodel's write-back to [preferences] so onboarding
  /// and other screens keep seeing updated values app-wide.
  static EntrepreneurCubit newEntrepreneurCubit() => EntrepreneurCubit(
    getProperties: GetProperties(propertyRepo),
    getRecommendations: GetRecommendations(recommendationRepo),
    getLocationAnalysis: GetLocationAnalysis(recommendationRepo),
    preferences: preferences,
    onPreferencesUpdated: (value) => preferences = value,
  );

  /// Fresh owner cubit (shared logic) scoped to the demo owner.
  static OwnerCubit newOwnerCubit() =>
      OwnerCubit(properties: properties, tours: tourService, ownerId: DemoData.demoOwnerId);

  /// Fresh admin cubit (shared logic).
  static AdminCubit newAdminCubit() => AdminCubit(
    verification: verification,
    properties: properties,
    users: userRepo,
    tours: tourService,
  );

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
