import 'dart:async';

import 'package:shared_logic/shared_logic.dart';

import '../../core/utils/capture_log.dart';
import '../../data/datasources/local/capture_frame_store.dart';
import '../../data/datasources/local/onboarding_local_data_source.dart';
import '../../data/datasources/local/opencv_panorama_stitcher_stub.dart'
    if (dart.library.io) '../../data/datasources/local/opencv_panorama_stitcher.dart';
import '../../data/repositories/onboarding_repository_impl.dart';
import '../../data/repositories/supabase_auth_repository.dart';
import '../state/app_view_model.dart';
import '../state/auth_view_model.dart';
import '../state/entrepreneur_view_model.dart';
import 'ar_capture_service.dart';
import 'assessment_session.dart';
import 'capture_session_store.dart';
import 'panorama_capture_service.dart';
import 'panorama_generation_service.dart';

/// Minimal hand-rolled locator (no third-party DI package in pubspec).
/// Wired once in main(); pages resolve view models and services from here.
///
/// The application-layer services (property, tour, auth, ...) and the shared
/// cubits now live in `shared_logic` so the Jaspr web app can instantiate the
/// same implementations from its own locator. Only platform-bound pieces
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
  /// role. Non-final so tests can inject a fake repository; [useAuth] swaps
  /// the state machine together with it.
  static AuthService auth = AuthService(SupabaseAuthRepository());

  /// The single shared authentication state. Startup, the auth screens, the
  /// route guards and sign-out all read this one instance, so they can never
  /// disagree about who is signed in. It owns the auth rules;
  /// [authViewModel] only adapts its notifications for `provider`.
  static AuthCubit authState = AuthCubit(auth: auth);

  /// The app-wide auth view model exposed by the root `MultiProvider`.
  static AuthViewModel authViewModel = AuthViewModel(cubit: authState);

  /// App-wide UI state (role, preview, saved and compare sets), one instance
  /// for the lifetime of the process. The root provider exposes it *by value*
  /// and never disposes it.
  static final AppViewModel appViewModel = AppViewModel();

  /// Replaces the repository *and* rebuilds [authState] from it. Closing the
  /// previous cubit means a stale restore cannot emit into a new test; the
  /// previous view model is disposed so nothing keeps listening to it.
  static void useAuth(AuthRepository repo) {
    final previous = authState;
    final previousViewModel = authViewModel;
    auth = AuthService(repo);
    authState = AuthCubit(auth: auth);
    authViewModel = AuthViewModel(cubit: authState);
    unawaited(previous.close());
    previousViewModel.dispose();
  }

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

  /// Fresh entrepreneur browsing view model (shared logic).
  ///
  /// The use cases and the initial preferences are constructor-injected — the
  /// view model never touches this locator. The `onPreferencesUpdated` callback
  /// preserves the old viewmodel's write-back to [preferences] so onboarding
  /// and other screens keep seeing updated values app-wide. Each screen owns
  /// the instance it builds and disposes it with its route.
  static EntrepreneurViewModel newEntrepreneurViewModel() =>
      EntrepreneurViewModel(
        EntrepreneurController(
          getProperties: GetProperties(propertyRepo),
          getRecommendations: GetRecommendations(recommendationRepo),
          getLocationAnalysis: GetLocationAnalysis(recommendationRepo),
          preferences: preferences,
          onPreferencesUpdated: (value) => preferences = value,
        ),
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
