import '../../domain/entities/property_verification.dart';
import '../../domain/repositories/property_verification_repository.dart';

/// Submitter-side verification flow (the property's owning account): read
/// the current status, attach evidence and submit each resubmittable
/// dimension for review.
///
/// Complements — does not replace — the legacy demo [VerificationService]:
/// that one drives the demo-data admin queue; this one is the live workflow
/// backed by `property_verification` and the authenticated document store.
class PropertyVerificationService {
  final PropertyVerificationRepository repo;
  const PropertyVerificationService(this.repo);

  Future<VerificationStatusView> status(String propertyId) =>
      repo.statusForProperty(propertyId);

  Future<PropertyVerification> submit(String propertyId) =>
      repo.submit(propertyId);

  Future<VerificationDocument> uploadDocument({
    required String propertyId,
    required VerificationDimension dimension,
    required String documentType,
    required String filename,
    required List<int> bytes,
    required String contentType,
  }) => repo.uploadDocument(
    propertyId: propertyId,
    upload: VerificationDocumentUpload(
      dimension: dimension,
      documentType: documentType,
      filename: filename,
      bytes: bytes,
      contentType: contentType,
    ),
  );

  Future<List<int>> download(String documentId) =>
      repo.downloadDocument(documentId);
}

/// Administrator review workspace flow: the server-backed queue with
/// composable filters and faceted counts, the per-property review detail,
/// and the per-dimension decisions (start review / approve / reject /
/// request information).
///
/// All rules live in the backend — this service transports decisions and
/// maps results; publication eligibility (both dimensions verified) is
/// recomputed server-side on every decision.
class AdminPropertyReviewService {
  final PropertyVerificationRepository repo;
  const AdminPropertyReviewService(this.repo);

  Future<VerificationQueuePage> queue(
    VerificationQueueFilters filters,
  ) => repo.adminQueue(filters);

  Future<VerificationDetail> detail(String propertyId) =>
      repo.adminDetail(propertyId);

  Future<PropertyVerification> startReview(
    String propertyId,
    VerificationDimension dimension,
  ) => repo.startReview(propertyId, dimension);

  Future<PropertyVerification> approve(
    String propertyId,
    VerificationDimension dimension,
  ) => repo.approve(propertyId, dimension);

  Future<PropertyVerification> reject(
    String propertyId,
    VerificationDimension dimension,
    String reason,
  ) => repo.reject(propertyId, dimension, reason);

  Future<PropertyVerification> requestInformation(
    String propertyId,
    VerificationDimension dimension,
    String note,
  ) => repo.requestInformation(propertyId, dimension, note);
}
