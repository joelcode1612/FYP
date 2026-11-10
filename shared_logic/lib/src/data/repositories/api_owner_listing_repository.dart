import '../../core/network/api_client.dart';
import '../../domain/entities/owner_listing.dart';

/// Live owner-listing lifecycle over the authenticated FastAPI endpoints
/// (`backend/src/sitewise/api/v1/properties.py`):
///
/// * `POST /api/v1/properties/listings/drafts`  — create a draft
/// * `PATCH /api/v1/properties/listings/{id}`   — update the SAME draft row
/// * `GET  /api/v1/properties/listings/{id}`    — resume a draft (with photos)
/// * `GET  /api/v1/properties/listings/mine`    — My Properties (all states)
/// * photo upload/delete/primary               — `fyp.property_photos`
///
/// Transport only: ownership comes from the verified bearer identity and the
/// draft → pending → approved/rejected lifecycle is enforced by the backend.
/// Submitting for verification and reading the verification state live in
/// [property_verification_repository.dart] (same backend subsystem).
class ApiOwnerListingRepository {
  final ApiClient _client;

  ApiOwnerListingRepository(this._client);

  OwnerListing _listing(Map<String, dynamic> payload) => OwnerListing.fromJson(
        payload['data'] is Map<String, dynamic>
            ? payload['data'] as Map<String, dynamic>
            : payload,
      );

  /// Creates a NEW server-persisted draft. [fields] uses
  /// [OwnerListing.toDraftJson]; only `name` is required.
  Future<OwnerListing> createDraft(Map<String, dynamic> fields) async =>
      _listing(await _client.post(
        '/api/v1/properties/listings/drafts',
        fields,
      ));

  /// Updates the SAME draft row — never creates a duplicate.
  Future<OwnerListing> updateDraft(String id, Map<String, dynamic> fields) async =>
      _listing(await _client.patch(
        '/api/v1/properties/listings/$id',
        fields,
      ));

  /// One owned listing (any status) with its photos.
  Future<OwnerListing> getListing(String id) async =>
      _listing(await _client.get('/api/v1/properties/listings/$id'));

  /// Every listing the signed-in owner has saved, drafts included.
  Future<List<OwnerListing>> myListings() async {
    final response = await _client.get('/api/v1/properties/listings/mine');
    final rows = (response['data'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(OwnerListing.fromJson)
        .toList();
    return List.unmodifiable(rows);
  }

  /// Uploads one property photo (JPG/PNG/WebP, <= 8 MB server-side).
  Future<OwnerListingPhoto> uploadPhoto({
    required String listingId,
    required String filename,
    required List<int> bytes,
    required String contentType,
    String caption = '',
    bool isPrimary = false,
  }) async {
    final payload = await _client.uploadMultipart(
      '/api/v1/properties/listings/$listingId/photos',
      fields: {
        'caption': caption,
        'is_primary': isPrimary ? 'true' : 'false',
      },
      fileField: 'file',
      filename: filename,
      bytes: bytes,
      contentType: contentType,
    );
    return OwnerListingPhoto.fromJson(
      payload['data'] is Map<String, dynamic>
          ? payload['data'] as Map<String, dynamic>
          : payload,
    );
  }

  Future<List<OwnerListingPhoto>> photos(String listingId) async {
    final response =
        await _client.get('/api/v1/properties/listings/$listingId/photos');
    return List.unmodifiable(
      (response['data'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(OwnerListingPhoto.fromJson),
    );
  }

  Future<void> deletePhoto(String listingId, int photoId) =>
      _client.delete('/api/v1/properties/listings/$listingId/photos/$photoId');

  Future<void> setPrimaryPhoto(String listingId, int photoId) =>
      _client.post(
        '/api/v1/properties/listings/$listingId/photos/$photoId/primary',
        const {},
      );
}
