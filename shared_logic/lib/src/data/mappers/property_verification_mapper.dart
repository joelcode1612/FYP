/// Wire → entity mapping for the property-verification API.
///
/// This is the data-layer entry point for `/api/v1/properties/*/verification`
/// and `/api/v1/staff/properties/*` payloads. It owns the backend's response
/// envelope (`data` wrapper) so repositories never re-implement it.
///
/// Field names and defaults stay identical to the entity factories; no
/// business rule is re-derived here.
library;

import '../../domain/entities/property_verification.dart';

abstract final class PropertyVerificationMapper {
  static Map<String, dynamic> unwrap(Map<String, dynamic> response) =>
      response['data'] is Map<String, dynamic>
          ? response['data'] as Map<String, dynamic>
          : response;

  static PropertyVerification verification(Map<String, dynamic> response) =>
      PropertyVerification.fromJson(unwrap(response));

  static VerificationDocument document(Map<String, dynamic> response) =>
      VerificationDocument.fromJson(unwrap(response));

  static VerificationStatusView statusView(Map<String, dynamic> response) =>
      VerificationStatusView.fromJson(response);

  static VerificationQueuePage queuePage(Map<String, dynamic> response) =>
      VerificationQueuePage.fromJson(unwrap(response));

  static VerificationDetail detail(Map<String, dynamic> response) =>
      VerificationDetail.fromJson(response);
}
