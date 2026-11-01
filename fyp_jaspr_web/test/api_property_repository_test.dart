import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/data/api_property_repository.dart';

void main() {
  test(
    'imported fields preserve source score and image without claiming verification',
    () {
      final p = ApiPropertyRepository.fromJson({
        'id': 'EP-001',
        'title': 'Imported property',
        'address': 'Source address',
        'state': 'Selangor',
        'rental_rm': 11000,
        'size_sqft': 2100,
        'latitude': 3.13,
        'longitude': 101.62,
        'property_type': 'Shop',
        'suitability_score': 45.5,
        'dataset_validation': 'PASS',
        'image_url': 'https://example.com/listing.jpg',
      });
      expect(p.id, 'EP-001');
      expect(p.suitabilityScore, 45.5);
      expect(p.imageUrl, 'https://example.com/listing.jpg');
      expect(p.verification.name, 'pending');
      expect(p.hasTour, false);
      expect(p.copyWith(title: 'Changed').imageUrl, p.imageUrl);
    },
  );
}
