import 'package:shared_logic/shared_logic.dart';
import 'api_property_repository.dart';
import 'auth_service.dart';

/// Web composition root — the Jaspr counterpart to the Flutter app's
/// `ServiceLocator`.
///
/// Properties come from the authenticated local API. User identity comes from
/// Supabase; unsupported analysis throws an explicit unavailable-data error.
/// Saved/compare selections and preferences remain local to this browser session.
abstract final class AppLocator {
  // --- Repositories (shared, demo-data implementations) ---------------------
  static final PropertyRepository propertyRepo = ApiPropertyRepository();
  static final RecommendationRepository recommendationRepo =
      DatasetRecommendationRepository(propertyRepo);
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
    ownerId: WebAuth.profile?['user_id'] as String? ?? '',
  );

  static AdminCubit newAdminCubit() => AdminCubit(
    verification: verification,
    properties: properties,
    users: userRepo,
    tours: tourService,
  );
}
