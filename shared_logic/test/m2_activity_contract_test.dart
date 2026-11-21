import 'package:test/test.dart';
import 'package:shared_logic/shared_logic.dart';

const aid = '00000000-0000-4000-8000-000000000001';
const eid = '00000000-0000-4000-8000-000000000002';

Map<String, dynamic> history() => {
  'contract_version': 'm2-activity/1',
  'assessment_id': aid,
  'assessment_revision': 3,
  'events': [
    {
      'event_id': eid,
      'kind': 'CONTEXT_PERSISTED',
      'assessment_revision': 2,
      'occurred_at': '2026-11-13T10:00:00Z',
      'actor_id': null,
      'module': 'BCB',
      'status': 'PERSISTED',
      'source_is_current': false,
    },
  ],
  'truncated': false,
  'history_extension': 'workflow-history-metadata/1',
  'bcb_history_available': true,
  'bcb_statuses_truncated': false,
  'authorization_decisions_included': false,
  'bcb_statuses': [
    {
      'confirmation_id': eid,
      'assessment_revision': 2,
      'status': 'FAILED',
      'attempt_count': 1,
      'source_is_current': false,
      'context_id': null,
    },
  ],
};

class Client extends ApiClient {
  Map<String, dynamic> data = history();
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async => data;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Read only');
}

void main() {
  test('legacy activity stays readable without pretending workflow coverage exists', () async {
    final c = Client();
    c.data.remove('history_extension');
    c.data.remove('bcb_statuses');
    final data = await ApiM2Repository(c).activity(aid);
    expect(data['history_extension'], isNull);
  });
  test(
    'accepts historical context and distinct current failure without promoting authority',
    () async {
      final result = await ApiM2Repository(Client()).activity(aid);
      expect(result['events'][0]['status'], 'PERSISTED');
      expect(result['events'][0]['source_is_current'], false);
      expect(result['bcb_statuses'][0]['status'], 'FAILED');
      expect(result['authorization_decisions_included'], false);
    },
  );
  for (final mutation in [
    'assessment',
    'future',
    'duplicate',
    'timezone',
    'actor',
    'authority',
    'snapshot',
  ]) {
    test('rejects invalid activity binding: $mutation', () async {
      final c = Client();
      final e = c.data['events'][0] as Map<String, dynamic>;
      switch (mutation) {
        case 'assessment':
          c.data['assessment_id'] = eid;
        case 'future':
          e['assessment_revision'] = 4;
        case 'duplicate':
          c.data['events'].add(Map<String, dynamic>.from(e));
        case 'timezone':
          e['occurred_at'] = '2026-11-13T10:00:00';
        case 'actor':
          e['actor_id'] = 'unverified identity';
        case 'authority':
          c.data['authorization_decisions_included'] = true;
        case 'snapshot':
          c.data['bcb_statuses'][0]['assessment_revision'] = 4;
      }
      await expectLater(
        ApiM2Repository(c).activity(aid),
        throwsFormatException,
      );
    });
  }
  test(
    'missing optional source is unavailable rather than successful empty history',
    () async {
      final c = Client();
      c.data['bcb_history_available'] = false;
      c.data['bcb_statuses'] = [];
      expect(
        (await ApiM2Repository(c).activity(aid))['bcb_history_available'],
        false,
      );
    },
  );
}
