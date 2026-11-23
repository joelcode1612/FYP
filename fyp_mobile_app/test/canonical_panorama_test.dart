import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/features/capture_360/data/api_panorama_viewer_repository.dart';
import 'package:shared_logic/shared_logic.dart';

void main() {
  test('reads the string property ID returned by the panorama endpoint', () {
    final panorama = CanonicalPanorama.fromJson({
      'panoramaId': 'panorama-11900',
      'propertyId': '11900',
    });

    expect(panorama.propertyId, 11900);
    expect(panorama.panoramaId, 'panorama-11900');
  });

  test('accepts integer IDs and rejects malformed IDs', () {
    expect(CanonicalPanorama.fromJson({'propertyId': 11900}).propertyId, 11900);
    expect(
      () => CanonicalPanorama.fromJson({'propertyId': 'invalid'}),
      throwsA(isA<ResponseFormatFailure>()),
    );
  });
}
