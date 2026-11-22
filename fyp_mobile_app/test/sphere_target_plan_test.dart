/// The 38-target capture plan contract (spec §5).
///
/// These tests pin the agreed target geometry so a future refactor cannot
/// silently change what the ARCore capture flow asks the user to photograph:
/// the middle ring is captured FIRST, rings sit at 0°/±40°, zenith and nadir
/// close the sphere, and every target id from 1 to 38 appears exactly once.
import 'package:flutter_test/flutter_test.dart';

import 'package:fyp/features/capture_360/domain/sphere/sphere_target.dart';

void main() {
  final targets = buildSphereTargets();

  test('the capture plan contains exactly 38 targets', () {
    expect(targets.length, kSphereTargetCount);
    expect(targets.map((t) => t.targetId).toList(), <int>[
      for (var id = 1; id <= 38; id++) id,
    ], reason: 'target ids run 1..38 exactly once — duplicate-target '
        'prevention and backend validation both rely on this');
  });

  test('ring layout: 12 middle at 0°, 12 upper at +40°, 12 lower at −40°', () {
    final middle = targets.where((t) => t.ringName == 'Middle Ring').toList();
    final upper = targets.where((t) => t.ringName == 'Upper Ring').toList();
    final lower = targets.where((t) => t.ringName == 'Lower Ring').toList();
    expect(middle.length, 12);
    expect(upper.length, 12);
    expect(lower.length, 12);
    expect(middle.every((t) => t.pitchDeg == 0), isTrue);
    expect(upper.every((t) => t.pitchDeg == kSphereRingPitchDeg), isTrue);
    expect(upper.every((t) => t.pitchDeg == 40), isTrue);
    expect(lower.every((t) => t.pitchDeg == -kSphereRingPitchDeg), isTrue);
    expect(lower.every((t) => t.pitchDeg == -40), isTrue);
  });

  test('zenith and nadir close the vertical coverage', () {
    final zenith = targets.where((t) => t.isZenith).toList();
    final nadir = targets.where((t) => t.isNadir).toList();
    expect(zenith.length, 1);
    expect(nadir.length, 1);
    expect(zenith.single.pitchDeg, 90);
    expect(nadir.single.pitchDeg, -90);
  });

  test('the middle ring is captured first', () {
    // The stitch/guide order is the target-id order; capture begins on the
    // horizon so the first frames establish exposure on the room.
    expect(targets.first.ringName, 'Middle Ring');
    expect(targets.first.pitchDeg, 0);
  });

  test('every ring yaw is unique so no direction is captured twice', () {
    for (final ring in ['Middle Ring', 'Upper Ring', 'Lower Ring']) {
      final yaws = targets
          .where((t) => t.ringName == ring)
          .map((t) => t.yawDeg)
          .toList();
      expect(yaws.toSet().length, yaws.length, reason: '$ring yaws');
    }
  });

  test('ring transitions stay inside a guided path length', () {
    // The documented vertical hops in the 0°/±40°/90° plan are exactly:
    //   middle → zenith 90°, zenith → upper 50°, upper → lower 80°,
    //   lower → nadir 50°. Nothing longer than 90° may ever appear.
    final pitches = <double>[
      for (final t in targets) t.pitchDeg,
    ];
    final hops = <double>[
      for (var i = 1; i < pitches.length; i++)
        (pitches[i] - pitches[i - 1]).abs(),
    ];
    expect(hops.where((h) => h > 1e-6).toSet(), <double>{90.0, 50.0, 80.0},
        reason: 'ring transitions match the agreed capture plan geometry');
    expect(hops.reduce((a, b) => a > b ? a : b), lessThanOrEqualTo(90.0));
  });
}
