import '../../core/network/api_client.dart';
import '../../domain/entities/property_verification.dart';
import '../../domain/repositories/property_verification_repository.dart';

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
      VerificationDocument.fromJson(
        payload['data'] is Map<String, dynamic>
            ? payload['data'] as Map<String, dynamic>
            : payload,
      );

  PropertyVerification _verification(Map<String, dynamic> payload) =>
      PropertyVerification.fromJson(
        payload['data'] is Map<String, dynamic>
            ? payload['data'] as Map<String, dynamic>
            : payload,
      );

  @override
  Future<VerificationStatusView> statusForProperty(String propertyId) async =>
      VerificationStatusView.fromJson(
        await _client.get(
          '/api/v1/properties/$propertyId/verification',
        ),
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
  Future<List<int>> downloadDocument(String documentId) =>
      _client.downloadBinary(
        '/api/v1/properties/verification-documents/$documentId',
      );

  @override
  Future<VerificationQueuePage> adminQueue(
    VerificationQueueFilters filters,
  ) async {
    final response = await _client.get(
      '/api/v1/staff/properties/',
      query: filters.toQuery(),
    );
    return VerificationQueuePage.fromJson(
      response['data'] is Map<String, dynamic>
          ? response['data'] as Map<String, dynamic>
          : response,
    );
  }

  @override
  Future<VerificationDetail> adminDetail(String propertyId) async =>
      VerificationDetail.fromJson(
        await _client.get('/api/v1/staff/properties/$propertyId'),
      );

  Future<PropertyVerification> _decide(
    String propertyId,
    VerificationDimension dimension,
    String action, [
    Map<String, String>? extra,
  ]) async => _verification(
    await _client.post(
      '/api/v1/staff/properties/$propertyId/verification/$action',
      {
        'dimension': dimension.wire,
        ...?extra,
      },
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
