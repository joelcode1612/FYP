import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/features/property_management/domain/entities/provider_models.dart';

/// Transport for the shared Provider workspace surfaces that are NOT listing
/// reads: the account identity, the performance report and account
/// verification.
///
/// The report and the verification status both answer the SAME question on the
/// server — "which properties may this account manage" — resolved from
/// ownership or assignment, so nothing here filters by role or agent id on the
/// client. An owner and an agent call identical endpoints; the server decides
/// what comes back.
///
/// The Enquiries transport was removed with the feature: the mobile Provider
/// workspace no longer reads or displays an enquiry inbox. The backend
/// endpoints and stored records are untouched.
abstract final class ProviderWorkspaceService {
  static String _inspectionPath(int propertyId) =>
      '/api/v1/provider-flow/properties/$propertyId';

  static Future<Map<String, dynamic>> inspection(int propertyId) async {
    final response = await ServiceLocator.apiClient.get(
      '${_inspectionPath(propertyId)}/inspection',
    );
    final data = response['data'];
    if (data is! Map<String, dynamic>) {
      throw const ResponseFormatFailure('The server did not return an inspection.');
    }
    return data;
  }

  static Future<void> inspectionCommand(
    int propertyId, String action, Map<String, dynamic> body,
  ) async {
    await ServiceLocator.apiClient.post('${_inspectionPath(propertyId)}/$action', body);
  }

  static Future<void> saveInspection(
    int propertyId, Map<String, dynamic> checklist,
  ) async {
    await ServiceLocator.apiClient.patch('${_inspectionPath(propertyId)}/inspection', checklist);
  }

  /// The signed-in account's own identity payload (`GET /api/v1/auth/me`).
  ///
  /// Returned as the server sent it: the profile page reads fields directly
  /// and reports the missing ones as unavailable. A failed read throws through
  /// the client so the page keeps showing its own error state.
  static Future<Map<String, dynamic>> profile() =>
      ServiceLocator.apiClient.get('/api/v1/auth/me');

  /// Listing figures over the managed properties.
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
