import 'package:jaspr_test/jaspr_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:sitewise_jaspr_web/components/project1_read_panel.dart';
import 'package:sitewise_jaspr_web/data/app_locator.dart';

class ReadClient extends ApiClient {
  Object? failure;
  final paths = <String>[];
  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) async {
    paths.add(path);
    if (failure != null) throw failure!;
    return {
      'contract_version': 'project1-readiness/1', 'assessment_id': null, 'property_id': null,
      for (final key in ['review', 'questionnaire', 'report', 'activity'])
        key: {'state': 'held', 'code': 'TEST_HOLD', 'message': 'Verified server hold for $key.'},
      'fielding_authorized': false, 'report_release_authorized': false,
    };
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected write.');
}

void main() {
  late ApiProject1ReadRepository original;
  late ReadClient client;
  setUp(() {
    original = AppLocator.project1Read;
    client = ReadClient();
    AppLocator.project1Read = ApiProject1ReadRepository(client);
  });
  tearDown(() => AppLocator.project1Read = original);

  testComponents('report renders server hold without invented snapshot or statistics', (tester) async {
    tester.pumpComponent(const Project1ReadPanel(assessmentId: '', section: 'report'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Report held'), findsOneComponent);
    expect(find.text('Verified server hold for report.'), findsOneComponent);
    expect(find.text('Morning Junction Café'), findsNothing);
    expect(client.paths.single, '/api/v1/project1-read/readiness');
  });

  testComponents('failed read offers retry and does not show an empty successful history', (tester) async {
    client.failure = StateError('Offline');
    tester.pumpComponent(const Project1ReadPanel(assessmentId: '', section: 'activity'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Availability could not be verified'), findsOneComponent);
    client.failure = null;
    await tester.click(find.ancestor(of: find.text('Retry'), matching: find.tag('button')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Verified server hold for activity.'), findsOneComponent);
    expect(client.paths, hasLength(2));
  });
}
