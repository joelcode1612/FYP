import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/src/domain/entities/recommendation_search.dart';

/// The search payload batch-enriches every card with `photos` (URL list from
/// the verified catalogue-photo chain) and `panorama` (the honest
/// ready/processing/unavailable payload). These tests pin the entity parsing:
/// a panorama URL may ONLY surface when the backend says `ready`.
void main() {
  Map<String, dynamic> baseJson({
    Object? photos,
    Object? panorama,
  }) =>
      {
        'property_id': 'MD-01755',
        'title': 'Shoplot, Jalan Tebrau',
        'address': '1 Jalan Tebrau',
        'state': 'Johor',
        'rental_rm': 7500,
        'size_sqft': 1760,
        'property_type': 'Shoplot',
        'image_url': 'https://img.example/cover.jpg',
        if (photos != null) 'photos': photos,
        if (panorama != null) 'panorama': panorama,
      };

  group('RankedProperty media parsing', () {
    test('ready panorama exposes URL and flips hasTour', () {
      final item = RankedProperty.fromJson(baseJson(
        photos: const [
          'https://img.example/1.jpg',
          '  https://img.example/2.jpg  ',
          '',
          null,
        ],
        panorama: {
          'available': true,
          'status': 'ready',
          'url': 'https://cdn.example/pano.jpg',
          'reason': null,
        },
      ));

      expect(item.property.imageUrls, [
        'https://img.example/1.jpg',
        'https://img.example/2.jpg',
      ], reason: 'blank entries are dropped and whitespace is trimmed');
      expect(item.property.imageUrl, 'https://img.example/cover.jpg');
      expect(item.panoramaUrl, 'https://cdn.example/pano.jpg');
      expect(item.panoramaStatus, 'ready');
      expect(item.hasPanorama, isTrue);
      expect(item.property.hasTour, isTrue);
    });

    test('processing panorama never carries an openable URL', () {
      final item = RankedProperty.fromJson(baseJson(
        panorama: {
          'available': false,
          'status': 'processing',
          'url': null,
          'reason': 'still being processed',
        },
      ));

      expect(item.panoramaUrl, isNull);
      expect(item.panoramaStatus, 'processing');
      expect(item.hasPanorama, isFalse);
      expect(item.property.hasTour, isFalse);
    });

    test('a lying payload (available but no url) stays closed', () {
      final item = RankedProperty.fromJson(baseJson(
        panorama: {
          'available': true,
          'status': 'ready',
          'url': '   ',
        },
      ));
      expect(item.panoramaUrl, isNull, reason: 'ready without a URL is not openable');

      final wrongStatus = RankedProperty.fromJson(baseJson(
        panorama: {
          'available': true,
          'status': 'unavailable',
          'url': 'https://cdn.example/pano.jpg',
        },
      ));
      expect(wrongStatus.panoramaUrl, isNull,
          reason: 'only status == ready grants the URL');
    });

    test('absent media keys degrade to photos-only defaults', () {
      final item = RankedProperty.fromJson(baseJson());
      expect(item.property.imageUrls, isEmpty);
      expect(item.property.imageUrl, 'https://img.example/cover.jpg',
          reason: 'the legacy cover key keeps working for one-photo cards');
      expect(item.panoramaUrl, isNull);
      expect(item.panoramaStatus, isNull);
      expect(item.property.hasTour, isFalse);

      final malformed = RankedProperty.fromJson(baseJson(
        photos: 'not-a-list',
        panorama: 'not-a-map',
      ));
      expect(malformed.property.imageUrls, isEmpty);
      expect(malformed.hasPanorama, isFalse);
    });
  });
}
