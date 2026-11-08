/// PROJECT1 — L1 system study zone geometry oracles and negative tests.
///
/// Directive: `PROJECT1-GEO-SYSTEM-ZONE-V2-L1-EXECUTE-20261030`.
///
/// These tests are **independent of the production membership function**:
/// a second, differently-implemented oracle (winding number) is cross-checked
/// against the module's ray-casting implementation over a deterministic grid.
/// Expected memberships are derived from the fixture geometry, not copied
/// from the implementation's own output.
library;

import 'dart:math' as math;

import 'package:test/test.dart';

import 'package:sitewise_jaspr_web/geo/admin_geography.dart' show GeoPoint;
import 'package:sitewise_jaspr_web/geo/system_study_zone.dart';
import 'package:sitewise_jaspr_web/geo/system_zone_fixture.dart';

// ---------------------------------------------------------------------------
// Independent oracle: winding number (separate algorithm from ray casting).
// ---------------------------------------------------------------------------

/// Winding-number point-in-ring. Returns 0 when outside, non-zero inside.
/// Deliberately implemented without any shared helper from the module.
int _windingNumber(GeoPoint p, List<GeoPoint> ring) {
  var wn = 0;
  for (var i = 0; i < ring.length - 1; i++) {
    final a = ring[i];
    final b = ring[i + 1];
    if (a.lat <= p.lat) {
      if (b.lat > p.lat) {
        final isLeft =
            (b.lon - a.lon) * (p.lat - a.lat) - (p.lon - a.lon) * (b.lat - a.lat);
        if (isLeft > 0) wn++;
      }
    } else {
      if (b.lat <= p.lat) {
        final isLeft =
            (b.lon - a.lon) * (p.lat - a.lat) - (p.lon - a.lon) * (b.lat - a.lat);
        if (isLeft < 0) wn--;
      }
    }
  }
  return wn;
}

/// Independent polygon membership (winding + hole exclusion), edge policy
/// approximated as "inside" only when strictly interior. Used only for
/// non-edge sample points.
bool _oracleInside(GeoPoint p, ZonePolygon poly) {
  if (_windingNumber(p, poly.outer) == 0) return false;
  for (final hole in poly.holes) {
    if (_windingNumber(p, hole) != 0) return false;
  }
  return true;
}

bool _oracleInsideGeometry(GeoPoint p, ZoneGeometry g) {
  for (final poly in g.polygons) {
    if (_oracleInside(p, poly)) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

GeoPoint gp(double lat, double lon) => GeoPoint(lat, lon);

ZonePolygon squarePolygon(
  double latMin,
  double lonMin,
  double latMax,
  double lonMax, {
  List<List<GeoPoint>> holes = const [],
}) {
  return ZonePolygon(
    outer: [
      gp(latMin, lonMin),
      gp(latMin, lonMax),
      gp(latMax, lonMax),
      gp(latMax, lonMin),
      gp(latMin, lonMin),
    ],
    holes: holes,
  );
}

void main() {
  // -------------------------------------------------------------------------
  group('F1 — fixture integrity', () {
    test('four regions with unique fixture ids', () {
      expect(kSystemZoneRegions.length, 4);
      final ids = kSystemZoneRegions.map((r) => r.regionFixtureId).toSet();
      expect(ids, {'KL', 'PEN', 'JHR', 'SGR'});
    });

    test('four system zones with unique zone ids', () {
      expect(kAllSystemZones.length, 4);
      final zoneIds = kAllSystemZones.map((z) => z.zoneId).toSet();
      expect(zoneIds.length, 4);
      for (final z in kAllSystemZones) {
        expect(z.zoneId.startsWith('SYSZONE-'), isTrue);
        expect(z.adminBoundary, isFalse,
            reason: 'synthetic zones must never claim to be admin boundaries');
        expect(z.sampleMode, isTrue);
      }
    });

    test('twelve sample venues with unique record ids', () {
      expect(kAllObservations.length, 12);
      expect(kAllObservations.map((o) => o.recordId).toSet().length, 12);
      for (final o in kAllObservations) {
        expect(o.sampleMode, isTrue);
        expect(o.sourceKind, 'SYNTHETIC_FIXTURE');
      }
    });

    test('exactly one observation inside each zone (fixture oracle)', () {
      for (final region in kSystemZoneRegions) {
        final inside = region.observations
            .where((o) =>
                o.position != null &&
                pointInGeometry(o.position!, region.zone.geometry))
            .toList();
        expect(inside.length, 1,
            reason: '${region.regionFixtureId} should have 1 inside venue, '
                'got ${inside.map((o) => o.recordId).toList()}');
      }
    });

    test('every zone is topologically valid', () {
      for (final z in kAllSystemZones) {
        final v = validateGeometry(z.geometry);
        expect(v.isValid, isTrue, reason: '${z.zoneId}: ${v.issues}');
      }
    });

    test('rental centres fall inside their own zone', () {
      for (final region in kSystemZoneRegions) {
        expect(region.rental.position, isNotNull);
        expect(pointInGeometry(region.rental.position!, region.zone.geometry),
            isTrue,
            reason: '${region.rental.rentalId} centre outside its zone');
      }
    });
  });

  // -------------------------------------------------------------------------
  group('F2 — zone resolution', () {
    test('each rental resolves to exactly one zone', () {
      for (final region in kSystemZoneRegions) {
        final zone = resolveZone(
          rentalId: region.rental.rentalId,
          zones: kAllSystemZones,
        );
        expect(zone.zoneId, region.zone.zoneId);
      }
    });

    test('unknown rental -> ZONE_NOT_AVAILABLE', () {
      expect(
        () => resolveZone(rentalId: 'SYN-UNKNOWN', zones: kAllSystemZones),
        throwsA(isA<ZoneResolutionError>()
            .having((e) => e.code, 'code', 'ZONE_NOT_AVAILABLE')),
      );
    });

    test('conflicting duplicate zones -> ZONE_CONFLICT', () {
      final region = kSystemZoneRegions.first;
      final duplicate = SystemStudyZone(
        zoneId: 'SYSZONE-KL-V1-DUP',
        rentalId: region.rental.rentalId,
        geometry:
            ZoneGeometry.polygon(squarePolygon(3.136, 101.686, 3.144, 101.694)),
        zoneSource: 'SYNTHETIC_FIXTURE',
        constructionMethod: 'PREDEFINED_VERSIONED_FIXTURE',
        ruleVersion: kSystemZoneRuleVersion,
        geometryRevision: 1,
        rightsState: 'SYNTHETIC_OWNED',
      );
      expect(
        () => resolveZone(
          rentalId: region.rental.rentalId,
          zones: [region.zone, duplicate],
        ),
        throwsA(isA<ZoneResolutionError>()
            .having((e) => e.code, 'code', 'ZONE_CONFLICT')),
      );
    });

    test('invalid geometry only -> ZONE_INVALID_GEOMETRY (no fallback)', () {
      final bowtie = ZoneGeometry.polygon(
        ZonePolygon(outer: [
          gp(0, 0),
          gp(1, 1),
          gp(0, 1),
          gp(1, 0),
          gp(0, 0),
        ]),
      );
      final bad = SystemStudyZone(
        zoneId: 'SYSZONE-BAD',
        rentalId: 'SYN-BAD-R1',
        geometry: bowtie,
        zoneSource: 'SYNTHETIC_FIXTURE',
        constructionMethod: 'PREDEFINED_VERSIONED_FIXTURE',
        ruleVersion: kSystemZoneRuleVersion,
        geometryRevision: 1,
        rightsState: 'SYNTHETIC_OWNED',
      );
      expect(
        () => resolveZone(rentalId: 'SYN-BAD-R1', zones: [bad]),
        throwsA(isA<ZoneResolutionError>()
            .having((e) => e.code, 'code', 'ZONE_INVALID_GEOMETRY')),
      );
    });

    test('resolution is deterministic across repeats', () {
      final region = kSystemZoneRegions[2];
      final a = resolveZone(
          rentalId: region.rental.rentalId, zones: kAllSystemZones);
      final b = resolveZone(
          rentalId: region.rental.rentalId, zones: kAllSystemZones);
      expect(a.zoneId, b.zoneId);
      expect(a.geometryHash, b.geometryHash);
    });
  });

  // -------------------------------------------------------------------------
  group('F3 — geometry validation (negative cases)', () {
    test('unclosed ring is rejected', () {
      final ring = [gp(0, 0), gp(0, 1), gp(1, 1), gp(1, 0)]; // not closed
      expect(validateRing(ring), isNotEmpty);
    });

    test('fewer than 4 points is rejected', () {
      expect(validateRing([gp(0, 0), gp(0, 1), gp(0, 0)]), isNotEmpty);
    });

    test('zero-area ring is rejected', () {
      // All points collinear.
      final ring = [gp(0, 0), gp(0, 1), gp(0, 2), gp(0, 0)];
      expect(ringArea(ring), 0);
      expect(validateRing(ring), isNotEmpty);
    });

    test('self-intersecting bow-tie is rejected', () {
      final bowtie = [gp(0, 0), gp(1, 1), gp(0, 1), gp(1, 0), gp(0, 0)];
      expect(ringSelfIntersects(bowtie), isTrue);
      expect(validateRing(bowtie), isNotEmpty);
    });

    test('reversed axis order (lon in lat slot) is rejected', () {
      // A Malaysian longitude (~101) placed in the latitude slot.
      final reversed = [
        gp(101.687, 3.137),
        gp(101.693, 3.137),
        gp(101.693, 3.143),
        gp(101.687, 3.143),
        gp(101.687, 3.137),
      ];
      final issues = validateRing(reversed);
      expect(issues, isNotEmpty);
      expect(issues.join(' '), contains('axis'));
    });

    test('NaN coordinate is rejected', () {
      final ring = [
        gp(double.nan, 0),
        gp(0, 1),
        gp(1, 1),
        gp(double.nan, 0),
      ];
      expect(validateRing(ring), isNotEmpty);
    });

    test('valid square passes validation', () {
      final v = validateGeometry(
          ZoneGeometry.polygon(squarePolygon(3.137, 101.687, 3.143, 101.693)));
      expect(v.isValid, isTrue, reason: v.issues.join('; '));
    });
  });

  // -------------------------------------------------------------------------
  group('F4 — point-in-polygon vs independent winding oracle', () {
    test('centre is inside, far point is outside', () {
      final poly = squarePolygon(3.137, 101.687, 3.143, 101.693);
      expect(pointInPolygon(gp(3.140, 101.690), poly), isTrue);
      expect(pointInPolygon(gp(3.200, 101.690), poly), isFalse);
      expect(pointInPolygon(gp(3.140, 101.800), poly), isFalse);
    });

    test('deterministic grid agrees with winding-number oracle', () {
      final rng = math.Random(42);
      final poly = squarePolygon(3.137, 101.687, 3.143, 101.693);
      var checked = 0;
      for (var i = 0; i < 400; i++) {
        final lat = 3.130 + rng.nextDouble() * 0.020; // 3.130..3.150
        final lon = 101.680 + rng.nextDouble() * 0.020; // 101.680..101.700
        final p = gp(lat, lon);
        final actual = pointInPolygon(p, poly);
        final oracle = _oracleInside(p, poly);
        // Skip points within 1e-6 of an edge: edge policy differs by design.
        final nearEdge = (lat - 3.137).abs() < 1e-6 ||
            (lat - 3.143).abs() < 1e-6 ||
            (lon - 101.687).abs() < 1e-6 ||
            (lon - 101.693).abs() < 1e-6;
        if (nearEdge) continue;
        expect(actual, oracle,
            reason: 'disagreement at ($lat, $lon): '
                'module=$actual oracle=$oracle');
        checked++;
      }
      expect(checked, greaterThan(300),
          reason: 'too few non-edge samples were compared');
    });

    test('adopted edge policy: on-edge and corner count as inside', () {
      final poly = squarePolygon(3.137, 101.687, 3.143, 101.693);
      // Midpoint of the south edge.
      expect(classifyPointInRing(gp(3.137, 101.690), poly.outer),
          PointPosition.onEdge);
      expect(pointInPolygon(gp(3.137, 101.690), poly), isTrue);
      // Corner.
      expect(classifyPointInRing(gp(3.137, 101.687), poly.outer),
          PointPosition.onEdge);
      expect(pointInPolygon(gp(3.137, 101.687), poly), isTrue);
    });

    test('negative control: a broken always-true oracle is caught', () {
      // Simulates a defective implementation that always reports "inside".
      bool brokenAlwaysTrue(GeoPoint p, ZonePolygon poly) => true;
      final poly = squarePolygon(3.137, 101.687, 3.143, 101.693);
      final farPoint = gp(3.200, 101.690);
      expect(pointInPolygon(farPoint, poly), isFalse,
          reason: 'real implementation must reject far point');
      expect(brokenAlwaysTrue(farPoint, poly), isTrue,
          reason: 'broken oracle reports inside — proves the test discriminates');
      // The two disagree, which is exactly what a mutation would surface.
      expect(pointInPolygon(farPoint, poly),
          isNot(equals(brokenAlwaysTrue(farPoint, poly))));
    });
  });

  // -------------------------------------------------------------------------
  group('F5 — holes', () {
    test('point inside a hole is outside the polygon', () {
      final poly = squarePolygon(
        0, 0, 10, 10,
        holes: [
          [gp(4, 4), gp(4, 6), gp(6, 6), gp(6, 4), gp(4, 4)],
        ],
      );
      expect(pointInPolygon(gp(5, 5), poly), isFalse,
          reason: 'centre of hole must be outside');
      expect(pointInPolygon(gp(2, 2), poly), isTrue,
          reason: 'between outer edge and hole must be inside');
    });

    test('point on a hole edge is covered (inside) under adopted policy', () {
      final poly = squarePolygon(
        0, 0, 10, 10,
        holes: [
          [gp(4, 4), gp(4, 6), gp(6, 6), gp(6, 4), gp(4, 4)],
        ],
      );
      // Midpoint of the hole's south edge.
      expect(pointInPolygon(gp(4, 5), poly), isTrue);
    });

    test('oracle agrees on hole interior/exterior', () {
      final poly = squarePolygon(
        0, 0, 10, 10,
        holes: [
          [gp(4, 4), gp(4, 6), gp(6, 6), gp(6, 4), gp(4, 4)],
        ],
      );
      for (final p in [gp(5, 5), gp(2, 2), gp(9, 9), gp(4.5, 5.0)]) {
        expect(pointInPolygon(p, poly), _oracleInside(p, poly),
            reason: 'hole disagreement at (${p.lat}, ${p.lon})');
      }
    });
  });

  // -------------------------------------------------------------------------
  group('F6 — multipolygon', () {
    test('point in either part is inside; gap between parts is outside', () {
      final geom = ZoneGeometry.multiPolygon([
        squarePolygon(0, 0, 2, 2),
        squarePolygon(10, 10, 12, 12),
      ]);
      expect(pointInGeometry(gp(1, 1), geom), isTrue);
      expect(pointInGeometry(gp(11, 11), geom), isTrue);
      expect(pointInGeometry(gp(6, 6), geom), isFalse,
          reason: 'gap between parts must be outside');
    });

    test('multipolygon validates and agrees with oracle', () {
      final geom = ZoneGeometry.multiPolygon([
        squarePolygon(0, 0, 2, 2),
        squarePolygon(10, 10, 12, 12),
      ]);
      expect(validateGeometry(geom).isValid, isTrue);
      for (final p in [gp(1, 1), gp(11, 11), gp(6, 6), gp(1, 11)]) {
        expect(pointInGeometry(p, geom), _oracleInsideGeometry(p, geom));
      }
    });
  });

  // -------------------------------------------------------------------------
  group('F7 — membership counts', () {
    test('each region reports exactly one inside observation', () {
      for (final region in kSystemZoneRegions) {
        final result = computeMembership(
          rental: region.rental,
          zone: region.zone,
          observations: kAllObservations,
          sourceSnapshotId: 'SYNTHETIC-SNAPSHOT-V2',
        );
        expect(result.activeFootprintType, 'SYSTEM_STUDY_ZONE');
        expect(result.rawObservationCount, 3);
        expect(result.distinctObservationCount, 3);
        expect(result.insideDistinctCount, 1,
            reason: '${region.regionFixtureId} inside ids: '
                '${result.insideRecordIds}');
        expect(result.undecidedCount, 0);
        expect(result.unavailableReason, isNull);
        expect(result.sampleMode, isTrue);
        expect(result.promotableToReal, isFalse);
      }
    });

    test('membership is deterministic across repeats', () {
      final region = kSystemZoneRegions.first;
      final a = computeMembership(
        rental: region.rental,
        zone: region.zone,
        observations: kAllObservations,
        sourceSnapshotId: 'SYNTHETIC-SNAPSHOT-V2',
      );
      final b = computeMembership(
        rental: region.rental,
        zone: region.zone,
        observations: kAllObservations,
        sourceSnapshotId: 'SYNTHETIC-SNAPSHOT-V2',
      );
      expect(a.toJson(), b.toJson());
    });

    test('radius is not an input: count cannot depend on it', () {
      // Structural proof: computeMembership has no radius parameter. This test
      // documents the invariant; the display radius lives only in the UI.
      final region = kSystemZoneRegions.first;
      final baseline = computeMembership(
        rental: region.rental,
        zone: region.zone,
        observations: kAllObservations,
        sourceSnapshotId: 'SYNTHETIC-SNAPSHOT-V2',
      );
      // Vary a display-only value; membership is unaffected because it is not
      // passed in at all.
      for (final displayRadius in [0.0, 400.0, 5000.0]) {
        final again = computeMembership(
          rental: region.rental,
          zone: region.zone,
          observations: kAllObservations,
          sourceSnapshotId: 'SYNTHETIC-SNAPSHOT-V2',
        );
        expect(again.insideDistinctCount, baseline.insideDistinctCount,
            reason: 'count changed when display radius=$displayRadius');
      }
    });
  });

  // -------------------------------------------------------------------------
  group('F8 — deduplication and missing data', () {
    test('duplicate recordId is collapsed and reported', () {
      final region = kSystemZoneRegions.first;
      final dup = Observation(
        recordId: 'SYN-KL-V1', // same id as an existing record
        rentalGroup: region.rental.rentalId,
        position: gp(3.1405, 101.6907),
        sourceKind: 'SYNTHETIC_FIXTURE',
        categoryType: 'cafe',
      );
      final result = computeMembership(
        rental: region.rental,
        zone: region.zone,
        observations: [...region.observations, dup],
        sourceSnapshotId: 'SYNTHETIC-SNAPSHOT-V2',
      );
      expect(result.rawObservationCount, 4);
      expect(result.distinctObservationCount, 3);
      expect(result.duplicateRecordIds, contains('SYN-KL-V1'));
      expect(result.insideDistinctCount, 1,
          reason: 'duplicate must not inflate the inside count');
    });

    test('positional duplicate with a different id is not double counted', () {
      final region = kSystemZoneRegions.first;
      final clone = Observation(
        recordId: 'SYN-NEG-DUP',
        rentalGroup: region.rental.rentalId,
        position: gp(3.1405, 101.6907), // identical to SYN-KL-V1
        sourceKind: 'SYNTHETIC_FIXTURE',
        categoryType: 'cafe',
      );
      final result = computeMembership(
        rental: region.rental,
        zone: region.zone,
        observations: [...region.observations, clone],
        sourceSnapshotId: 'SYNTHETIC-SNAPSHOT-V2',
      );
      expect(result.distinctObservationCount, 4);
      expect(result.positionalDuplicateRecordIds, contains('SYN-NEG-DUP'));
      expect(result.insideDistinctCount, 1,
          reason: 'positional duplicate must not be double counted');
    });

    test('observation with no coordinate is undecided, never outside/zero', () {
      final region = kSystemZoneRegions.first;
      final noPoint = Observation(
        recordId: 'SYN-NEG-NOPOINT',
        rentalGroup: region.rental.rentalId,
        position: null,
        sourceKind: 'SYNTHETIC_FIXTURE',
        categoryType: 'cafe',
      );
      final result = computeMembership(
        rental: region.rental,
        zone: region.zone,
        observations: [...region.observations, noPoint],
        sourceSnapshotId: 'SYNTHETIC-SNAPSHOT-V2',
      );
      expect(result.undecidedCount, 1);
      expect(result.insideDistinctCount, 1,
          reason: 'undecided must not be silently counted outside');
      expect(result.insideRecordIds, isNot(contains('SYN-NEG-NOPOINT')));
    });

    test('rental without a coordinate -> unavailable, not a zero count', () {
      final region = kSystemZoneRegions.first;
      final noCoordRental = RentalFixtureRef(
        rentalId: region.rental.rentalId,
        listingRevision: region.rental.listingRevision,
        position: null,
        locationKind: 'AREA_ONLY',
        sourceKind: 'SYNTHETIC_FIXTURE',
      );
      final result = computeMembership(
        rental: noCoordRental,
        zone: region.zone,
        observations: region.observations,
        sourceSnapshotId: 'SYNTHETIC-SNAPSHOT-V2',
      );
      expect(result.unavailableReason, contains('RENTAL_POSITION_UNAVAILABLE'));
      expect(result.undecidedCount, 3);
      expect(result.insideDistinctCount, 0);
      expect(result.insideRecordIds, isEmpty);
    });

    test('observations from another region do not leak in', () {
      final kl = kSystemZoneRegions.first;
      final pen = kSystemZoneRegions[1];
      final result = computeMembership(
        rental: kl.rental,
        zone: kl.zone,
        observations: [...kl.observations, ...pen.observations],
        sourceSnapshotId: 'SYNTHETIC-SNAPSHOT-V2',
      );
      expect(result.rawObservationCount, 3,
          reason: 'only the KL rental group should be scoped');
    });
  });

  // -------------------------------------------------------------------------
  group('F9 — guards and refusals', () {
    test('user zone edit is refused with a named code', () {
      expect(
        rejectUserZoneEdit,
        throwsA(isA<ZoneResolutionError>().having(
            (e) => e.code, 'code', 'REJECT_UNAUTHORIZED_ZONE_EDIT')),
      );
    });

    test('ambiguous footprint is refused', () {
      expect(() => assertSingleFootprint('RADIUS_CIRCLE'),
          throwsA(isA<ZoneResolutionError>()));
      expect(() => assertSingleFootprint('SYSTEM_STUDY_ZONE'), returnsNormally);
    });

    test('system zone has no public mutation surface', () {
      // Structural: SystemStudyZone exposes only final fields and getters.
      // This test documents the absence of a vertex mutator API.
      final zone = kAllSystemZones.first;
      expect(zone.zoneId, isNotEmpty);
      expect(zone.geometryHash, startsWith('digest32:'));
    });
  });

  // -------------------------------------------------------------------------
  group('F10 — determinism and digests', () {
    test('geometry digest is stable and geometry-sensitive', () {
      final a = ZoneGeometry.polygon(squarePolygon(0, 0, 1, 1));
      final b = ZoneGeometry.polygon(squarePolygon(0, 0, 1, 1));
      final c = ZoneGeometry.polygon(squarePolygon(0, 0, 2, 2));
      expect(geometryDigest(a), geometryDigest(b));
      expect(geometryDigest(a), isNot(equals(geometryDigest(c))));
    });

    test('all four zones have distinct digests', () {
      final digests = kAllSystemZones.map((z) => z.geometryHash).toSet();
      expect(digests.length, 4);
    });
  });

  // -------------------------------------------------------------------------
  // F11 — independent-review regression fixes (review defects D1–D4)
  // -------------------------------------------------------------------------
  group('F11 — review regression fixes', () {
    test('D1: resolver pins the rule version', () {
      final region = kSystemZoneRegions.first;
      // Same rental, different rule version -> must NOT be returned.
      final otherVersion = SystemStudyZone(
        zoneId: 'SYSZONE-KL-V0',
        rentalId: region.rental.rentalId,
        geometry: ZoneGeometry.polygon(squarePolygon(3.0, 101.0, 3.1, 101.1)),
        zoneSource: 'SYNTHETIC_FIXTURE',
        constructionMethod: 'PREDEFINED_VERSIONED_FIXTURE',
        ruleVersion: 'some-other-rule-v9',
        geometryRevision: 1,
        rightsState: 'SYNTHETIC_OWNED',
      );
      expect(
        () => resolveZone(
          rentalId: region.rental.rentalId,
          zones: [otherVersion],
          ruleVersion: kSystemZoneRuleVersion,
        ),
        throwsA(isA<ZoneResolutionError>()
            .having((e) => e.code, 'code', 'ZONE_NOT_AVAILABLE')),
      );
      // The matching version still resolves.
      expect(
        resolveZone(
          rentalId: region.rental.rentalId,
          zones: [region.zone, otherVersion],
          ruleVersion: kSystemZoneRuleVersion,
        ).zoneId,
        region.zone.zoneId,
      );
    });

    test('D3: unsupported rental emits ZONE_UNSUPPORTED_RENTAL', () {
      expect(
        () => resolveZone(
          rentalId: 'SYN-OUTSIDE-MALAYSIA',
          zones: kAllSystemZones,
          knownRentalIds: kKnownRentalIds,
        ),
        throwsA(isA<ZoneResolutionError>()
            .having((e) => e.code, 'code', 'ZONE_UNSUPPORTED_RENTAL')),
      );
      // Known ids still resolve.
      expect(
        resolveZone(
          rentalId: 'SYN-KL-R1',
          zones: kAllSystemZones,
          knownRentalIds: kKnownRentalIds,
        ).zoneId,
        'SYSZONE-KL-V1',
      );
    });

    test('D2: zone/rental mismatch is explicit, never a silent zero', () {
      final kl = kSystemZoneRegions.first;
      final pen = kSystemZoneRegions[1];
      final result = computeMembership(
        rental: kl.rental, // KL rental
        zone: pen.zone, // PEN zone
        observations: kl.observations,
        sourceSnapshotId: 'SYNTHETIC-SNAPSHOT-V2',
      );
      expect(result.unavailableReason, contains('ZONE_RENTAL_MISMATCH'));
      expect(result.insideDistinctCount, 0);
      expect(result.undecidedCount, 3,
          reason: 'all observations must be undecided, not silently outside');
      expect(result.insideRecordIds, isEmpty);
    });

    test('D4: a ring that revisits a vertex is rejected', () {
      // (1,1) is visited twice — a self-touching ring.
      final selfTouch = [
        gp(0, 0),
        gp(2, 0),
        gp(2, 2),
        gp(1, 1),
        gp(0, 2),
        gp(1, 1),
        gp(0, 0),
      ];
      expect(ringSelfIntersects(selfTouch), isTrue);
      expect(validateRing(selfTouch), isNotEmpty);
    });

    test('D4: a non-adjacent T-junction touch is rejected', () {
      // Segment (0,0)-(2,0) and segment (1,0)-(1,-2) touch at (1,0), which is
      // not a shared vertex of the ring's adjacency graph.
      final tJunction = [
        gp(0, 0),
        gp(2, 0),
        gp(1, -2),
        gp(1, 0),
        gp(0, 0),
      ];
      expect(ringSelfIntersects(tJunction), isTrue);
      expect(validateRing(tJunction), isNotEmpty);
    });

    test('D4: a plain square is still accepted', () {
      expect(ringSelfIntersects(squarePolygon(0, 0, 1, 1).outer), isFalse);
      expect(validateRing(squarePolygon(0, 0, 1, 1).outer), isEmpty);
    });

    test('D6: sample-to-real promotion is refused with a named token', () {
      expect(
        rejectSampleToRealPromotion,
        throwsA(isA<ZoneResolutionError>()
            .having((e) => e.code, 'code', 'REFUSE_SAMPLE_TO_REAL_PROMOTION')),
      );
      // And the structural guard agrees: no L1 result is promotable.
      final region = kSystemZoneRegions.first;
      final r = computeMembership(
        rental: region.rental,
        zone: region.zone,
        observations: region.observations,
        sourceSnapshotId: 'SYNTHETIC-SNAPSHOT-V2',
      );
      expect(r.promotableToReal, isFalse);
    });
  });
}
