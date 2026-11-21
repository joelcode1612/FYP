import '../../core/network/api_client.dart';

/// Separate operator contract. Never returns a participatory CQ session.
class ApiSyntheticInspectionRepository {
  ApiSyntheticInspectionRepository(this.client);
  final ApiClient client;
  static const _path = '/api/v1/cq/developer-imports';

  Map<String, dynamic> _checked(Map<String, dynamic> value) {
    if (value['contract_version'] != 'synthetic-inspection/1' ||
        value['origin'] != 'SYNTHETIC_TEST' ||
        value['real_reportable'] != false ||
        value['participant_collection_enabled'] != false) {
      throw const FormatException('Unsafe synthetic inspection contract.');
    }
    return Map<String, dynamic>.unmodifiable(value);
  }

  Future<List<Map<String, dynamic>>> runs() async {
    final data = _checked(await client.get(_path));
    return (data['runs'] as List)
        .map(
          (v) => Map<String, dynamic>.unmodifiable(v as Map<String, dynamic>),
        )
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> inspect(String runId) async =>
      _checked(await client.get('$_path/${Uri.encodeComponent(runId)}'));

  Future<List<Map<String, dynamic>>> cases(String runId) async {
    final d = await client.get('$_path/${Uri.encodeComponent(runId)}/cases');
    if (d['contract_version'] != 'synthetic-cases/1' ||
        d['origin'] != 'SYNTHETIC_TEST' ||
        d['real_reportable'] != false) {
      throw const FormatException('Unsafe synthetic execution case list.');
    }
    return (d['cases'] as List).cast<Map<String, dynamic>>();
  }
}
