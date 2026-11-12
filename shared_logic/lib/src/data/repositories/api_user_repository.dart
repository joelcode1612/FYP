import '../../core/network/api_client.dart';
import '../../domain/entities/app_role.dart';
import '../../domain/entities/user.dart';
import '../../domain/repositories/admin_repositories.dart';

/// Live [UserRepository] over the authenticated FastAPI `/users` endpoints.
///
/// Depends only on the abstract [ApiClient] port, so it stays pure Dart and
/// browser-safe (no `http`, no Flutter, no Supabase import). The platform
/// supplies a bearer-aware client; the backend enforces administrator + `aal2`
/// on every route here, so this repository never decides authorization.
///
/// Replaces the demo `UserRepositoryImpl` for the web admin console. The read
/// shape mirrors `backend/src/sitewise/api/v1/users.py::_profile_payload`.
class ApiUserRepository implements UserRepository {
  final ApiClient _client;

  ApiUserRepository(this._client);

  /// Backend `list_users` caps `limit` at 200 and returns a bare array (no
  /// total), so paging stops on the first short page.
  static const int _pageSize = 200;

  /// Same canonicalisation the backend applies on read (`rbac.LEGACY_ROLE_ALIASES`).
  /// `_profile_payload` returns the stored role verbatim, so legacy values can
  /// still arrive here and must be normalised before mapping to [AppRole].
  static const Map<String, String> _roleAliases = {
    'administrator': 'admin',
    'property_owner': 'entrepreneur',
    'user': 'entrepreneur',
  };

  static AppRole _role(String? raw) {
    final canonical = raw == null ? '' : (_roleAliases[raw] ?? raw);
    return switch (canonical) {
      'admin' => AppRole.admin,
      'agent' => AppRole.agent,
      'owner' => AppRole.owner,
      _ => AppRole.entrepreneur,
    };
  }

  /// Backend statuses are lowercase (`active`/`pending`/`suspended`); the shared
  /// UI vocabulary capitalises them (`AdminCubit.pendingUsers` matches 'Pending',
  /// `StatusBadge.forText` keyword-matches). Unknown values pass through verbatim.
  static String _status(String? raw) => switch ((raw ?? '').toLowerCase()) {
    'active' => 'Active',
    'pending' => 'Pending',
    'suspended' => 'Suspended',
    _ => raw ?? '',
  };

  /// Maps one `_profile_payload` row to the domain entity. The backend exposes
  /// no location, so it is left empty rather than invented; `joinedAt` is the
  /// authoritative `created_at` (epoch only when the server omitted it).
  static SitewiseUser fromJson(Map<String, dynamic> row) {
    final email = row['email'] as String? ?? '';
    final fullName = (row['full_name'] as String?)?.trim() ?? '';
    final created = row['created_at'] as String?;
    return SitewiseUser(
      id: '${row['user_id']}',
      name: fullName.isNotEmpty ? fullName : email,
      email: email,
      role: _role(row['role'] as String?),
      status: _status(row['account_status'] as String?),
      location: '',
      joinedAt:
          (created == null ? null : DateTime.tryParse(created)) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      listingCount: (row['listing_count'] as num?)?.toInt(),
    );
  }

  @override
  Future<List<SitewiseUser>> getUsers() async {
    final users = <SitewiseUser>[];
    var offset = 0;
    while (true) {
      final response = await _client.get(
        '/api/v1/users/',
        query: {'limit': '$_pageSize', 'offset': '$offset'},
      );
      // The bridge wraps a bare array as {'data': [...]} on both platforms.
      final page = (response['data'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
      users.addAll(page.map(fromJson));
      offset += page.length;
      if (page.length < _pageSize) break;
    }
    return List.unmodifiable(users);
  }

  @override
  Future<SitewiseUser?> getUserById(String id) async {
    try {
      // GET /users/{id} returns a single object, so the payload is the map
      // itself (not wrapped). A 404/403 throws in the bridge → null here.
      return fromJson(await _client.get('/api/v1/users/$id'));
    } on Object {
      return null;
    }
  }
}