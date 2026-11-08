import 'package:flutter_riverpod/misc.dart';
import 'package:shared_logic/shared_logic.dart';

import 'services/service_locator.dart';

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
