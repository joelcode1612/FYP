import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:shared_logic/shared_logic.dart';

class RecordingClient extends ApiClient {
  Map<String, dynamic> response;
  int writes = 0;
  String? path;
  Map<String, dynamic>? body;
  RecordingClient(this.response);
  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    writes++;
    this.path = path;
    this.body = body;
    return response;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected request');
}

void main() {
  test('generic M2 actions cannot override the saved source revision', () {
    const aid = '00000000-0000-4000-8000-000000000001';
    const iid = '00000000-0000-4000-8000-000000000002';
    final d = M2Draft.fromJson({
      'assessment': {'id': aid, 'revision': 2, 'instrument_id': iid},
      'instrument': {'id': iid},
      'items': [
        {'item_key': 'M2-01', 'id': iid, 'instrument_id': iid},
      ],
      'answers': <String, dynamic>{},
    }, assessmentId: aid);
    final c = RecordingClient({});
    expect(
      () => ApiM2Repository(c).action(d, 'review', {'expected_revision': 9}),
      throwsArgumentError,
    );
    expect(c.writes, 0);
  });
  final file = Platform.environment['V13_CONTEXT_FIXTURE'];
  group(
    'actual private PostgreSQL/FastAPI BCB envelope',
    () {
      Map<String, dynamic> fixture() =>
          jsonDecode(File(file!).readAsStringSync()) as Map<String, dynamic>;
      test(
        'named build pins request and accepts the exact persisted UTF-8 packet hash',
        () async {
          final d = fixture(), c = RecordingClient(d);
          final result = await ApiM2Repository(c).buildContext(
            d['assessment_id'],
            d['confirmation_id'],
            d['assessment_revision'],
          );
          expect(result.id, d['context_id']);
          expect(c.writes, 1);
          expect(
            c.path,
            '/api/v1/m2/assessments/${d['assessment_id']}/business-context',
          );
          expect(c.body, {
            'confirmation_id': d['confirmation_id'],
            'expected_revision': d['assessment_revision'],
          });
          expect(result.data['qj_execution_authorized'], false);
          expect(
            () =>
                result.data['packet']['identity']['assessment_id'] = 'tampered',
            throwsUnsupportedError,
          );
        },
      );
      for (final mutation in [
        'revision',
        'confirmation',
        'payload',
        'authority',
      ]) {
        test('rejects context mismatch: $mutation', () {
          final d = fixture(),
              aid = d['assessment_id'] as String,
              cid = d['confirmation_id'] as String,
              rev = d['assessment_revision'] as int;
          if (mutation == 'revision') d['assessment_revision'] = rev + 1;
          if (mutation == 'confirmation')
            d['confirmation_id'] = '00000000-0000-4000-8000-000000000099';
          if (mutation == 'payload')
            d['packet']['identity']['assessment_id'] = 'tampered';
          if (mutation == 'authority') d['qj_execution_authorized'] = true;
          expect(
            () => M2BusinessContext.parse(d, aid, cid, rev),
            throwsFormatException,
          );
        });
      }
    },
    skip: file == null
        ? 'Set V13_CONTEXT_FIXTURE to an actual isolated FastAPI context receipt.'
        : false,
  );
}
