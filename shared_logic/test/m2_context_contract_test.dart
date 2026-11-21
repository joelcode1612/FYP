import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:crypto/crypto.dart';

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
  test('BCB 1.1 binds the explicitly selected objective', () async {
    const aid = '00000000-0000-4000-8000-000000000001';
    const cid = '00000000-0000-4000-8000-000000000002';
    const objective = '00000000-0000-4000-8000-000000000003';
    const context = '00000000-0000-4000-8000-000000000004';
    final packet = <String, dynamic>{
      'schema_version': 'business-context-package/1.1',
      'identity': {'assessment_id': aid},
      'confirmation': {'id': cid, 'revision': 3, 'status': 'CURRENT_CONFIRMED'},
      'confirmed_uncertainty': {'id': objective},
      'geography': null,
      'permissions': {'qj_execution': false, 'qg_execution': false},
    };
    packet['packet_hash'] = sha256
        .convert(utf8.encode(canonicalSourceJson(packet)))
        .toString();
    final client = RecordingClient({
      'contract_version': 'persisted-business-context/1',
      'assessment_id': aid,
      'confirmation_id': cid,
      'assessment_revision': 3,
      'lifecycle_status': 'PERSISTED',
      'context_id': context,
      'replayed': false,
      'created_at': '2026-01-01T00:00:00Z',
      'qj_execution_authorized': false,
      'qg_execution_authorized': false,
      'packet': packet,
    });
    final repository = ApiM2Repository(client);
    expect(
      (await repository.buildContext(aid, cid, 3, objectiveId: objective)).id,
      context,
    );
    expect(client.body!['objective_id'], objective);
    await expectLater(
      repository.buildContext(aid, cid, 3, objectiveId: aid),
      throwsFormatException,
    );
  });
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
