import 'dart:convert';
import 'dart:io';
import 'package:shared_logic/shared_logic.dart';
import 'package:test/test.dart';

Map<String, dynamic> heldFixture() => {
  'contract_version': 'project1-readiness/1',
  'assessment_id': null, 'property_id': null,
  for (final key in ['review', 'questionnaire', 'report', 'activity'])
    key: {'state': 'held', 'code': 'TEST_HOLD', 'message': 'Synthetic test hold.'},
  'fielding_authorized': false, 'report_release_authorized': false,
};

class ReadClient extends ApiClient {
  Map<String, dynamic> data;
  Object? failure;
  final paths = <String>[];
  ReadClient(this.data);
  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) async {
    paths.add(path);
    if (failure != null) throw failure!;
    return data;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected write or download.');
}

void main() {
  test('shared transport consumes an actual isolated FastAPI response', () async {
    final path = Platform.environment['P1_CONTRACT_FIXTURE']!;
    final json = jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    final client = ReadClient(json);
    final result = await ApiProject1ReadRepository(client).read();
    expect(result.questionnaire.code, 'QUESTIONNAIRE_AUTHORIZATION_REQUIRED');
    expect(result.report.code, 'REPORT_ADMISSION_REQUIRED');
    expect(result.assessmentId, isNull);
    expect(client.paths.single, '/api/v1/project1-read/readiness');
  }, skip: Platform.environment['P1_CONTRACT_FIXTURE'] == null
      ? 'Set P1_CONTRACT_FIXTURE to the guarded backend test response.' : false);

  test('a failed read stays failed and never becomes an empty success', () async {
    final client = ReadClient(heldFixture())..failure = StateError('Unavailable');
    await expectLater(ApiProject1ReadRepository(client).read(), throwsStateError);
    expect(client.paths, hasLength(1));
  });

  test('wrong assessment binding and an empty requested id fail closed', () async {
    final client = ReadClient({...heldFixture(), 'assessment_id': 'another-id'});
    await expectLater(ApiProject1ReadRepository(client).read(assessmentId: 'requested-id'), throwsFormatException);
    await expectLater(ApiProject1ReadRepository(client).read(assessmentId: ''), throwsArgumentError);
  });

  for (final field in ['fielding_authorized', 'report_release_authorized']) {
    test('availability cannot promote $field', () {
      expect(() => Project1Readiness.fromJson({...heldFixture(), field: true}), throwsFormatException);
    });
  }

  test('unknown schema or an asserted available artifact is rejected', () {
    expect(() => Project1Readiness.fromJson({...heldFixture(), 'contract_version': 'unexpected/2'}), throwsFormatException);
    expect(() => Project1Readiness.fromJson({...heldFixture(), 'report': {'state': 'available'}}), throwsFormatException);
  });
}
