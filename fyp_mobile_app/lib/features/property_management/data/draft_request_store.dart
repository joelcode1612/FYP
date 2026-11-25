import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

/// Stores only the request UUID, scoped to the account that issued the create.
class DraftRequestStore {
  const DraftRequestStore(this._storage);

  final FlutterSecureStorage _storage;

  String? get accountKey {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      return userId == null ? null : 'sitewise.draft-request.$userId';
    } on StateError {
      return null;
    } on AssertionError {
      return null;
    }
  }

  Future<String?> read(String key) => _storage.read(key: key);

  Future<void> remember(String key, String id) =>
      _storage.write(key: key, value: id);

  Future<void> forget(String key, String id) async {
    if (await read(key) == id) {
      await _storage.delete(key: key);
    }
  }
}
