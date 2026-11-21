import '../../core/errors/app_failure.dart';
import '../../core/network/api_client.dart';
import '../../domain/entities/property_compare.dart';
import '../../domain/repositories/property_compare_repository.dart';

/// Live client for `POST /api/v1/compare` — one batch request for up to three
/// selected catalogue ids. Both Jaspr and Flutter bind this same class.
class ApiPropertyCompareRepository implements PropertyCompareRepository {
  final ApiClient _client;

  const ApiPropertyCompareRepository(this._client);

  @override
  Future<PropertyCompareResult> compare(List<String> propertyIds) async {
    final response = await _client.post(
      '/api/v1/compare',
      {'property_ids': propertyIds},
    );
    final data = response['data'];
    if (data is! Map<String, dynamic>) {
      throw const ResponseFormatFailure(
        'The comparison response did not contain comparison data.',
      );
    }
    return PropertyCompareResult.fromJson(data);
  }
}
