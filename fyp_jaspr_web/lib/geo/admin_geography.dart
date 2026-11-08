/// Administrative geography model for the GEO-DEV-C01 synthetic demonstrator.
///
/// Implements GEOH-03 "Administrative, district/mukim and geometry contract"
/// (`PROPOSED_FOR_OWNER_ADOPTION`) using **synthetic fixtures only**. The four
/// real-polygon gates (BL-1 lineage, BL-2 source rights, BL-3 parent linkage,
/// BL-4 feature counts) are **all unmet for real data** (GEOH-03 §7: today
/// `geometry_state = G_NO` for every tier), so no real boundary is ever drawn.
///
/// Adopted, synthetic-only ideas (Rule G-1/G-2 non-substitution, G-4, G-9,
/// G-10, G-12):
///  * `verified | partial | named | unresolved | notApplicable` are five
///    **disjoint, total** predicates (Rule G-9) — colour is never the only
///    channel; an icon + outline style is provided alongside the badge.
///  * The tier graph is per-jurisdiction; `notApplicable` (a jurisdiction fact)
///    is never collapsed with `unresolved` (a data fact) — Rule G-4.
///  * Parents are never inferred from names, adjacency, centroids, postcodes or
///    a synthetic coordinate — Rule G-10. A missing parent renders
///    `Parent district: not verified`.
///  * Identity and geometry are separate axes — Rule G-22.
///
/// UNADOPTED_POLICY (held back pending corrected GEOHD second-pass specs):
///  * disputed boundary-membership predicate (second pass), E2_DESC, the
///    GM-12 "Option B" digit rule, boundary partition, and area-code inference.
///  * any `geometry_state = VALIDATED_LICENSED` for a real layer (would need a
///    real `licence_id`, rights, parent linkage and feature-count match).
library sitewise_jaspr_web.geo.admin_geography;

/// A synthetic longitude/latitude pair used only for demonstrator geometry.
class GeoPoint {
  final double lat;
  final double lon;
  const GeoPoint(this.lat, this.lon);
}

/// The three tiers surfaced in the demonstrator UI.
/// Mirrors GEOH-03 §2.1 tiers without pretending a real hierarchy exists.
enum GeoAdminTier { stateFt, district, mukim }

/// Geometry readiness gate (GEOH-03 §7 `BoundaryLayer`). Real data is always
/// `absent` here because no licence exists; `validatedLicensed` is retained
/// only to make the `verified` predicate explicit and unattainable on real data.
enum GeometryState {
  absent,          // no geometry for this tier
  unvalidated,     // geometry exists but is not licensed/validated for display
  validatedLicensed, // BL-1..BL-4 all hold — never true for real data this cycle
}

/// The five display states from GEOH-03 §4, evaluated as total disjoint
/// predicates (Rule G-9). Order is significant: `notApplicable` short-circuits
/// on the jurisdiction, then identity, then geometry.
enum AdminDisplayLabel {
  verified,
  partial,
  named,
  unresolved,
  notApplicable
}

/// Visible, non-colour watermark carried on every synthetic polygon fixture
/// (Rule G-12). Never rendered without it on a synthetic geometry.
const String kSyntheticBoundaryWatermark =
    'SYNTHETIC FIXTURE — NOT A REAL BOUNDARY';

/// Human-readable, colour-independent rendering of a display label.
/// Badge text carries the meaning; an icon + CSS class carries it again so it
/// survives greyscale/c colour-vision deficiency (GM_05 R-10, Rule G-9).
class AdminLabelStyle {
  final String badge;
  final String icon;     // non-colour visual channel
  final String cssClass; // outline style for polygon rendering
  const AdminLabelStyle({
    required this.badge,
    required this.icon,
    required this.cssClass,
  });
}

const Map<AdminDisplayLabel, AdminLabelStyle> kAdminLabelStyles = {
  AdminDisplayLabel.verified: AdminLabelStyle(
    badge: 'VERIFIED',
    icon: '✓',
    cssClass: 'geo-admin--verified',
  ),
  AdminDisplayLabel.partial: AdminLabelStyle(
    badge: 'PARTIAL / UNVERIFIED',
    icon: '◯',
    cssClass: 'geo-admin--partial',
  ),
  AdminDisplayLabel.named: AdminLabelStyle(
    badge: 'NAME ONLY',
    icon: '—',
    cssClass: 'geo-admin--named',
  ),
  AdminDisplayLabel.unresolved: AdminLabelStyle(
    badge: 'NOT RESOLVED',
    icon: '?',
    cssClass: 'geo-admin--unresolved',
  ),
  AdminDisplayLabel.notApplicable: AdminLabelStyle(
    badge: 'TIER NOT APPLICABLE',
    icon: '∅',
    cssClass: 'geo-admin--n/a',
  ),
};

/// One administrative tier as surfaced by the demonstrator.
///
/// Identity (`areaCode`/`name`) and geometry (`polygon*`) are deliberately
/// separate fields (GEOH-03 §3), so a name never smuggles in a boundary.
class AdminArea {
  final String id;                  // synthetic fixture id, e.g. 'ADM-E-KL'
  final GeoAdminTier tier;
  final String areaCode;            // the locality hint is carried separately
  final String localityHint;        // Rule G-11: a label, never a zone
  final String name;                // tier identity (may equal localityHint text)
  final bool jurisdictionNotApplicable; // Rule G-4: a jurisdiction fact
  final bool tierIdentityResolved;  // identity resolved for this tier
  final GeometryState geometryState;
  final bool synthetic;             // always true in this demonstrator
  final bool watermarked;           // Rule G-12: synthetic polygon watermark
  final bool parentDistrictVerified; // Rule G-10: never inferred
  final String? provenanceNote;
  final List<GeoPoint>? syntheticPolygon; // watermarked synthetic fixture only

  const AdminArea({
    required this.id,
    required this.tier,
    required this.areaCode,
    required this.localityHint,
    required this.name,
    this.jurisdictionNotApplicable = false,
    this.tierIdentityResolved = false,
    this.geometryState = GeometryState.absent,
    this.synthetic = true,
    this.watermarked = true,
    this.parentDistrictVerified = false,
    this.provenanceNote,
    this.syntheticPolygon,
  });

  AdminDisplayLabel get displayLabel {
    if (jurisdictionNotApplicable) return AdminDisplayLabel.notApplicable;
    if (!tierIdentityResolved) return AdminDisplayLabel.unresolved;
    switch (geometryState) {
      case GeometryState.validatedLicensed:
        return AdminDisplayLabel.verified; // BL-1..4 — unattainable on real data
      case GeometryState.unvalidated:
        return AdminDisplayLabel.partial;
      case GeometryState.absent:
        return AdminDisplayLabel.named;
    }
  }

  /// A polygon is renderable only when it is a watermarked synthetic fixture
  /// (real data never reaches this branch). Keeps polygon-render state separate
  /// from marker-display and tier-identity (Rule G-22).
  bool get polygonRenderable =>
      synthetic && watermarked && syntheticPolygon != null;
}

/// Total, disjoint predicate from GEOH-03 §4, factored out for direct tests.
/// Mirrors [AdminArea.displayLabel] so the fixture and the predicate can never
/// drift. `tolerance`/radius do NOT enter; this is administrative identity.
AdminDisplayLabel classifyAdminArea({
  required bool jurisdictionNotApplicable,
  required bool tierIdentityResolved,
  required GeometryState geometryState,
}) {
  if (jurisdictionNotApplicable) return AdminDisplayLabel.notApplicable;
  if (!tierIdentityResolved) return AdminDisplayLabel.unresolved;
  switch (geometryState) {
    case GeometryState.validatedLicensed:
      return AdminDisplayLabel.verified;
    case GeometryState.unvalidated:
      return AdminDisplayLabel.partial;
    case GeometryState.absent:
      return AdminDisplayLabel.named;
  }
}

/// The demonstrator's default synthetic jurisdiction.
///
/// Models a **synthetic Federal Territory** analogue sitting on the three
/// rental fixtures (≈ 3.14°N, 101.69°E). Deliberately chosen to exercise the
/// label semantics an FT actually carries (GEOH-03 §8):
///  * STATE_FT present and `partial` (synthetic watermarked polygon) — never
///    `verified`, because no licence exists (BL-1..4 unmet);
///  * DISTRICT `notApplicable` — an FT has no district tier (mirrors KL,
///    `KOD_DAERAH='00'` is a placeholder, not a code — Rule G-5);
///  * MUKIM `named` — identity only, no polygon (parent district not verified).
///
/// This is a synthetic fixture list; each entry is explicitly `synthetic=true`
/// and `watermarked=true` where a polygon is drawn, and none is exported in any
/// report (Rule G-12/G-13). The polygon is NOT used for circle membership
/// (Rule G-1): it is a separate administrative layer.
const List<AdminArea> kSyntheticAdminAreas = [
  AdminArea(
    id: 'ADM-SYN-FT',
    tier: GeoAdminTier.stateFt,
    areaCode: 'SYN-FT',
    localityHint: 'FICTIONAL_TEST_LOCALITY',
    name: 'Synthetic Federal Territory',
    tierIdentityResolved: true,
    geometryState: GeometryState.unvalidated, // synthetic polygon, not licensed
    parentDistrictVerified: false,
    provenanceNote:
        'Synthetic polygon fixture for UI development only; rights_state=UNVERIFIED.',
    synthetic: true,
    watermarked: true,
    syntheticPolygon: [
      GeoPoint(3.1320, 101.6820),
      GeoPoint(3.1550, 101.6820),
      GeoPoint(3.1550, 101.7100),
      GeoPoint(3.1320, 101.7100),
    ],
  ),
  AdminArea(
    id: 'ADM-SYN-DT',
    tier: GeoAdminTier.district,
    areaCode: 'NA-DISTRICT', // Rule G-5: placeholder, never rendered as a code
    localityHint: 'FICTIONAL_TEST_LOCALITY',
    name: 'Not applicable for this federal territory',
    jurisdictionNotApplicable: true,
    tierIdentityResolved: false,
    geometryState: GeometryState.absent,
    parentDistrictVerified: false,
    provenanceNote: 'Federal territory has no district tier (synthetic analogue of KL).',
    synthetic: true,
    watermarked: true,
    syntheticPolygon: null,
  ),
  AdminArea(
    id: 'ADM-SYN-MK',
    tier: GeoAdminTier.mukim,
    areaCode: 'SYN-MK-01',
    localityHint: 'FICTIONAL_TEST_LOCALITY',
    name: 'Synthetic Mukim One',
    tierIdentityResolved: true,
    geometryState: GeometryState.absent, // identity only — parent district not verified
    parentDistrictVerified: false,
    provenanceNote:
        'Synthetic mukim identity only; parent district not verified (Rule G-10).',
    synthetic: true,
    watermarked: true,
    syntheticPolygon: null,
  ),
];

/// Returns the synthetic area for a tier, or `null` if the jurisdiction has no
/// such tier. Used by the R01 locality/admin-status presenter.
AdminArea? adminAreaForTier(GeoAdminTier tier) =>
    kSyntheticAdminAreas.firstWhere(
      (a) => a.tier == tier,
      orElse: () => throw StateError('fixture not present for tier $tier'),
    );
