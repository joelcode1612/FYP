import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/features/virtual_tour/platform/arcore_ar.dart';
import 'package:fyp/data/datasources/local/capture_frame_store.dart';
import 'package:fyp/features/capture/data/repositories/sitewise_capture_repository.dart';
import 'package:fyp/features/capture/domain/models/capture_record.dart';
import 'package:fyp/features/capture/domain/models/capture_station.dart';
import 'package:fyp/features/capture/domain/models/capture_target.dart';
import 'package:fyp/features/capture/domain/services/rotation_in_place.dart';
import 'package:fyp/features/capture/domain/services/target_sphere.dart';
import 'package:fyp/core/math/vio_sphere_math.dart' as vio;
import 'package:fyp/features/virtual_tour/domain/math/quaternions.dart';
import 'package:fyp/features/virtual_tour/domain/math/vectors.dart';
import 'package:fyp/features/virtual_tour/platform/ar_types.dart';
import 'package:shared_logic/shared_logic.dart';

/// A frame store rooted in a test directory instead of the app documents dir.
class _TempFrameStore extends CaptureFrameStore {
  _TempFrameStore(this.root);

  final String root;

  @override
  Future<String> tourRoot(String tourId) async => '$root/$tourId';
}

CaptureTarget _target(int id, String stationId, {double yaw = 0}) =>
    CaptureTarget(
      targetId: id,
      stationId: stationId,
      yawDegrees: yaw,
      pitchDegrees: 0,
      stationLocalDirection: const Vec3(0, 0, 1),
    );

CaptureRecord _record(int targetId, String stationId, String path) =>
    CaptureRecord(
      stationId: stationId,
      targetId: targetId,
      imagePath: path,
      capturedAt: DateTime.utc(2026, 11, 12, 10, targetId),
      targetYawDegrees: 0,
      targetPitchDegrees: 0,
      cameraPosition: const Vec3(0, 0, 0),
      cameraOrientation: const Quat(0, 0, 0, 1),
      alignmentErrorDeg: 0.5,
      anchored: true,
      imageWidth: 640,
      imageHeight: 480,
    );

void main() {
  group('26-target sphere geometry', () {
    test('builds exactly 26 unique, ordered directions', () {
      final specs = buildCaptureSphere();
      expect(specs.length, 26);
      expect(
        specs.map((s) => s.targetId).toList(),
        List<int>.generate(26, (i) => i + 1),
      );
      expect(specs.map((s) => s.targetId).toSet().length, 26);
    });

    test('keeps the two poles and the three rings', () {
      final specs = buildCaptureSphere();
      final zenith = specs.firstWhere((s) => s.isZenith);
      final nadir = specs.firstWhere((s) => s.isNadir);
      expect(zenith.pitchDegrees, 90);
      expect(nadir.pitchDegrees, -90);
      expect(specs.where((s) => s.ringName == 'Horizontal').length, 8);
      expect(specs.where((s) => s.ringName == 'Upper').length, 8);
      expect(specs.where((s) => s.ringName == 'Lower').length, 8);
    });

    test('every direction is a unit vector', () {
      for (final spec in buildCaptureSphere()) {
        expect(spec.direction.length, closeTo(1, 1e-9));
      }
    });
  });

  group('SiteWiseCaptureRepository', () {
    late Directory tmp;
    late _TempFrameStore frames;
    late SiteWiseCaptureRepository repo;
    const tourId = 'tour-1';

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sitewise_capture_');
      frames = _TempFrameStore(tmp.path);
      repo = SiteWiseCaptureRepository(tourId: tourId, frameStore: frames);
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('writes frames inside the tour directory', () async {
      final path = await repo.framePath(tourId, 7);
      expect(
        path.replaceAll('\\', '/'),
        endsWith('$tourId/ar_capture/$tourId/frames/t07.jpg'),
      );
      expect(File(path).parent.existsSync(), isTrue);
    });

    test('round-trips station, targets and records', () async {
      final station = CaptureStation(
        stationId: tourId,
        referencePosition: const Vec3(0.1, 1.2, -0.3),
        referenceOrientation: const Quat(0, 0, 0, 1),
        createdAt: DateTime.utc(2026, 11, 12),
        trackingStatus: TrackingState.tracking,
      );
      await repo.saveStation(station);
      await repo.saveTargets([_target(1, tourId), _target(2, tourId, yaw: 90)]);
      await repo.saveRecord(_record(1, tourId, '/tmp/t01.jpg'));

      final loadedStation = await repo.loadStation(tourId);
      expect(loadedStation!.stationId, tourId);
      expect(loadedStation.referencePosition.y, closeTo(1.2, 1e-9));

      final targets = await repo.loadTargets(tourId);
      expect(targets.map((t) => t.targetId), [1, 2]);

      final records = await repo.loadRecords(tourId);
      expect(records.length, 1);
      expect(records.single.imagePath, '/tmp/t01.jpg');
    });

    test('a retake replaces the record instead of appending', () async {
      await repo.saveTargets([_target(3, tourId)]);
      await repo.saveRecord(_record(3, tourId, '/tmp/first.jpg'));
      await repo.saveRecord(_record(3, tourId, '/tmp/second.jpg'));

      final records = await repo.loadRecords(tourId);
      expect(records.length, 1);
      expect(records.single.imagePath, '/tmp/second.jpg');
    });

    test('mirrors saved records into the tour manifest', () async {
      await repo.saveTargets([_target(1, tourId), _target(2, tourId, yaw: 90)]);
      // The manifest only lists frames whose JPEG really exists, so the test
      // writes the bytes the AR still path would have written.
      final f1 = await _writeFrame(repo, tourId, 1);
      final f2 = await _writeFrame(repo, tourId, 2);
      await repo.saveRecord(_record(2, tourId, f2));
      await repo.saveRecord(_record(1, tourId, f1));

      final manifest = await frames.loadManifest(tourId);
      expect(manifest.keys.toList()..sort(), [0, 1]);
      expect(manifest[0]!.imagePath, f1);
      expect(manifest[1]!.targetYaw, 90);
      // The manifest is ordered by capture target, not by save order.
      expect(manifest[0]!.frameIndex, 0);
    });

    test('reports progress to the tour after every save', () async {
      final counts = <int>[];
      final reporting = SiteWiseCaptureRepository(
        tourId: tourId,
        frameStore: frames,
        onProgress: counts.add,
      );
      await reporting.saveTargets([_target(1, tourId), _target(2, tourId)]);
      await reporting.saveRecord(
        _record(1, tourId, await _writeFrame(reporting, tourId, 1)),
      );
      await reporting.saveRecord(
        _record(2, tourId, await _writeFrame(reporting, tourId, 2)),
      );
      expect(counts, [1, 2]);
    });

    test('only a written station counts as resumable', () async {
      expect(await repo.stationIds(), isEmpty);

      // A frames-only directory (a killed process) is not a station.
      final partial = Directory(
        '${tmp.path}/$tourId/ar_capture/$tourId/frames',
      );
      await partial.create(recursive: true);
      expect(await repo.stationIds(), isEmpty);

      await repo.saveStation(
        CaptureStation(
          stationId: tourId,
          referencePosition: const Vec3(0, 0, 0),
          referenceOrientation: const Quat(0, 0, 0, 1),
          createdAt: DateTime.utc(2026, 11, 12),
          trackingStatus: TrackingState.tracking,
        ),
      );
      expect(await repo.stationIds(), [tourId]);
    });
  });

  group('ARCore channel contract', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    const channel = MethodChannel('test/arcore');
    const events = EventChannel('test/arcore/events');
    late List<MethodCall> calls;

    ArCoreHost host() => ArCoreHost(channel: channel, events: events);

    void answer(Future<Object?> Function(MethodCall call) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) {
            calls.add(call);
            return handler(call);
          });
    }

    setUp(() => calls = <MethodCall>[]);

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'probeDirections reads the host outcome map, not a bare list',
      () async {
        // The Kotlin host wraps every answer in an outcome map: the probe list
        // arrives under `results`. Reading it as a bare list threw a cast error
        // on every scan, which is what made all 26 targets report "no surface".
        answer((MethodCall call) async {
          expect(call.method, 'probeDirections');
          final args = call.arguments as Map;
          expect((args['directions'] as List).length, 6);
          return <String, Object?>{
            'results': <Object?>[
              <String, Object?>{
                'hit': true,
                'distanceM': 2.5,
                'planeType': 'VERTICAL',
              },
              <String, Object?>{'hit': false},
            ],
          };
        });

        final probes = await host().probeDirections(
          origin: const Vec3(0, 0, 0),
          directions: const <Vec3>[Vec3(0, 0, 1), Vec3(1, 0, 0)],
        );

        expect(probes.length, 2);
        expect(probes[0].found, isTrue);
        expect(probes[0].distanceM, 2.5);
        expect(probes[0].surfaceType, 'VERTICAL');
        expect(probes[1].found, isFalse);
      },
    );

    test('probeDirections still accepts a bare list from the host', () async {
      answer((MethodCall call) async {
        return <Object?>[
          <String, Object?>{'hit': true, 'distanceM': 1.25},
        ];
      });

      final probes = await host().probeDirections(
        origin: const Vec3(0, 0, 0),
        directions: const <Vec3>[Vec3(0, 0, 1)],
      );

      expect(probes.single.found, isTrue);
      expect(probes.single.distanceM, 1.25);
    });

    test('an empty outcome map is a miss, not a fabricated hit', () async {
      answer((MethodCall call) async => <String, Object?>{});

      final probes = await host().probeDirections(
        origin: const Vec3(0, 0, 0),
        directions: const <Vec3>[Vec3(0, 0, 1)],
      );

      expect(probes, isEmpty);
    });

    test('start enables plane detection and reports the texture', () async {
      answer((MethodCall call) async {
        expect(call.method, 'start');
        final args = call.arguments as Map;
        expect(args['planes'], isTrue);
        return <String, Object?>{
          'textureId': 7,
          'planes': true,
          'anchors': true,
          'cameraImage': true,
        };
      });

      final session = await host().start(width: 1080, height: 1920);
      expect(session.textureId, 7);
      expect(session.planes, isTrue);
      expect(session.cameraImage, isTrue);
      expect(session.reused, isFalse);
    });
  });

  group('rotation in place', () {
    const origin = vio.Vec3(0, 0, 0);
    final start = DateTime.utc(2026, 11, 12, 6);
    const stepMs = 66;

    /// Turns the whole body with the phone held [offsetM] in front of the
    /// operator. The camera therefore starts **at the station origin** and
    /// travels around a pivot behind it — the physical motion the 0.20 m gate
    /// must tolerate — instead of orbiting the calibration point.
    RotationInPlaceAssessment bodyTurn(
      RotationInPlaceMonitor monitor, {
      required double offsetM,
      required double sweepDeg,
      double degreesPerSecond = 45,
      double tremorM = 0,
      int? maxSamples,
    }) {
      var result = const RotationInPlaceAssessment(
        rawDriftM: 0,
        effectiveDriftM: 0,
        rotatingInPlace: false,
        withinAllowance: true,
      );
      final stepDeg = degreesPerSecond * stepMs / 1000;
      final totalSteps = maxSamples ?? (sweepDeg / stepDeg).ceil();
      for (var i = 0; i <= totalSteps; i++) {
        final theta = math.min(i * stepDeg, sweepDeg);
        final radians = theta * math.pi / 180;
        // Pivot sits directly behind the calibration camera position: the
        // camera starts at the station origin and travels around it.
        final jitter = tremorM * math.sin(i * 2.7);
        result = monitor.observe(
          position: vio.Vec3(
            offsetM * math.sin(radians) + jitter,
            0,
            offsetM * (math.cos(radians) - 1),
          ),
          yawDeg: theta,
          at: start.add(Duration(milliseconds: i * stepMs)),
          timestampNanoseconds: i * stepMs * 1000000,
        );
      }
      return result;
    }

    test('a body-spin with the phone held forward is not a walk-away', () {
      final monitor = RotationInPlaceMonitor(stationOrigin: origin);
      final result = bodyTurn(monitor, offsetM: 0.40, sweepDeg: 90);

      expect(result.rotatingInPlace, isTrue);
      expect(result.compensationActive, isTrue);
      expect(result.rotationRadiusM, closeTo(0.40, 0.02));
      expect(result.rawDriftM, greaterThan(0.20));
      // The gate sees the deviation from the predicted pivot path, not the
      // ~0.57 m translation the turn produced.
      expect(result.effectiveDriftM, lessThan(0.20));
      expect(result.driftReference, isNotNull);
    });

    test('90°, 180° and 360° body turns stay inside the compensated gate', () {
      for (final sweep in <double>[90, 180, 360]) {
        final monitor = RotationInPlaceMonitor(stationOrigin: origin);
        final result = bodyTurn(monitor, offsetM: 0.35, sweepDeg: sweep);
        expect(result.rotatingInPlace, isTrue, reason: 'sweep $sweep');
        expect(result.effectiveDriftM, lessThan(0.20), reason: 'sweep $sweep');
        expect(result.rawDriftM, lessThanOrEqualTo(1.05), reason: 'sweep $sweep');
      }
    });

    test('natural hand tremor during a body turn keeps compensation active', () {
      final monitor = RotationInPlaceMonitor(stationOrigin: origin);
      final result = bodyTurn(
        monitor,
        offsetM: 0.40,
        sweepDeg: 90,
        tremorM: 0.02,
      );
      expect(result.rotatingInPlace, isTrue);
      expect(result.effectiveDriftM, lessThan(0.10));
    });

    test('rotating the phone about its own centre needs no compensation', () {
      final monitor = RotationInPlaceMonitor(stationOrigin: origin);
      // Phone-only spin: camera stays within 3 cm of the calibrated point, so
      // the strict frozen-origin gate already accepts every frame.
      final result = bodyTurn(monitor, offsetM: 0.02, sweepDeg: 90);
      expect(result.rotatingInPlace, isFalse);
      expect(result.compensationActive, isFalse);
      expect(result.effectiveDriftM, result.rawDriftM);
      expect(result.rawDriftM, lessThan(0.20));
    });

    test('a slow walk-away never establishes a pivot model', () {
      final monitor = RotationInPlaceMonitor(stationOrigin: origin);
      var result = const RotationInPlaceAssessment(
        rawDriftM: 0,
        effectiveDriftM: 0,
        rotatingInPlace: false,
        withinAllowance: true,
      );
      // Walks away while turning: a spiral, not a fixed-pivot circle.
      for (var i = 0; i <= 30; i++) {
        final theta = i * 2.0;
        final radius = i * 0.02;
        final radians = theta * math.pi / 180;
        result = monitor.observe(
          position: vio.Vec3(
            radius * math.sin(radians),
            0,
            radius * math.cos(radians),
          ),
          yawDeg: theta,
          at: start.add(Duration(milliseconds: i * stepMs)),
          timestampNanoseconds: i * stepMs * 1000000,
        );
      }
      expect(result.rotatingInPlace, isFalse);
      expect(result.effectiveDriftM, result.rawDriftM);
      expect(result.rawDriftM, greaterThan(0.20));
    });

    test('sideways movement without a yaw sweep keeps the strict gate', () {
      final monitor = RotationInPlaceMonitor(stationOrigin: origin);
      var result = const RotationInPlaceAssessment(
        rawDriftM: 0,
        effectiveDriftM: 0,
        rotatingInPlace: false,
        withinAllowance: true,
      );
      for (var i = 0; i <= 20; i++) {
        result = monitor.observe(
          position: vio.Vec3(i * 0.025, 0, 0),
          yawDeg: 0,
          at: start.add(Duration(milliseconds: i * stepMs)),
          timestampNanoseconds: i * stepMs * 1000000,
        );
      }
      expect(result.rotatingInPlace, isFalse);
      expect(result.effectiveDriftM, result.rawDriftM);
      expect(result.rawDriftM, greaterThan(0.20));
    });

    test('back-and-forth yaw does not establish a pivot model', () {
      final monitor = RotationInPlaceMonitor(stationOrigin: origin);
      var result = const RotationInPlaceAssessment(
        rawDriftM: 0,
        effectiveDriftM: 0,
        rotatingInPlace: false,
        withinAllowance: true,
      );
      for (var i = 0; i <= 60; i++) {
        final theta = 25 * math.sin(i * 0.35);
        final radians = theta * math.pi / 180;
        result = monitor.observe(
          position: vio.Vec3(
            0.40 * math.sin(radians),
            0,
            0.40 * math.cos(radians),
          ),
          yawDeg: theta,
          at: start.add(Duration(milliseconds: i * stepMs)),
          timestampNanoseconds: i * stepMs * 1000000,
        );
      }
      expect(result.rotationRadiusM, isNull);
      expect(result.rotatingInPlace, isFalse);
    });

    test('beyond the raw excursion cap the compensation is refused', () {
      final monitor = RotationInPlaceMonitor(stationOrigin: origin);
      final result = bodyTurn(monitor, offsetM: 0.60, sweepDeg: 180);
      expect(result.withinAllowance, isFalse);
      expect(result.rotatingInPlace, isFalse);
      expect(result.effectiveDriftM, result.rawDriftM);
    });

    test(
      'leaving the predicted pivot path drops straight back to the raw gate',
      () {
        final monitor = RotationInPlaceMonitor(stationOrigin: origin);
        bodyTurn(monitor, offsetM: 0.40, sweepDeg: 90);
        // After the turn the operator slides 0.4 m sideways off the arc.
        var moved = const RotationInPlaceAssessment(
          rawDriftM: 0,
          effectiveDriftM: 0,
          rotatingInPlace: false,
          withinAllowance: true,
        );
        for (var i = 0; i < 8; i++) {
          moved = monitor.observe(
            position: vio.Vec3(0.40 + i * 0.05, 0, -0.40),
            yawDeg: 90,
            at: start.add(Duration(milliseconds: 2100 + i * stepMs)),
            timestampNanoseconds: (2100 + i * stepMs) * 1000000,
          );
        }
        expect(moved.rotatingInPlace, isFalse);
        expect(moved.effectiveDriftM, moved.rawDriftM);
      },
    );

    test('a tracking break invalidates the pivot model', () {
      final monitor = RotationInPlaceMonitor(stationOrigin: origin);
      bodyTurn(monitor, offsetM: 0.40, sweepDeg: 90);
      monitor.invalidate();
      final after = monitor.observe(
        position: const vio.Vec3(0.40, 0, -0.40),
        yawDeg: 90,
        at: start.add(const Duration(milliseconds: 900)),
        timestampNanoseconds: 900 * 1000000,
      );
      expect(after.rotatingInPlace, isFalse);
      expect(after.rotationRadiusM, isNull);
    });

    test('a sample-gap or timestamp discontinuity invalidates the model', () {
      final monitor = RotationInPlaceMonitor(stationOrigin: origin);
      bodyTurn(monitor, offsetM: 0.40, sweepDeg: 90);
      final after = monitor.observe(
        position: const vio.Vec3(0.40, 0, -0.40),
        yawDeg: 90,
        at: start.add(const Duration(milliseconds: 2600)),
        timestampNanoseconds: 2600 * 1000000,
      );
      // ~550 ms after the last turn sample: outside the continuity window.
      expect(after.rotatingInPlace, isFalse);
      expect(after.rotationRadiusM, isNull);
    });

    test('stopping mid-turn keeps the hold compensated and ready', () {
      final monitor = RotationInPlaceMonitor(stationOrigin: origin);
      bodyTurn(monitor, offsetM: 0.40, sweepDeg: 120);
      // The operator stops and holds. Raw drift stays ~0.69 m, so only the
      // verified pivot reference can keep the capture gate open.
      var held = const RotationInPlaceAssessment(
        rawDriftM: 0,
        effectiveDriftM: 0,
        rotatingInPlace: false,
        withinAllowance: true,
      );
      for (var i = 0; i < 20; i++) {
        held = monitor.observe(
          position: vio.Vec3(
            0.40 * math.sin(120 * math.pi / 180),
            0,
            0.40 * (math.cos(120 * math.pi / 180) - 1),
          ),
          yawDeg: 120,
          at: start.add(Duration(milliseconds: 2800 + i * stepMs)),
          timestampNanoseconds: (2800 + i * stepMs) * 1000000,
        );
      }
      expect(held.rotatingInPlace, isTrue);
      expect(held.compensationActive, isTrue);
      expect(held.effectiveDriftM, lessThan(0.05));
    });

    test('the engine gates on the pivot reference but still reports raw distance', () {
      final engine = vio.VioSphereEngine();
      engine.calibrateWithReference(stationOrigin: origin, stationYawRad: 0);
      const position = vio.Vec3(0.45, 0, 0);
      final pose = vio.VioPoseSample(
        position: position,
        rotation: const vio.Quat(0, 0, 0, 1),
        timestampNanoseconds: 0,
      );

      final strict = engine.evaluateFrame(
        pose: pose,
        trackingValid: true,
        activeTargetIndex: 0,
      );
      expect(strict.isWithinStation, isFalse);
      expect(strict.rawDriftM, closeTo(0.45, 1e-6));

      final compensated = engine.evaluateFrame(
        pose: pose,
        trackingValid: true,
        activeTargetIndex: 0,
        stationDriftReference: position,
      );
      expect(compensated.isWithinStation, isTrue);
      expect(compensated.stationDriftM, closeTo(0, 1e-6));
      expect(compensated.rawDriftM, closeTo(0.45, 1e-6));
    });
  });

  group('tourForPropertyDraft', () {
    test('returns the newest draft and ignores finished tours', () async {
      final repo = TourRepositoryImpl();
      const propertyId = 'MD-09999';

      final first = await repo.createDraft(
        propertyId: propertyId,
        title: 'First',
        frameCount: 3,
      );
      final second = await repo.createDraft(
        propertyId: propertyId,
        title: 'Second',
        frameCount: 0,
      );

      final resumable = await repo.tourForPropertyDraft(propertyId);
      expect(resumable, isNotNull);
      expect(resumable!.id, second.id);

      // A finished tour is never resumable.
      await repo.updateTour(
        second.copyWith(status: VirtualTourStatus.approved, published: true),
      );
      final afterApproval = await repo.tourForPropertyDraft(propertyId);
      expect(afterApproval!.id, first.id);

      await repo.updateTour(
        first.copyWith(status: VirtualTourStatus.pendingVerification),
      );
      expect(await repo.tourForPropertyDraft(propertyId), isNull);
    });

    test('a processing tour stays resumable', () async {
      final repo = TourRepositoryImpl();
      final tour = await repo.createDraft(
        propertyId: 'EP-00042',
        title: 'Interrupted stitch',
        frameCount: 26,
      );
      await repo.updateTour(
        tour.copyWith(status: VirtualTourStatus.processing),
      );
      final resumable = await repo.tourForPropertyDraft('EP-00042');
      expect(resumable?.id, tour.id);
    });
  });
}

/// Writes a one-byte JPEG placeholder at the repository's own frame path, which
/// is what `PhotoCaptureService` does before it records the frame.
Future<String> _writeFrame(
  SiteWiseCaptureRepository repo,
  String stationId,
  int targetId,
) async {
  final path = await repo.framePath(stationId, targetId);
  await File(path).writeAsBytes(<int>[0xFF, 0xD8, 0xFF, 0xD9], flush: true);
  return path;
}
