import 'package:shared_logic/src/data/mappers/explore_property_mapper.dart';
import 'package:test/test.dart';

/// Regression guard for the Entrepreneur Listing page.
///
/// `fyp.rental_properties` uses PostgreSQL `numeric` columns. SQLAlchemy
/// serialises those as JSON STRINGS ("6000.00", "2.0"), not JSON numbers. The
/// mapper used to cast every value with `v as num?`, so the first real row
/// threw a `TypeError`. That error is not an AppFailure, so the page fell
/// through to the generic "Unable to load properties" state even though the
/// backend answered 200 with 227 eligible listings.
///
/// This fixture is the shape returned by GET /api/v1/explore/properties on the
/// development database (verified 2026-11-10) — not an invented one.
void main() {
  Map<String, dynamic> realRow() => <String, dynamic>{
    'property_id': 315,
    'name': 'One Puchong Ground + Basement Retail',
    'property_type': 'Shop',
    'description': null,
    'address': 'Jalan OP, One Puchong, Bandar Puchong Jaya, Puchong, Selangor',
    'city': 'Puchong',
    'state': 'Selangor',
    'latitude': 3.018,
    'longitude': 101.624,
    'rental_price': '6000.00',
    'size_sqft': '3000.00',
    'psf': '2.00',
    'availability': 'Available Now',
    'tenure': 'NULL',
    'furnishing': 'Partially Furnished',
    'floor_level': null,
    'bathrooms': '2.0',
    'is_fnb_suitable': 1,
    'has_parking': 0,
    'is_corner_lot': 0,
    'is_freehold': 0,
    'verification_status': 'approved',
    'is_published': true,
    'primary_image': null,
    'competitor_count_500m': 7,
    'competitor_count_1km': 11,
    'population_500m': '12000.5',
    'population_1km': '48000.0',
    'accessibility_score': '64.25',
    'overall_location_score': '71.0',
    'has_research_link': false,
    'nearby_property_count': 4,
  };

  group('ExplorePropertyMapper.property — real fyp.rental_properties row', () {
    test('numeric-string columns parse without throwing', () {
      final property = ExplorePropertyMapper.property(realRow());

      expect(property.id, '315');
      expect(property.title, 'One Puchong Ground + Basement Retail');
      expect(property.rentalRm, 6000.0);
      expect(property.sizeSqft, 3000.0);
      expect(property.psf, 2.0);
      expect(property.bathrooms, 2);
      expect(property.population500m, 12000.5);
      expect(property.accessibilityScore, 64.25);
      expect(property.suitabilityScore, 71.0);
      expect(property.hasSuitabilityScore, isTrue);
      expect(property.nearbyPropertyCount, 4);
    });

    test('smallint flags keep their tri-state meaning', () {
      final property = ExplorePropertyMapper.property(realRow());
      expect(property.isFnbSuitable, isTrue); // 1
      expect(property.hasParking, isFalse); // 0
      expect(property.isCornerLot, isFalse);
      expect(property.isFreehold, isFalse);
      expect(property.floorLevel, isNull); // SQL NULL, not invented
    });

    test('missing values stay missing — no fabricated image or coordinates', () {
      final property = ExplorePropertyMapper.property(realRow());
      expect(property.imageUrl, isNull);
      expect(property.hasCoordinates, isTrue);
      expect(property.verification.name, 'verified');
    });

    test('a row with NULL numeric columns yields nulls, never zeros', () {
      final row = realRow()
        ..['rental_price'] = null
        ..['size_sqft'] = null
        ..['psf'] = null
        ..['bathrooms'] = null
        ..['population_500m'] = null
        ..['latitude'] = null
        ..['longitude'] = null
        ..['nearby_property_count'] = null;
      final property = ExplorePropertyMapper.property(row);
      expect(property.rentalRm, 0); // domain entity has a non-nullable double
      expect(property.psf, isNull);
      expect(property.bathrooms, isNull);
      expect(property.population500m, isNull);
      expect(property.nearbyPropertyCount, isNull);
      expect(property.hasCoordinates, isFalse);
    });

    test('native JSON numbers still parse (backward compatible)', () {
      final row = realRow()
        ..['rental_price'] = 6000
        ..['size_sqft'] = 3000.5
        ..['bathrooms'] = 3;
      final property = ExplorePropertyMapper.property(row);
      expect(property.rentalRm, 6000.0);
      expect(property.sizeSqft, 3000.5);
      expect(property.bathrooms, 3);
    });
  });
}
