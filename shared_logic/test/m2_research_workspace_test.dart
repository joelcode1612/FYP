import 'package:shared_logic/shared_logic.dart';
import 'package:test/test.dart';

const assessment = '00000000-0000-4000-8000-000000000001';
const confirmation = '00000000-0000-4000-8000-000000000002';
const objective = '00000000-0000-4000-8000-000000000003';

class WorkspaceClient extends ApiClient {
  Map<String, dynamic> data;
  String? path;
  Map<String, String>? query;
  WorkspaceClient(this.data);
  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) async {
    this.path = path;
    this.query = query;
    return data;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected write');
}

void main() {
  Map<String, dynamic> fixture() => {'objectives': [{
    'id': objective, 'exact_text': 'Synthetic concern',
    'provenance': {'assessment_id': assessment, 'confirmation_id': confirmation, 'assessment_revision': 3},
  }]};
  test('authenticated transport reads exact confirmation and revision', () async {
    final client = WorkspaceClient(fixture());
    final result = await ApiM2Repository(client).readResearchWorkspace(assessment, confirmation, 3);
    expect(result.rows.single['exact_text'], 'Synthetic concern');
    expect(client.path, '/api/v1/m2/confirmations/$confirmation/research-workspace');
    expect(client.query, {'expected_revision': '3'});
    expect(() => result.rows.clear(), throwsUnsupportedError);
  });
  test('rejects a wrong source binding and malformed response', () async {
    final bad = fixture();
    (bad['objectives'] as List).first['provenance']['confirmation_id'] = objective;
    await expectLater(ApiM2Repository(WorkspaceClient(bad)).readResearchWorkspace(assessment, confirmation, 3), throwsFormatException);
    await expectLater(ApiM2Repository(WorkspaceClient({'objectives': null})).readResearchWorkspace(assessment, confirmation, 3), throwsFormatException);
  });
}
