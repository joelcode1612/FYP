import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Persistence primitive for user-scoped, non-sensitive form drafts.
///
/// Layout: `<appDocs>/sitewise/drafts/<namespace>/<workflow>.json`, where
/// `<namespace>` is the account id the draft belongs to (or `device` for
/// pre-auth drafts such as the remembered sign-in email). One account can
/// therefore never read another account's saved data, and a draft survives
/// process termination because it is a plain file written with `flush: true`.
///
/// SECURITY CONTRACT: only non-sensitive values may be written through this
/// store — form fields, selections, image file paths. Passwords, tokens and
/// session material must never be passed here; they belong to
/// `flutter_secure_storage` (see `SecureSessionLocalStorage`).
abstract class DraftLocalDataSource {
  /// The stored payload for [workflow] under [namespace], or null.
  Future<Map<String, dynamic>?> read(String namespace, String workflow);

  Future<void> write(
    String namespace,
    String workflow,
    Map<String, dynamic> payload,
  );

  Future<void> clear(String namespace, String workflow);

  /// Removes every draft for [namespace] (sign-out hygiene, explicit discard).
  Future<void> clearNamespace(String namespace);
}

class FileDraftLocalDataSource implements DraftLocalDataSource {
  Future<Directory> _dir(String namespace) async {
    final docs = await getApplicationDocumentsDirectory();
    final safeNamespace = namespace.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final dir = Directory('${docs.path}/sitewise/drafts/$safeNamespace');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file(String namespace, String workflow) async {
    final dir = await _dir(namespace);
    final safeWorkflow = workflow.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File('${dir.path}/$safeWorkflow.json');
  }

  @override
  Future<Map<String, dynamic>?> read(String namespace, String workflow) async {
    try {
      final file = await _file(namespace, workflow);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      // Corrupt or unreadable draft: report "no draft" rather than crashing
      // the screen that would have restored it.
      return null;
    }
  }

  @override
  Future<void> write(
    String namespace,
    String workflow,
    Map<String, dynamic> payload,
  ) async {
    try {
      final file = await _file(namespace, workflow);
      await file.writeAsString(jsonEncode(payload), flush: true);
    } catch (_) {
      // Best effort: the in-session state stays coherent even if the disk
      // write fails; the next successful write replaces it.
    }
  }

  @override
  Future<void> clear(String namespace, String workflow) async {
    try {
      final file = await _file(namespace, workflow);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Same best-effort contract as [write].
    }
  }

  @override
  Future<void> clearNamespace(String namespace) async {
    try {
      final dir = await _dir(namespace);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Best effort.
    }
  }
}

/// In-memory implementation for widget tests and unsupported platforms.
class InMemoryDraftLocalDataSource implements DraftLocalDataSource {
  final Map<String, Map<String, dynamic>> _store = {};

  String _key(String namespace, String workflow) => '$namespace/$workflow';

  @override
  Future<Map<String, dynamic>?> read(String namespace, String workflow) async =>
      _store[_key(namespace, workflow)];

  @override
  Future<void> write(
    String namespace,
    String workflow,
    Map<String, dynamic> payload,
  ) async => _store[_key(namespace, workflow)] = Map.of(payload);

  @override
  Future<void> clear(String namespace, String workflow) async =>
      _store.remove(_key(namespace, workflow));

  @override
  Future<void> clearNamespace(String namespace) async =>
      _store.removeWhere((key, _) => key.startsWith('$namespace/'));
}
