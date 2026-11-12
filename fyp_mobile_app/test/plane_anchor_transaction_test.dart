import 'package:flutter_test/flutter_test.dart';

import 'package:fyp/features/capture/data/services/plane_anchor_service.dart';
import 'package:fyp/features/capture/domain/services/station_frame.dart';
import 'package:fyp/features/capture/domain/services/target_sphere.dart';
import 'package:fyp/features/virtual_tour/domain/math/quaternions.dart';
import 'package:fyp/features/virtual_tour/domain/math/vectors.dart';
import 'package:fyp/features/virtual_tour/platform/arcore_ar.dart';
import 'package:fyp/features/virtual_tour/platform/ar_types.dart';

/// A gateway that answers only the calls `PlaneAnchorService` makes.
/// Everything else is a deliberate failure if it is ever reached.
class _FakeGateway implements ArCoreGateway {
  _FakeGateway({this.anchorOutcome});

  /// `null` → host refuses the anchor; a throwing closure → host throws.
  final Object? Function()? anchorOutcome;

  int createAnchorCalls = 0;
  final List<String> detachCalls = <String>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #createAnchor:
        createAnchorCalls++;
        final outcome = anchorOutcome?.call();
        if (outcome is ArCoreAnchor) return Future<ArCoreAnchor?>.value(outcome);
        return Future<ArCoreAnchor?>.value();
      case #detachAnchor:
        detachCalls.add(invocation.positionalArguments.first as String);
        return Future<void>.value();
      case #setScene:
        return Future<void>.value();
      case #refreshAnchor:
        return Future<ArCoreAnchor?>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

StationFrame _stationFrame() => StationFrame(
  origin: const Vec3(0, 1.4, 0),
  orientation: const Quat(0, 0, 0, 1),
);

void main() {
  const geometry = CaptureGeometryConfig();

  test('a successful calibration creates exactly one shared station anchor', () async {
    final gateway = _FakeGateway(
      anchorOutcome: () => ArCoreAnchor(
        id: 'station-anchor',
        worldPosition: const Vec3(0, 1.4, 0),
        tracking: TrackingState.tracking,
      ),
    );
    final service = PlaneAnchorService(gateway, geometry: geometry);

    final outcome = await service.placeAll(
      station: _stationFrame(),
      specs: buildCaptureSphere(),
    );

    expect(gateway.createAnchorCalls, 1, reason: 'one shared anchor, not 26');
    expect(outcome.allPlaced, isTrue);
    expect(outcome.placedCount, 26);
    for (var id = 1; id <= 26; id++) {
      expect(service.placementFor(id), isNotNull);
      expect(service.placementFor(id)!.anchor.id, 'station-anchor');
    }

    await service.releaseAll();
    expect(gateway.detachCalls, ['station-anchor']);
    expect(service.placedCount, 0);
  });

  test('a refused anchor fails the whole placement without orphans', () async {
    final gateway = _FakeGateway(anchorOutcome: () => null);
    final service = PlaneAnchorService(gateway, geometry: geometry);

    final outcome = await service.placeAll(
      station: _stationFrame(),
      specs: buildCaptureSphere(),
    );

    expect(outcome.allPlaced, isFalse);
    expect(outcome.placedCount, 0);
    expect(outcome.failures.length, 26);
    expect(service.placedCount, 0);
  });

  test('a throwing anchor creation fails without leaking a native anchor', () async {
    final gateway = _FakeGateway(
      anchorOutcome: () => throw StateError('session closed'),
    );
    final service = PlaneAnchorService(gateway, geometry: geometry);

    final outcome = await service.placeAll(
      station: _stationFrame(),
      specs: buildCaptureSphere(),
    );

    expect(outcome.allPlaced, isFalse);
    expect(outcome.placedCount, 0);
    expect(outcome.failures.values.first, contains('could not be created'));
    expect(service.placedCount, 0);
  });

  test('a partially unresolvable target set rolls back the created anchor', () async {
    final gateway = _FakeGateway(
      anchorOutcome: () => ArCoreAnchor(
        id: 'station-anchor',
        worldPosition: const Vec3(0, 0, 0),
        tracking: TrackingState.tracking,
      ),
    );
    final service = PlaneAnchorService(gateway, geometry: geometry);

    // A spec with a zero direction from a zero-origin station resolves to a
    // zero-length world position, which `resolveTarget` refuses. The placement
    // set is therefore incomplete and the whole transaction must roll back.
    final specs = buildCaptureSphere().toList();
    specs[7] = CaptureTargetSpec(
      targetId: 8,
      yawDegrees: 0,
      pitchDegrees: 0,
      ringName: 'Horizontal',
      direction: Vec3.zero,
    );

    final outcome = await service.placeAll(
      station: const StationFrame(
        origin: Vec3(0, 0, 0),
        orientation: Quat(0, 0, 0, 1),
      ),
      specs: specs,
    );

    expect(outcome.allPlaced, isFalse);
    // Nothing was committed: no placement survived the rollback.
    expect(service.placedCount, 0);
    // The freshly created anchor was detached again — no orphan.
    expect(gateway.detachCalls, ['station-anchor']);
  });

  test('overlapping placeAll calls serialise instead of double-creating', () async {
    final gateway = _FakeGateway(
      anchorOutcome: () => ArCoreAnchor(
        id: 'station-anchor',
        worldPosition: const Vec3(0, 1.4, 0),
        tracking: TrackingState.tracking,
      ),
    );
    final service = PlaneAnchorService(gateway, geometry: geometry);

    await Future.wait(<Future<PlacementOutcome>>[
      service.placeAll(station: _stationFrame(), specs: buildCaptureSphere()),
      service.placeAll(station: _stationFrame(), specs: buildCaptureSphere()),
    ]);

    expect(gateway.createAnchorCalls, 1);
    expect(service.placedCount, 26);
  });
}
