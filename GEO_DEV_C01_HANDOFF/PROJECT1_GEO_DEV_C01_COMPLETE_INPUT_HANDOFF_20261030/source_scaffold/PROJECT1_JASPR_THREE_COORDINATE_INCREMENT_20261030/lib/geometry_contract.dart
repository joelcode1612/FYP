/// Project1 geographic/report demonstration domain.
///
/// Research basis: ODR3_DECISION_DELTA_20261030, GM_12_COMPETITOR_ABSENCE_STATES.
/// Contract status: PROPOSED / SYNTHETIC ONLY. Not an approved study radius,
/// competitor data source, rental coordinate, production implementation or report.
/// Maintainer: Project1 geographic and report integration teams (assignment pending).
import 'dart:math' as math;

const double meanEarthRadiusMetres = 6371000.0;
const double maximumDemonstratorRadiusMetres = 5000.0;

/// An example only: F-2 requires an Owner-adopted boundary policy.
/// No geographic result using this experimental tolerance is reportable.
const double experimentalBoundaryToleranceMetres = 0.5;

enum CentreClass { premises, building, listingPin, areaOnly }
enum CoverageClass { unknown, partial, complete }
enum CompetitorState { s1, s2, s3, s4, s5, s6, s7 }

class RentalCentre {
  final String rentalId;
  final String label;
  final String locality;
  final CentreClass kind;
  final double? latitude;
  final double? longitude;
  final double? accuracyMetres;
  final double? entranceOffsetBoundMetres;
  final String? positionSource;
  final String? coordinateVersion;
  final bool synthetic;

  const RentalCentre({
    required this.rentalId,
    required this.label,
    required this.locality,
    required this.kind,
    this.latitude,
    this.longitude,
    this.accuracyMetres,
    this.entranceOffsetBoundMetres,
    this.positionSource,
    this.coordinateVersion,
    this.synthetic = true,
  });
}

class CentreDecision {
  final bool canDraw;
  final String explanation;
  const CentreDecision(this.canDraw, this.explanation);
}

CentreDecision classifyCentre(RentalCentre r) {
  if (r.kind == CentreClass.areaOnly) {
    return const CentreDecision(false, 'Area name only; no premises-specific circle or distance.');
  }
  if (r.kind == CentreClass.listingPin) {
    return const CentreDecision(false, 'Listing pin is not certified as the premises.');
  }
  if (r.latitude == null || r.longitude == null || r.positionSource == null || r.accuracyMetres == null || r.accuracyMetres! < 0) {
    return const CentreDecision(false, 'Coordinates, provenance and numeric accuracy must all be documented.');
  }
  if (r.latitude! < -90 || r.latitude! > 90 || r.longitude! < -180 || r.longitude! > 180) {
    return const CentreDecision(false, 'Invalid geographic coordinate.');
  }
  if (r.kind == CentreClass.building && r.entranceOffsetBoundMetres == null) {
    return const CentreDecision(false, 'Building centre lacks a documented entrance-offset bound.');
  }
  if (r.kind == CentreClass.building && r.entranceOffsetBoundMetres! < 0) {
    return const CentreDecision(false, 'Invalid entrance-offset bound.');
  }
  return const CentreDecision(true, 'Synthetic geometry preview only; rental accuracy is not independently certified.');
}

/// Reject a requested radius outside this prototype's supported range.
/// Never silently clamp a request (ODR-3 D-1).
double validateRadius(double radiusMetres) {
  if (!radiusMetres.isFinite || radiusMetres <= 0 || radiusMetres > maximumDemonstratorRadiusMetres) {
    throw RangeError('Unsupported study radius; request explicitly refused rather than clamped.');
  }
  return radiusMetres;
}

double haversineMetres(double lat1, double lon1, double lat2, double lon2) {
  double radians(double d) => d * math.pi / 180.0;
  final latDelta = radians(lat2 - lat1);
  final lonDelta = radians(lon2 - lon1);
  final a = math.pow(math.sin(latDelta / 2), 2) +
      math.cos(radians(lat1)) * math.cos(radians(lat2)) *
      math.pow(math.sin(lonDelta / 2), 2);
  final safeA = (a as num).toDouble().clamp(0.0, 1.0);
  return 2 * meanEarthRadiusMetres * math.asin(math.sqrt(safeA));
}

/// Experimental tolerance is explicitly passed, not hidden.
/// A positive real-world proximity result requires an adopted tolerance and R.
bool withinCircle(double measuredMetres, double studyRadiusMetres, {required double toleranceMetres}) {
  validateRadius(studyRadiusMetres);
  if (!measuredMetres.isFinite || measuredMetres < 0 || !toleranceMetres.isFinite || toleranceMetres < 0) {
    throw RangeError('Invalid distance or boundary tolerance.');
  }
  return measuredMetres <= studyRadiusMetres + toleranceMetres;
}

/// Versioned downloaded-source record. DO NOT fill this using scraped websites
/// until the ODR-4 rights review and H-F feasibility gate permit the source.
class VenueSnapshot {
  final String snapshotId;
  final String source;
  final String sourceRelease;
  final DateTime? queriedAt;
  final DateTime? retrievedAt;
  final DateTime? sourceAsOf;
  final CoverageClass coverage;
  final bool sourceAnswered;
  final bool queryFailed;
  final bool displayRightsEstablished;
  final bool areaResolved;
  final bool hasWrittenCompletenessStatement;
  final int recordCount;

  const VenueSnapshot({
    required this.snapshotId,
    required this.source,
    required this.sourceRelease,
    this.queriedAt,
    this.retrievedAt,
    this.sourceAsOf,
    required this.coverage,
    required this.sourceAnswered,
    required this.queryFailed,
    required this.displayRightsEstablished,
    required this.areaResolved,
    required this.hasWrittenCompletenessStatement,
    required this.recordCount,
  });
}

/// Canonical GM-12: state depends on rights/query/coverage, NOT only item count.
CompetitorState competitorState(VenueSnapshot? snapshot) {
  if (snapshot == null || !snapshot.displayRightsEstablished) return CompetitorState.s1;
  if (!snapshot.areaResolved) return CompetitorState.s3;
  if (snapshot.queryFailed) return CompetitorState.s2;
  if (!snapshot.sourceAnswered) return CompetitorState.s2;
  if (snapshot.recordCount < 0) throw StateError('Invalid record count');
  if (snapshot.recordCount > 0) return CompetitorState.s7;
  if (snapshot.coverage == CoverageClass.partial) return CompetitorState.s5;
  if (snapshot.coverage == CoverageClass.complete && snapshot.hasWrittenCompletenessStatement) return CompetitorState.s6;
  return CompetitorState.s4;
}

/// The report body and provenance are separate accessible components under
/// ODR-V21A-07/-08/-09; never place dates/digits inside S1--S5 state body.
String absenceBody(CompetitorState state, {int? count}) {
  switch (state) {
    case CompetitorState.s1:
      return 'Competitor data unavailable. No approved displayable source is connected. This says nothing about nearby businesses.';
    case CompetitorState.s2:
      return 'Competitor data unavailable. The source query failed. No market conclusion can be drawn.';
    case CompetitorState.s3:
      return 'Nearby businesses not queried. A suitable premises location has not been established.';
    case CompetitorState.s4:
      return 'No records returned by the source. Coverage is unknown; the absence of records is not a finding about local businesses.';
    case CompetitorState.s5:
      return 'No records returned by the source. Coverage is partial and the result cannot establish absence.';
    case CompetitorState.s6:
      return 'Competitor records: 0. The source has supplied a specific dated completeness statement.';
    case CompetitorState.s7:
      if (count == null || count < 1) throw StateError('S7 requires a positive record count');
      return 'Competitor records: $count. These are dataset records, not a complete census or a suitability verdict.';
  }
}

/// A compare-count cannot be emitted merely because circles have equal R.
/// Reject incomplete/unknown coverage even when both are tagged UNKNOWN.
bool mayDisplayCrossCandidateCounts({
  required bool sameMethodAndRadius,
  required bool sameVersionedSource,
  required bool sameObservationWindow,
  required bool bothDisplayable,
  required bool bothHaveDocumentedCompleteness,
}) => sameMethodAndRadius && sameVersionedSource && sameObservationWindow && bothDisplayable && bothHaveDocumentedCompleteness;
