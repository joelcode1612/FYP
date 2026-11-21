import '../entities/property_verification.dart';

/// The bytes of one evidence document plus how the transport must present it.
class VerificationDocumentUpload {
  final VerificationDimension dimension;
  final String documentType;
  final String filename;
  final List<int> bytes;
  final String contentType;

  const VerificationDocumentUpload({
    required this.dimension,
    required this.documentType,
    required this.filename,
    required this.bytes,
    required this.contentType,
  });
}

/// Contract for the unified property verification workflow.
///
/// Pure Dart, HTTP-independent: implementations live behind this port (the
/// live one rides the shared [ApiClient] transport). Every rule — ownership
/// scoping, RBAC + MFA, lifecycle transitions, both-verified publication —
/// is enforced server-side; this contract only transports and maps.
abstract class PropertyVerificationRepository {
  // -- submitter (the property's owning account) ---------------------------

  /// Current verification status, evidence and requested corrections for one
  /// owned property.
  Future<VerificationStatusView> statusForProperty(String propertyId);

  /// Submit (or resubmit) the property for verification. The backend moves
  /// each resubmittable dimension to `pending` and refuses invalid
  /// transitions with 409.
  ///
  /// [scope] selects how much is submitted: `null`/`'full'` keeps the
  /// historical contract (ownership evidence required, both dimensions go
  /// `pending`); `'listing'` submits the listing information only — the
  /// listing dimension enters review while ownership stays untouched
  /// (`not_submitted` on a first submission). Authorization is enforced
  /// server-side either way.
  ///
  /// [acknowledgeUnavailablePopulation] must be `true` once the owner has been
  /// told that population could not be measured for these coordinates. The
  /// backend refuses the submission (409) while enrichment is still running,
  /// and refuses it without this acknowledgement when population is
  /// unavailable — population is never estimated, so the gap has to be
  /// accepted explicitly rather than silently shipped to the reviewer.
  Future<PropertyVerification> submit(
    String propertyId, {
    String? scope,
    bool acknowledgeUnavailablePopulation = false,
  });

  /// Upload one evidence document (metadata is returned, bytes are stored
  /// server-side under an unpredictable key).
  Future<VerificationDocument> uploadDocument({
    required String propertyId,
    required VerificationDocumentUpload upload,
  });

  /// Download one document's bytes through the authenticated endpoint.
  Future<List<int>> downloadDocument(String documentId);

  // -- administrator review workspace ---------------------------------------

  /// One server-computed queue page with faceted status counts.
  Future<VerificationQueuePage> adminQueue(VerificationQueueFilters filters);

  /// Full review detail for one property.
  Future<VerificationDetail> adminDetail(String propertyId);

  /// `pending` -> `under_review` on one dimension.
  Future<PropertyVerification> startReview(
    String propertyId,
    VerificationDimension dimension,
  );

  /// Decide one dimension. The backend refuses invalid transitions with 409,
  /// requires a reason for rejections / notes for information requests, and
  /// recomputes publication eligibility (both-verified rule).
  Future<PropertyVerification> approve(
    String propertyId,
    VerificationDimension dimension,
  );

  Future<PropertyVerification> reject(
    String propertyId,
    VerificationDimension dimension,
    String reason,
  );

  Future<PropertyVerification> requestInformation(
    String propertyId,
    VerificationDimension dimension,
    String note,
  );
}
