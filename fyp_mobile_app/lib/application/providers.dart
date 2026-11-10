import 'dart:async';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' as legacy;

import '../core/config/mobile_config.dart';
import 'services/bootstrap_aware_auth_service.dart';
import 'services/service_locator.dart';
import '../features/assessment/model/repository/assessment_repository.dart';
import '../features/assessment/model/service/assessment_local_service.dart';
import '../features/assessment/model/service/questionnaire_routing_service.dart';
import '../features/assessment/viewmodel/assessment_view_model.dart';

/// Riverpod provides dependencies; ChangeNotifier owns MVVM state.
final assessmentLocalServiceProvider = Provider<AssessmentLocalService>((ref) {
  final service = SqliteAssessmentLocalService();
  ref.onDispose(() {
    unawaited(service.close());
  });
  return service;
});

final assessmentRepositoryProvider = Provider<AssessmentRepository>((ref) {
  return AssessmentRepository(
    localService: ref.watch(assessmentLocalServiceProvider),
  );
});

final questionnaireRoutingServiceProvider =
    Provider<QuestionnaireRoutingService>((ref) {
      return const DemoQuestionnaireRoutingService();
    });

final assessmentViewModelProvider =
    legacy.ChangeNotifierProvider<AssessmentViewModel>((ref) {
      return AssessmentViewModel(
        repository: ref.watch(assessmentRepositoryProvider),
        routingService: ref.watch(questionnaireRoutingServiceProvider),
      );
    });

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
  return [
    authServiceProvider.overrideWithValue(resolvedAuth),
    getPropertiesProvider.overrideWithValue(
      GetProperties(ServiceLocator.propertyRepo),
    ),
    getRecommendationsProvider.overrideWithValue(
      GetRecommendations(ServiceLocator.recommendationRepo),
    ),
    getLocationAnalysisProvider.overrideWithValue(
      GetLocationAnalysis(ServiceLocator.recommendationRepo),
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
    onPreferencesUpdatedProvider.overrideWithValue((value) {
      ServiceLocator.preferences = value;
      // §4: preferences are part of the persistent form state — every change
      // is written through to the user-scoped draft store (best-effort, the
      // repository swallows its own I/O failures).
      ServiceLocator.drafts.savePreferences(value);
    }),
    propertyServiceProvider.overrideWithValue(ServiceLocator.properties),
    tourServiceProvider.overrideWithValue(ServiceLocator.tourService),
    if (MobileConfig.usesLiveApi) ...[
      exploreRepositoryProvider.overrideWithValue(
        ApiExploreRepository(ServiceLocator.apiClient),
      ),
      savedPropertiesRepositoryProvider.overrideWithValue(
        ApiSavedPropertiesRepository(ServiceLocator.apiClient),
      ),
    ],
  ];
}
