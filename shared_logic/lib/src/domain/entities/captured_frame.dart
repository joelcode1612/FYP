/// One captured panorama frame: the real image file plus the metadata that
/// ties it to its capture target. Pure Dart — no Flutter/AR imports.
class CapturedFrame {
  final int frameIndex;
  final String targetName;
  final double targetYaw;
  final double targetPitch;
  final String imagePath;
  final DateTime capturedAt;
  final int retakeCount;

  const CapturedFrame({
    required this.frameIndex,
    required this.targetName,
    required this.targetYaw,
    required this.targetPitch,
    required this.imagePath,
    required this.capturedAt,
    this.retakeCount = 0,
  });

  CapturedFrame retaken({required String imagePath, required DateTime at}) =>
      CapturedFrame(
        frameIndex: frameIndex,
        targetName: targetName,
        targetYaw: targetYaw,
        targetPitch: targetPitch,
        imagePath: imagePath,
        capturedAt: at,
        retakeCount: retakeCount + 1,
      );
}
