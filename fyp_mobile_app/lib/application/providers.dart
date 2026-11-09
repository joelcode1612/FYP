import 'dart:async';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' as legacy;

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
List<Override> sitewiseOverrides({AuthService? auth}) => [
  authServiceProvider.overrideWithValue(auth ?? ServiceLocator.auth),
  getPropertiesProvider.overrideWithValue(
    GetProperties(ServiceLocator.propertyRepo),
  ),
  getRecommendationsProvider.overrideWithValue(
    GetRecommendations(ServiceLocator.recommendationRepo),
  ),
  getLocationAnalysisProvider.overrideWithValue(
    GetLocationAnalysis(ServiceLocator.recommendationRepo),
  ),
  businessPreferencesProvider.overrideWithValue(ServiceLocator.preferences),
  onPreferencesUpdatedProvider.overrideWithValue(
    (value) => ServiceLocator.preferences = value,
  ),
  propertyServiceProvider.overrideWithValue(ServiceLocator.properties),
  tourServiceProvider.overrideWithValue(ServiceLocator.tourService),
];
