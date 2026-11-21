/// Owner-facing listing lifecycle contract.
///
/// The live implementation rides the authenticated `ApiClient`, but callers
/// only need this port: creating/updating drafts, reading a draft or the
/// account's listings, managing photos and reading enrichment state. Ownership
/// and the draft → review lifecycle are enforced by the backend, never here.
library;

import '../entities/owner_listing.dart';
import '../entities/property_enrichment.dart';

abstract class OwnerListingRepository {
  Future<OwnerListing> createDraft(Map<String, dynamic> fields);

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
