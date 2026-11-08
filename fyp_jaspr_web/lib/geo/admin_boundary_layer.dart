/// L2a administrative boundary overlay — DOSM open data.
///
/// Directive: `PROJECT1-L2-OPEN-DATA-FOUR-AREA-ACCEPTANCE-20261031`.
///
/// What this layer is:
///  * The DOSM `data-open` ADM1 (state / federal territory) and ADM2 (district)
///    polygons for the four supported jurisdictions — Kuala Lumpur, Pulau
///    Pinang, Johor and Selangor — served from the same bytes that the L2
///    verification harness measured (identical SHA-256; see [kAdminDatasetAdm1]).
///  * Distributed under the DOSM Open Data Licence, which permits copying,
///    publishing, distributing, adapting and commercial exploitation without an
///    application, a payment or an official request.
///
/// What this layer is NOT:
///  * It is not the system study zone, not the display radius and not a
///    competitor footprint. It never enters the membership count. The only
///    calculation footprint in WF-07 remains `SYSTEM_STUDY_ZONE`.
///  * It is not a lower-tier (mukim / ADM3) layer. L2b is withheld: the banked
///    geoBoundaries ADM3 collection has an unverified licence chain and no
///    official codes, so no ADM3 feature is drawn.
///  * It is not repaired. Source defects (OGC-invalid districts, material
///    overlaps between neighbouring units) are disclosed and displayed as-is.
library sitewise_jaspr_web.geo.admin_boundary_layer;

/// Stable identifiers for the layer state machine. These are surfaced in the
/// page, the accessible summary and the machine-readable receipt so a reader
/// can distinguish "drawn", "withheld" and "unavailable" without colour.
const String kAdminLayerStatusAvailable = 'L2A_OPEN_DATA_AVAILABLE';
const String kAdminLayerStatusWithheld = 'L2B_WITHHELD_BLOCKED_RIGHTS';
const String kAdminLayerStatusUnavailable = 'ADMIN_LAYER_UNAVAILABLE';

/// Dataset URLs. The files are copied verbatim from the L2 package sources;
/// the hashes below are the package hashes, re-verified after the copy.
const String kAdminDatasetAdm1 = '/data/administrative_1_state.geojson';
const String kAdminDatasetAdm2 = '/data/administrative_2_district.geojson';
const String kAdminDatasetAdm1Sha256 =
    '538f9301431c9f4a7c9262b419c9f6705fdfc57275aedf44c7bbbd7aff748587';
const String kAdminDatasetAdm2Sha256 =
    '3edb1022b2de371bba6b7afb9802b6fc6d747c86dbcc40abf2374a9134f3c561';
const int kAdminDatasetAdm1Bytes = 391521;
const int kAdminDatasetAdm2Bytes = 947755;

/// Source identity and licence, quoted from the repository `LICENSE.md`.
const String kAdminSourceId =
    'DOSM data-open · datasets/geodata/administrative_1_state.geojson + '
    'administrative_2_district.geojson';
const String kAdminSourceRepo = 'https://github.com/dosm-malaysia/data-open';
const String kAdminLicenceName = 'DOSM Open Data Licence';
const String kAdminLicenceSummary =
    'Permits copying, publishing, distributing, adapting and commercial or '
    'non-commercial exploitation, including inclusion in a product, without an '
    'individual permission request, paid purchase or official application. No '
    'endorsement may be implied; third-party rights and personal data are '
    'excluded; data is supplied as is.';
const String kAdminLicenceUrl =
    'https://github.com/dosm-malaysia/data-open/blob/main/LICENSE.md';

/// The sentence that must accompany every rendering of the layer.
const String kAdminSeparationStatement =
    'Administrative boundaries are context only. They are not the system study '
    'zone, not the display radius and not a competitor footprint, and they never '
    'change the sample venue count.';

/// The lower-tier verdict carried beside the L2a layer.
const String kAdminLowerTierReason =
    'No ADM3 feature is released: the banked geoBoundaries MYS ADM3 collection '
    'has an unverified licence chain (licenseSource points at a Wikimedia File '
    'namespace index, licenseDetail is "nan"), carries no official area code '
    '(shapeISO empty on 1,859 of 1,859), and 245 features materially overlap '
    'districts in two or more states. 0 of 1,859 features pass the release '
    'preconditions.';

/// One jurisdiction as the overlay exposes it.
class AdminJurisdiction {
  final String regionFixtureId;
  final String navigationLabel;
  final String dosmStateName;
  final String codeState;
  final Map<String, String> districtCodes; // district name -> DOSM code_district
  final List<String> sourceInvalidDistricts;
  final String sourceInvalidReasons;

  const AdminJurisdiction({
    required this.regionFixtureId,
    required this.navigationLabel,
    required this.dosmStateName,
    required this.codeState,
    required this.districtCodes,
    this.sourceInvalidDistricts = const [],
    this.sourceInvalidReasons = '',
  });

  int get districtCount => districtCodes.length;
}

/// The four supported jurisdictions, in fixture order.
///
/// District names are transcribed from the DOSM `district` property; they are
/// the source's spelling, not an official gazette transcription.
const List<AdminJurisdiction> kAdminJurisdictions = [
  AdminJurisdiction(
    regionFixtureId: 'KL',
    navigationLabel: 'Kuala Lumpur',
    dosmStateName: 'W.P. Kuala Lumpur',
    codeState: '14',
    districtCodes: {'W.P. Kuala Lumpur': '14_1'},
  ),
  AdminJurisdiction(
    regionFixtureId: 'PEN',
    navigationLabel: 'Penang',
    dosmStateName: 'Pulau Pinang',
    codeState: '7',
    districtCodes: {
      'Seberang Perai Tengah': '7_1',
      'Seberang Perai Utara': '7_2',
      'Seberang Perai Selatan': '7_3',
      'Timur Laut': '7_4',
      'Barat Daya': '7_5',
    },
    sourceInvalidDistricts: ['Timur Laut'],
    sourceInvalidReasons:
        'Timur Laut (7_4): "Too few points in geometry component[100.29908 5.34408]"',
  ),
  AdminJurisdiction(
    regionFixtureId: 'JHR',
    navigationLabel: 'Johor',
    dosmStateName: 'Johor',
    codeState: '1',
    districtCodes: {
      'Batu Pahat': '1_1',
      'Johor Bahru': '1_2',
      'Kluang': '1_3',
      'Kota Tinggi': '1_4',
      'Mersing': '1_5',
      'Muar': '1_6',
      'Pontian': '1_7',
      'Segamat': '1_8',
      'Kulai': '1_9',
      'Tangkak': '1_10',
    },
    sourceInvalidDistricts: ['Kluang', 'Tangkak'],
    sourceInvalidReasons:
        'Kluang (1_3): "Too few points in geometry component[103.30012 1.8261]"; '
        'Tangkak (1_10): "Too few points in geometry component[102.53557 2.27333]"',
  ),
  AdminJurisdiction(
    regionFixtureId: 'SGR',
    navigationLabel: 'Selangor',
    dosmStateName: 'Selangor',
    codeState: '10',
    districtCodes: {
      'Gombak': '10_1',
      'Klang': '10_2',
      'Kuala Langat': '10_3',
      'Kuala Selangor': '10_4',
      'Petaling': '10_5',
      'Sabak Bernam': '10_6',
      'Sepang': '10_7',
      'Ulu Langat': '10_8',
      'Ulu Selangor': '10_9',
    },
  ),
];

AdminJurisdiction? adminJurisdictionForRegion(String regionFixtureId) {
  for (final j in kAdminJurisdictions) {
    if (j.regionFixtureId == regionFixtureId) return j;
  }
  return null;
}

/// Total districts across the four jurisdictions (the historical 25 groups).
int get kAdminDistrictTotal =>
    kAdminJurisdictions.fold(0, (sum, j) => sum + j.districtCount);

/// Measured source-geometry facts for the displayed set. Threshold = 1,000 m^2
/// material overlap (author-stated display rule, not a published tolerance).
const int kAdminMaterialOverlapThresholdM2 = 1000;
const int kAdminOverlapPairsTouchingFour = 51;
const int kAdminOverlapPairsWithinFour = 28;
const int kAdminOverlapPairsCrossBorder = 23;
const double kAdminLargestOverlapKm2 = 1.726; // Bagan Datuk (Perak) / Sabak Bernam
const int kAdminAdm1OverlapPairsTouchingFour = 9;
const int kAdminSourceInvalidCount = 3;

/// L2b facts, pinned from the L2b assessment receipt.
const int kAdm3FeatureCount = 1859;
const int kAdm3Releasable = 0;
const int kAdm3CrossStateStraddles = 245;
const int kAdm3UnassignedToDosmDistrict = 8;

/// Machine payload consumed by the map bridge and asserted by tests.
Map<String, dynamic> adminBoundaryPayload({
  required String regionFixtureId,
  required bool visible,
}) {
  final j = adminJurisdictionForRegion(regionFixtureId);
  if (j == null) {
    return {
      'status': kAdminLayerStatusUnavailable,
      'visible': false,
      'reason': 'UNSUPPORTED_REGION — no DOSM jurisdiction is mapped to '
          'region "$regionFixtureId"; no boundary is drawn and no empty area '
          'is implied.',
    };
  }
  final districts = j.districtCodes.entries.toList();
  return {
    'status': kAdminLayerStatusAvailable,
    'visible': visible,
    'tier': 'ADM1+ADM2',
    'source': {
      'id': kAdminSourceId,
      'repo': kAdminSourceRepo,
      'adm1': {'url': kAdminDatasetAdm1, 'sha256': kAdminDatasetAdm1Sha256,
               'bytes': kAdminDatasetAdm1Bytes},
      'adm2': {'url': kAdminDatasetAdm2, 'sha256': kAdminDatasetAdm2Sha256,
               'bytes': kAdminDatasetAdm2Bytes},
    },
    'licence': {
      'name': kAdminLicenceName,
      'url': kAdminLicenceUrl,
      'permitsReuseWithoutApplication': true,
      'summary': kAdminLicenceSummary,
    },
    'jurisdiction': {
      'regionId': j.regionFixtureId,
      'label': j.navigationLabel,
      'dosmState': j.dosmStateName,
      'codeState': j.codeState,
      'districtCount': j.districtCount,
      'districts': [
        for (final e in districts) {'name': e.key, 'code': e.value},
      ],
      'sourceInvalidDistricts': j.sourceInvalidDistricts,
      'sourceInvalidReasons': j.sourceInvalidReasons,
    },
    'geometryNotes': {
      'materialOverlapThresholdM2': kAdminMaterialOverlapThresholdM2,
      'overlapPairsTouchingFour': kAdminOverlapPairsTouchingFour,
      'overlapPairsWithinFour': kAdminOverlapPairsWithinFour,
      'overlapPairsCrossBorder': kAdminOverlapPairsCrossBorder,
      'largestOverlapKm2': kAdminLargestOverlapKm2,
      'adm1OverlapPairsTouchingFour': kAdminAdm1OverlapPairsTouchingFour,
      'sourceInvalidCount': kAdminSourceInvalidCount,
      'displayedUnmodified': true,
    },
    'lowerTier': {
      'status': kAdminLayerStatusWithheld,
      'features': kAdm3FeatureCount,
      'releasable': kAdm3Releasable,
      'crossStateStraddles': kAdm3CrossStateStraddles,
      'unassignedToDosmDistrict': kAdm3UnassignedToDosmDistrict,
      'reason': kAdminLowerTierReason,
    },
    'separation': kAdminSeparationStatement,
  };
}
