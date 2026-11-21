import '../../core/network/api_client.dart';
import '../../domain/repositories/saved_properties_repository.dart';

/// Live [SavedPropertiesRepository] over the authenticated FastAPI
/// `/api/v1/saved-properties` endpoints (`public.favourite_property`).
///
/// Refs are CATALOGUE ids (`EP-xxxxx`) — the backend validates every write
/// against the catalogue, so a `fyp.rental_properties` numeric id would 404.
/// Ownership always comes from the verified bearer token server-side.
///
/// DELETE answers 204 with no body; the shared [ApiClient] contract turns
/// that into an empty map, which is treated as success.
class ApiSavedPropertiesRepository implements SavedPropertiesRepository {
  final ApiClient _client;

  ApiSavedPropertiesRepository(this._client);

  @override
  Future<Set<String>> savedRefs() async =>
      (await savedWithUnresolved()).resolved;

  @override
  Future<({Set<String> resolved, Set<String> unresolved})>
  savedWithUnresolved() async {
    final response = await _client.get('/api/v1/saved-properties/me');
    final saved = [
      for (final row
          in (response['saved'] as List? ?? const [])
              .whereType<Map<String, dynamic>>())
        '${row['property_ref']}',
    ];
    final unresolved = {
      for (final ref in (response['unresolved'] as List? ?? const [])) '$ref',
    };
    // Delisted refs are reported by the server, never silently dropped — but
    // they also never enter the caller's shortlist, which must only contain
    // properties that still resolve.
    return (
      resolved: {
        for (final ref in saved) if (!unresolved.contains(ref)) ref,
      },
      unresolved: unresolved,
    );
  }

  @override
  Future<void> save(String propertyRef) => _client.post(
    '/api/v1/saved-properties/',
    {'property_ref': propertyRef},
  );

  @override
  Future<void> unsave(String propertyRef) =>
      _client.delete('/api/v1/saved-properties/me/${Uri.encodeComponent(propertyRef)}');
}
