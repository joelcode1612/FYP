/// Exactly three synthetic, non-property test points for Project1 Jaspr.
/// No coordinate here is a verified rental, entrance, or business location.
/// Synthetic accuracy is a fixture assumption, NOT a measured property.
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
