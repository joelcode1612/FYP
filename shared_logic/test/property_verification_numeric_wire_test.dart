import 'package:shared_logic/src/domain/entities/property_verification.dart';
import 'package:test/test.dart';

void main() {
  group('Admin property verification numeric wire decoding', () {
    test('queue refresh accepts NUMERIC/DECIMAL as strings', () {
      final page = VerificationQueuePage.fromJson({
        'items': [
          {
            'property_id': '1001',
            'title': 'Test shoplot',
            'price': '32.00',
            'built_up_area_sqft': '1500.50',
            'listing_status': 'pending',
            'ownership_status': 'not_submitted',
            'publication_eligible': false,
          },
        ],
        'counts': {
          'listing': {'pending': '1'},
          'ownership': {'not_submitted': 1},
        },
        'total': '1',
        'offset': 0,
        'limit': '20',
      });
      expect(page.total, 1);
      expect(page.items.single.propertyId, 1001);
      expect(page.items.single.monthlyRent, 32.0);
      expect(page.items.single.builtUpAreaSqft, 1500.5);
      expect(page.countOf(VerificationDimension.listing,
          PropertyVerificationStatus.pending), 1);
    });

    test('detail accepts decimal strings and preserves missing values', () {
      final property = VerificationProperty.fromJson({
        'property_id': 1001,
        'title': 'Test shoplot',
        'monthly_rent': '32.00',
        'built_up_area_sqft': '1500.50',
        'land_area_sqft': null,
        'latitude': '3.112345',
        'longitude': '101.712345',
        'frontage_ft': '20.00',
      });
      expect(property.monthlyRent, 32.0);
      expect(property.builtUpAreaSqft, 1500.5);
      expect(property.landAreaSqft, isNull);
      expect(property.latitude, closeTo(3.112345, 1e-8));
      expect(property.frontageFt, 20.0);
      expect(property.rentPerSqft, closeTo(32 / 1500.5, 1e-8));
    });

    test('geo features and model evidence accept decimal strings', () {
      final geo = VerificationGeoFeatures.fromJson({
        'competitor_count_500m': '3',
        'population_500m': '1524.00',
        'accessibility_score': '32.00',
        'income_median': null,
      });
      expect(geo.competitorCount500m, 3);
      expect(geo.population500m, 1524);
      expect(geo.accessibilityScore, 32);
      expect(geo.incomeMedian, isNull);
      final model = LocationResearchAssociation.fromJson({
        'available': true,
        'score': '0.32',
        'feature_count': '47',
        'available_features': 47,
      });
      expect(model.score, 0.32);
      expect(model.featureCount, 47);
      expect(model.availableFeatures, 47);
    });

    test('location intelligence values and states survive the wire unchanged', () {
      final model = LocationResearchAssociation.fromJson({
        'available': false,
        'feature_count': 64,
        'available_features': 2,
        'calculated_features': 4,
        'feature_values': {
          'road_length_density_500m_km_km2': 3.25,
          'osm_walkway_length_density_500m_km_km2': 'invalid',
          'pop_2000m': 0.0,
          'walk_isochrone_area_10min_km2': double.nan,
        },
        'feature_states': {
          'road_length_density_500m_km_km2': 'validated',
          'osm_walkway_length_density_500m_km_km2': 'calculated_unvalidated',
          'pop_2000m': 'validated',
          'walk_isochrone_area_10min_km2': 'unavailable',
        },
        'missing_features': ['walk_isochrone_area_10min_km2'],
        'unvalidated_features': ['osm_walkway_length_density_500m_km_km2'],
      });
      expect(model.featureValues['road_length_density_500m_km_km2'], 3.25);
      expect(model.featureValues['pop_2000m'], 0.0);
      expect(model.featureValues.containsKey('osm_walkway_length_density_500m_km_km2'), isFalse);
      expect(model.featureValues.containsKey('walk_isochrone_area_10min_km2'), isFalse);
      expect(model.featureStates['osm_walkway_length_density_500m_km_km2'],
          'calculated_unvalidated');
      expect(model.featureStates['walk_isochrone_area_10min_km2'], 'unavailable');
      expect(model.unvalidatedFeatures, contains('osm_walkway_length_density_500m_km_km2'));
    });

    test('population only accepts the exact cumulative catchments', () {
      final incomplete = VerificationPopulation.fromJson({
        'pop_total_200m': 20,
        'pop_ring_500_1km': '32.00',
      });
      expect(incomplete.pop500m, isNull);
      expect(incomplete.pop1km, isNull);
      final complete = VerificationPopulation.fromJson({
        'pop_ring_0_500m': '32.00',
        'pop_total_1km': 64.0,
      });
      expect(complete.pop500m, 32);
      expect(complete.pop1km, 64);
    });

    test('invalid numeric input remains absent rather than guessed as zero', () {
      final property = VerificationProperty.fromJson({
        'property_id': 1001,
        'title': 'Test shoplot',
        'monthly_rent': 'not recorded',
        'built_up_area_sqft': '',
        'latitude': 'Infinity',
      });
      expect(property.monthlyRent, isNull);
      expect(property.builtUpAreaSqft, isNull);
      expect(property.latitude, isNull);
    });
  });
}
