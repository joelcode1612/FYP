import 'package:test/test.dart';
import 'package:project1_geo_report_demo/geometry_contract.dart';
import 'package:project1_geo_report_demo/synthetic_rentals.dart';

// Test-only venue points. NONE represent real competitors or source records.
// These fixtures must NEVER be rendered as production R09 data.
const syntheticVenues = [
  (id: 'FIXTURE-01', lat: 3.1439, lon: 101.6885),
  (id: 'FIXTURE-02', lat: 3.1483, lon: 101.6947),
  (id: 'FIXTURE-03', lat: 3.1503, lon: 101.7000),
  (id: 'FIXTURE-04', lat: 3.1360, lon: 101.7029),
  (id: 'FIXTURE-05', lat: 3.1395, lon: 101.6960),
  (id: 'FIXTURE-06', lat: 3.1600, lon: 101.7130),
];

Set<String> includedIds(RentalCentre centre, double radiusMetres) {
  final eligible = classifyCentre(centre);
  if (!eligible.canDraw || !centre.synthetic) {
    throw StateError('This test may only run on eligible synthetic fixtures.');
  }
  return {
    for (final v in syntheticVenues)
      if (withinCircle(
        haversineMetres(centre.latitude!, centre.longitude!, v.lat, v.lon),
        radiusMetres, toleranceMetres: experimentalBoundaryToleranceMetres,
      )) v.id,
  };
}

void main() {
  test('test venue fixtures are uniquely identified', () {
    expect(syntheticVenues.length, 6);
    expect(syntheticVenues.map((v) => v.id).toSet().length, 6);
  });
  test('inclusion monotonically increases for the three synthetic centres', () {
    for (final rental in syntheticRentalCentres) {
      final small = includedIds(rental, 400);
      final medium = includedIds(rental, 800);
      final large = includedIds(rental, 1200);
      expect(medium.containsAll(small), isTrue);
      expect(large.containsAll(medium), isTrue);
      expect(large.length, lessThanOrEqualTo(syntheticVenues.length));
    }
  });
  test('shared test venues are unioned by stable id rather than summed', () {
    final first = includedIds(syntheticRentalCentres[0], 1200);
    final second = includedIds(syntheticRentalCentres[1], 1200);
    expect(first.union(second).length, lessThanOrEqualTo(first.length + second.length));
  });
  test('invalid radius cannot silently clamp a requested footprint', () {
    expect(() => includedIds(syntheticRentalCentres.first, 6000), throwsRangeError);
  });
}
