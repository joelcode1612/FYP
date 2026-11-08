import 'package:shared_logic/shared_logic.dart';

import '../../core/utils/capture_log.dart';
import '../../data/datasources/local/capture_frame_store.dart';
import '../../data/datasources/local/onboarding_local_data_source.dart';
import '../../data/datasources/local/opencv_panorama_stitcher_stub.dart'
    if (dart.library.io) '../../data/datasources/local/opencv_panorama_stitcher.dart';
import '../../data/repositories/onboarding_repository_impl.dart';
import '../../data/repositories/supabase_auth_repository.dart';
import 'ar_capture_service.dart';
import 'assessment_session.dart';
import 'capture_session_store.dart';
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

  /// Single in-session assessment draft (app-layer because the flow that
  /// reads and writes it is mobile presentation; nothing persists it).
  static final AssessmentSessionStore assessmentSession =
      AssessmentSessionStore();

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
