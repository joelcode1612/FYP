import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/service_locator.dart';
import 'provider_models.dart';

/// Transport for the shared Provider workspace surfaces that are NOT listing
/// reads: the enquiry inbox, the performance report and account verification.
///
/// All three answer the SAME question on the server — "which properties may
/// this account manage" — resolved from ownership or assignment, so nothing
/// here filters by role or agent id on the client. An owner and an agent call
/// identical endpoints; the server decides what comes back.
abstract final class ProviderWorkspaceService {
  /// Enquiries received for the listings this account manages.
  ///
  /// [status] filters server-side; passing null returns every state. [limit]
  /// caps the rows so a caller that groups by property can ask for more than
  /// the inbox default — it must compare `metrics.total` against the returned
  /// row count to know whether the grouping saw the whole inbox.
  static Future<({List<ProviderEnquiry> enquiries, ProviderEnquiryMetrics metrics})>
  enquiries({ProviderEnquiryStatus? status, int limit = 100}) async {
    final response = await ServiceLocator.apiClient.get(
      '/api/v1/provider/enquiries',
      query: {
        if (status != null && status.isSettable) 'status': status.wire,
        'limit': '$limit',
      },
    );
    return (
      enquiries: [
        for (final row in (response['data'] as List? ?? const [])
            .whereType<Map<String, dynamic>>())
          ProviderEnquiry.fromJson(row),
      ],
      metrics: ProviderEnquiryMetrics.fromJson(
        response['meta'] as Map<String, dynamic>? ?? const {},
      ),
    );
  }

  /// Move one enquiry forward. Returns the server's own updated row so the
  /// screen never predicts the new state.
  static Future<ProviderEnquiry> updateEnquiry({
    required int enquiryId,
    required ProviderEnquiryStatus status,
    String? reply,
  }) async {
    final response = await ServiceLocator.apiClient.patch(
      '/api/v1/provider/enquiries/${enquiryId.toInt()}',
      {
        'status': status.wire,
        if (reply != null && reply.trim().isNotEmpty) 'reply': reply.trim(),
      },
    );
    final row = response['data'];
    if (row is! Map<String, dynamic>) {
      throw const ResponseFormatFailure(
        'The server did not return the updated enquiry.',
      );
    }
    return ProviderEnquiry.fromJson(row);
  }

  /// Listing and enquiry figures over the managed properties.
  static Future<ProviderPerformance> performance() async {
    final response = await ServiceLocator.apiClient.get(
      '/api/v1/provider/performance',
    );
    final row = response['data'];
    if (row is! Map<String, dynamic>) {
      throw const ResponseFormatFailure(
        'The server did not return a performance report.',
      );
    }
    return ProviderPerformance.fromJson(row);
  }

  /// Who manages one listing, straight from the backend's derivation.
  ///
  /// `/properties/listings/{id}` is authorized for the owner OR an agent that
  /// holds the assignment, so one call covers both provider kinds. A read that
  /// fails returns [ProviderManagement.unknown] — the page says the manager
  /// could not be resolved rather than implying "no manager".
  static Future<ProviderManagement> management(int listingId) async {
    try {
      final response = await ServiceLocator.apiClient.get(
        '/api/v1/properties/listings/${listingId.toInt()}',
      );
      final data = response['data'];
      if (data is Map<String, dynamic>) {
        final management = data['management'];
        if (management is Map<String, dynamic>) {
          return ProviderManagement.fromJson(management);
        }
      }
    } catch (_) {
      // Scope refusal or transport failure: reported as unavailable below.
    }
    return ProviderManagement.unknown;
  }

  /// The account-level verification state, plus the requirements served by the
  /// backend (so the screen never restates them from a local copy).
  static Future<ProviderVerification> verification() async {
    final response = await ServiceLocator.apiClient.get(
      '/api/v1/provider/verification',
    );
    final row = response['data'];
    if (row is! Map<String, dynamic>) {
      throw const ResponseFormatFailure(
        'The server did not return a verification status.',
      );
    }
    return ProviderVerification.fromJson(row);
  }

  /// Submit (or re-submit after a rejection) for administrator review.
  static Future<ProviderVerification> submitVerification({
    required String businessName,
    required String contactPhone,
    String? registrationNo,
    String? submissionNote,
  }) async {
    final response = await ServiceLocator.apiClient.post(
      '/api/v1/provider/verification',
      {
        'business_name': businessName.trim(),
        'contact_phone': contactPhone.trim(),
        if (registrationNo != null && registrationNo.trim().isNotEmpty)
          'registration_no': registrationNo.trim(),
        if (submissionNote != null && submissionNote.trim().isNotEmpty)
          'submission_note': submissionNote.trim(),
      },
    );
    final row = response['data'];
    if (row is! Map<String, dynamic>) {
      throw const ResponseFormatFailure(
        'The server did not return a verification status.',
      );
    }
    return ProviderVerification.fromJson(row);
  }
}
