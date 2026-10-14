/// Shared constants. No business rules live here.
abstract final class AppBreakpoints {
  static const double mobile = 768;
  static const double desktop = 1024;
  static const double maxContentWidth = 1200;

  /// Desktop sidebar width per the Sitewise prototype (§7).
  static const double sidebarWidth = 236;

  /// Mobile outer margin (§8).
  static const double mobileMargin = 16;

  /// Maximum properties in a comparison set (§22).
  static const int maxCompare = 3;
}

abstract final class AppStrings {
  static const String appName = 'Sitewise';
  static const String tagline = 'F&B Location Intelligence Platform';
  static const String currency = 'RM';
}

enum PreviewMode { auto, web, mobile }

/// Centralised configuration for the on-device AR panorama capture flow.
/// The reticle asset must stay in sync with `pubspec.yaml` (single source).
abstract final class ArCaptureConfig {
  static const String targetReticleAsset = 'models/target_reticle.glb';
  static const double nodeRadius = 3;
  static const double nodeScale = 0.5;
  static const String captureRoute = '/owner/capture';
}
