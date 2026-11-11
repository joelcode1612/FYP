import 'package:flutter_riverpod/misc.dart';
import 'package:shared_logic/shared_logic.dart';

import '../core/config/mobile_config.dart';
import 'services/bootstrap_aware_auth_service.dart';
import 'services/service_locator.dart';

/// Composition-root overrides for the shared Riverpod providers.
///
/// The shared notifiers consume their dependencies through providers declared
/// in `shared_logic`; only this app knows which implementations to wire, so
/// every one of them is overridden here. `main.dart` installs the list in the
/// root `ProviderScope`; tests spread it and replace individual entries (the
/// auth service is the usual one) with fakes.
///
/// Live-mode note: the property/recommendation screens stay on the demo
/// repositories ([AppConfig.usesDemoData] in `shared_logic` governs that
/// flag). The Explore/saved-list providers below gain real backend
/// implementations only when [MobileConfig.usesLiveApi] is true (a valid
/// build-time API base URL + credentials), so flipping to live mode is a
/// build-define change, not a code change. `usesLiveApi` must NOT depend on
/// the runtime Supabase init flag: overrides are built before that async
/// bootstrap completes.
///
/// When no [auth] is supplied (production), the real service is wrapped so
/// no session read can race the deferred Supabase initialization. Tests keep
/// injecting fakes directly, so they never touch the bootstrap at all.
List<Override> sitewiseOverrides({AuthService? auth}) {
  final resolvedAuth =
      auth ?? BootstrapAwareAuthService(ServiceLocator.auth.repo);

  // Riverpod asserts ("Tried to override a provider twice within the same
  // container") when one provider appears twice in this list, so every
  // provider must have EXACTLY ONE override here. The live build therefore
  // switches the repository behind [GetLocationAnalysis] instead of adding a
  // second override in the live-only block below: `/explore/analysis` resolves
  // BOTH id universes (numeric `fyp.rental_properties` ids and
  // `EP-xxxxx`/`MD-xxxxx` catalogue refs), so "Assess this property" works
  // for live listings. Ranking stays on the demo recommendation repository —
  // the recommendation module is out of scope for this integration.
  final RecommendationRepository analysisRepository = MobileConfig.usesLiveApi
      ? IntelligenceBackedRecommendationRepository(
          ServiceLocator.recommendationRepo,
          ApiLocationIntelligenceRepository(ServiceLocator.apiClient),
        )
      : ServiceLocator.recommendationRepo;

  // Live builds read the real catalogue. Demo builds keep the bundled
  // fixtures. The swap happens BEFORE the override list is built so
  // `GetProperties` and every `ServiceLocator.properties` call see the same
  // repository.
  if (MobileConfig.usesLiveApi &&
      ServiceLocator.propertyRepo is! ApiPropertyRepository) {
    ServiceLocator.propertyRepo = ApiPropertyRepository(ServiceLocator.apiClient);
  }

  // The report and assessment-summary screens resolve their analysis through
  // `ServiceLocator.recommendations`, not through the provider above. Point the
  // locator at the SAME repository so a live build never renders the demo
  // `analysisFor` fallback (which returns the first demo property's figures for
  // any id it does not recognise).
  ServiceLocator.analysisRepo = analysisRepository;

  return [
    authServiceProvider.overrideWithValue(resolvedAuth),
    getPropertiesProvider.overrideWithValue(
      GetProperties(ServiceLocator.propertyRepo),
    ),
    getRecommendationsProvider.overrideWithValue(
      GetRecommendations(ServiceLocator.recommendationRepo),
    ),
    getLocationAnalysisProvider.overrideWithValue(
      GetLocationAnalysis(analysisRepository),
    ),
    // Lazy read, not `overrideWithValue`: [ServiceLocator.preferences] is
    // rehydrated from the draft store AFTER the override list is built (during
    // startup, once the account namespace is known). A captured value would
    // freeze the pre-restore default forever; this closure is evaluated when
    // the provider is first read, which is always after the gate has restored
    // the drafts.
    businessPreferencesProvider.overrideWith(
      (ref) => ServiceLocator.preferences,
    ),
    // `overrideWith` (not `overrideWithValue`) so the handler can invalidate
    // `businessPreferencesProvider`. Without that invalidation the provider
    // closure is never re-evaluated, so every screen watching it — Profile,
    // the recommendations criteria summary — kept rendering the pre-edit
    // values until the app restarted.
    onPreferencesUpdatedProvider.overrideWith(
      (ref) => (value) {
        ServiceLocator.preferences = value;
        ref.invalidate(businessPreferencesProvider);
        // §4: preferences are part of the persistent form state — every change
        // is written through to the user-scoped draft store (best-effort, the
        // repository swallows its own I/O failures).
        ServiceLocator.drafts.savePreferences(value);
      },
    ),
    propertyServiceProvider.overrideWithValue(ServiceLocator.properties),
    tourServiceProvider.overrideWithValue(ServiceLocator.tourService),
    if (MobileConfig.usesLiveApi) ...[
      exploreRepositoryProvider.overrideWithValue(
        ApiExploreRepository(ServiceLocator.apiClient),
      ),
      savedPropertiesRepositoryProvider.overrideWithValue(
        ApiSavedPropertiesRepository(ServiceLocator.apiClient),
      ),
      // Server-ranked recommendations (`POST /api/v1/recommendations/search`).
      // Without this override the Recommendations page reports the feature as
      // unavailable rather than sorting a local list — the server owns
      // filtering, ordering and paging for both platforms.
      recommendationSearchRepositoryProvider.overrideWithValue(
        ApiRecommendationSearchRepository(ServiceLocator.apiClient),
      ),
      // [getLocationAnalysisProvider] is deliberately absent here: its single
      // override above already selected the live-backed [analysisRepository].
      // Re-adding it would trip Riverpod's duplicate-override assertion and
      // red-screen the app before the first frame.
    ],
  ];
}
