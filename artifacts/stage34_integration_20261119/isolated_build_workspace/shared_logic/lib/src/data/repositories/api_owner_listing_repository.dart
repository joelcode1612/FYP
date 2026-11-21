import '../../core/network/api_client.dart';
import '../../domain/entities/owner_listing.dart';
import '../../domain/entities/property_enrichment.dart';

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

  /// Called after a write the server confirmed (draft saved, photo uploaded,
  /// photo removed). The workspace uses it to reload "My property listings"
  /// when the user comes back from Add Property — previously that list only
  /// refreshed when the screen was rebuilt from scratch, so a freshly saved
  /// draft was invisible until the app restarted.
  ///
  /// Private on purpose: it is a wiring hook, not part of the repository
  /// contract. A public field would become part of the implicit interface and
  /// force every `implements` test double to re-declare it.
  final void Function()? _onMutated;

  ApiOwnerListingRepository(this._client, {void Function()? onMutated})
    : _onMutated = onMutated;

  void _mutated() {
    try {
      _onMutated?.call();
    } catch (_) {
      // A listener failure must never make a successful write look failed.
    }
  }

  OwnerListing _listing(Map<String, dynamic> payload) => OwnerListing.fromJson(
        payload['data'] is Map<String, dynamic>
            ? payload['data'] as Map<String, dynamic>
            : payload,
      );

  /// Creates a NEW server-persisted draft. [fields] uses
  /// [OwnerListing.toDraftJson]; only `name` is required.
  Future<OwnerListing> createDraft(Map<String, dynamic> fields) async {
    final listing = _listing(await _client.post(
      '/api/v1/properties/listings/drafts',
      fields,
    ));
    _mutated();
    return listing;
  }

  /// Updates the SAME draft row — never creates a duplicate.
  Future<OwnerListing> updateDraft(String id, Map<String, dynamic> fields) async {
    final listing = _listing(await _client.patch(
      '/api/v1/properties/listings/$id',
      fields,
    ));
    _mutated();
    return listing;
  }

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
    final photo = OwnerListingPhoto.fromJson(
      payload['data'] is Map<String, dynamic>
          ? payload['data'] as Map<String, dynamic>
          : payload,
    );
    _mutated();
    return photo;
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

  Future<void> deletePhoto(String listingId, int photoId) async {
    await _client.delete('/api/v1/properties/listings/$listingId/photos/$photoId');
    _mutated();
  }

  Future<void> setPrimaryPhoto(String listingId, int photoId) async {
    await _client.post(
      '/api/v1/properties/listings/$listingId/photos/$photoId/primary',
      const {},
    );
    _mutated();
  }

  // -------------------------------------------------------------------
  // Two-phase geospatial enrichment
  //
  // Phase 1 (PostGIS) and Phase 2 (population) are separate requests on
  // purpose: the owner sees the fast categories settle while the raster work
  // is still running, and a population failure never invalidates the rest.
  // -------------------------------------------------------------------

  /// Runs one enrichment phase and returns the settled per-category states.
  ///
  /// [phase] is [EnrichmentPhase.postgis] or [EnrichmentPhase.population].
  /// Passing `null` runs both (the backend's legacy default).
  /// [force] recalculates even when a category is already current.
  Future<PropertyEnrichmentSummary> enrich(
    String listingId, {
    EnrichmentPhase? phase,
    bool force = false,
    List<EnrichmentCategory>? categories,
  }) async {
    final response = await _client.post(
      '/api/v1/properties/listings/$listingId/enrich',
      {
        if (phase != null) 'phase': phase.wire,
        if (force) 'force': true,
        if (categories != null && categories.isNotEmpty)
          'categories': categories.map((c) => c.wire).toList(),
      },
    );
    return PropertyEnrichmentSummary.fromJson(_summaryPayload(response));
  }

  /// Reads stored enrichment state. Never triggers a recalculation, so the
  /// progress panel can poll it safely.
  Future<PropertyEnrichmentSummary> enrichment(String listingId) async {
    final response = await _client.get(
      '/api/v1/properties/listings/$listingId/enrichment',
    );
    return PropertyEnrichmentSummary.fromJson(_summaryPayload(response));
  }

  /// Retries exactly one category.
  Future<PropertyEnrichmentSummary> retryCategory(
    String listingId,
    EnrichmentCategory category,
  ) async {
    final response = await _client.post(
      '/api/v1/properties/listings/$listingId/enrichment/${category.wire}/retry',
      const {},
    );
    return PropertyEnrichmentSummary.fromJson(_summaryPayload(response));
  }

  static Map<String, dynamic> _summaryPayload(Map<String, dynamic> response) {
    final data = response['data'];
    return data is Map<String, dynamic> ? data : response;
  }
}
