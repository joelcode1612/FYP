import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:shared_logic/shared_logic.dart';

class SyntheticApi extends ApiClient {
  SyntheticApi(this.payload);
  final Map<String, dynamic> payload;
  String? path;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    this.path = path;
    return payload;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const run = '3d58c824-a82f-5b5f-b037-f70487971917';
  Map<String, dynamic> data() =>
      (jsonDecode(
              File('test/fixtures/cq_session_isolated.json').readAsStringSync(),
            )
            as Map<String, dynamic>)
        ..addAll({
          'synthetic_execution': true,
          'synthetic_run_id': run,
          'origin': 'SYNTHETIC_TEST',
          'real_reportable': false,
          'lifecycle_status': 'IN_PROGRESS',
        });
  test(
    'developer flow uses run-scoped paths and preserves original version DTO',
    () async {
      final d = data(), api = SyntheticApi(data());
      final s = await ApiCustomerQuestionnaireRepository.synthetic(
        api,
        runId: run,
      ).read(d['session_id'] as String);
      expect(api.path, '/api/v1/cq/developer-imports/$run/sessions/${s.id}');
      expect(s.revision, d['revision']);
      expect(s.manifestHash, d['manifest_hash']);
    },
  );
  test('developer parser rejects wrong run or reportable data', () async {
    for (final change in [
      {'synthetic_run_id': 'another-run'},
      {'real_reportable': true},
      {'synthetic_execution': false},
    ]) {
      final d = data()..addAll(change);
      await expectLater(
        ApiCustomerQuestionnaireRepository.synthetic(
          SyntheticApi(d),
          runId: run,
        ).read(d['session_id'] as String),
        throwsFormatException,
      );
    }
  });
  test('ordinary parser retains its isolated-scope refusal', () async {
    final d = data();
    await expectLater(
      ApiCustomerQuestionnaireRepository(
        SyntheticApi(d),
      ).read(d['session_id'] as String),
      throwsFormatException,
    );
  });
}
