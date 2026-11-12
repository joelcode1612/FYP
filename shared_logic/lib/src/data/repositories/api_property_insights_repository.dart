import '../../core/network/api_client.dart';
import '../models/property_insights_model.dart';

/// Live read of `/api/v1/catalog/properties/{id}/insights`.
///
/// Returns `null` rather than throwing when the request fails or the listing
/// has no verified link to the model: the caller then shows an honest
/// "not available" state instead of an error dialog on a detail page.
///
/// Nothing is computed here. The score, the SHAP factors and the category
/// totals all come from the backend's deployed artifact; this class only
/// decodes them.
class ApiPropertyInsightsRepository {
  final ApiClient _client;

  ApiPropertyInsightsRepository(this._client);

  Future<PropertyInsightsModel?> fetch(String propertyId) async {
    try {
      final response = await _client.get(
        '/api/v1/catalog/properties/${Uri.encodeComponent(propertyId)}/insights',
      );
      // The bridge may hand back the bare object or wrap it under `data`.
      final payload = response['property_id'] != null
          ? response
          : (response['data'] as Map<String, dynamic>? ?? response);
      return PropertyInsightsModel.fromJson(payload);
    } on Object {
      return null;
    }
  }
}
