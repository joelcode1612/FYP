import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/core/di/mobile_api_client.dart';

/// Uploads a stitched 360° panorama and connects it to its listing through
/// the existing virtual-tour endpoints.
///
/// The capture flow stitches on device; this transport is what carries the
/// finished JPEG to the SiteWise backend, where `POST
/// /api/v1/virtual-tours/property/{id}/panorama` stores it in public storage
/// and upserts the `virtual_tour` row for the property. That row is what the
/// property-detail 360° viewer and the insights panorama card read, so a
/// capture only becomes visible to buyers through this call.
///
/// `require_property_owner` gates the role and the mandatory TOTP session;
/// the record-level decision — the caller's own `owner_user_id` on the
/// listing, or the caller's agent profile holding an
/// `agent_listing_assignment` row for it — is made server-side from the
/// verified token. This class never sends an identity, so Property Owners and
/// Agents go through exactly one capture-upload path.
class ApiVirtualTourRepository {
  ApiVirtualTourRepository(this._client);

  final MobileApiClient _client;

  /// Uploads the stitched panorama JPEG for [propertyId] (the saved draft's
  /// `fyp.rental_properties` id) and returns its permanent public URL.
  ///
  /// Failures carry the backend's user-facing detail through the shared
  /// failure taxonomy. The capture frames and the device-local panorama stay
  /// untouched, so the caller can retry the upload without recapturing.
  Future<String> uploadPanorama({
    required String propertyId,
    required List<int> bytes,
    String filename = 'panorama.jpg',
  }) async {
    final payload = await _client.uploadMultipart(
      '/api/v1/virtual-tours/property/$propertyId/panorama',
      fields: const {},
      fileField: 'file',
      filename: filename,
      bytes: bytes,
      contentType: 'image/jpeg',
    );
    final data = payload['data'];
    if (data is Map<String, dynamic>) {
      final url = data['url'];
      if (url is String && url.isNotEmpty) return url;
    }
    throw const ResponseFormatFailure(
      'The server accepted the panorama but returned no URL.',
    );
  }
}
