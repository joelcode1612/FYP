import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/application/services/panorama_capture_service.dart';
import 'package:fyp/application/services/panorama_generation_service.dart';
import 'package:fyp/core/utils/ar_math.dart';
import 'package:vector_math/vector_math_64.dart' as v;

/// Test double so unit tests never load the native OpenCV library.
class _FakeStitcher implements PanoramaStitcher {
  final StitchResult result;
  const _FakeStitcher(this.result);

  @override
  Future<StitchResult> stitchFrames(
    List<String> paths, {
    void Function(String stage)? onStage,
  }) async => result;
}

void main() {
  group('capture rig configuration (bug #1)', () {
    test('26 targets with unique frame indexes 1..26', () {
      final targets = CaptureTargetDataSource.targets;
      expect(targets, hasLength(26));
      expect(targets.map((t) => t.frameIndex).toSet(), hasLength(26));
    });

    test('zenith above, nadir below, rings correctly signed', () {
      v.Vector3 pos(String name) {
        final t = CaptureTargetDataSource.targets.firstWhere(
          (e) => e.name == name,
        );
        return sphericalToVector(t.pitch, t.yaw);
      }

      expect(pos('ZENITH').y, greaterThan(0));
      expect(pos('NADIR').y, lessThan(0));
      expect(pos('UPPER FRONT').y, greaterThan(0));
      expect(pos('MIDDLE FRONT').y, closeTo(0, 0.001));
      expect(pos('LOWER FRONT').y, lessThan(0));
    });

    test('ring tolerances are meaningful, poles stay yaw-free', () {
      for (final t in CaptureTargetDataSource.targets) {
        if (t.name == 'ZENITH' || t.name == 'NADIR') {
          expect(t.yawTolerance, 360);
        } else {
          expect(t.yawTolerance, lessThanOrEqualTo(45));
          expect(t.pitchTolerance, lessThanOrEqualTo(20));
        }
      }
    });
  });

  group('angular difference (bug #2)', () {
    test('wraps around 0/360', () {
      expect(angleDifferenceDeg(355, 0), closeTo(5, 0.001));
      expect(angleDifferenceDeg(0, 355), closeTo(-5, 0.001));
      expect(angleDifferenceDeg(170, -170), closeTo(20, 0.001));
      expect(wrapAngleDeg(360), closeTo(0, 0.001));
      expect(wrapAngleDeg(-190), closeTo(170, 0.001));
    });

    test('camera facing a target reports aligned with ~0 yaw/pitch', () {
      final reading = computeAlignment(
        cameraPosition: v.Vector3.zero(),
        cameraRotation: v.Quaternion.identity(),
        targetPosition: sphericalToVector(0, 0),
        yawTolerance: 15,
        pitchTolerance: 12,
      );
      expect(reading.yawDeg, closeTo(0, 0.001));
      expect(reading.pitchDeg, closeTo(0, 0.001));
      expect(reading.aligned, isTrue);
    });

    test('target yaw influences alignment', () {
      AlignmentReading read(double camYawDeg) {
        final rad = camYawDeg * 3.141592653589793 / 180;
        final q = v.Quaternion.axisAngle(v.Vector3(0, 1, 0), rad);
        return computeAlignment(
          cameraPosition: v.Vector3.zero(),
          cameraRotation: q,
          targetPosition: sphericalToVector(0, 90),
          yawTolerance: 15,
          pitchTolerance: 12,
        );
      }

      expect(read(90).aligned, isTrue);
      expect(read(0).aligned, isFalse);
      expect(read(0).yawError, closeTo(90, 0.5));
    });
  });

  group('session state machine + sequence', () {
    PanoramaCaptureService fresh() =>
        PanoramaCaptureService(CaptureTargetDataSource.targets);

    void warmUp(PanoramaCaptureService s, DateTime t) {
      for (var i = 0; i < 5; i++) {
        s.observePose(
          cameraPosition: v.Vector3.zero(),
          yawError: 90,
          pitchError: 45,
          alignedNow: false,
          at: t.add(Duration(milliseconds: 100 * i)),
        );
      }
      s.observePose(
        cameraPosition: v.Vector3.zero(),
        yawError: 90,
        pitchError: 45,
        alignedNow: false,
        at: t.add(const Duration(milliseconds: 600)),
      );
    }

    test('tracking warms up, origin is captured, then guiding', () {
      final s = fresh();
      final t = DateTime(2026, 1, 1);
      expect(s.state, CaptureSessionState.initializing);
      warmUp(s, t);
      expect(s.state, CaptureSessionState.guiding);
      expect(s.origin, isNotNull);
    });

    test('full 1..26 sequence with stability + confirmed frames', () {
      final s = fresh();
      var t = DateTime(2026, 1, 1);
      warmUp(s, t);
      for (var i = 0; i < 26; i++) {
        t = t.add(const Duration(milliseconds: 100));
        s.observePose(
          cameraPosition: v.Vector3.zero(),
          yawError: 0,
          pitchError: 0,
          alignedNow: true,
          at: t,
        );
        expect(
          s.stabilityReady(t.add(const Duration(milliseconds: 799))),
          isFalse,
        );
        t = t.add(const Duration(milliseconds: 800));
        expect(s.stabilityReady(t), isTrue);
        expect(s.beginCapture(), isTrue);
        expect(s.confirmFrame(imagePath: 'frame_$i.png', at: t), isTrue);
      }
      expect(s.allCaptured, isTrue);
      expect(s.missingFrames(), isEmpty);
      expect(s.capturedCount, 26);
    });

    test('failed capture does not advance; duplicates rejected', () {
      final s = fresh();
      final t = DateTime(2026, 1, 1);
      warmUp(s, t);
      // begin without alignment is refused
      expect(s.beginCapture(), isFalse);
      expect(s.currentIndex, 0);
      // aligned capture then duplicate confirm
      s.observePose(
        cameraPosition: v.Vector3.zero(),
        yawError: 0,
        pitchError: 0,
        alignedNow: true,
        at: t.add(const Duration(seconds: 2)),
      );
      expect(s.beginCapture(), isTrue);
      s.failCapture('boom');
      expect(s.currentIndex, 0);
      expect(s.state, CaptureSessionState.guiding);
      expect(s.beginCapture(), isTrue);
      expect(s.confirmFrame(imagePath: 'a.png', at: t), isTrue);
      expect(s.currentIndex, 1);
    });

    test('retake reopens the frame without duplicating', () {
      final s = fresh();
      final t = DateTime(2026, 1, 1);
      warmUp(s, t);
      for (var i = 0; i < 3; i++) {
        s.observePose(
          cameraPosition: v.Vector3.zero(),
          yawError: 0,
          pitchError: 0,
          alignedNow: true,
          at: t.add(Duration(seconds: 2 + i)),
        );
        s.beginCapture();
        s.confirmFrame(imagePath: 'f$i.png', at: t);
      }
      expect(s.currentIndex, 3);
      s.reopenFrame(1);
      expect(s.currentIndex, 1);
      expect(s.frames.containsKey(1), isFalse);
      expect(s.frames.containsKey(2), isTrue);
      expect(s.missingFrames(), contains(1));
    });

    test('moving off origin raises a warning and blocks alignment', () {
      final s = fresh();
      final t = DateTime(2026, 1, 1);
      warmUp(s, t);
      s.observePose(
        cameraPosition: v.Vector3(5, 0, 0),
        yawError: 0,
        pitchError: 0,
        alignedNow: true,
        at: t.add(const Duration(seconds: 3)),
      );
      expect(s.positionWarning, isTrue);
      expect(s.aligned, isFalse);
      expect(s.beginCapture(), isFalse);
    });

    test('restore keeps frames and points at first gap', () {
      final s = fresh();
      s.restoreFrames({
        0: CapturedFrame(
          frameIndex: 1,
          targetName: 'ZENITH',
          targetYaw: 0,
          targetPitch: 90,
          imagePath: 'a.png',
          capturedAt: DateTime(2026, 1, 1),
        ),
        2: CapturedFrame(
          frameIndex: 2,
          targetName: 'UPPER BACK',
          targetYaw: 0,
          targetPitch: 45,
          imagePath: 'c.png',
          capturedAt: DateTime(2026, 1, 1),
        ),
      });
      expect(s.currentIndex, 1);
      expect(s.missingFrames(), contains(1));
    });
  });

  group('generation validation (no fake stitching)', () {
    PanoramaGenerationService serviceWith(StitchResult r) =>
        PanoramaGenerationService(_FakeStitcher(r), TourRepositoryImpl());

    test('fewer than 26 frames is rejected before stitching', () async {
      final service = serviceWith(
        const StitchResult.failure('should not be called'),
      );
      final result = await service.generate(
        tourId: 't-x',
        frames: [
          for (var i = 0; i < 5; i++)
            CapturedFrame(
              frameIndex: i + 1,
              targetName: 'T$i',
              targetYaw: 0,
              targetPitch: 0,
              imagePath: 'missing_$i.png',
              capturedAt: DateTime(2026, 1, 1),
            ),
        ],
      );
      expect(result.success, isFalse);
      expect(result.message, contains('5/26'));
    });

    test('duplicate frame indexes are rejected', () async {
      final service = serviceWith(
        const StitchResult.failure('should not be called'),
      );
      CapturedFrame f(int idx) => CapturedFrame(
        frameIndex: idx,
        targetName: 'T$idx',
        targetYaw: 0,
        targetPitch: 0,
        imagePath: 'f$idx.png',
        capturedAt: DateTime(2026, 1, 1),
      );
      final result = await service.generate(
        tourId: 't-x',
        frames: [for (var i = 1; i <= 25; i++) f(i), f(25)],
      );
      expect(result.success, isFalse);
      expect(result.message, contains('Duplicate'));
    });

    test('successful stitch records the panorama on the tour', () async {
      final repo = TourRepositoryImpl();
      final service = PanoramaGenerationService(
        const _FakeStitcher(
          StitchResult(
            success: true,
            panoramaPath: '/tmp/pano.jpg',
            message: 'ok',
          ),
        ),
        repo,
      );
      final draft = await TourService(repo).createDraft(propertyId: 'p-x', title: 'T', frameCount: 26);
      CapturedFrame f(int i) => CapturedFrame(
        frameIndex: i,
        targetName: 'T$i',
        targetYaw: 0,
        targetPitch: 0,
        imagePath: 'f$i.png',
        capturedAt: DateTime(2026, 1, 1),
      );
      final result = await service.generate(
        tourId: draft.id,
        frames: [for (var i = 1; i <= 26; i++) f(i)],
      );
      expect(result.success, isTrue);
      final stored = await repo.tourById(draft.id);
      expect(stored?.panoramaPath, '/tmp/pano.jpg');
      expect(stored?.status, VirtualTourStatus.ready);
    });
  });

  group('tour lifecycle', () {
    test('draft → submit requires panorama → approve gates viewing', () async {
      // NOTE: uses a synthetic property id so the approved demo tours
      // (p-artisan, p-heritage) cannot leak into the gate assertions.
      const pid = 'p-test-lifecycle';
      final repo = TourRepositoryImpl();
      final tours = TourService(repo);
      final draft = await tours.createDraft(
        propertyId: pid,
        title: 'Test tour',
        frameCount: 26,
      );
      expect(draft.status, VirtualTourStatus.draft);
      expect(await tours.tourForPropertyApproved(pid), isNull);

      await expectLater(tours.submitTour(draft.id), throwsStateError);

      await tours.attachPanorama(draft.id, '/tmp/pano.jpg');
      await tours.submitTour(draft.id);
      var stored = await repo.tourById(draft.id);
      expect(stored?.status, VirtualTourStatus.pendingVerification);
      expect(await tours.tourForPropertyApproved(pid), isNull);

      await tours.approveTour(draft.id);
      stored = await repo.tourById(draft.id);
      expect(stored?.status, VirtualTourStatus.approved);
      expect(stored?.published, isTrue);

      await tours.deleteTour(draft.id);
      expect(await repo.tourById(draft.id), isNull);
    });

    test('capture config defaults are sane', () {
      const c = CaptureConfig();
      expect(c.stabilityDuration.inMilliseconds, 800);
      expect(c.movementThresholdMeters, 0.5);
      expect(c.autoCapture, isTrue);
    });
  });
}
