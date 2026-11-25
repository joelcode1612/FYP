import '../../core/network/api_client.dart';
import '../../domain/entities/property_verification.dart';
import '../../domain/repositories/property_verification_repository.dart';
import '../mappers/property_verification_mapper.dart';

/// Live [PropertyVerificationRepository] over the authenticated FastAPI
/// endpoints (`backend/src/sitewise/api/v1/property_verification.py`):
/// submitter routes under `/api/v1/properties/...` and administrator review
/// routes under `/api/v1/staff/properties/...`.
///
/// Transport only — every authorization and lifecycle rule is enforced by the
/// backend. A non-2xx response throws with the backend's own `detail`
/// sentence, so dialogs render the server's words verbatim.
class ApiPropertyVerificationRepository
    implements PropertyVerificationRepository {
  final ApiClient _client;

  ApiPropertyVerificationRepository(this._client);

  VerificationDocument _document(Map<String, dynamic> payload) =>
      PropertyVerificationMapper.document(payload);

  PropertyVerification _verification(Map<String, dynamic> payload) =>
      PropertyVerificationMapper.verification(payload);

  @override
  Future<VerificationStatusView> statusForProperty(String propertyId) async =>
      PropertyVerificationMapper.statusView(
        await _client.get('/api/v1/properties/$propertyId/verification'),
      );

  @override
  Future<PropertyVerification> submit(
    String propertyId, {
    String? scope,
    bool acknowledgeUnavailablePopulation = false,
  }) async => _verification(
    await _client.post(
      '/api/v1/properties/$propertyId/verification/submit',
      // The wire default is `full`; the key is only sent when the caller
      // explicitly narrows the scope, so legacy payloads stay identical.
      {
        if (scope != null && scope != 'full') 'scope': scope,
        if (acknowledgeUnavailablePopulation)
          'acknowledge_unavailable_population': true,
      },
    ),
  );

  @override
  Future<VerificationDocument> uploadDocument({
    required String propertyId,
    required VerificationDocumentUpload upload,
  }) async => _document(
    await _client.uploadMultipart(
      '/api/v1/properties/$propertyId/verification/documents',
      fields: {
        'verification_type': upload.dimension.wire,
        'document_type': upload.documentType,
      },
      fileField: 'file',
      filename: upload.filename,
      bytes: upload.bytes,
      contentType: upload.contentType,
    ),
  );

  @override
  Future<List<int>> downloadDocument(String documentId) => _client
      .downloadBinary('/api/v1/properties/verification-documents/$documentId');

  @override
  Future<VerificationQueuePage> adminQueue(
    VerificationQueueFilters filters,
  ) async {
    final response = await _client.get(
      '/api/v1/staff/properties/',
      query: filters.toQuery(),
    );
    return PropertyVerificationMapper.queuePage(response);
  }

  @override
  Future<VerificationDetail> adminDetail(String propertyId) async =>
      PropertyVerificationMapper.detail(
        await _client.get('/api/v1/staff/properties/$propertyId'),
      );

  @override
  Future<void> finalDecision(
    String propertyId,
    Map<String, dynamic> decision,
  ) async {
    await _client.post(
      '/api/v1/staff/properties/$propertyId/final-review',
      decision,
    );
  }

  Future<LocationResearchAssociation> locationIntelligence(
    String propertyId,
  ) async => LocationResearchAssociation.fromJson(
    await _client.get(
      '/api/v1/staff/properties/$propertyId/location-intelligence',
    ),
  );

  /// Queues one category (or every category) for recalculation.
  ///
  /// Returns the backend's own explanation when the request could not do any
  /// work — most often because the listing has no usable location — so the
  /// reviewer is told what is wrong instead of being shown a success message
  /// for a queue entry that was never created.
  Future<String?> queueLocationIntelligence(
    String propertyId, {
    String? category,
  }) async {
    final action = category == null ? 'recalculate' : 'retry/$category';
    final response = await _client.post(
      '/api/v1/staff/properties/$propertyId/location-intelligence/$action',
      {},
    );
    final location = response['location'];
    if (location is Map && location['located'] != true) {
      final reason = location['reason'];
      if (reason is String && reason.isNotEmpty) return reason;
    }
    if (response['queued'] == true) {
      return category == null
          ? 'Queued every measurement category for recalculation.'
          : 'Queued $category for recalculation.';
    }
    final reason = response['reason'];
    return reason is String && reason.isNotEmpty ? reason : null;
  }

  /// Queues only the measurement categories that are missing, failed or stale
  /// for the property's current coordinates. Pass [full] only when an
  /// administrator explicitly asks for a full recalculation.
  ///
  /// Returns the backend's own reason when nothing needed queueing.
  Future<String?> analyzeLocationIntelligence(
    String propertyId, {
    bool full = false,
  }) async {
    final response = await _client.post(
      '/api/v1/staff/properties/$propertyId/location-intelligence/analyze'
      '${full ? '?full=true' : ''}',
      const {},
    );
    final queued = response['queued'];
    final reason = response['reason'];
    if (reason is String && reason.isNotEmpty) return reason;
    if (queued is List && queued.isNotEmpty) {
      return 'Queued ${queued.length} categor${queued.length == 1 ? 'y' : 'ies'} '
          'for calculation.';
    }
    return null;
  }

  Future<PropertyVerification> _decide(
    String propertyId,
    VerificationDimension dimension,
    String action, [
    Map<String, String>? extra,
  ]) async => _verification(
    await _client.post(
      '/api/v1/staff/properties/$propertyId/verification/$action',
      {'dimension': dimension.wire, ...?extra},
    ),
  );

  @override
  Future<PropertyVerification> startReview(
    String propertyId,
    VerificationDimension dimension,
  ) => _decide(propertyId, dimension, 'start-review');

  @override
  Future<PropertyVerification> approve(
    String propertyId,
    VerificationDimension dimension,
  ) => _decide(propertyId, dimension, 'approve');

  @override
  Future<PropertyVerification> reject(
    String propertyId,
    VerificationDimension dimension,
    String reason,
  ) => _decide(propertyId, dimension, 'reject', {'reason': reason});

  @override
  Future<PropertyVerification> requestInformation(
    String propertyId,
    VerificationDimension dimension,
    String note,
  ) => _decide(propertyId, dimension, 'request-information', {'note': note});
}
