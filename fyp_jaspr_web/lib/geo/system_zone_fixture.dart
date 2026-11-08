/// PROJECT1 — Four-region synthetic system-zone fixture (L1, sample-only).
///
/// Mirrors `02_SYNTHETIC_SYSTEM_ZONE_FOUR_AREA_FIXTURE.json`
/// (SHA-256 960e8f39b734022294c844a0f679f8dea1bbf7ba2462a5f718e78757f5a05048).
///
/// **Every coordinate, polygon and venue here is fictional.** The system zones
/// are predetermined synthetic squares, **not** real Malaysian administrative
/// boundaries (Kuala Lumpur / Penang / Johor / Selangor) and **not** observed
/// customer catchments. The region labels are navigation labels only.
library sitewise_jaspr_web.geo.system_zone_fixture;

import 'admin_geography.dart' show GeoPoint;
import 'system_study_zone.dart';

/// Fixture mode marker carried on every consumer.
const String kFixtureMode = 'SYNTHETIC_ONLY';

/// Naming reconciliation (review defect D5).
///
/// The frozen reference fixture
/// (`02_SYNTHETIC_SYSTEM_ZONE_FOUR_AREA_FIXTURE.json`) uses the token
/// `SYSTEM_PREDEFINED_ZONE` for `active_observation_footprint` and
/// `sample_competitor_query_footprint`. The directive
/// `PROJECT1-GEO-SYSTEM-ZONE-V2-L1-EXECUTE-20261030` and this implementation
/// use `SYSTEM_STUDY_ZONE` for the same concept.
///
/// Mapping: **`SYSTEM_PREDEFINED_ZONE` (fixture JSON) ≡ `SYSTEM_STUDY_ZONE`
/// (code, UI, receipt)**. The fixture file is a frozen input and was not
/// edited; the code follows the directive's token. Only one footprint exists.
const String kFixtureFootprintAlias = 'SYSTEM_PREDEFINED_ZONE';

/// Visible sample watermark for the system zone layer.
const String kSystemZoneWatermark =
    'SYNTHETIC SYSTEM ZONE — NOT A REAL BOUNDARY OR CATCHMENT';

/// One region: a rental ref, its system zone and its sample observations.
class SystemZoneRegion {
  final String regionFixtureId;
  final String navigationLabel;
  final RentalFixtureRef rental;
  final SystemStudyZone zone;
  final List<Observation> observations;

  const SystemZoneRegion({
    required this.regionFixtureId,
    required this.navigationLabel,
    required this.rental,
    required this.zone,
    required this.observations,
  });
}

GeoPoint _p(double lat, double lon) => GeoPoint(lat, lon);

ZoneGeometry _square(
  double latMin,
  double lonMin,
  double latMax,
  double lonMax,
) {
  return ZoneGeometry.polygon(
    ZonePolygon(
      outer: [
        _p(latMin, lonMin),
        _p(latMin, lonMax),
        _p(latMax, lonMax),
        _p(latMax, lonMin),
        _p(latMin, lonMin), // explicit closure
      ],
    ),
  );
}

SystemStudyZone _zone({
  required String zoneId,
  required String rentalId,
  required ZoneGeometry geometry,
}) {
  return SystemStudyZone(
    zoneId: zoneId,
    rentalId: rentalId,
    geometry: geometry,
    zoneSource: 'SYNTHETIC_FIXTURE',
    constructionMethod: 'PREDEFINED_VERSIONED_FIXTURE',
    ruleVersion: kSystemZoneRuleVersion,
    geometryRevision: 1,
    rightsState: 'SYNTHETIC_OWNED',
    sampleMode: true,
    adminBoundary: false,
  );
}

/// The four supported L1 regions (KL, Penang, Johor, Selangor).
///
/// Each region resolves to exactly one system zone and carries three sample
/// observations; exactly one observation per region falls inside the zone.
final List<SystemZoneRegion> kSystemZoneRegions = [
  SystemZoneRegion(
    regionFixtureId: 'KL',
    navigationLabel: 'Kuala Lumpur',
    rental: const RentalFixtureRef(
      rentalId: 'SYN-KL-R1',
      listingRevision: 'fixture-r1',
      position: GeoPoint(3.14, 101.69),
      locationKind: 'SYNTHETIC_POINT',
      sourceKind: 'SYNTHETIC_FIXTURE',
    ),
    zone: _zone(
      zoneId: 'SYSZONE-KL-V1',
      rentalId: 'SYN-KL-R1',
      geometry: _square(3.137, 101.687, 3.143, 101.693),
    ),
    observations: const [
      Observation(
        recordId: 'SYN-KL-V1',
        rentalGroup: 'SYN-KL-R1',
        position: GeoPoint(3.1405, 101.6907),
        sourceKind: 'SYNTHETIC_FIXTURE',
        categoryType: 'cafe',
      ),
      Observation(
        recordId: 'SYN-KL-V2',
        rentalGroup: 'SYN-KL-R1',
        position: GeoPoint(3.141, 101.695),
        sourceKind: 'SYNTHETIC_FIXTURE',
        categoryType: 'bakery',
      ),
      Observation(
        recordId: 'SYN-KL-V3',
        rentalGroup: 'SYN-KL-R1',
        position: GeoPoint(3.14, 101.716),
        sourceKind: 'SYNTHETIC_FIXTURE',
        categoryType: 'restaurant',
      ),
    ],
  ),
  SystemZoneRegion(
    regionFixtureId: 'PEN',
    navigationLabel: 'Penang',
    rental: const RentalFixtureRef(
      rentalId: 'SYN-PEN-R1',
      listingRevision: 'fixture-r1',
      position: GeoPoint(5.42, 100.33),
      locationKind: 'SYNTHETIC_POINT',
      sourceKind: 'SYNTHETIC_FIXTURE',
    ),
    zone: _zone(
      zoneId: 'SYSZONE-PEN-V1',
      rentalId: 'SYN-PEN-R1',
      geometry: _square(5.417, 100.327, 5.423, 100.333),
    ),
    observations: const [
      Observation(
        recordId: 'SYN-PEN-V1',
        rentalGroup: 'SYN-PEN-R1',
        position: GeoPoint(5.4205, 100.3307),
        sourceKind: 'SYNTHETIC_FIXTURE',
        categoryType: 'cafe',
      ),
      Observation(
        recordId: 'SYN-PEN-V2',
        rentalGroup: 'SYN-PEN-R1',
        position: GeoPoint(5.421, 100.335),
        sourceKind: 'SYNTHETIC_FIXTURE',
        categoryType: 'bakery',
      ),
      Observation(
        recordId: 'SYN-PEN-V3',
        rentalGroup: 'SYN-PEN-R1',
        position: GeoPoint(5.42, 100.356),
        sourceKind: 'SYNTHETIC_FIXTURE',
        categoryType: 'restaurant',
      ),
    ],
  ),
  SystemZoneRegion(
    regionFixtureId: 'JHR',
    navigationLabel: 'Johor',
    rental: const RentalFixtureRef(
      rentalId: 'SYN-JHR-R1',
      listingRevision: 'fixture-r1',
      position: GeoPoint(1.49, 103.75),
      locationKind: 'SYNTHETIC_POINT',
      sourceKind: 'SYNTHETIC_FIXTURE',
    ),
    zone: _zone(
      zoneId: 'SYSZONE-JHR-V1',
      rentalId: 'SYN-JHR-R1',
      geometry: _square(1.487, 103.747, 1.493, 103.753),
    ),
    observations: const [
      Observation(
        recordId: 'SYN-JHR-V1',
        rentalGroup: 'SYN-JHR-R1',
        position: GeoPoint(1.4905, 103.7507),
        sourceKind: 'SYNTHETIC_FIXTURE',
        categoryType: 'cafe',
      ),
      Observation(
        recordId: 'SYN-JHR-V2',
        rentalGroup: 'SYN-JHR-R1',
        position: GeoPoint(1.491, 103.755),
        sourceKind: 'SYNTHETIC_FIXTURE',
        categoryType: 'bakery',
      ),
      Observation(
        recordId: 'SYN-JHR-V3',
        rentalGroup: 'SYN-JHR-R1',
        position: GeoPoint(1.49, 103.776),
        sourceKind: 'SYNTHETIC_FIXTURE',
        categoryType: 'restaurant',
      ),
    ],
  ),
  SystemZoneRegion(
    regionFixtureId: 'SGR',
    navigationLabel: 'Selangor',
    rental: const RentalFixtureRef(
      rentalId: 'SYN-SGR-R1',
      listingRevision: 'fixture-r1',
      position: GeoPoint(3.08, 101.55),
      locationKind: 'SYNTHETIC_POINT',
      sourceKind: 'SYNTHETIC_FIXTURE',
    ),
    zone: _zone(
      zoneId: 'SYSZONE-SGR-V1',
      rentalId: 'SYN-SGR-R1',
      geometry: _square(3.077, 101.547, 3.083, 101.553),
    ),
    observations: const [
      Observation(
        recordId: 'SYN-SGR-V1',
        rentalGroup: 'SYN-SGR-R1',
        position: GeoPoint(3.0805, 101.5507),
        sourceKind: 'SYNTHETIC_FIXTURE',
        categoryType: 'cafe',
      ),
      Observation(
        recordId: 'SYN-SGR-V2',
        rentalGroup: 'SYN-SGR-R1',
        position: GeoPoint(3.081, 101.555),
        sourceKind: 'SYNTHETIC_FIXTURE',
        categoryType: 'bakery',
      ),
      Observation(
        recordId: 'SYN-SGR-V3',
        rentalGroup: 'SYN-SGR-R1',
        position: GeoPoint(3.08, 101.576),
        sourceKind: 'SYNTHETIC_FIXTURE',
        categoryType: 'restaurant',
      ),
    ],
  ),
];

/// All zones flattened (used by the resolver).
final List<SystemStudyZone> kAllSystemZones = [
  for (final region in kSystemZoneRegions) region.zone,
];

/// All observations flattened.
final List<Observation> kAllObservations = [
  for (final region in kSystemZoneRegions) ...region.observations,
];

/// The four supported rental ids. Pass this to `resolveZone` so an unknown
/// reference yields `ZONE_UNSUPPORTED_RENTAL` instead of a generic miss.
final Set<String> kKnownRentalIds = {
  for (final region in kSystemZoneRegions) region.rental.rentalId,
};

/// Look up a region by fixture id (e.g. `KL`), or null when unknown.
SystemZoneRegion? regionById(String regionFixtureId) {
  for (final region in kSystemZoneRegions) {
    if (region.regionFixtureId == regionFixtureId) return region;
  }
  return null;
}

/// Resolve a region by rental id, or null when unknown.
SystemZoneRegion? regionByRentalId(String rentalId) {
  for (final region in kSystemZoneRegions) {
    if (region.rental.rentalId == rentalId) return region;
  }
  return null;
}
