/// Exactly three synthetic, non-property test points for Project1 Jaspr.
/// No coordinate here is a verified rental, entrance, or business location.
/// Synthetic accuracy is a fixture assumption, NOT a measured property.
///
/// ---------------------------------------------------------------------------
/// GEO-DEV-C01 integration note
/// ---------------------------------------------------------------------------
/// Verbatim reuse of the scaffold file `lib/synthetic_rentals.dart`
/// (SHA-256 918a14ed2786afc2bcde5a8a225dd468472bc5ca4b0654511d77f62a68a00883),
/// relocated under `lib/geo/` inside `sitewise_jaspr_web`. The three fixtures
/// (SYN-A/B/C) are the canonical, unchanging synthetic coordinates for this
/// increment; see docs/03 "three synthetic coordinates can proceed independently
/// of BC-05". The real rental-selection UI belongs to the BC-05 teammate and is
/// left untouched here.
library sitewise_jaspr_web.geo.synthetic_rentals;

import 'geometry_contract.dart';

const List<RentalCentre> syntheticRentalCentres = [
  RentalCentre(
    rentalId: 'SYN-A', label: 'Synthetic Rental A', locality: 'FICTIONAL_TEST_LOCALITY',
    kind: CentreClass.premises, latitude: 3.1432, longitude: 101.6892,
    accuracyMetres: 1.0, positionSource: 'SYNTHETIC_FIXTURE_NOT_MEASURED',
    coordinateVersion: 'synthetic-3point-v1', synthetic: true,
  ),
  RentalCentre(
    rentalId: 'SYN-B', label: 'Synthetic Rental B', locality: 'FICTIONAL_TEST_LOCALITY',
    kind: CentreClass.premises, latitude: 3.1502, longitude: 101.6988,
    accuracyMetres: 1.0, positionSource: 'SYNTHETIC_FIXTURE_NOT_MEASURED',
    coordinateVersion: 'synthetic-3point-v1', synthetic: true,
  ),
  RentalCentre(
    rentalId: 'SYN-C', label: 'Synthetic Rental C', locality: 'FICTIONAL_TEST_LOCALITY',
    kind: CentreClass.premises, latitude: 3.1356, longitude: 101.7022,
    accuracyMetres: 1.0, positionSource: 'SYNTHETIC_FIXTURE_NOT_MEASURED',
    coordinateVersion: 'synthetic-3point-v1', synthetic: true,
  ),
];
