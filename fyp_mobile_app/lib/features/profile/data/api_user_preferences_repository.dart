import 'package:shared_logic/shared_logic.dart';

/// Server-confirmed preferences for the signed-in entrepreneur.
/// The mobile client uses the exact same endpoints and field names as web.
class UserPreferencesRecord {
  final Map<String, dynamic>? preferences;
  final bool saved;
  final String? updatedAt;

  const UserPreferencesRecord({
    required this.preferences,
    required this.saved,
    required this.updatedAt,
  });

  factory UserPreferencesRecord.fromJson(Map<String, dynamic> response) {
    final payload = response['data'] is Map
        ? Map<String, dynamic>.from(response['data'] as Map)
        : response;
    final raw = payload['preferences'];
    return UserPreferencesRecord(
      preferences: raw is Map ? Map<String, dynamic>.from(raw) : null,
      saved: payload['saved'] == true,
      updatedAt: payload['updated_at'] as String?,
    );
  }
}

class ApiUserPreferencesRepository {
  final ApiClient _client;

  const ApiUserPreferencesRepository(this._client);

  Future<UserPreferencesRecord> load() async =>
      UserPreferencesRecord.fromJson(
        await _client.get('/api/v1/preferences/me'),
      );

  Future<UserPreferencesRecord> save(Map<String, dynamic> values) async =>
      UserPreferencesRecord.fromJson(
        await _client.patch(
          '/api/v1/preferences/me',
          {'preferences': values},
        ),
      );

  /// Real catalogue property types, without provider availability counts.
  Future<List<String>> propertyTypes() async {
    final response = await _client.get('/api/v1/catalog/property-types');
    final rows = response['data'];
    if (rows is! List) {
      throw const ResponseFormatFailure(
        'The property-type list returned by the server is invalid.',
      );
    }
    return <String>{
      for (final row in rows)
        if (row is Map && row['value'] is String &&
            (row['value'] as String).trim().isNotEmpty)
          (row['value'] as String).trim(),
    }.toList(growable: false);
  }
}
