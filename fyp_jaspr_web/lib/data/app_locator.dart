import 'package:shared_logic/shared_logic.dart';

/// Web composition root — the Jaspr counterpart to the Flutter app's
/// `ServiceLocator`.
///
/// Same rule as the mobile locator: repositories and services are shared
/// implementations from `shared_logic` (demo-data mode), instantiated fresh
/// here so the web runtime owns its own object graph. Nothing Flutter-bound
/// is reachable from this file.
///
/// Session-scoped state ([appCubit]) is a client-side singleton: the static
/// build renders each route from fresh component trees, and the browser keeps
/// this instance alive across client-side navigations, which is exactly when
/// saved/compared selections need to persist.
abstract final class AppLocator {
  // --- Repositories (shared, demo-data implementations) ---------------------
  static final PropertyRepositoryImpl propertyRepo = PropertyRepositoryImpl();
  static final RecommendationRepositoryImpl recommendationRepo =
      RecommendationRepositoryImpl();
  static final VerificationRepositoryImpl verificationRepo =
      VerificationRepositoryImpl(propertyRepo);
  static final UserRepositoryImpl userRepo = UserRepositoryImpl();
  static final TourRepositoryImpl tourRepo = TourRepositoryImpl();

  // --- Application services (shared orchestration) --------------------------
  static final PropertyService properties = PropertyService(propertyRepo);
  static final RecommendationService recommendations = RecommendationService(
    recommendationRepo,
  );

  /// Explanation + location intelligence live on their own repository in
  /// `shared_logic`; the recommendation repository only serves rankings.
  static final LocationIntelligenceRepositoryImpl intelligenceRepo =
      LocationIntelligenceRepositoryImpl();
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
  static BusinessPreferences preferences = DemoData.defaultPreferences;

  // --- Session state ---------------------------------------------------------
  /// Saved/compare selections and role. Client-side singleton.
  static final AppCubit appCubit = AppCubit();

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
    ownerId: DemoData.demoOwnerId,
  );

  static AdminCubit newAdminCubit() => AdminCubit(
    verification: verification,
    properties: properties,
    users: userRepo,
    tours: tourService,
  );
}
