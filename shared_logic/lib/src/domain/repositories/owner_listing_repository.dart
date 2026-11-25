/// Owner-facing listing lifecycle contract.
///
/// The live implementation rides the authenticated `ApiClient`, but callers
/// only need this port: creating/updating drafts, reading a draft or the
/// account's listings, managing photos and reading enrichment state. Ownership
/// and the draft → review lifecycle are enforced by the backend, never here.
library;

import '../entities/address_preview.dart';
import '../entities/owner_listing.dart';
import '../entities/property_enrichment.dart';

abstract class OwnerListingRepository {
  Future<OwnerListing?> recoverDraft(String requestId);

  /// Verify the saved address and persist the provider's verdict.
  Future<String> validateSavedAddress(String id);

  /// Read-only Malaysian address preview for the Add Property wizards:
  /// resolves the typed address server-side, classifies the match and returns
  /// signed confirmation evidence. Persists nothing; Save Draft never depends
  /// on it succeeding.
  Future<AddressPreview> previewAddress({
    required String address,
    required String city,
    required String state,
    required String postcode,
  });

  Future<OwnerListing> createDraft(
    Map<String, dynamic> fields, {
    Map<String, dynamic>? replayPatch,
  });

  Future<OwnerListing> updateDraft(String id, Map<String, dynamic> fields);

  Future<OwnerListing> getListing(String id);

  Future<List<OwnerListing>> myListings();

  Future<OwnerListingPhoto> uploadPhoto({
    required String listingId,
    required String filename,
    required List<int> bytes,
    required String contentType,
    String caption = '',
    bool isPrimary = false,
  });

  Future<List<OwnerListingPhoto>> photos(String listingId);

  Future<void> deletePhoto(String listingId, int photoId);

  Future<void> setPrimaryPhoto(String listingId, int photoId);

  Future<PropertyEnrichmentSummary> enrich(
    String listingId, {
    EnrichmentPhase? phase,
    bool force = false,
    List<EnrichmentCategory>? categories,
  });

  Future<PropertyEnrichmentSummary> enrichment(String listingId);

  Future<PropertyEnrichmentSummary> retryCategory(
    String listingId,
    EnrichmentCategory category,
  );
}
