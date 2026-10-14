import 'package:shared_logic/shared_logic.dart';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';


/// Demo/local authentication implementation.
///
/// The project currently runs in demo-data mode ([AppConfig.usesDemoData]);
/// there is no Supabase client in `pubspec.yaml`. This implementation keeps
/// the *contract* the UI depends on, backed by [DemoData.users], and persists
/// the active session to `<appDocs>/sitewise/state/session.json` so returning
/// users are routed correctly across restarts.
///
/// When Supabase is introduced, replace this class with a
/// `SupabaseAuthRepository` — [AuthService] and every widget stay untouched.

class AuthRepositoryImpl implements AuthRepository {
  static const String _sessionFile = 'session.json';

  final Map<String, SitewiseUser> _registered = {};
  SitewiseUser? _session;
  bool _restored = false;

  @override
  List<SitewiseUser> get demoAccounts =>
      AppConfig.usesDemoData ? DemoData.users : const [];

  @override
  Future<SitewiseUser?> currentUser() async {
    if (_session != null) return _session;
    if (_restored) return null;
    _restored = true;
    _session = await _readSession();
    return _session;
  }

  @override
  Future<bool> isAuthenticated() async => await currentUser() != null;

  @override
  Future<SitewiseUser> signInWithEmail({
    required String email,
    required String password,
  }) async {
    final normalized = email.trim().toLowerCase();
    if (password.length < 6) {
      throw const ValidationFailure(
        'Password must contain at least 6 characters.',
      );
    }
    final user = _findByEmail(normalized);
    if (user == null) {
      throw const ValidationFailure(
        'No Sitewise account found for that email. Try a demo account or sign up.',
      );
    }
    if (user.status.toLowerCase() != 'active') {
      throw ValidationFailure(
        'This ${user.role.label} account is ${user.status}. Contact Sitewise support.',
      );
    }
    await _persist(user);
    return user;
  }

  @override
  Future<SitewiseUser> signUpWithEmail({
    required String email,
    required String password,
  }) async {
    final normalized = email.trim().toLowerCase();
    if (password.length < 6) {
      throw const ValidationFailure(
        'Password must contain at least 6 characters.',
      );
    }
    if (_findByEmail(normalized) != null) {
      throw const ValidationFailure(
        'An account already exists for that email. Log in instead.',
      );
    }
    // New self-service accounts are F&B entrepreneurs.
    final user = SitewiseUser(
      id: 'ent-${DateTime.now().millisecondsSinceEpoch}',
      name: _nameFromEmail(normalized),
      email: normalized,
      role: AppRole.entrepreneur,
      status: 'Active',
      location: 'Kuala Lumpur',
      joinedAt: DateTime.now(),
    );
    _registered[normalized] = user;
    await _persist(user);
    return user;
  }

  @override
  Future<SitewiseUser> signInWithProvider(AuthProvider provider) async {
    // Demo: providers resolve to the seeded F&B entrepreneur account.
    final user = _findByEmail('sarah@artisanbrew.my') ?? DemoData.users.first;
    await _persist(user);
    return user;
  }

  @override
  Future<void> signOut() async {
    _session = null;
    _restored = true;
    await _deleteSession();
  }

  // --- internals -----------------------------------------------------------

  SitewiseUser? _findByEmail(String email) {
    final local = _registered[email];
    if (local != null) return local;
    for (final user in DemoData.users) {
      if (user.email.toLowerCase() == email) return user;
    }
    return null;
  }

  static String _nameFromEmail(String email) {
    final handle = email.split('@').first;
    final parts = handle
        .split(RegExp(r'[._\-]+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'Sitewise User';
    return parts.map((p) => p[0].toUpperCase() + p.substring(1)).join(' ');
  }

  Future<void> _persist(SitewiseUser user) async {
    _session = user;
    _restored = true;
    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode({
          'id': user.id,
          'name': user.name,
          'email': user.email,
          'role': user.role.name,
          'status': user.status,
          'location': user.location,
          'joinedAt': user.joinedAt.toIso8601String(),
        }),
        flush: true,
      );
    } catch (_) {
      // Best effort: the in-memory session still drives this run.
    }
  }

  Future<SitewiseUser?> _readSession() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return SitewiseUser(
        id: data['id'] as String,
        name: data['name'] as String,
        email: data['email'] as String,
        role: AppRole.values.firstWhere(
          (r) => r.name == data['role'],
          orElse: () => AppRole.entrepreneur,
        ),
        status: data['status'] as String? ?? 'Active',
        location: data['location'] as String? ?? '',
        joinedAt:
            DateTime.tryParse(data['joinedAt'] as String? ?? '') ??
            DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _deleteSession() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort.
    }
  }

  Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/sitewise/state');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/$_sessionFile');
  }
}
