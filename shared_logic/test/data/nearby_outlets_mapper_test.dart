import 'package:shared_logic/src/data/mappers/explore_property_mapper.dart';
import 'package:test/test.dart';

/// The competitor response now carries normalized provider fields next to the
/// legacy keys. Both shapes must parse, and the per-provider counts must be
/// exposed so a UI can show raw vs deduplicated numbers.
void main() {
  group('ExplorePropertyMapper.outlets', () {
    test('parses the normalized response (provider, status, licence, counts)', () {
      final outlets = ExplorePropertyMapper.outlets({
        'data': [
          {
            'competitor_key': 'overture-123',
            'outlet_key': 'overture-123',
            'provider': 'overture',
            'provider_record_id': 'overture-123',
            'name': 'Dapur Dahlia',
            'outlet_name': 'Dapur Dahlia',
            'category': 'restaurant',
            'outlet_category': 'restaurant',
            'operating_status': 'unknown',
            'source_licence': 'ODbL-1.0 (Overture Maps Foundation)',
            'source_snapshot': '2026-09-23.1',
            'latitude': 3.04,
            'longitude': 101.58,
            'distance_m': 22.8,
          },
        ],
        'meta': {
          'available': true,
          'radius_m': 500,
          'source': 'merged',
          'counts': {
            'osm': 5,
            'overture_raw': 16,
            'overture_unique': 14,
            'merged': 19,
            'duplicates_removed': 2,
          },
        },
      });

      expect(outlets.available, isTrue);
      expect(outlets.radiusM, 500);
      expect(outlets.mergedCount, 19);
      expect(outlets.counts['duplicates_removed'], 2);
      final row = outlets.outlets.single;
      expect(row.outletKey, 'overture-123');
      expect(row.provider, 'overture');
      expect(row.operatingStatus, 'unknown');
      expect(row.category, 'restaurant');
      expect(row.sourceLicence, contains('Overture'));
      expect(row.sourceSnapshot, '2026-09-23.1');
      expect(row.distanceM, closeTo(22.8, 0.001));
    });

    test('still parses the legacy OSM-only shape', () {
      final outlets = ExplorePropertyMapper.outlets({
        'data': [
          {
            'outlet_key': '98765',
            'outlet_name': 'Healthy Vegetarian',
            'outlet_category': 'CAFE_COFFEE_SHOP',
            'brand': null,
            'addr_street': 'Jalan SS15/4',
            'addr_city': 'Subang Jaya',
            'latitude': 3.07,
            'longitude': 101.59,
            'distance_m': 120.5,
          },
        ],
        'meta': {'available': true, 'radius_m': 500},
      });

      final row = outlets.outlets.single;
      expect(row.outletKey, '98765');
      expect(row.name, 'Healthy Vegetarian');
      expect(row.category, 'CAFE_COFFEE_SHOP');
      expect(row.streetAddress, 'Jalan SS15/4');
      expect(row.city, 'Subang Jaya');
      // `_s()` normalizes a missing key to an empty string.
      expect(row.provider ?? '', isEmpty);
      expect(outlets.counts, isEmpty);
      expect(outlets.mergedCount, isNull);
    });

    test('an unavailable lookup is empty, not a fabricated zero count', () {
      final outlets = ExplorePropertyMapper.outlets({
        'data': <Object>[],
        'meta': {'available': false, 'radius_m': 500},
      });
      expect(outlets.available, isFalse);
      expect(outlets.outlets, isEmpty);
      expect(outlets.mergedCount, isNull);
    });
  });
}
