import 'package:jaspr_riverpod/jaspr_riverpod.dart';
// The main barrel does not re-export `Override`; this companion barrel does.
import 'package:jaspr_riverpod/misc.dart' show Override;
// The shared barrel now also exports an ApiPropertyRepository; this app binds
// its own browser-transport implementation from api_property_repository.dart.
import 'package:shared_logic/shared_logic.dart' hide ApiPropertyRepository;

import 'package:sitewise_jaspr_web/features/authentication/data/dev_auth_bypass.dart';

import 'package:sitewise_jaspr_web/features/administration/data/admin_api.dart';
import 'package:sitewise_jaspr_web/features/listing/data/api_property_repository.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/authentication/data/auth_service.dart';
import 'package:sitewise_jaspr_web/core/utils/ui_store.dart';
import 'package:sitewise_jaspr_web/core/utils/web_api_client.dart';
import 'package:sitewise_jaspr_web/features/authentication/application/workspaces.dart';

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
  /// Typed as the concrete adapter because the self-profile save
  /// ([ApiUserRepository.updateOwnProfile]) is a live-backend operation the
  /// demo [UserRepository] cannot serve; reads keep using the interface.
  static final ApiUserRepository userRepo = ApiUserRepository(
    const WebApiClient(),
  );
  static final TourRepositoryImpl tourRepo = TourRepositoryImpl();

  /// Live Explore surface over `/api/v1/explore/*` (the `fyp.rental_properties`
  /// universe, approved + published rows). Consumed for location analysis,
  /// competitor/demand lookups and the numeric-id detail fallback — NOT as the
  /// Explore listing source, because the saved-list and assessment backends
  /// validate against the CATALOGUE id space (`EP-xxxxx`) and a numeric id
  /// would 404 on save/assess. That contract gap keeps the listing on the
  /// catalogue repository; switching it requires a backend change first.
  static final ExploreRepository exploreRepo = ApiExploreRepository(
    const WebApiClient(),
  );

  /// The signed-in account's server-side saved shortlist (catalogue refs).
  /// Replaces the duplicated save/unsave calls the old [AssessmentApi] made —
  /// same endpoints, one shared implementation.
  static final SavedPropertiesRepository savedPropertiesRepo =
      ApiSavedPropertiesRepository(const WebApiClient());

  /// Server-side recommendation search over the property catalogue
  /// (`POST /api/v1/recommendations/search`).
  ///
  /// The backend owns filtering, ordering and cursor pagination, so this app
  /// never sorts or pages the catalogue locally. Ids are CATALOGUE ids — the
  /// same space [savedPropertiesRepo], assessments and the PU model use — so a
  /// ranked card can be saved, assessed and opened without translation.
  static final RecommendationSearchRepository recommendationSearchRepo =
      ApiRecommendationSearchRepository(const WebApiClient());

  /// Direct shortlist comparison — one batch request for up to three ids,
  /// never a second recommendation ranking.
  static final PropertyCompareRepository compareRepo =
      ApiPropertyCompareRepository(const WebApiClient());

  /// The personalised Layer 2/3 pipeline (`/recommendations/generate`,
  /// `/recommendations/me/generated`, `/recommendations/{id}/explanation`).
  /// Ownership always comes from the authenticated session; no user id is
  /// ever sent by this app.
  static final ApiPersonalisedRecommendationRepository
      personalisedRecommendations =
      ApiPersonalisedRecommendationRepository(const WebApiClient());

  /// The assessment Stage 1 selector's data source: the account's own saved
  /// properties, each resolved against the catalogue so the page can show real
  /// listing details. One use case, one saved-list read, one catalogue read
  /// per distinct ref — and never the browser-session mock list.
  static final GetAssessmentSelectableProperties
  assessmentSelectableProperties = GetAssessmentSelectableProperties(
    savedPropertiesRepo,
    propertyRepo,
  );

  /// The unified listing/ownership verification workflow — submitter actions
  /// and the admin review queue both ride this one repository over
  /// `/api/v1/properties/verification/*` and `/api/v1/staff/properties/*`.
  static final PropertyVerificationRepository propertyVerificationRepo =
      ApiPropertyVerificationRepository(const WebApiClient());

  /// Staff/audit/properties reads and writes for the five administrator
  /// operations pages (Ownership, Agents, Campaigns, Activity, Surveys).
  /// Stateless: one shared const instance. Campaigns and Surveys deliberately
  /// do not use it — those two have no backend surface on purpose.
  static const AdminApi adminApi = AdminApi();

  /// Agent listing management over `/api/v1/staff/me/listings` and the
  /// assigned-listing detail/proposal/photo endpoints. Rides the shared
  /// [ApiClient] port like every other live repository, so the same
  /// shared_logic class backs the mobile agent workspace when it exists.
  static final AgentListingRepository agentListingRepo =
      ApiAgentListingRepository(const WebApiClient());

  // --- Application services (shared orchestration) --------------------------
  static final PropertyService properties = PropertyService(propertyRepo);

  /// Ranking and analysis on one service. Analysis goes through the live
  /// intelligence repository (`/explore/analysis`) via the shared adapter —
  /// the catalogue ranking repository itself can only report unavailability,
  /// which used to leave the Explore analysis column permanently empty.
  static final RecommendationService recommendations = RecommendationService(
    IntelligenceBackedRecommendationRepository(
      recommendationRepo,
      intelligenceRepo,
    ),
  );

  /// Explanation + location intelligence live on their own repository in
  /// `shared_logic`; the recommendation repository only serves rankings.
  /// The live repository reads the authenticated backend `/explore/analysis`
  /// endpoint (fyp.rental_properties + research schemas via the cross-universe
  /// `ref` resolution) instead of throwing for every property.
  static final LocationIntelligenceRepository intelligenceRepo =
      ApiLocationIntelligenceRepository(const WebApiClient());
  static final LocationIntelligenceService intelligence =
      LocationIntelligenceService(intelligenceRepo);

  /// Read-only research-ML surface for the Full Analysis page: the selected
  /// artifact's metadata/taxonomy, the P/U association score and the per-
  /// feature coverage diagnostic over `/api/v1/ml/*`. Transport only — the
  /// backend resolves features and runs the saved model; this never scores.
  /// The persisted SHAP explanation and target matching are read through
  /// [AssessmentApi] (assessment-scoped), not here, so this page can never
  /// trigger the POST that computes SHAP or advances a stage.
  static final PuPredictionRepository puPredictions = ApiPuPredictionRepository(
    const WebApiClient(),
  );

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

  /// The account tag the boot cookie was written under ('' = anonymous).
  static String _storedAccount = '';

  /// Seeds the saved/compare sets and recommendation preferences.
  ///
  /// The [cookies] argument is the request's cookie map on the server; the
  /// browser implementation ignores it and reads `document.cookie` instead.
  /// Called once per render, before the router builds — the values are picked
  /// up by the next `ProviderScope` mount.
  static void installUiState([Map<String, String> cookies = const {}]) {
    final stored = UiStore.read(cookies);
    _storedAccount = stored.account;
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
      // Demo Mode has no server-side shortlist to defer to: keep the cookie
      // selection, otherwise every toggle would be persisted as an empty set.
      saved: isSignedIn ? const {} : state.saved,
      compared: state.compared,
      roles: Workspaces.granted,
      account: _currentAccountTag,
    ));
  }

  /// Whether the current visitor holds a verified session.
  ///
  /// Development Demo Mode deliberately reports **false**: the fake profile is
  /// for rendering only (avatar, role label), so every page keeps using its
  /// local/cookie state. Reporting true here would send unauthenticated writes
  /// to endpoints that correctly reject them with 401.
  static bool get isSignedIn =>
      !devAuthBypassEnabled && WebAuth.profile != null;

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
    try {
      if (wantSaved) {
        await savedPropertiesRepo.save(propertyRef);
      } else {
        await savedPropertiesRepo.unsave(propertyRef);
      }
      return null;
    } on Object {
      // The bridge throws without a status code, so the caller gets the same
      // service-failure treatment the AssessmentApi path gave — the shortlist
      // must not move on an unconfirmed change.
      return const AssessmentFailure(
        message: 'The data service could not complete this request.',
      );
    }
  }

  /// Drops the boot compare shortlist when it belongs to a different account.
  ///
  /// The cookie's compare set carries the profile id it was written under:
  ///   * matching tag, or no tag at all (written while anonymous — the same
  ///     person, just not signed in yet) → the selection stands;
  ///   * a tag naming ANOTHER account (expired session, account switch) → the
  ///     seed is cleared so account B never inherits account A's shortlist.
  /// The saved shortlist is untouched: it is server-owned and merged per
  /// account.
  static void applyAccountScope() {
    if (!isSignedIn) return;
    final profileId = _currentAccountTag;
    if (profileId.isEmpty) return;
    if (_storedAccount.isEmpty || _storedAccount == profileId) return;
    uiSeed = uiSeed.copyWith(compared: const <String>{});
  }

  /// The account tag [persistUiState] should stamp: the signed-in profile's
  /// server-verified id (`GET /api/v1/auth/me` returns `user_id`), or '' for
  /// visitors and development Demo Mode.
  static String get _currentAccountTag {
    if (!isSignedIn) return '';
    final profile = WebAuth.profile;
    if (profile == null) return '';
    return '${(profile['user_id'] ?? profile['id'] ?? profile['sub'] ?? '')}';
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
    // Demo Mode has no account shortlist; skip the (unauthenticated) read.
    if (!isSignedIn) return;
    try {
      final refs = await savedPropertiesRepo.savedRefs().timeout(
        const Duration(seconds: 3),
      );
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
  ///
  /// `exploreRepositoryProvider` is deliberately NOT overridden: the
  /// entrepreneur state's listing path must stay on the catalogue id space
  /// (see [exploreRepo]).
  static List<Override> webOverrides() => [
    appInitialStateProvider.overrideWithValue(uiSeed),
    businessPreferencesProvider.overrideWithValue(preferences),
    onPreferencesUpdatedProvider.overrideWithValue(persistPreferences),
    getPropertiesProvider.overrideWithValue(GetProperties(propertyRepo)),
    getRecommendationsProvider.overrideWithValue(
      GetRecommendations(recommendationRepo),
    ),
    // Analysis must come from the live intelligence repository
    // (/explore/analysis), not from the ranking repository whose analysis
    // member can only report unavailability.
    getLocationAnalysisProvider.overrideWithValue(
      GetLocationAnalysis(
        IntelligenceBackedRecommendationRepository(
          recommendationRepo,
          intelligenceRepo,
        ),
      ),
    ),
    savedPropertiesRepositoryProvider.overrideWithValue(savedPropertiesRepo),
    // Recommendations are server-ranked for both apps. Overriding this is what
    // makes the Recommendations page show real, ranked, paginated catalogue
    // rows instead of a locally sorted list.
    recommendationSearchRepositoryProvider.overrideWithValue(
      recommendationSearchRepo,
    ),
    propertyCompareRepositoryProvider.overrideWithValue(compareRepo),
    propertyVerificationRepositoryProvider.overrideWithValue(
      propertyVerificationRepo,
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
