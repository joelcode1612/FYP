import '../entities/agent_listing.dart';

/// Agent listing management — the write surface for ASSIGNED listings.
///
/// Authorization is never expressed here: the backend resolves the agent from
/// the bearer token, verifies the staff role + MFA and the Supabase
/// assignment (`listing.agent_id`), and answers 403/404 otherwise. A client
/// cannot select an agent id or an owner path to widen its reach.
abstract interface class AgentListingRepository {
  /// Listings genuinely assigned to the authenticated agent
  /// (`GET /api/v1/staff/me/listings`). An empty list is a valid state
  /// (no profile or no assignment) — never substituted with sample rows.
  Future<List<AgentAssignment>> assignedListings();

  /// One assigned listing with its operational record, photos and open
  /// change request (`GET /api/v1/staff/listings/{id}`).
  Future<AgentListingDetail> listingDetail(int listingId);

  /// Save/replace the agent's DRAFT change request
  /// (`PATCH /api/v1/staff/listings/{id}/proposal`). Returns the persisted
  /// request; `updated == false` means the diff against the live row was
  /// empty and nothing was written.
  Future<({bool updated, AgentChangeRequest? request})> saveProposal(
    int listingId,
    AgentProposal proposal,
  );

  /// Submit the draft for administrator review
  /// (`POST …/review-request`). Throws on 409 (duplicate pending, no draft).
  Future<AgentChangeRequest> requestAdminReview(int listingId, String reason);

  /// Requests + audit history for the listing
  /// (`GET …/change-requests`).
  Future<({List<AgentChangeRequest> requests, List<AgentActivityEvent> audit})>
  changeHistory(int listingId);

  /// Persist an internal note as an audit event
  /// (`POST …/notes`).
  Future<void> addNote(int listingId, String note);

  /// Verification findings recorded on the listing through the pre-existing
  /// staff mechanism (`GET /api/v1/staff/listings/{id}/verifications`).
  Future<List<AgentActivityEvent>> verificationFindings(int listingId);

  /// Upload one photo (`POST …/photos`, multipart).
  Future<void> uploadPhoto(
    int listingId, {
    required String filename,
    required String contentType,
    required List<int> bytes,
    String caption,
  });

  /// Remove one photo (`DELETE …/photos/{photoId}`).
  Future<void> deletePhoto(int listingId, int photoId);

  /// Set the primary image (`POST …/photos/{photoId}/primary`).
  Future<void> setPrimaryPhoto(int listingId, int photoId);
}
