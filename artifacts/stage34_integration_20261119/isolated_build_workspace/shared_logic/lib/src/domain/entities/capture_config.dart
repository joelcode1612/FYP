/// Tunable parameters for the AR-guided 360° capture session.
///
/// Centralises every threshold the workflow depends on so behaviour can be
/// tuned without touching capture logic.
class CaptureConfig {
  /// How long alignment must hold (continuously) before auto-capture fires.
  final Duration stabilityDuration;

  /// Max distance in metres the user may drift from the capture origin
  /// before capture is blocked with a return-to-position warning.
  final double movementThresholdMeters;

  /// Consecutive successful camera-pose polls required before tracking
  /// counts as ready and the capture origin may be established.
  final int trackingWarmupPolls;

  /// Capture automatically once alignment is stable (recommended).
  final bool autoCapture;

  /// Emit `[360]` development logs.
  final bool enableLogs;

  const CaptureConfig({
    this.stabilityDuration = const Duration(milliseconds: 800),
    this.movementThresholdMeters = 0.5,
    this.trackingWarmupPolls = 5,
    this.autoCapture = true,
    this.enableLogs = true,
  });
}
