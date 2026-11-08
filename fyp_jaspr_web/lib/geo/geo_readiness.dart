/// WF-07 geographic completeness and readiness model (GEO-DEV-C01).
///
/// Directive: `PROJECT1-GEO-DEV-C01-WF07-READINESS-CORRECTION-20261030`.
///
/// This file extends the existing synthetic `RentalCentre` / `AdminArea` /
/// `CentreDecision` / `GeometryState` model with **completeness and
/// operation-readiness** predicates. Each predicate is an independent,
/// explainable status with a reason code and a remediation action — never a
/// single global "ready" or percentage.
///
/// The model is pure Dart (no Jaspr imports) so it can be unit-tested with
/// `package:test` and shared by both the server-side readiness checker and the
/// client-side page renderer.
library sitewise_jaspr_web.geo.geo_readiness;

import 'admin_geography.dart';
import 'geometry_contract.dart';
import 'synthetic_rentals.dart';

// ---------------------------------------------------------------------------
// Per-check status vocabulary (correction doc §3, table rows)
// ---------------------------------------------------------------------------

/// Independent status for a single geographic check on a single rental.
///
/// The status is never just "yes/no": it carries a machine-readable code,
/// a human explanation, the required input that is missing (if any) and a
/// remediation action. `present` is never conflated with `validated` or
/// `ready`.
class CheckStatus {
  final String code;
  final String explanation;
  final String? missingInput;
  final String? remediationAction;
  final bool inputPresent;
  final bool validated;
  final bool ready;

  const CheckStatus({
    required this.code,
    required this.explanation,
    this.missingInput,
    this.remediationAction,
    required this.inputPresent,
    required this.validated,
    required this.ready,
  });

  /// Convenience: `WITHHELD` + a reason, keeping the rental visible.
  factory CheckStatus.withheld(String reason, String? remediationAction) =>
      CheckStatus(
        code: 'WITHHELD',
        explanation: reason,
        remediationAction: remediationAction,
        inputPresent: false,
        validated: false,
        ready: false,
      );

  /// Convenience: `ELIGIBLE` / `DISPLAY_PERMITTED` / `READY_FOR_OPERATION`.
  factory CheckStatus.eligible(String code, String explanation) =>
      CheckStatus(
        code: code,
        explanation: explanation,
        inputPresent: true,
        validated: true,
        ready: true,
      );
}

/// Operation-level readiness rows (correction doc §3 item 4).
enum GeoOperation {
  mapPreview,
  adminAreaLabel,
  adminPolygonDisplay,
  rentalRadiusQuery,
  competitorList,
  crossRentalCount,
}

/// Human-readable label + explanation for a `GeoOperation`.
class OperationRow {
  final GeoOperation op;
  final String label;
  final String description;
  const OperationRow(this.op, this.label, this.description);
}

const List<OperationRow> kOperationRows = [
  OperationRow(GeoOperation.mapPreview, 'MAP_PREVIEW',
      'Synthetic map + markers/circles rendered on OSM basemap tiles only.'),
  OperationRow(GeoOperation.adminAreaLabel, 'ADMIN_AREA_LABEL',
      'Administrative tier name/identity surfaced (label only, no polygon).'),
  OperationRow(GeoOperation.adminPolygonDisplay, 'ADMIN_POLYGON_DISPLAY',
      'Administrative boundary polygon drawn (requires verified licence + parent + feature count).'),
  OperationRow(GeoOperation.rentalRadiusQuery, 'RENTAL_RADIUS_QUERY',
      'Circle-based proximity query for nearby businesses (requires adopted radius policy + tolerance).'),
  OperationRow(GeoOperation.competitorList, 'COMPETITOR_LIST',
      'Competitor premises list returned under accepted GM-12 source (snapshot + rights).'),
  OperationRow(GeoOperation.crossRentalCount, 'CROSS_RENTAL_COUNT',
      'Cross-rental competitor counts compared (requires matching source release + method + coverage).'),
];

/// Status for a single operation row.
///
/// `AVAILABLE` — the operation can be performed with adopted evidence.
/// `PREVIEW_ONLY` — only synthetic/preview is possible; no adopted source.
/// `WITHHELD` — the operation is explicitly withheld with a reason.
/// `NOT_EVALUATED` — not yet considered.
enum OperationStatus {
  available,
  previewOnly,
  withheld,
  notEvaluated,
}

const Map<OperationStatus, String> kOperationStatusBadge = {
  OperationStatus.available: 'AVAILABLE',
  OperationStatus.previewOnly: 'PREVIEW_ONLY',
  OperationStatus.withheld: 'WITHHELD',
  OperationStatus.notEvaluated: 'NOT_EVALUATED',
};

const Map<OperationStatus, String> kOperationStatusTone = {
  OperationStatus.available: 'success',
  OperationStatus.previewOnly: 'warn',
  OperationStatus.withheld: 'danger',
  OperationStatus.notEvaluated: 'neutral',
};

/// A single operation-status row in the readiness matrix.
class OperationReadiness {
  final GeoOperation op;
  final OperationStatus status;
  final String reason;
  final String? remediationAction;

  const OperationReadiness({
    required this.op,
    required this.status,
    required this.reason,
    this.remediationAction,
  });
}

// ---------------------------------------------------------------------------
// Engineering release readiness (correction doc §3 item 5)
// ---------------------------------------------------------------------------

/// Engineering readiness levels, kept separate from per-rental geometry.
///
/// L0  — documentary: policy, contracts, rules pinned.
/// L1  — tested Jaspr: local component/unit tests pass under the test runner.
/// L2  — real teammate rental integration: real coordinate pipeline wired.
/// L3  — licensed real competitor evidence: approved GM-12 source connected.
enum EngineeringLevel { l0, l1, l2, l3 }

class EngineeringEntry {
  final EngineeringLevel level;
  final String label;
  final String requiredEvidence;
  final bool achieved;
  final String status;
  final String explanation;

  const EngineeringEntry({
    required this.level,
    required this.label,
    required this.requiredEvidence,
    required this.achieved,
    required this.status,
    required this.explanation,
  });
}

/// L0–L3 status as of this increment. L2/L3 are WITHHELD — never marked READY.
const List<EngineeringEntry> kEngineeringReadiness = [
  EngineeringEntry(
    level: EngineeringLevel.l0,
    label: 'L0 — Documentary',
    requiredEvidence:
        'GEO-DEV-C01 directive, GEOH-03 §7 contracts, GM-GEO-01..15 rules, '
        'BL-1..4 gates, GM-12 absence states',
    achieved: true,
    status: 'PROPOSED',
    explanation:
        'All governing documents are pinned in geo_readiness.dart and the '
        'synthetic fixtures. Pending Owner adoption of GEOHD second-pass '
        'rules — not production-ready.',
  ),
  EngineeringEntry(
    level: EngineeringLevel.l1,
    label: 'L1 — Tested Jaspr',
    requiredEvidence:
        'Unit tests + component tests pass (dart test) under Jaspr.',
    achieved: true,
    status: 'PARTIAL',
    explanation:
        'Data-model predicates and the page component are covered by tests. '
        'Browser-level interactive-map tests are NOT executed in this '
        'environment (WebSocket daemon blocked).',
  ),
  EngineeringEntry(
    level: EngineeringLevel.l2,
    label: 'L2 — Real teammate rental integration',
    requiredEvidence:
        'Real coordinate pipeline wired to BC-05 rental-selection data.',
    achieved: false,
    status: 'WITHHELD',
    explanation:
        'BC-05 rental-selection is a teammate workflow, not modified here. '
        'No real coordinate provenance exists — only SYN-A/B/C fixtures.',
  ),
  EngineeringEntry(
    level: EngineeringLevel.l3,
    label: 'L3 — Licensed real competitor evidence',
    requiredEvidence:
        'Approved GM-12 competitor source (snapshot + rights + completeness).',
    achieved: false,
    status: 'WITHHELD',
    explanation:
        'Competitor source snapshot = NO_COMPETITOR_SNAPSHOT. Rights '
        'unverified. No evidence may enter any report or comparison path.',
  ),
];

// ---------------------------------------------------------------------------
// Per-rental completeness model
// ---------------------------------------------------------------------------

/// Aggregated completeness status for one synthetic rental across all checks.
///
/// Built by [computeRentalReadiness] from the existing `RentalCentre` fixture
/// and the synthetic admin-area list. Each field below maps to a row in
/// correction-document §3 table.
class RentalReadiness {
  final RentalCentre rental;

  /// Check 1 — Location/provenance
  final CheckStatus position;

  /// Check 2 — Administrative identity (per-tier labels)
  final Map<GeoAdminTier, CheckStatus> adminIdentity;

  /// Check 3 — Polygon display
  final CheckStatus polygonDisplay;

  /// Check 4 — Study footprint
  final CheckStatus footprint;

  /// Check 5 — Competitor evidence
  final CheckStatus competitor;

  /// Check 6 — Cross-rental comparison
  final CheckStatus comparison;

  const RentalReadiness({
    required this.rental,
    required this.position,
    required this.adminIdentity,
    required this.polygonDisplay,
    required this.footprint,
    required this.competitor,
    required this.comparison,
  });

  /// Whether the rental has enough data to display a map marker.
  bool get markerDisplayable {
    final c = classifyCentre(rental);
    return c.canDraw;
  }

  /// Whether the experimental circle can be shown for this rental.
  bool get circleDisplayable => markerDisplayable;
}

// ---------------------------------------------------------------------------
// Completeness predicates
// ---------------------------------------------------------------------------

/// Check 1: Location/provenance evaluation.
///
/// A rental is `ELIGIBLE_FOR_SPECIFIED_OPERATION` only when it has:
///  * a recognised `CentreClass` (not `areaOnly` or `listingPin`),
///  * non-null latitude/longitude,
///  * a documented `positionSource`,
///  * a non-null `accuracyMetres >= 0`,
///  * and for `building` centres, a non-null `entranceOffsetBoundMetres >= 0`.
///
/// Returns a [CheckStatus] with `WITHHELD` on failure, keeping the rental
/// visible in the UI.
CheckStatus evaluatePosition(RentalCentre r) {
  if (r.kind == CentreClass.areaOnly) {
    return CheckStatus.withheld(
      'Area name only; no premises-specific circle or distance. '
      'An area-only locality cannot carry a certified premises circle.',
      'Provide a premises or building coordinate to enable a study radius.',
    );
  }
  if (r.kind == CentreClass.listingPin) {
    return CheckStatus.withheld(
      'Listing pin is not certified as the premises. '
      'A listing pin may differ from the actual entrance.',
      'Request a premises-level coordinate or building entrance offset.',
    );
  }
  if (r.latitude == null ||
      r.longitude == null ||
      r.positionSource == null ||
      r.accuracyMetres == null ||
      r.accuracyMetres! < 0) {
    return CheckStatus.withheld(
      'Coordinates, provenance and numeric accuracy must all be documented.',
      'Supply a coordinate source, coordinate version, and accuracy bound.',
    );
  }
  if (r.latitude! < -90 ||
      r.latitude! > 90 ||
      r.longitude! < -180 ||
      r.longitude! > 180) {
    return CheckStatus.withheld(
      'Invalid geographic coordinate (latitude or longitude out of range).',
      'Correct coordinate values to valid lat/lon ranges.',
    );
  }
  if (r.kind == CentreClass.building && r.entranceOffsetBoundMetres == null) {
    return CheckStatus.withheld(
      'Building centre lacks a documented entrance-offset bound.',
      'Provide entranceOffsetBoundMetres for building-class centres.',
    );
  }
  if (r.kind == CentreClass.building && r.entranceOffsetBoundMetres! < 0) {
    return CheckStatus.withheld(
      'Invalid entrance-offset bound (negative value).',
      'Correct the entrance-offset bound to a non-negative value.',
    );
  }
  return CheckStatus.eligible(
    'ELIGIBLE_FOR_SPECIFIED_OPERATION',
    'Synthetic geometry preview only; rental accuracy is not independently '
    'certified. Coordinate source: ${r.positionSource}.',
  );
}

/// Check 3: Polygon display evaluation for a given admin tier.
///
/// A real polygon is `LAYER_WITHHELD` unless every gate holds:
///   BL-1  real boundary present
///   BL-2  display rights established
///   BL-3  parent district verified
///   BL-4  feature-count check passes
///
/// For the synthetic demonstrator, `polygonRenderable` is true only when the
/// fixture is `synthetic && watermarked && syntheticPolygon != null` — and even
/// then the result is watermarked synthetic, never a real boundary.
CheckStatus evaluatePolygonDisplay(AdminArea area) {
  if (!area.polygonRenderable) {
    // Distinguish absent geometry from unvalidated geometry.
    if (area.geometryState == GeometryState.absent) {
      return CheckStatus.withheld(
        '${area.name} has no polygon geometry for this tier.',
        'Obtain a boundary fixture for the ${tierLabel(area.tier)} tier.',
      );
    }
    if (area.geometryState == GeometryState.unvalidated) {
      if (!area.synthetic || !area.watermarked) {
        return CheckStatus.withheld(
          'Polygon exists but is not validated/licensed for display '
          '(rights unverified, parent district not verified).',
          'Complete BL-1..4 gates: licence, rights, parent link, feature count.',
        );
      }
      // Synthetic but NOT renderable — e.g. missing syntheticPolygon list.
      return CheckStatus.withheld(
        'Synthetic polygon fixture is incomplete.',
        'Supply a complete watermarked syntheticPolygon fixture for display.',
      );
    }
    return CheckStatus.withheld(
      'Polygon state unknown.',
      'Inspect GeometryState for this tier.',
    );
  }
  // polygonRenderable is true — synthetic + watermarked + has polygon.
  return CheckStatus.eligible(
    'DISPLAY_PERMITTED',
    'Synthetic, watermarked polygon is renderable for UI development only. '
    'Real boundary licence (BL-1..4) is unmet — do not export or use for '
    'membership (Rule G-1).',
  );
}

/// Check 4: Study footprint evaluation.
///
/// The radius policy is `PROPOSED_FOR_OWNER_ADOPTION` — not adopted. The
/// experimental 0.5 m tolerance is a labelled example, never a default.
/// A radius request above 5 000 m is refused (GM-GEO-15), never silently
/// clamped.
CheckStatus evaluateFootprint(RentalCentre r, double? requestedRadius) {
  final pos = evaluatePosition(r);
  if (!pos.ready) {
    return CheckStatus.withheld(
      'Study radius requires an eligible centre coordinate.',
      'Resolve position/provenance before a radius can be computed.',
    );
  }
  if (requestedRadius == null) {
    return CheckStatus.withheld(
      'No study radius requested.',
      'Specify a radius (experimental preview options: 400 / 500 / 800 / '
      '1200 m). No production policy is adopted — preview only.',
    );
  }
  try {
    validateRadius(requestedRadius);
  } on RangeError {
    return CheckStatus.withheld(
      'Requested radius ($requestedRadius m) is outside the supported range '
      '(0 < r <= ${maximumDemonstratorRadiusMetres.toInt()} m). '
      'Explicitly refused, not clamped (GM-GEO-15).',
      'Reduce the radius to within 0 and 5 000 m, or await Owner adoption of '
      'a production policy.',
    );
  }
  return CheckStatus.eligible(
    'PREVIEW_ONLY',
    'Experimental radius ${requestedRadius.toInt()} m with '
    'tolerance=$experimentalBoundaryToleranceMetres m '
    '(GM-GEO-14, NOT ADOPTED). Spherical haversine (R\u2298 = '
    '${meanEarthRadiusMetres.toInt()} m). Preview only — no production '
    'policy is in force.',
  );
}

/// Check 5: Competitor evidence evaluation.
///
/// Uses [competitorState] from the existing fixture. S1 = source unavailable.
CheckStatus evaluateCompetitor(VenueSnapshot? snapshot) {
  final state = competitorState(snapshot);
  return switch (state) {
    CompetitorState.s1 => CheckStatus.withheld(
        'No approved displayable competitor source is connected '
        '(GM-12 S1).',
        'Connect an approved competitor snapshot with display rights '
        'established.',
      ),
    CompetitorState.s2 => CheckStatus.withheld(
        'Competitor source query failed (GM-12 S2).',
        'Resolve source query failure before drawing conclusions.',
      ),
    CompetitorState.s3 => CheckStatus.withheld(
        'Nearby-businesses not queried (GM-12 S3 — no premises established).',
        'Establish a certified premises coordinate to enable querying.',
      ),
    CompetitorState.s4 => CheckStatus.withheld(
        'No competitor records returned; coverage unknown (GM-12 S4).',
        'Attest completeness of the query coverage before treating'
        ' absence as evidence.',
      ),
    CompetitorState.s5 => CheckStatus.withheld(
        'No competitor records returned; coverage is partial (GM-12 S5).',
        'Obtain complete coverage for this observation window.',
      ),
    CompetitorState.s6 => CheckStatus.eligible(
        'SOURCE_OBSERVATIONS_AVAILABLE',
        'Competitor records: 0. Source supplied a dated completeness '
        'statement (GM-12 S6).',
      ),
    CompetitorState.s7 => CheckStatus.eligible(
        'SOURCE_OBSERVATIONS_AVAILABLE',
        'Competitor records returned (GM-12 S7). These are dataset records,'
        ' not a complete census or a suitability verdict.',
      ),
  };
}

/// Check 6: Cross-rental comparison evaluation.
///
/// Comparison is only permitted when the adopted GM-12 policy, source release,
/// method, radius, coverage and rights are all aligned across rentals. With
/// the current synthetic-only, single-snapshot setup the comparison is
/// `COMPARISON_WITHHELD`.
CheckStatus evaluateComparison(RentalReadiness a, RentalReadiness b) {
  // E2_DESC / E2* policy unresolved → comparison withheld.
  if (!a.competitor.ready || !b.competitor.ready) {
    return CheckStatus.withheld(
      'Cross-rental comparison requires both rentals to have available '
      'competitor source observations. At least one rental lacks an '
      'approved source (GM-12).',
      'Supply matching approved competitor snapshots for both rentals '
      'before comparing counts.',
    );
  }
  // Even with both sources "available", the comparison contract (E2_DESC,
  // matching source release, matching geometry, documented dedup, matching
  // coverage/rights) is UNADOPTED_POLICY in this cycle.
  return CheckStatus.withheld(
    'E2_DESC / E2* boundary-partition and cross-candidate comparison '
    'policy is UNADOPTED_POLICY (GEOH-03 §12, GEOHD second-pass). '
    'Comparison remains withheld despite individual source availability.',
    'Await Owner adoption of the corrected GM-12 Option B / E2_DESC '
    'comparison contract.',
  );
}

// ---------------------------------------------------------------------------
// Aggregation
// ---------------------------------------------------------------------------

/// Human-readable tier label for UI display.
String tierLabel(GeoAdminTier tier) => switch (tier) {
      GeoAdminTier.stateFt => 'State / Federal Territory',
      GeoAdminTier.district => 'District',
      GeoAdminTier.mukim => 'Mukim',
    };

/// Evaluate all six checks for one rental and return the aggregated
/// [RentalReadiness]. The competitor snapshot is synthetic-only (S1) by
/// default; callers may pass a real snapshot once L3 is achieved.
RentalReadiness computeRentalReadiness(
  RentalCentre rental, {
  double? requestedRadius,
  VenueSnapshot? competitorSnapshot,
}) {
  // Check 1: Position/provenance
  final position = evaluatePosition(rental);

  // Check 2: Administrative identity (per tier)
  final adminIdentity = <GeoAdminTier, CheckStatus>{};
  for (final area in kSyntheticAdminAreas) {
    if (area.tier == GeoAdminTier.district && area.jurisdictionNotApplicable) {
      adminIdentity[area.tier] = CheckStatus(
        code: 'NOT_APPLICABLE',
        explanation: 'Federal territory has no district tier (Rule G-5). '
            'Place code "NA-DISTRICT" is a placeholder, not a real code.',
        inputPresent: true,
        validated: true,
        ready: true,
      );
    } else if (area.tierIdentityResolved) {
      adminIdentity[area.tier] = CheckStatus(
        code: area.displayLabel == AdminDisplayLabel.verified
            ? 'VERIFIED'
            : area.displayLabel == AdminDisplayLabel.partial
                ? 'PARTIAL'
                : 'NAME_ONLY',
        explanation: _adminExplanation(area),
        inputPresent: true,
        validated:
            area.displayLabel == AdminDisplayLabel.verified ||
            area.displayLabel == AdminDisplayLabel.partial ||
            area.displayLabel == AdminDisplayLabel.named,
        ready: area.displayLabel == AdminDisplayLabel.verified,
      );
    } else {
      adminIdentity[area.tier] = CheckStatus.withheld(
        'Administrative identity for ${tierLabel(area.tier)} is not resolved.',
        'Supply area code and authority-verified name for this tier.',
      );
    }
  }

  // Check 3: Polygon display (per tier, using the first matching AdminArea)
  final ftArea = kSyntheticAdminAreas.firstWhere(
    (a) => a.tier == GeoAdminTier.stateFt,
    orElse: () => throw StateError('stateFt fixture missing'),
  );
  final polygonDisplay = evaluatePolygonDisplay(ftArea);

  // Check 4: Footprint
  final footprint = evaluateFootprint(rental, requestedRadius);

  // Check 5: Competitor evidence
  final competitor = evaluateCompetitor(competitorSnapshot);

  return RentalReadiness(
    rental: rental,
    position: position,
    adminIdentity: adminIdentity,
    polygonDisplay: polygonDisplay,
    footprint: footprint,
    competitor: competitor,
    comparison: CheckStatus.withheld(
      'Not evaluated for this rental in isolation.',
      'Compare against another rental via the cross-rental readiness view.',
    ),
  );
}

String _adminExplanation(AdminArea area) {
  switch (area.displayLabel) {
    case AdminDisplayLabel.verified:
      return 'Boundary polygon is validated and licensed (BL-1..4 all hold).';
    case AdminDisplayLabel.partial:
      return 'Identity resolved but polygon is UNVALIDATED (not licensed for '
          'display). Boundary exists but rights unverified (Rule G-4).';
    case AdminDisplayLabel.named:
      return 'Name identity only — no polygon geometry available '
          '(${area.geometryState.name}).';
    case AdminDisplayLabel.unresolved:
      return 'Administrative identity is not resolved for this tier.';
    case AdminDisplayLabel.notApplicable:
      return area.provenanceNote ??
          'This tier does not exist in the jurisdiction (Rule G-4/G-5).';
  }
}

/// Compute the [OperationReadiness] matrix for a given rental.
///
/// Each row maps a `GeoOperation` to a `PREVIEW_ONLY` / `WITHHELD` /
/// `AVAILABLE` status with a reason tied to the underlying check evidence.
List<OperationReadiness> computeOperationMatrix(RentalReadiness r) {
  return [
    // MAP_PREVIEW — always preview-only with synthetic markers.
    OperationReadiness(
      op: GeoOperation.mapPreview,
      status: r.markerDisplayable
          ? OperationStatus.previewOnly
          : OperationStatus.withheld,
      reason: r.markerDisplayable
          ? 'OSM basemap tiles + synthetic marker/circle from '
              'data-geo JSON. Browser must demonstrate tile attribution, '
              'marker selection, keyboard navigation and refusal text.'
          : 'Rental has no eligible coordinate; map preview withheld.',
      remediationAction: r.markerDisplayable ? null : r.position.remediationAction,
    ),
    // ADMIN_AREA_LABEL — label is always available from synthetic fixtures.
    OperationReadiness(
      op: GeoOperation.adminAreaLabel,
      status: OperationStatus.previewOnly,
      reason: 'Administrative tier names are surfaced from synthetic fixtures. '
          'Label identity only — no real boundary polygon is licensed (BL-1..4 unmet).',
    ),
    // ADMIN_POLYGON_DISPLAY — only when polygonDisplay is eligible.
    OperationReadiness(
      op: GeoOperation.adminPolygonDisplay,
      status: r.polygonDisplay.ready
          ? OperationStatus.previewOnly
          : OperationStatus.withheld,
      reason: r.polygonDisplay.ready
          ? 'Synthetic watermarked polygon is renderable for UI development only.'
          : r.polygonDisplay.explanation,
      remediationAction: r.polygonDisplay.remediationAction,
    ),
    // RENTAL_RADIUS_QUERY — only when footprint is eligible and radius is valid.
    OperationReadiness(
      op: GeoOperation.rentalRadiusQuery,
      status: r.footprint.ready
          ? OperationStatus.previewOnly
          : OperationReadiness(
              op: GeoOperation.rentalRadiusQuery,
              status: OperationStatus.withheld,
              reason: r.footprint.explanation,
              remediationAction: r.footprint.remediationAction,
            ).status,
      reason: r.footprint.ready
          ? 'Experimental radius with adopted-only policy pending. '
              'Spherical haversine; no real proximity verdict issued.'
          : r.footprint.explanation,
      remediationAction: r.footprint.remediationAction,
    ),
    // COMPETITOR_LIST — only with accepted GM-12 source.
    OperationReadiness(
      op: GeoOperation.competitorList,
      status: r.competitor.ready
          ? OperationStatus.available
          : OperationStatus.withheld,
      reason: r.competitor.ready
          ? 'Approved competitor source is connected.'
          : r.competitor.explanation,
      remediationAction: r.competitor.remediationAction,
    ),
    // CROSS_RENTAL_COUNT — only under adopted E2* comparison policy.
    OperationReadiness(
      op: GeoOperation.crossRentalCount,
      status: OperationStatus.withheld,
      reason: 'E2_DESC / E2* comparison policy is UNADOPTED_POLICY. '
          'Even with accepted sources individually, cross-rental counts '
          'are withheld pending corrected geometry/precedence rules.',
      remediationAction:
          'Await Owner adoption of GM-12 Option B / E2_DESC comparison contract.',
    ),
  ];
}

/// The default synthetic competitor snapshot (S1 — no source connected).
const VenueSnapshot kNoCompetitorSnapshot = VenueSnapshot(
  snapshotId: 'NO_COMPETITOR_SNAPSHOT',
  source: 'none',
  sourceRelease: 'none',
  coverage: CoverageClass.unknown,
  sourceAnswered: false,
  queryFailed: false,
  displayRightsEstablished: false,
  areaResolved: false,
  hasWrittenCompletenessStatement: false,
  recordCount: 0,
);

/// Convenience: compute readiness for all three synthetic rentals at once.
List<RentalReadiness> computeAllRentalReadiness() {
  return [
    for (final r in syntheticRentalCentres)
      computeRentalReadiness(
        r,
        requestedRadius: 800,
        competitorSnapshot: null, // S1 — no source
      ),
  ];
}
