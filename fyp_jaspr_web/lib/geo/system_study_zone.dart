/// PROJECT1 — System-generated study zone (L1, sample-only) domain model.
///
/// Directive: `PROJECT1-GEO-SYSTEM-ZONE-V2-L1-EXECUTE-20261030`.
///
/// This module is **pure Dart** (no Jaspr, no Flutter, no I/O) so it can be
/// unit-tested with `package:test` and reused by the server-side renderer.
///
/// ## Non-negotiable semantics implemented here
///
///  * **No user polygon editor.** [SystemStudyZone] is system-owned and
///    read-only; there is no mutator, no vertex editing API and no
///    user-authored shape constructor. [rejectUserZoneEdit] exists only to
///    produce an explicit refusal for an attempted edit route.
///  * **Exactly one calculation footprint.** At L1 only
///    `SYSTEM_STUDY_ZONE` drives observation membership. The experimental
///    radius circle is **display-only**; [computeMembership] takes no radius
///    parameter at all, so a radius can never influence the count.
///  * **No fabricated fallback.** Failed resolution returns a named error
///    (`ZONE_NOT_AVAILABLE`, `ZONE_CONFLICT`, `ZONE_INVALID_GEOMETRY`,
///    `ZONE_UNSUPPORTED_RENTAL`). A rectangle is never synthesised.
///  * **Missing is not OUTSIDE.** An observation with no coordinate is
///    `undecided`, never counted as outside and never converted to zero.
///  * **Sample-only.** Every type carries `sampleMode`; there is no path from
///    a sample result to a real competitor finding.
///
/// ## Adopted L1 edge policy (explicit, tested)
///
/// `EDGE_INCLUSIVE_COVERS`: a point lying exactly on an outer ring edge is
/// **inside**; a point strictly inside a hole is **outside**; a point on a
/// hole edge is **inside** (the polygon covers its own boundary, including
/// hole boundaries). This is a documented L1 fixture oracle, not an adopted
/// production GIS policy.
library sitewise_jaspr_web.geo.system_study_zone;

import 'dart:math' as math;

import 'admin_geography.dart' show GeoPoint;

/// Default construction rule version for the synthetic square fixtures.
const String kSystemZoneRuleVersion = 'synthetic-squares-v1';

/// Tolerance (degrees) for exact-edge detection. ~0.1 mm at the equator.
const double kEdgeEpsilon = 1e-9;

/// Contract version stamped on every result.
const String kSystemZoneContractVersion = 'sample-v2-system-owned-zone';

// ---------------------------------------------------------------------------
// Position classification
// ---------------------------------------------------------------------------

/// Position of a point relative to a single ring.
enum PointPosition { inside, outside, onEdge }

/// Why a zone could not be resolved. Never a silent zero.
enum ZoneFailure {
  /// No zone fixture is registered for the requested rental.
  notAvailable,

  /// More than one valid zone claims the same rental (ambiguous assignment).
  conflict,

  /// A zone exists but its geometry fails validation (self-intersection,
  /// zero area, unclosed ring, reversed axis, out-of-range coordinate).
  invalidGeometry,

  /// The rental reference is not a known fixture (unsupported jurisdiction).
  unsupportedRental,
}

/// Explicit, named refusal raised instead of fabricating a zone or a count.
class ZoneResolutionError implements Exception {
  final ZoneFailure failure;
  final String code;
  final String message;

  const ZoneResolutionError(this.failure, this.code, this.message);

  @override
  String toString() => 'ZoneResolutionError($code): $message';
}

// ---------------------------------------------------------------------------
// Geometry primitives
// ---------------------------------------------------------------------------

/// One polygon: an outer ring plus zero or more holes. Rings are lat/lon
/// `GeoPoint` lists that must be explicitly closed (first == last).
class ZonePolygon {
  final List<GeoPoint> outer;
  final List<List<GeoPoint>> holes;

  const ZonePolygon({required this.outer, this.holes = const []});
}

/// A geometry that is either a single Polygon or a MultiPolygon.
class ZoneGeometry {
  /// `'Polygon'` or `'MultiPolygon'`.
  final String type;
  final List<ZonePolygon> polygons;

  const ZoneGeometry({required this.type, required this.polygons});

  factory ZoneGeometry.polygon(ZonePolygon p) =>
      ZoneGeometry(type: 'Polygon', polygons: [p]);

  factory ZoneGeometry.multiPolygon(List<ZonePolygon> ps) =>
      ZoneGeometry(type: 'MultiPolygon', polygons: ps);
}

/// Validation outcome for a geometry. `issues` is empty when valid.
class GeometryValidation {
  final bool isValid;
  final List<String> issues;

  const GeometryValidation(this.isValid, this.issues);

  static const GeometryValidation ok = GeometryValidation(true, []);
}

bool _approxEqual(double a, double b, [double eps = kEdgeEpsilon]) =>
    (a - b).abs() <= eps;

/// True when the ring's first and last points coincide.
bool isRingClosed(List<GeoPoint> ring) {
  if (ring.length < 2) return false;
  final a = ring.first;
  final b = ring.last;
  return _approxEqual(a.lat, b.lat) && _approxEqual(a.lon, b.lon);
}

/// Signed shoelace area in square degrees (absolute value is used for tests).
double ringSignedArea(List<GeoPoint> ring) {
  var sum = 0.0;
  for (var i = 0; i < ring.length - 1; i++) {
    sum += ring[i].lon * ring[i + 1].lat - ring[i + 1].lon * ring[i].lat;
  }
  return sum / 2.0;
}

double ringArea(List<GeoPoint> ring) => ringSignedArea(ring).abs();

bool _onSegment(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
) {
  final cross = (bx - ax) * (py - ay) - (by - ay) * (px - ax);
  if (cross.abs() > kEdgeEpsilon) return false;
  final minX = math.min(ax, bx);
  final maxX = math.max(ax, bx);
  final minY = math.min(ay, by);
  final maxY = math.max(ay, by);
  return px >= minX - kEdgeEpsilon &&
      px <= maxX + kEdgeEpsilon &&
      py >= minY - kEdgeEpsilon &&
      py <= maxY + kEdgeEpsilon;
}

int _orientation(
  double ax,
  double ay,
  double bx,
  double by,
  double cx,
  double cy,
) {
  final v = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
  if (v.abs() <= kEdgeEpsilon) return 0; // collinear
  return v > 0 ? 1 : -1;
}

bool _segmentsProperlyIntersect(
  GeoPoint a,
  GeoPoint b,
  GeoPoint c,
  GeoPoint d,
) {
  final o1 = _orientation(a.lon, a.lat, b.lon, b.lat, c.lon, c.lat);
  final o2 = _orientation(a.lon, a.lat, b.lon, b.lat, d.lon, d.lat);
  final o3 = _orientation(c.lon, c.lat, d.lon, d.lat, a.lon, a.lat);
  final o4 = _orientation(c.lon, c.lat, d.lon, d.lat, b.lon, b.lat);
  return o1 != o2 && o3 != o4 && o1 != 0 && o2 != 0 && o3 != 0 && o4 != 0;
}

/// True when two segments touch at all, including collinear overlap and a
/// shared endpoint. Used to reject self-touching rings (a vertex or edge that
/// revisits itself), which the "proper intersection" test alone would miss.
bool _segmentsTouch(GeoPoint a, GeoPoint b, GeoPoint c, GeoPoint d) {
  if (_segmentsProperlyIntersect(a, b, c, d)) return true;
  // Any endpoint lying on the other segment counts as a touch.
  if (_onSegment(c.lon, c.lat, a.lon, a.lat, b.lon, b.lat)) return true;
  if (_onSegment(d.lon, d.lat, a.lon, a.lat, b.lon, b.lat)) return true;
  if (_onSegment(a.lon, a.lat, c.lon, c.lat, d.lon, d.lat)) return true;
  if (_onSegment(b.lon, b.lat, c.lon, c.lat, d.lon, d.lat)) return true;
  return false;
}

/// True when a ring crosses **or touches** itself.
///
/// Adjacent segments share a vertex and are excluded, as is the closure pair.
/// Non-adjacent segments that merely touch at a shared vertex (a self-touching
/// ring, e.g. a figure-eight that revisits one point) are also rejected — a
/// "proper intersection" test alone would miss those.
bool ringSelfIntersects(List<GeoPoint> ring) {
  final n = ring.length;
  if (n < 4) return false;
  // A vertex visited twice (other than the closing duplicate) is degenerate.
  final seen = <String>{};
  for (var i = 0; i < n - 1; i++) {
    final key =
        '${ring[i].lat.toStringAsFixed(9)},${ring[i].lon.toStringAsFixed(9)}';
    if (!seen.add(key)) return true;
  }
  // Segments: (i, i+1) for i in [0, n-2].
  for (var i = 0; i <= n - 2; i++) {
    for (var j = i + 1; j <= n - 2; j++) {
      final adjacent = (j == i + 1) || (i == 0 && j == n - 2);
      if (adjacent) continue;
      if (_segmentsTouch(ring[i], ring[i + 1], ring[j], ring[j + 1])) {
        return true;
      }
    }
  }
  return false;
}

/// Validate one ring: closed, >= 4 points, in-range coordinates, non-zero
/// area, no self-intersection. Returns human-readable issues.
List<String> validateRing(List<GeoPoint> ring, {String label = 'ring'}) {
  final issues = <String>[];
  if (ring.length < 4) {
    issues.add('$label: fewer than 4 points (got ${ring.length})');
    return issues;
  }
  if (!isRingClosed(ring)) {
    issues.add('$label: ring is not closed (first != last)');
  }
  for (final p in ring) {
    if (p.lat.isNaN || p.lon.isNaN) {
      issues.add('$label: NaN coordinate');
      return issues;
    }
    // Reversed-axis guard: a Malaysian longitude (~100-104) placed in the
    // latitude slot exceeds 90 and is rejected here.
    if (p.lat < -90 || p.lat > 90) {
      issues.add('$label: latitude out of range (${p.lat}) — axis order?');
      return issues;
    }
    if (p.lon < -180 || p.lon > 180) {
      issues.add('$label: longitude out of range (${p.lon})');
      return issues;
    }
  }
  if (ringArea(ring) <= 0) {
    issues.add('$label: zero or negative area');
  }
  if (ringSelfIntersects(ring)) {
    issues.add('$label: self-intersecting ring');
  }
  return issues;
}

/// Validate a whole geometry (outer + holes for every polygon).
GeometryValidation validateGeometry(ZoneGeometry geometry) {
  final issues = <String>[];
  if (geometry.polygons.isEmpty) {
    issues.add('geometry: no polygons');
    return GeometryValidation(false, issues);
  }
  if (geometry.type == 'Polygon' && geometry.polygons.length != 1) {
    issues.add('geometry: Polygon must contain exactly one polygon');
  }
  for (var i = 0; i < geometry.polygons.length; i++) {
    final poly = geometry.polygons[i];
    issues.addAll(validateRing(poly.outer, label: 'polygon[$i].outer'));
    for (var h = 0; h < poly.holes.length; h++) {
      issues.addAll(
        validateRing(poly.holes[h], label: 'polygon[$i].hole[$h]'),
      );
    }
  }
  return GeometryValidation(issues.isEmpty, issues);
}

// ---------------------------------------------------------------------------
// Point-in-polygon (adopted EDGE_INCLUSIVE_COVERS policy)
// ---------------------------------------------------------------------------

/// Classify a point against a single ring.
PointPosition classifyPointInRing(GeoPoint p, List<GeoPoint> ring) {
  final n = ring.length;
  for (var i = 0, j = n - 1; i < n; j = i++) {
    if (_onSegment(
      p.lon,
      p.lat,
      ring[j].lon,
      ring[j].lat,
      ring[i].lon,
      ring[i].lat,
    )) {
      return PointPosition.onEdge;
    }
  }
  // Ray casting (even-odd) along +longitude.
  var inside = false;
  for (var i = 0, j = n - 1; i < n; j = i++) {
    final xi = ring[i].lon, yi = ring[i].lat;
    final xj = ring[j].lon, yj = ring[j].lat;
    final straddles = (yi > p.lat) != (yj > p.lat);
    if (straddles) {
      final xAtY = (xj - xi) * (p.lat - yi) / (yj - yi) + xi;
      if (p.lon < xAtY) inside = !inside;
    }
  }
  return inside ? PointPosition.inside : PointPosition.outside;
}

/// Membership of a point in one polygon under EDGE_INCLUSIVE_COVERS.
bool pointInPolygon(GeoPoint p, ZonePolygon polygon) {
  final outerPos = classifyPointInRing(p, polygon.outer);
  if (outerPos == PointPosition.outside) return false;
  // inside or onEdge of the outer ring => candidate.
  for (final hole in polygon.holes) {
    final holePos = classifyPointInRing(p, hole);
    if (holePos == PointPosition.inside) return false; // strictly inside hole
    // onEdge of a hole: polygon covers its own boundary -> remains inside.
  }
  return true;
}

/// Membership of a point in a (possibly multi-) polygon geometry.
bool pointInGeometry(GeoPoint p, ZoneGeometry geometry) {
  for (final poly in geometry.polygons) {
    if (pointInPolygon(p, poly)) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Deterministic content digest (non-cryptographic)
// ---------------------------------------------------------------------------

/// Deterministic content digest of a geometry. This is an identity/version
/// helper, **not** a cryptographic signature or an attestation.
///
/// Uses a polynomial rolling hash modulo a Mersenne prime (2^31-1) so the
/// arithmetic stays exact on both the Dart VM and JavaScript.
String geometryDigest(ZoneGeometry geometry) {
  final buf = StringBuffer();
  void ring(List<GeoPoint> r) {
    for (final p in r) {
      buf
        ..write(p.lat.toStringAsFixed(6))
        ..write(',')
        ..write(p.lon.toStringAsFixed(6))
        ..write(';');
    }
    buf.write('|');
  }

  buf.write(geometry.type);
  buf.write('#');
  for (final poly in geometry.polygons) {
    ring(poly.outer);
    for (final hole in poly.holes) {
      ring(hole);
    }
    buf.write('/');
  }
  return 'digest32:${_rollingHash(buf.toString())}';
}

const int _rollingMod = 2147483647; // 2^31 - 1 (Mersenne prime)

String _rollingHash(String s) {
  var h = 0;
  for (var i = 0; i < s.length; i++) {
    h = (h * 131 + s.codeUnitAt(i)) % _rollingMod;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

// ---------------------------------------------------------------------------
// Contract types
// ---------------------------------------------------------------------------

/// Stable reference to a synthetic rental fixture. Never a real rental.
class RentalFixtureRef {
  final String rentalId;
  final String listingRevision;
  final GeoPoint? position;
  final String locationKind;
  final String sourceKind;
  final bool sampleMode;

  const RentalFixtureRef({
    required this.rentalId,
    required this.listingRevision,
    required this.position,
    required this.locationKind,
    required this.sourceKind,
    this.sampleMode = true,
  });
}

/// System-owned, read-only study zone. There is deliberately **no** mutator,
/// no vertex setter and no user constructor for arbitrary geometry.
class SystemStudyZone {
  final String zoneId;
  final String rentalId;
  final ZoneGeometry geometry;
  final String zoneSource;
  final String constructionMethod;
  final String ruleVersion;
  final int geometryRevision;
  final String rightsState;
  final bool sampleMode;
  final bool adminBoundary;

  const SystemStudyZone({
    required this.zoneId,
    required this.rentalId,
    required this.geometry,
    required this.zoneSource,
    required this.constructionMethod,
    required this.ruleVersion,
    required this.geometryRevision,
    required this.rightsState,
    this.sampleMode = true,
    this.adminBoundary = false,
  });

  /// Deterministic digest of the geometry, recomputed from the data.
  String get geometryHash => geometryDigest(geometry);
}

/// One sample observation (a synthetic "competitor" venue row).
class Observation {
  final String recordId;
  final String rentalGroup;
  final GeoPoint? position;
  final String sourceKind;
  final String categoryType;
  final bool sampleMode;
  final String branchVerificationState;
  final String? observedAt;

  const Observation({
    required this.recordId,
    required this.rentalGroup,
    required this.position,
    required this.sourceKind,
    required this.categoryType,
    this.sampleMode = true,
    this.branchVerificationState = 'NOT_VERIFIED_SYNTHETIC',
    this.observedAt,
  });
}

/// Result of a zone membership query. Exactly one footprint type is active.
class QueryResult {
  final String rentalId;
  final String zoneId;
  final String zoneHash;
  final String activeFootprintType; // always 'SYSTEM_STUDY_ZONE' at L1
  final String ruleVersion;
  final String sourceSnapshotId;
  final int rawObservationCount;
  final int distinctObservationCount;
  final int insideDistinctCount;
  final int undecidedCount;
  final List<String> insideRecordIds;
  final List<String> duplicateRecordIds;
  final List<String> positionalDuplicateRecordIds;
  final String? unavailableReason;
  final bool sampleMode;
  final String contractVersion;

  const QueryResult({
    required this.rentalId,
    required this.zoneId,
    required this.zoneHash,
    required this.activeFootprintType,
    required this.ruleVersion,
    required this.sourceSnapshotId,
    required this.rawObservationCount,
    required this.distinctObservationCount,
    required this.insideDistinctCount,
    required this.undecidedCount,
    required this.insideRecordIds,
    required this.duplicateRecordIds,
    required this.positionalDuplicateRecordIds,
    required this.unavailableReason,
    required this.sampleMode,
    required this.contractVersion,
  });

  /// True only when a real (non-sample) result could be promoted. Always
  /// false at L1 — this is the hard sample/real boundary.
  bool get promotableToReal => !sampleMode;

  Map<String, Object?> toJson() => {
        'rental_id': rentalId,
        'zone_id': zoneId,
        'zone_hash': zoneHash,
        'active_footprint_type': activeFootprintType,
        'rule_version': ruleVersion,
        'source_snapshot_id': sourceSnapshotId,
        'raw_observation_count': rawObservationCount,
        'distinct_observation_count': distinctObservationCount,
        'inside_distinct_count': insideDistinctCount,
        'undecided_count': undecidedCount,
        'inside_record_ids': insideRecordIds,
        'duplicate_record_ids': duplicateRecordIds,
        'positional_duplicate_record_ids': positionalDuplicateRecordIds,
        'unavailable_reason': unavailableReason,
        'sample_mode': sampleMode,
        'contract_version': contractVersion,
      };
}

// ---------------------------------------------------------------------------
// Resolver
// ---------------------------------------------------------------------------

/// Resolve the single valid system zone for [rentalId] under [ruleVersion].
///
/// Resolution is pinned by **both** the stable rental id and the rule version.
/// Rejects zero matches, conflicting matches, invalid geometry and (when
/// [knownRentalIds] is supplied) an unsupported rental reference, each with a
/// named [ZoneResolutionError]. Never fabricates a rectangle.
SystemStudyZone resolveZone({
  required String rentalId,
  required List<SystemStudyZone> zones,
  String ruleVersion = kSystemZoneRuleVersion,
  Set<String>? knownRentalIds,
}) {
  // Unsupported jurisdiction / rental reference.
  if (knownRentalIds != null && !knownRentalIds.contains(rentalId)) {
    throw ZoneResolutionError(
      ZoneFailure.unsupportedRental,
      'ZONE_UNSUPPORTED_RENTAL',
      'Rental "$rentalId" is not part of the supported four-region L1 '
      'fixture set (KL, PEN, JHR, SGR). No other area\'s zone may be used.',
    );
  }

  // Rule-version pinning: only zones constructed by the requested rule version
  // may be considered.
  final candidates = zones
      .where((z) => z.rentalId == rentalId && z.ruleVersion == ruleVersion)
      .toList(growable: false);
  if (candidates.isEmpty) {
    final anyVersion = zones.any((z) => z.rentalId == rentalId);
    throw ZoneResolutionError(
      ZoneFailure.notAvailable,
      'ZONE_NOT_AVAILABLE',
      anyVersion
          ? 'No system zone for rental "$rentalId" under rule version '
              '"$ruleVersion".'
          : 'No system zone fixture is registered for rental "$rentalId".',
    );
  }

  final valid = <SystemStudyZone>[];
  final invalidIssues = <String>[];
  for (final zone in candidates) {
    final validation = validateGeometry(zone.geometry);
    if (validation.isValid) {
      valid.add(zone);
    } else {
      invalidIssues.add('${zone.zoneId}: ${validation.issues.join('; ')}');
    }
  }

  if (valid.isEmpty) {
    throw ZoneResolutionError(
      ZoneFailure.invalidGeometry,
      'ZONE_INVALID_GEOMETRY',
      'Every candidate zone for "$rentalId" failed validation: '
      '${invalidIssues.join(' | ')}',
    );
  }
  if (valid.length > 1) {
    throw ZoneResolutionError(
      ZoneFailure.conflict,
      'ZONE_CONFLICT',
      'Conflicting zone assignment for "$rentalId": '
      '${valid.map((z) => z.zoneId).join(', ')}',
    );
  }
  return valid.single;
}

/// Explicit refusal for any attempted user edit of a system zone (A04).
///
/// There is no code path that mutates a zone; this exists so an attempted
/// edit route produces a named refusal rather than a silent no-op.
Never rejectUserZoneEdit() {
  throw const ZoneResolutionError(
    ZoneFailure.conflict,
    'REJECT_UNAUTHORIZED_ZONE_EDIT',
    'System study zones are system-owned and read-only at L1. '
    'User draw/edit/drag/delete of polygon geometry is not permitted.',
  );
}

/// Explicit refusal for any attempt to promote a sample result to a real
/// competitor finding (fixture negative case `REFUSE_SAMPLE_TO_REAL_PROMOTION`).
///
/// L1 results are structurally non-promotable (`QueryResult.promotableToReal`
/// is always `false`); this exists so an attempted promotion produces a named
/// refusal rather than a silent pass-through into a report path.
Never rejectSampleToRealPromotion() {
  throw const ZoneResolutionError(
    ZoneFailure.conflict,
    'REFUSE_SAMPLE_TO_REAL_PROMOTION',
    'A synthetic sample result cannot be promoted to a real competitor '
    'finding. Real evidence requires an approved source, rights and a report '
    'authority (L4).',
  );
}

/// Guard: the active footprint must be exactly one type (A10).
void assertSingleFootprint(String activeFootprintType) {
  if (activeFootprintType != 'SYSTEM_STUDY_ZONE') {
    throw ZoneResolutionError(
      ZoneFailure.conflict,
      'REFUSE_AMBIGUOUS_FOOTPRINT',
      'At L1 the only permitted calculation footprint is '
      'SYSTEM_STUDY_ZONE (got "$activeFootprintType").',
    );
  }
}

// ---------------------------------------------------------------------------
// Membership
// ---------------------------------------------------------------------------

/// Compute observation membership for [rental] inside [zone].
///
/// **No radius parameter exists.** The experimental radius circle is
/// display-only and structurally cannot change this count (A10).
///
/// Dedup rule (established for L1): exact `recordId` duplicates are collapsed
/// and reported in [QueryResult.duplicateRecordIds]; distinct record IDs that
/// share an identical rounded position are reported in
/// [QueryResult.positionalDuplicateRecordIds] and are not double-counted.
QueryResult computeMembership({
  required RentalFixtureRef rental,
  required SystemStudyZone zone,
  required List<Observation> observations,
  required String sourceSnapshotId,
}) {
  assertSingleFootprint('SYSTEM_STUDY_ZONE');

  final scoped = observations
      .where((o) => o.rentalGroup == rental.rentalId)
      .toList(growable: false);

  // A zone that belongs to a different rental must never be silently applied:
  // that would yield a plausible-looking zero. Report it explicitly instead.
  if (zone.rentalId != rental.rentalId) {
    return QueryResult(
      rentalId: rental.rentalId,
      zoneId: zone.zoneId,
      zoneHash: zone.geometryHash,
      activeFootprintType: 'SYSTEM_STUDY_ZONE',
      ruleVersion: zone.ruleVersion,
      sourceSnapshotId: sourceSnapshotId,
      rawObservationCount: scoped.length,
      distinctObservationCount: scoped.map((o) => o.recordId).toSet().length,
      insideDistinctCount: 0,
      undecidedCount: scoped.length,
      insideRecordIds: const [],
      duplicateRecordIds: const [],
      positionalDuplicateRecordIds: const [],
      unavailableReason:
          'ZONE_RENTAL_MISMATCH: zone "${zone.zoneId}" belongs to rental '
          '"${zone.rentalId}", not "${rental.rentalId}". No count is emitted.',
      sampleMode: true,
      contractVersion: kSystemZoneContractVersion,
    );
  }

  // A rental with no coordinate cannot decide inside/outside for anyone.
  if (rental.position == null) {
    return QueryResult(
      rentalId: rental.rentalId,
      zoneId: zone.zoneId,
      zoneHash: zone.geometryHash,
      activeFootprintType: 'SYSTEM_STUDY_ZONE',
      ruleVersion: zone.ruleVersion,
      sourceSnapshotId: sourceSnapshotId,
      rawObservationCount: scoped.length,
      distinctObservationCount: scoped.map((o) => o.recordId).toSet().length,
      insideDistinctCount: 0,
      undecidedCount: scoped.length,
      insideRecordIds: const [],
      duplicateRecordIds: const [],
      positionalDuplicateRecordIds: const [],
      unavailableReason:
          'RENTAL_POSITION_UNAVAILABLE: rental has no certified coordinate, '
          'so no observation can be classified inside or outside.',
      sampleMode: true,
      contractVersion: kSystemZoneContractVersion,
    );
  }

  final seenIds = <String>{};
  final duplicateIds = <String>[];
  final positionalDuplicates = <String>[];
  final seenPositions = <String>{};
  final insideIds = <String>[];
  var undecided = 0;

  for (final obs in scoped) {
    if (obs.position == null) {
      undecided++;
      continue;
    }
    if (!seenIds.add(obs.recordId)) {
      duplicateIds.add(obs.recordId);
      continue;
    }
    final pos = obs.position!;
    if (!pointInGeometry(pos, zone.geometry)) {
      continue;
    }
    final posKey =
        '${pos.lat.toStringAsFixed(6)},${pos.lon.toStringAsFixed(6)}';
    if (!seenPositions.add(posKey)) {
      positionalDuplicates.add(obs.recordId);
      continue;
    }
    insideIds.add(obs.recordId);
  }

  return QueryResult(
    rentalId: rental.rentalId,
    zoneId: zone.zoneId,
    zoneHash: zone.geometryHash,
    activeFootprintType: 'SYSTEM_STUDY_ZONE',
    ruleVersion: zone.ruleVersion,
    sourceSnapshotId: sourceSnapshotId,
    rawObservationCount: scoped.length,
    distinctObservationCount: seenIds.length,
    insideDistinctCount: insideIds.length,
    undecidedCount: undecided,
    insideRecordIds: List.unmodifiable(insideIds),
    duplicateRecordIds: List.unmodifiable(duplicateIds),
    positionalDuplicateRecordIds: List.unmodifiable(positionalDuplicates),
    unavailableReason: null,
    sampleMode: true,
    contractVersion: kSystemZoneContractVersion,
  );
}
