import 'package:shared_logic/shared_logic.dart';
import 'package:test/test.dart';

/// F6 regression: the admin console reads live `/users` data, not demo rows.
///
/// These run against a fake [ApiClient] (no network, no ports, no Supabase) and
/// pin the transport contract the web bridge produces: a bare array wrapped as
/// `{'data': [...]}`, lowercase backend statuses, and verbatim legacy roles that
/// the repository must canonicalise. Authorization itself is the backend's job
/// (administrator + aal2); here we only assert the client requests that route.
void main() {
  group('ApiUserRepository.fromJson', () {
    test('maps the authoritative payload to the domain entity', () {
      final u = ApiUserRepository.fromJson(
        _row(id: 'abc-123', role: 'admin', status: 'active'),
      );
      expect(u.id, 'abc-123');
      expect(u.name, 'Test User');
      expect(u.email, 'user@example.com');
      expect(u.role, AppRole.admin);
      expect(u.status, 'Active');
      expect(u.location, isEmpty, reason: 'backend exposes no location');
      expect(u.joinedAt, DateTime.parse('2024-03-05T10:20:30+00:00'));
    });

    test('canonicalises legacy roles exactly as backend rbac does', () {
      expect(ApiUserRepository.fromJson(_row(role: 'administrator')).role,
          AppRole.admin);
      expect(ApiUserRepository.fromJson(_row(role: 'property_owner')).role,
          AppRole.entrepreneur);
      expect(
          ApiUserRepository.fromJson(_row(role: 'user')).role, AppRole.entrepreneur);
      expect(
          ApiUserRepository.fromJson(_row(role: 'agent')).role, AppRole.agent);
      expect(ApiUserRepository.fromJson(_row(role: 'entrepreneur')).role,
          AppRole.entrepreneur);
    });

    test('capitalises backend statuses to the shared UI vocabulary', () {
      expect(ApiUserRepository.fromJson(_row(status: 'pending')).status, 'Pending');
      expect(
          ApiUserRepository.fromJson(_row(status: 'suspended')).status, 'Suspended');
      expect(ApiUserRepository.fromJson(_row(status: 'active')).status, 'Active');
    });

    test('passes an unknown status through rather than guessing', () {
      expect(ApiUserRepository.fromJson(_row(status: 'locked')).status, 'locked');
    });

    test('falls back to email when full_name is missing or blank', () {
      expect(ApiUserRepository.fromJson(_row(fullName: null)).name,
          'user@example.com');
      expect(ApiUserRepository.fromJson(_row(fullName: '   ')).name,
          'user@example.com');
    });

    test('uses epoch joinedAt only when the server omitted created_at', () {
      expect(ApiUserRepository.fromJson(_row(createdAt: null)).joinedAt,
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
    });
  });

  group('ApiUserRepository.getUsers', () {
    test('requests the admin-only list route and unwraps the array', () async {
      final client = _FakeApiClient(pages: [
        [_row(id: 'u1'), _row(id: 'u2')],
      ]);
      final users = await ApiUserRepository(client).getUsers();
      expect(users.map((u) => u.id), ['u1', 'u2']);
      expect(client.calls.single.path, '/api/v1/users/');
      expect(client.calls.single.query, {'limit': '200', 'offset': '0'});
    });

    test('pages until a short page, advancing offset by the page size', () async {
      final client = _FakeApiClient(pages: [
        List.generate(200, (i) => _row(id: 'u$i')),
        [_row(id: 'last')],
      ]);
      final users = await ApiUserRepository(client).getUsers();
      expect(users, hasLength(201));
      expect(users.last.id, 'last');
      expect(client.calls, hasLength(2));
      expect(client.calls[0].query, {'limit': '200', 'offset': '0'});
      expect(client.calls[1].query, {'limit': '200', 'offset': '200'});
    });

    test('a full final page still terminates on the next empty page', () async {
      final client = _FakeApiClient(pages: [
        List.generate(200, (i) => _row(id: 'u$i')),
        <Map<String, dynamic>>[],
      ]);
      final users = await ApiUserRepository(client).getUsers();
      expect(users, hasLength(200));
      expect(client.calls, hasLength(2));
    });

    test('an empty directory yields no users', () async {
      final client = _FakeApiClient(pages: [<Map<String, dynamic>>[]]);
      expect(await ApiUserRepository(client).getUsers(), isEmpty);
    });

    test('propagates a backend denial instead of returning demo data', () async {
      final client = _FakeApiClient(error: StateError('403 Forbidden'));
      expect(ApiUserRepository(client).getUsers(), throwsA(isA<StateError>()));
    });
  });

  group('ApiUserRepository.getUserById', () {
    test('maps a single-object payload', () async {
      final client = _FakeApiClient(single: _row(id: 'solo', role: 'agent'));
      final u = await ApiUserRepository(client).getUserById('solo');
      expect(u?.id, 'solo');
      expect(u?.role, AppRole.agent);
      expect(client.calls.single.path, '/api/v1/users/solo');
    });

    test('returns null when the backend reports not found / forbidden', () async {
      final client = _FakeApiClient(error: StateError('404 Not Found'));
      expect(await ApiUserRepository(client).getUserById('ghost'), isNull);
    });
  });
}

Map<String, dynamic> _row({
  String id = 'u-1',
  String? email = 'user@example.com',
  String? fullName = 'Test User',
  String? role = 'entrepreneur',
  String? status = 'active',
  String? createdAt = '2024-03-05T10:20:30+00:00',
}) => {
  'user_id': id,
  'email': email,
  'full_name': fullName,
  'phone_number': null,
  'profile_picture_url': null,
  'role': role,
  'account_status': status,
  'email_verified': true,
  'last_login': null,
  'created_at': createdAt,
  'updated_at': null,
};

/// Records every GET and replays canned pages. Only `get` is exercised by the
/// repository; the write verbs are unimplemented so an accidental call fails
/// loudly rather than silently returning fake data.
class _FakeApiClient implements ApiClient {
  final List<List<Map<String, dynamic>>> pages;
  final Map<String, dynamic>? single;
  final Object? error;
  final List<({String path, Map<String, String>? query})> calls = [];
  int _i = 0;

  _FakeApiClient({this.pages = const [], this.single, this.error});

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) async {
    calls.add((path: path, query: query));
    if (error != null) throw error!;
    if (path != '/api/v1/users/') return single ?? <String, dynamic>{};
    final page = _i < pages.length ? pages[_i++] : <Map<String, dynamic>>[];
    return {'data': page};
  }

  @override
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> patch(String path, Map<String, dynamic> body) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> delete(String path) => throw UnimplementedError();
}