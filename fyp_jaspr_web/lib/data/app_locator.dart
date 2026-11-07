import 'package:shared_logic/shared_logic.dart';
import 'api_property_repository.dart';
import 'auth_service.dart';
import 'ui_store.dart';
import 'web_api_client.dart';
import 'workspaces.dart';

/// Web composition root — the Jaspr counterpart to the Flutter app's
/// `ServiceLocator`.
///
/// Properties come from the authenticated local API. User identity comes from
/// Supabase; unsupported analysis throws an explicit unavailable-data error.
/// Saved/compare selections and preferences remain local to this browser session.
abstract final class AppLocator {
  // --- Repositories ---------------------------------------------------------
  // Properties and users come from the authenticated FastAPI backend (bearer
  // token via WebAuth); verification wraps the live property repo. Tours remain
  // demo-data — capture frames exist only on mobile, so there is no web source.
  static final PropertyRepository propertyRepo = ApiPropertyRepository();
  static final RecommendationRepository recommendationRepo =
      DatasetRecommendationRepository(propertyRepo);
  static final VerificationRepositoryImpl verificationRepo =
      VerificationRepositoryImpl(propertyRepo);
  static final UserRepository userRepo = ApiUserRepository(const WebApiClient());
  static final TourRepositoryImpl tourRepo = TourRepositoryImpl();

  // --- Application services (shared orchestration) --------------------------
  static final PropertyService properties = PropertyService(propertyRepo);
  static final RecommendationService recommendations = RecommendationService(
    recommendationRepo,
  );

  /// Explanation + location intelligence live on their own repository in
  /// `shared_logic`; the recommendation repository only serves rankings.
  static final LocationIntelligenceRepository intelligenceRepo =
      UnavailableIntelligenceRepository();
  static final LocationIntelligenceService intelligence =
      LocationIntelligenceService(intelligenceRepo);

  static final VerificationService verification = VerificationService(
    verificationRepo,
  );

  /// No frame purge: capture files exist only on mobile devices. Tour deletion
  /// drops the repository record alone, which is the web-correct behaviour.
  static final TourService tourService = TourService(tourRepo);

  /// App-wide preferences (the mobile app's onboarding writes these too; the
  /// web app only reads/edits them in Preferences).
  static BusinessPreferences preferences = const BusinessPreferences(
    businessType: '',
    maxBudgetRm: 25000,
    minSizeSqft: 0,
    maxSizeSqft: 6000,
    propertyType: 'Any',
  );

  // --- Session state ---------------------------------------------------------
  /// Saved/compare selections and role. One per document.
  ///
  /// Each navigation is a fresh document now, so this singleton is rebuilt per
  /// request/page load; [installUiState] seeds it from the selection cookie and
  /// every emit writes back. The role still comes from the server-side profile.
  static AppCubit appCubit = AppCubit();

  /// Seeds the saved/compare sets and starts mirroring them into the cookie.
  ///
  /// The [cookies] argument is the request's cookie map on the server; the
  /// browser implementation ignores it and reads `document.cookie` instead.
  /// Called once per render, before the router builds.
  static void installUiState([Map<String, String> cookies = const {}]) {
    final stored = UiStore.read(cookies);
    appCubit = AppCubit(
      AppState(saved: stored.saved, compared: stored.compared),
    );
    Workspaces.seed(stored.roles);
    appCubit.stream.listen((_) => persistUi());
  }

  /// Writes the current selections and demo role grants back to the cookie.
  static void persistUi() {
    UiStore.write((
      saved: appCubit.state.saved,
      compared: appCubit.state.compared,
      roles: Workspaces.granted,
    ));
  }
  /// Demo role grants as role names — the shape the cookie stores.
  static Set<String> get grantedRoles => Workspaces.granted;

  // --- Per-page cubits (mirroring the mobile app's per-page lifetimes) -------
  static EntrepreneurCubit newEntrepreneurCubit() => EntrepreneurCubit(
    getProperties: GetProperties(propertyRepo),
    getRecommendations: GetRecommendations(recommendationRepo),
    getLocationAnalysis: GetLocationAnalysis(recommendationRepo),
    preferences: preferences,
    onPreferencesUpdated: (value) => preferences = value,
  );

  static OwnerCubit newOwnerCubit() => OwnerCubit(
    properties: properties,
    tours: tourService,
    ownerId: WebAuth.profile?['user_id'] as String? ?? '',
  );

  static AdminCubit newAdminCubit() => AdminCubit(
    verification: verification,
    properties: properties,
    users: userRepo,
    tours: tourService,
  );
}
