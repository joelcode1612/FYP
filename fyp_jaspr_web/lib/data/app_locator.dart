import 'package:shared_logic/shared_logic.dart';

import '../state/admin_view_model.dart';
import '../state/app_view_model.dart';
import '../state/entrepreneur_view_model.dart';
import '../state/owner_view_model.dart';
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
  static final UserRepository userRepo = ApiUserRepository(
    const WebApiClient(),
  );
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
  /// every change writes back. The role still comes from the server-side profile.
  static AppViewModel appViewModel = AppViewModel();

  /// Seeds the saved/compare sets and starts mirroring them into the cookie.
  ///
  /// The [cookies] argument is the request's cookie map on the server; the
  /// browser implementation ignores it and reads `document.cookie` instead.
  /// Called once per render, before the router builds.
  static void installUiState([Map<String, String> cookies = const {}]) {
    final stored = UiStore.read(cookies);
    appViewModel = AppViewModel(
      AppState(saved: stored.saved, compared: stored.compared),
    );
    appViewModel.addListener(persistUi);
    // Recommendation preferences survive reloads through their own cookie, so
    // the criteria the user saved are what the ranking actually uses — not a
    // silently-reset default.
    final storedPrefs = UiStore.readPreferences(cookies);
    if (storedPrefs != null) {
      preferences = BusinessPreferences(
        businessType: storedPrefs.businessType,
        propertyType: storedPrefs.propertyType.isEmpty
            ? 'Any'
            : storedPrefs.propertyType,
        minBudgetRm: storedPrefs.minBudgetRm,
        maxBudgetRm: storedPrefs.maxBudgetRm,
        minSizeSqft: storedPrefs.minSizeSqft,
        maxSizeSqft: storedPrefs.maxSizeSqft,
        requirements: storedPrefs.requirements,
        preferredAreas: preferences.preferredAreas,
        seatingModel: preferences.seatingModel,
      );
    }
  }

  /// Persists the entrepreneur's preferences: the session singleton the
  /// ranking reads, plus the reload-surviving cookie mirror.
  static void persistPreferences(BusinessPreferences value) {
    preferences = value;
    UiStore.writePreferences(value);
  }

  /// Persists only UI selections, never authorization grants.
  static void persistUi() {
    UiStore.write((
      saved: appViewModel.saved,
      compared: appViewModel.compared,
      roles: Workspaces.granted,
    ));
  }

  /// Compatibility shim; authorization grants are never persisted.
  static Set<String> get grantedRoles => Workspaces.granted;

  // --- Per-page view models (mirroring the mobile app's per-page lifetimes) --
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

  static OwnerViewModel newOwnerViewModel() => OwnerViewModel(
    OwnerController(
      properties: properties,
      tours: tourService,
      ownerId: WebAuth.profile?['user_id'] as String? ?? '',
    ),
  );

  static AdminViewModel newAdminViewModel() => AdminViewModel(
    AdminController(
      verification: verification,
      properties: properties,
      users: userRepo,
      tours: tourService,
    ),
  );
}
