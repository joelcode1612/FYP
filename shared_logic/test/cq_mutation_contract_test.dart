import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:shared_logic/shared_logic.dart';

class Client extends ApiClient {
  int writes = 0;
  @override
  Future<Map<String, dynamic>> post(String p, Map<String, dynamic> b) async {
    writes++;
    throw StateError('Must not dispatch');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected request');
}

void main() {
  test(
    'CQ caller cannot replace manifest/revision or dispatch arbitrary action',
    () async {
      final d =
          jsonDecode(
                File(
                  'test/fixtures/cq_session_isolated.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final s = CqSession.fromJson(d, allowIsolatedTesting: true), c = Client();
      final repo = ApiCustomerQuestionnaireRepository(
        c,
        allowIsolatedTesting: true,
      );
      for (final body in [
        {'expected_revision': 999},
        {'manifest_hash': 'forged'},
      ]) {
        await expectLater(repo.mutate(s, 'submit', body), throwsArgumentError);
      }
      await expectLater(repo.mutate(s, '../campaign', {}), throwsArgumentError);
      expect(c.writes, 0);
    },
  );
}
