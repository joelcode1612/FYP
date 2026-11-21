import '../../core/network/api_client.dart';
import '../../domain/entities/agent_listing.dart';
import '../../domain/repositories/agent_listing_repository.dart';

/// Live [AgentListingRepository] over the authenticated FastAPI staff
/// listing-management endpoints. Transport and mapping only — authorization
/// (staff role, MFA, assignment) is decided server-side on every call.
///
/// Endpoint map (all exist in `backend/src/sitewise/api/v1/staff.py` and
/// `staff_listings.py`):
///
/// | Method | Path                                                        |
/// |--------|-------------------------------------------------------------|
/// | GET    | `/api/v1/staff/me/listings`                                 |
/// | GET    | `/api/v1/staff/listings/{id}`                               |
/// | PATCH  | `/api/v1/staff/listings/{id}/proposal`                      |
/// | POST   | `/api/v1/staff/listings/{id}/review-request`                |
/// | GET    | `/api/v1/staff/listings/{id}/change-requests`               |
/// | POST   | `/api/v1/staff/listings/{id}/notes`                         |
/// | GET    | `/api/v1/staff/listings/{id}/verifications`                 |
/// | POST   | `/api/v1/staff/listings/{id}/photos`                        |
/// | DELETE | `/api/v1/staff/listings/{id}/photos/{photoId}`              |
/// | POST   | `/api/v1/staff/listings/{id}/photos/{photoId}/primary`      |
class ApiAgentListingRepository implements AgentListingRepository {
  final ApiClient _client;

  ApiAgentListingRepository(this._client);

  static List<Map<String, dynamic>> _rows(dynamic payload, String key) => [
    for (final row
        in (payload[key] as List? ?? const [])
            .whereType<Map<String, dynamic>>())
      row,
  ];

  static AgentActivityEvent _auditEvent(Map<String, dynamic> row) =>
      AgentActivityEvent(
        source: 'change',
        action: '${row['action'] ?? ''}',
        actorId: '${row['actor_user_id'] ?? ''}',
        note: row['note']?.toString(),
        createdAt: '${row['created_at'] ?? ''}',
        raw: row,
      );

  @override
  Future<List<AgentAssignment>> assignedListings() async {
    final response = await _client.get('/api/v1/staff/me/listings');
    return [
      for (final row in _rows(response, 'listings'))
        AgentAssignment.fromJson(row),
    ];
  }

  @override
  Future<AgentListingDetail> listingDetail(int listingId) async {
    final response = await _client.get(
      '/api/v1/staff/listings/${listingId.toInt()}',
    );
    final factsRow = response['property'];
    final ownerRow = response['owner'];
    final requestRow = response['change_request'];
    return AgentListingDetail(
      assignment: AgentAssignment.fromJson(
        response['listing'] is Map<String, dynamic>
            ? response['listing'] as Map<String, dynamic>
            : const <String, dynamic>{},
      ),
      facts: factsRow is Map<String, dynamic>
          ? AgentListingFacts.fromJson(factsRow)
          : null,
      owner: ownerRow is Map<String, dynamic>
          ? AgentOwnerReference.fromJson(ownerRow)
          : null,
      photos: [
        for (final row in _rows(response, 'photos')) AgentPhoto.fromJson(row),
      ],
      openRequest: requestRow is Map<String, dynamic>
          ? AgentChangeRequest.fromJson(requestRow)
          : null,
    );
  }

  @override
  Future<({bool updated, AgentChangeRequest? request})> saveProposal(
    int listingId,
    AgentProposal proposal,
  ) async {
    final response = await _client.patch(
      '/api/v1/staff/listings/${listingId.toInt()}/proposal',
      proposal.toBody(),
    );
    final row = response['change_request'];
    return (
      updated: response['updated'] == true,
      request: row is Map<String, dynamic>
          ? AgentChangeRequest.fromJson(row)
          : null,
    );
  }

  @override
  Future<AgentChangeRequest> requestAdminReview(
    int listingId,
    String reason,
  ) async {
    final response = await _client.post(
      '/api/v1/staff/listings/${listingId.toInt()}/review-request',
      {'reason': reason},
    );
    final row = response['change_request'];
    if (row is! Map<String, dynamic>) {
      throw StateError('The backend returned no change request record.');
    }
    return AgentChangeRequest.fromJson(row);
  }

  @override
  Future<({List<AgentChangeRequest> requests, List<AgentActivityEvent> audit})>
  changeHistory(int listingId) async {
    final response = await _client.get(
      '/api/v1/staff/listings/${listingId.toInt()}/change-requests',
    );
    return (
      requests: [
        for (final row in _rows(response, 'requests'))
          AgentChangeRequest.fromJson(row),
      ],
      audit: [for (final row in _rows(response, 'audit')) _auditEvent(row)],
    );
  }

  @override
  Future<void> addNote(int listingId, String note) => _client.post(
    '/api/v1/staff/listings/${listingId.toInt()}/notes',
    {'note': note},
  );

  @override
  Future<List<AgentActivityEvent>> verificationFindings(int listingId) async {
    final response = await _client.get(
      '/api/v1/staff/listings/${listingId.toInt()}/verifications',
    );
    // The endpoint answers a bare array; the WebAuth bridge wraps it under
    // `data` — both shapes are handled.
    final rows = (response['data'] as List? ?? const [])
        .whereType<Map<String, dynamic>>();
    return [
      for (final row in rows)
        AgentActivityEvent(
          source: 'verification',
          action: 'verification_finding',
          actorId: '${row['verified_by_user_id'] ?? ''}',
          note: row['verification_reason']?.toString(),
          createdAt: '${row['created_at'] ?? ''}',
          raw: row,
        ),
    ];
  }

  @override
  Future<void> uploadPhoto(
    int listingId, {
    required String filename,
    required String contentType,
    required List<int> bytes,
    String caption = '',
  }) => _client.uploadMultipart(
    '/api/v1/staff/listings/${listingId.toInt()}/photos',
    fields: {'caption': caption},
    fileField: 'file',
    filename: filename,
    bytes: bytes,
    contentType: contentType,
  );

  @override
  Future<void> deletePhoto(int listingId, int photoId) => _client.delete(
    '/api/v1/staff/listings/${listingId.toInt()}/photos/$photoId',
  );

  @override
  Future<void> setPrimaryPhoto(int listingId, int photoId) => _client.post(
    '/api/v1/staff/listings/${listingId.toInt()}/photos/$photoId/primary',
    <String, dynamic>{},
  );
}
