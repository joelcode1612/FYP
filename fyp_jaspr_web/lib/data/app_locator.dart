import 'package:jaspr_riverpod/jaspr_riverpod.dart';
// The main barrel does not re-export `Override`; this companion barrel does.
import 'package:jaspr_riverpod/misc.dart' show Override;
import 'package:shared_logic/shared_logic.dart';

import 'admin_api.dart';
import 'api_property_repository.dart';
import 'assessment_api.dart';
import 'auth_service.dart';
import 'ui_store.dart';
import 'web_api_client.dart';
import 'workspaces.dart';

/// Web composition root — the Jaspr counterpart to the Flutter app's
/// `ServiceLocator`.
///
/// Properties come from the authenticated local API. User identity comes from
/// Supabase; unsupported analysis throws an explicit unavailable-data error.
/// A signed-in account's saved list and preferences live on the server; a
/// visitor's selections stay in this browser session.
///
/// All shared state flows through the Riverpod providers from `shared_logic`;
/// [webOverrides] is the one place that points them at the services this
/// locator owns. Pages resolve the services directly (`AppLocator.properties`,
/// `AppLocator.verification`, …) exactly as before — only the state plumbing
/// changed.
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

  /// Staff/audit/properties reads and writes for the five administrator
  /// operations pages (Ownership, Agents, Campaigns, Activity, Surveys).
  /// Stateless: one shared const instance. Campaigns and Surveys deliberately
  /// do not use it — those two have no backend surface on purpose.
  static const AdminApi adminApi = AdminApi();

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

  /// The saved/compare selection the first frame shows, seeded from the
  /// selection cookie. The `appNotifierProvider` override in [webOverrides]
  /// plants it in the container when the scope mounts.
  static AppState uiSeed = const AppState();

  /// Seeds the saved/compare sets and recommendation preferences.
  ///
  /// The [cookies] argument is the request's cookie map on the server; the
  /// browser implementation ignores it and reads `document.cookie` instead.
  /// Called once per render, before the router builds — the values are picked
  /// up by the next `ProviderScope` mount.
  static void installUiState([Map<String, String> cookies = const {}]) {
    final stored = UiStore.read(cookies);
    uiSeed = AppState(saved: stored.saved, compared: stored.compared);
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
  ///
  /// A signed-in account's saved list lives on the server, not in this
  /// browser: writing it here would resurrect removed properties on the next
  /// boot (the boot merge unions the cookie with the account list). Compare
  /// selections stay cookie-persisted for everyone.
  static void persistUiState(AppState state) {
    UiStore.write((
      saved: WebAuth.profile != null ? const {} : state.saved,
      compared: state.compared,
      roles: Workspaces.granted,
    ));
  }

  /// Whether the current visitor holds a verified session.
  static bool get isSignedIn => WebAuth.profile != null;

  /// Persists one saved-shortlist toggle for a signed-in account.
  ///
  /// Returns null only when the server accepted the change — the caller may
  /// then update its local shortlist. A failure returns the reason and the
  /// caller must change nothing, so what the shortlist shows is always what
  /// the account holds. Visitors never reach this: their shortlist is
  /// cookie-persisted locally and needs no round trip.
  static Future<AssessmentFailure?> persistToggleSaved(
    String propertyRef, {
    required bool wantSaved,
  }) async {
    const api = AssessmentApi();
    final result = wantSaved
        ? await api.saveProperty(propertyRef)
        : await api.unsaveProperty(propertyRef);
    return result.ok ? null : result.failure;
  }

  /// Unions the signed-in account's saved properties into [uiSeed], so the
  /// first frame after boot already shows the account's shortlist.
  ///
  /// Called once from the browser entrypoint after the session is resolved.
  /// For a visitor with no session this is a no-op — their shortlist is the
  /// cookie's. A failed or timed-out read keeps the cookie state and reports
  /// nothing: the shortlist still works from the previous boot's selection.
  /// Delisted refs (the server's `unresolved`) are excluded so dead entries
  /// never re-enter the shortlist.
  static Future<void> mergeAccountSaved() async {
    if (WebAuth.profile == null) return;
    try {
      final result = await const AssessmentApi().savedProperties().timeout(
        const Duration(seconds: 3),
      );
      if (!result.ok) return;
      final refs = result.value!.resolvedRefs();
      if (refs.isEmpty) return;
      uiSeed = uiSeed.copyWith(saved: {...uiSeed.saved, ...refs});
    } on Object {
      // Boot must not stall on a dead API; the cookie selection stands.
    }
  }

  /// Compatibility shim; authorization grants are never persisted.
  static Set<String> get grantedRoles => Workspaces.granted;

  /// Points every composition-required provider from `shared_logic` at this
  /// app's implementations. Reading an un-overridden provider fails loudly by
  /// contract, so this list must stay complete.
  static List<Override> webOverrides() => [
    appInitialStateProvider.overrideWithValue(uiSeed),
    businessPreferencesProvider.overrideWithValue(preferences),
    onPreferencesUpdatedProvider.overrideWithValue(persistPreferences),
    getPropertiesProvider.overrideWithValue(GetProperties(propertyRepo)),
    getRecommendationsProvider.overrideWithValue(
      GetRecommendations(recommendationRepo),
    ),
    getLocationAnalysisProvider.overrideWithValue(
      GetLocationAnalysis(recommendationRepo),
    ),
    propertyServiceProvider.overrideWithValue(properties),
    tourServiceProvider.overrideWithValue(tourService),
    verificationServiceProvider.overrideWithValue(verification),
    userRepositoryProvider.overrideWithValue(userRepo),
  ];
}

/// Mirrors every `appNotifierProvider` publish into the selection cookie.
///
/// Riverpod's scope owns the container, so there is no handle to attach a
/// listener to — an observer is the sanctioned hook. Authorization grants are
/// never persisted here.
final class UiPersistObserver extends ProviderObserver {
  const UiPersistObserver();

  @override
  void didUpdateProvider(
    ProviderObserverContext context,
    Object? previousValue,
    Object? newValue,
  ) {
    if (context.provider == appNotifierProvider && newValue is AppState) {
      AppLocator.persistUiState(newValue);
    }
  }
}
