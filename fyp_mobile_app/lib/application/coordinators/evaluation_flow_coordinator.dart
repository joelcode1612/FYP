// Centralised entrepreneur evaluation-flow navigation (§15–§24).
// Pages call these helpers instead of hardcoding each other's routes.

abstract final class EvaluationFlowCoordinator {
  static String detailRoute(String id) => '/entrepreneur/property/$id';
  static String locationRoute(String id) =>
      '/entrepreneur/property/$id/location';
  static String suitabilityRoute(String id) =>
      '/entrepreneur/property/$id/suitability';
  static String tourRoute(String id) => '/entrepreneur/property/$id/tour';
  static String explanationRoute(String id) =>
      '/entrepreneur/property/$id/explanation';
}
