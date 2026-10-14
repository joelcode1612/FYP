/// Explicit capture-session lifecycle for the 26-frame AR workflow.
/// Linear progression only: guiding → stabilizing → capturing → next.
enum CaptureSessionState {
  initializing,
  trackingReady,
  settingOrigin,
  guiding,
  stabilizing,
  capturing,
  processing,
  preview,
  completed,
  error,
}
