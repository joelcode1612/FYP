import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:vector_math/vector_math_64.dart' as v;

import 'package:fyp/application/services/panorama_capture_service.dart';
import 'package:fyp/core/utils/capture_log.dart';
import 'package:fyp/core/utils/device_pose_math.dart';

/// The capture state machine and the orientation fusion that feeds it.
///
/// Both are pure Dart, so the rules that protect a tour — no advance without a
/// confirmed image, no duplicates, no skipped target, retakes keep the other
/// frames — are verified here rather than on a device.
void main() {
  setUp(() => CaptureLog.enabled = false);
  tearDown(() => CaptureLog.enabled = true);

  group('DevicePoseMath', () {
    // Upright portrait phone, camera pointing at magnetic north.
    // Device axes: +X east, +Y up, +Z south; field dips down in the north.
    const northAccel = [0.0, 9.81, 0.0];
    const northMag = [0.0, -40.0, -20.0];

    test('upright phone facing north reads level and 0°', () {
      final pose = DevicePoseMath.fuse(accel: northAccel, mag: northMag)!;
      expect(pose.headingDeg, closeTo(0, 1e-6));
      expect(pose.pitchDeg, closeTo(0, 1e-6));
      expect(pose.rollDeg, closeTo(0, 1e-6));
    });

    test('camera elevation is asin(-Az), not the device tilt', () {
      // Pointing straight up: gravity reads along -Z, so elevation is +90.
      final up = DevicePoseMath.fuse(accel: [0, 0, -9.81], mag: northMag)!;
      expect(up.pitchDeg, closeTo(90, 1e-6));
      // Pointing straight down (phone flat, screen up): elevation is -90.
      final down = DevicePoseMath.fuse(accel: [0, 0, 9.81], mag: northMag)!;
      expect(down.pitchDeg, closeTo(-90, 1e-6));
      // An upright phone is NOT a 90° camera pitch — that is the bug Android's
      // own getOrientation pitch would introduce here.
      final level = DevicePoseMath.fuse(accel: northAccel, mag: northMag)!;
      expect(level.pitchDeg, closeTo(0, 1e-6));
    });

    test('bearing follows the camera axis, not the phone top', () {
      // Same upright phone rotated a quarter turn: camera now points east.
      // Device axes become +X south, +Y up, +Z west.
      final east = DevicePoseMath.fuse(
        accel: northAccel,
        mag: [-20.0, -40.0, 0.0],
      )!;
      expect(east.headingDeg, closeTo(90, 1e-6));
      expect(east.pitchDeg, closeTo(0, 1e-6));
    });

    test('roll reports horizon tilt from upright portrait', () {
      // Top of the phone tilted to the right: gravity reads along -X.
      final tilted = DevicePoseMath.fuse(
        accel: [-9.81, 0, 0],
        mag: [0.0, -40.0, -20.0],
      )!;
      expect(tilted.rollDeg, closeTo(-90, 1e-6));
    });

    test('degenerate vectors produce no pose instead of noise', () {
      expect(DevicePoseMath.fuse(accel: [0, 0, 0], mag: northMag), isNull);
      // Field parallel to gravity: the east vector collapses.
      expect(
        DevicePoseMath.fuse(accel: [0, 0, 9.81], mag: [0, 0, 50]),
        isNull,
      );
      expect(DevicePoseMath.fuse(accel: [0, 9.81], mag: northMag), isNull);
    });

    test('angle wrapping keeps yaw errors on the short arc', () {
      expect(DevicePoseMath.wrap360(-10), 350);
      expect(DevicePoseMath.wrap360(370), 10);
      expect(DevicePoseMath.wrap180(350), -10);
      expect(DevicePoseMath.wrap180(-190), 170);
      expect(DevicePoseMath.wrap180(180), 180);
      // The composition the capture screen uses: heading relative to the
      // start direction, then relative to the target, across the 0/360 seam.
      double relative(double heading, double origin, double target) =>
          DevicePoseMath.wrap180(
            DevicePoseMath.wrap180(heading - origin) - target,
          );
      expect(relative(350, 10, 0), -20);
      expect(relative(10, 350, 0), 20);
      expect(relative(5, 350, 45), -30);
    });

    test('low-pass seeds from the first sample then blends', () {
      final first = DevicePoseMath.lowPass(null, [1, 2, 3]);
      expect(first, [1, 2, 3]);
      final next = DevicePoseMath.lowPass(first, [3, 4, 5], alpha: 0.5);
      expect(next, [2, 3, 4]);
    });
  });

  group('PanoramaCaptureService', () {
    CapturePoint point({
      String name = 'TARGET',
      double yaw = 0,
      double pitch = 0,
      double yawTolerance = 15,
      double pitchTolerance = 12,
      int frameIndex = 1,
    }) => CapturePoint(
      name: name,
      pitch: pitch,
      yaw: yaw,
      roll: 0,
      pitchTolerance: pitchTolerance,
      yawTolerance: yawTolerance,
      rollTolerance: 40,
      frameIndex: frameIndex,
      expectedYawDelta: 0,
      expectedPitchDelta: 0,
      overlapNeighbors: const [],
    );

    final origin = v.Vector3.zero();
    final t0 = DateTime.utc(2026, 1, 1, 12);

    /// Runs the warm-up and origin polls so a session starts in `guiding`,
    /// then one aligned poll when requested. Every poll is stamped [t0] so the
    /// stability window starts exactly there.
    void arm(
      PanoramaCaptureService service, {
      bool aligned = false,
      double yawError = 0,
      double pitchError = 0,
    }) {
      for (var i = 0; i < service.config.trackingWarmupPolls + 1; i++) {
        service.observePose(
          cameraPosition: origin,
          yawError: yawError,
          pitchError: pitchError,
          alignedNow: false,
          at: t0,
        );
      }
      if (aligned) {
        service.observePose(
          cameraPosition: origin,
          yawError: yawError,
          pitchError: pitchError,
          alignedNow: true,
          at: t0,
        );
      }
    }

    test('tracking must warm up before the origin is established', () {
      final service = PanoramaCaptureService(
        [point()],
        const CaptureConfig(trackingWarmupPolls: 3),
      );
      for (var i = 0; i < 3; i++) {
        service.observePose(
          cameraPosition: origin,
          yawError: 0,
          pitchError: 0,
          alignedNow: false,
          at: t0,
        );
      }
      expect(service.state, CaptureSessionState.trackingReady);
      expect(service.origin, isNull);
      service.observePose(
        cameraPosition: origin,
        yawError: 0,
        pitchError: 0,
        alignedNow: false,
        at: t0,
      );
      expect(service.state, CaptureSessionState.guiding);
      expect(service.origin, isNotNull);
    });

    test('an empty target list is an error, not a silent session', () {
      final service = PanoramaCaptureService(const []);
      service.observePose(
        cameraPosition: origin,
        yawError: 0,
        pitchError: 0,
        alignedNow: true,
        at: t0,
      );
      expect(service.state, CaptureSessionState.error);
      expect(service.error, isNotNull);
    });

    test('alignment gates on both yaw and pitch tolerances', () {
      final service = PanoramaCaptureService([point()]);
      arm(service);
      service.observePose(
        cameraPosition: origin,
        yawError: 20,
        pitchError: 0,
        alignedNow: false,
        at: t0,
      );
      expect(service.aligned, isFalse);
      expect(service.state, CaptureSessionState.guiding);
      service.observePose(
        cameraPosition: origin,
        yawError: 5,
        pitchError: 20,
        alignedNow: false,
        at: t0,
      );
      expect(service.aligned, isFalse);
      service.observePose(
        cameraPosition: origin,
        yawError: 5,
        pitchError: 5,
        alignedNow: true,
        at: t0,
      );
      expect(service.aligned, isTrue);
      expect(service.state, CaptureSessionState.stabilizing);
    });

    test('capture is refused while misaligned', () {
      final service = PanoramaCaptureService([point()]);
      arm(service);
      expect(service.beginCapture(), isFalse);
      expect(service.error, isNotNull);
      expect(service.state, CaptureSessionState.guiding);
      expect(service.capturedCount, 0);
    });

    test('stability must hold continuously for the configured window', () {
      final service = PanoramaCaptureService(
        [point()],
        const CaptureConfig(stabilityDuration: Duration(milliseconds: 800)),
      );
      arm(service, aligned: true);
      expect(service.state, CaptureSessionState.stabilizing);
      expect(service.stabilityReady(t0.add(const Duration(milliseconds: 799))),
          isFalse);
      expect(service.stabilityReady(t0.add(const Duration(milliseconds: 800))),
          isTrue);
      expect(service.stabilityFraction(t0.add(const Duration(milliseconds: 400))),
          closeTo(0.5, 1e-9));

      // Losing alignment resets the window; it does not resume where it left off.
      final lost = t0.add(const Duration(seconds: 2));
      service.observePose(
        cameraPosition: origin,
        yawError: 40,
        pitchError: 0,
        alignedNow: false,
        at: lost,
      );
      expect(service.state, CaptureSessionState.guiding);
      expect(service.stabilityReady(lost.add(const Duration(seconds: 5))),
          isFalse);
      service.observePose(
        cameraPosition: origin,
        yawError: 0,
        pitchError: 0,
        alignedNow: true,
        at: lost,
      );
      expect(service.stabilityReady(lost.add(const Duration(milliseconds: 799))),
          isFalse);
      expect(service.stabilityReady(lost.add(const Duration(milliseconds: 800))),
          isTrue);
    });

    test('the index advances only after a confirmed image', () {
      final service = PanoramaCaptureService([
        point(name: 'A', frameIndex: 1),
        point(name: 'B', frameIndex: 2),
      ]);
      arm(service, aligned: true);
      expect(service.beginCapture(), isTrue);
      expect(service.state, CaptureSessionState.capturing);
      // Pose polls while capturing must not move the sequence on.
      service.observePose(
        cameraPosition: origin,
        yawError: 0,
        pitchError: 0,
        alignedNow: true,
        at: t0,
      );
      expect(service.currentIndex, 0);
      expect(service.capturedCount, 0);
      expect(service.confirmFrame(imagePath: '/frames/a.png', at: t0), isTrue);
      expect(service.currentIndex, 1);
      expect(service.capturedCount, 1);
      expect(service.frames[0]!.imagePath, '/frames/a.png');
      // A second confirm without a new reservation is rejected.
      expect(service.confirmFrame(imagePath: '/frames/a.png', at: t0), isFalse);
      expect(service.currentIndex, 1);
      expect(service.capturedCount, 1);
    });

    test('a failed capture stays on the same target and can be retried', () {
      final service = PanoramaCaptureService([point()]);
      arm(service, aligned: true);
      expect(service.beginCapture(), isTrue);
      service.failCapture('The camera could not save this frame.');
      expect(service.state, CaptureSessionState.guiding);
      expect(service.currentIndex, 0);
      expect(service.capturedCount, 0);
      expect(service.error, 'The camera could not save this frame.');
      expect(service.beginCapture(), isTrue);
      expect(service.confirmFrame(imagePath: '/frames/a.png', at: t0), isTrue);
    });

    test('a retake keeps the frames captured after it', () {
      final service = PanoramaCaptureService([
        for (var i = 0; i < 4; i++) point(name: 'T$i', frameIndex: i + 1),
      ]);
      arm(service, aligned: true);
      for (var i = 0; i < 3; i++) {
        expect(service.beginCapture(), isTrue);
        expect(
          service.confirmFrame(imagePath: '/frames/$i.png', at: t0),
          isTrue,
        );
      }
      expect(service.capturedCount, 3);
      service.reopenFrame(1);
      expect(service.currentIndex, 1);
      expect(service.capturedCount, 2);
      expect(service.frames.containsKey(0), isTrue);
      expect(service.frames.containsKey(2), isTrue);
      expect(service.missingFrames(), [1, 3]);
      expect(service.beginCapture(), isTrue);
      expect(
        service.confirmFrame(imagePath: '/frames/1b.png', at: t0),
        isTrue,
      );
      expect(service.frames[1]!.imagePath, '/frames/1b.png');
      expect(service.currentIndex, 2);
    });

    test('a restored session points at the first missing frame', () {
      final service = PanoramaCaptureService([
        for (var i = 0; i < 4; i++) point(name: 'T$i', frameIndex: i + 1),
      ]);
      service.restoreFrames({
        0: CapturedFrame(
          frameIndex: 1,
          targetName: 'T0',
          targetYaw: 0,
          targetPitch: 0,
          imagePath: '/frames/0.png',
          capturedAt: t0,
        ),
        2: CapturedFrame(
          frameIndex: 3,
          targetName: 'T2',
          targetYaw: 0,
          targetPitch: 0,
          imagePath: '/frames/2.png',
          capturedAt: t0,
        ),
      });
      expect(service.currentIndex, 1);
      expect(service.capturedCount, 2);
      expect(service.state, CaptureSessionState.guiding);
    });

    test('prepareResume re-warms tracking without dropping frames', () {
      final service = PanoramaCaptureService([
        point(name: 'A', frameIndex: 1),
        point(name: 'B', frameIndex: 2),
      ]);
      arm(service, aligned: true);
      service.beginCapture();
      service.confirmFrame(imagePath: '/frames/a.png', at: t0);
      service.prepareResume();
      expect(service.state, CaptureSessionState.trackingReady);
      expect(service.capturedCount, 1);
      expect(service.currentIndex, 1);
    });

    test('drift beyond the threshold blocks alignment', () {
      final service = PanoramaCaptureService(
        [point()],
        const CaptureConfig(movementThresholdMeters: 0.5),
      );
      arm(service, aligned: true);
      expect(service.positionWarning, isFalse);
      service.observePose(
        cameraPosition: v.Vector3(2, 0, 0),
        yawError: 0,
        pitchError: 0,
        alignedNow: true,
        at: t0,
      );
      expect(service.positionWarning, isTrue);
      expect(service.aligned, isFalse);
      expect(service.beginCapture(), isFalse);
    });

    test('processing refuses an incomplete sequence and names the gap', () {
      final service = PanoramaCaptureService([
        point(name: 'A', frameIndex: 1),
        point(name: 'B', frameIndex: 2),
      ]);
      arm(service, aligned: true);
      service.beginCapture();
      service.confirmFrame(imagePath: '/frames/a.png', at: t0);
      service.startProcessing();
      expect(service.state, isNot(CaptureSessionState.processing));
      expect(service.error, contains('Frame 2'));
      service.beginCapture();
      service.confirmFrame(imagePath: '/frames/b.png', at: t0);
      service.startProcessing();
      expect(service.state, CaptureSessionState.processing);
      expect(service.error, isNull);
    });

    test('the whole 26-target rig completes in order with no gaps', () {
      final service = PanoramaCaptureService(CaptureTargetDataSource.targets);
      expect(service.targets.length, 26);
      expect(service.targets.first.name, 'ZENITH');
      expect(service.targets.first.pitch, 90);
      expect(service.targets.last.name, 'NADIR');
      expect(service.targets.last.pitch, -90);
      expect(
        service.targets.map((t) => t.frameIndex).toSet(),
        {for (var i = 1; i <= 26; i++) i},
      );

      arm(service, aligned: true);
      for (var i = 0; i < service.targets.length; i++) {
        service.observePose(
          cameraPosition: origin,
          yawError: 0,
          pitchError: 0,
          alignedNow: true,
          at: t0.add(Duration(milliseconds: i * 100)),
        );
        expect(service.currentIndex, i);
        expect(service.beginCapture(), isTrue);
        expect(
          service.confirmFrame(
            imagePath: '/frames/$i.png',
            at: t0.add(Duration(milliseconds: i * 100 + 50)),
          ),
          isTrue,
        );
      }
      expect(service.allCaptured, isTrue);
      expect(service.capturedCount, 26);
      expect(service.missingFrames(), isEmpty);
      expect(service.progress, 1);
      service.startProcessing();
      expect(service.state, CaptureSessionState.processing);
      service.markPreview();
      expect(service.state, CaptureSessionState.preview);
    });

    test('ZENITH and NADIR accept any yaw', () {
      final zenith = CaptureTargetDataSource.targets.first;
      final nadir = CaptureTargetDataSource.targets.last;
      expect(zenith.isAligned(yawDeg: 179, pitchDeg: 80), isTrue);
      expect(nadir.isAligned(yawDeg: -179, pitchDeg: -80), isTrue);
      expect(zenith.isAligned(yawDeg: 0, pitchDeg: 60), isFalse);
    });
  });
}