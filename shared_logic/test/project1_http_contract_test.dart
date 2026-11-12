import 'dart:convert';
import 'dart:io';
import 'package:shared_logic/shared_logic.dart';
import 'package:test/test.dart';

class PrivateHttpClient extends ApiClient {
  final String? token;
  final HttpClient transport = HttpClient();
  PrivateHttpClient(this.token);
  Future<({int status, Map<String, dynamic> body})> request(String path, {String method = 'GET'}) async {
    final base = Uri.parse(Platform.environment['P1_HTTP_BASE']!);
    if (base.host != '127.0.0.1' || !base.hasPort) throw StateError('Private loopback lab required.');
    final request = await transport.openUrl(method, base.resolve(path));
    if (token != null) request.headers.set('Authorization', 'Bearer $token');
    final response = await request.close();
    final data = jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, dynamic>;
    return (status: response.statusCode, body: data);
  }
  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) async {
    final response = await request(path);
    if (response.status != 200) throw HttpException('HTTP ${response.status}');
    return response.body;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected operation.');
}

void main() {
  group('private FastAPI to shared Dart contract', () {
    late PrivateHttpClient client;
    setUp(() => client = PrivateHttpClient(Platform.environment['P1_HTTP_TOKEN']));
    tearDown(() => client.transport.close(force: true));

    test('CA-01 holds the questionnaire without offering synthetic fielding', () async {
      final result = await ApiProject1ReadRepository(client).read();
      expect(result.questionnaire.code, 'QUESTIONNAIRE_AUTHORIZATION_REQUIRED');
      expect(result.assessmentId, isNull);
    });
    test('CA-02 returns a report hold bound to the owned workspace', () async {
      final aid = Platform.environment['P1_HTTP_ASSESSMENT']!;
      final result = await ApiProject1ReadRepository(client).read(assessmentId: aid);
      expect(result.assessmentId, aid);
      expect(result.report.code, 'REPORT_ADMISSION_REQUIRED');
      expect(result.activity.code, 'RESEARCH_AUDIT_BINDING_REQUIRED');
    });
    test('a different signed principal cannot read another workspace', () async {
      final other = PrivateHttpClient(Platform.environment['P1_HTTP_OTHER_TOKEN']);
      try {
        await expectLater(ApiProject1ReadRepository(other).read(
          assessmentId: Platform.environment['P1_HTTP_ASSESSMENT']), throwsA(isA<HttpException>()));
      } finally { other.transport.close(force: true); }
    });
    test('the read endpoint rejects unauthenticated access and mutation', () async {
      final anonymous = PrivateHttpClient(null);
      try {
        expect((await anonymous.request('/api/v1/project1-read/readiness')).status, 401);
      } finally { anonymous.transport.close(force: true); }
      expect((await client.request('/api/v1/project1-read/readiness', method: 'POST')).status, 405);
    });
  }, skip: Platform.environment['P1_HTTP_BASE'] == null
      ? 'Run backend/tests/integration/run_cross_app.py for the private HTTP lab.' : false);
}
