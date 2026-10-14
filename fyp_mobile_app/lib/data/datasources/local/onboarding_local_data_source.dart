import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Persistence primitive for the mobile first-run flag.
///
/// Kept behind an interface so widgets/controllers never touch
/// `SharedPreferences`/files directly, and so tests can swap in the
/// in-memory variant. Mirrors the file layout used by `CaptureFrameStore`:
/// `<appDocs>/sitewise/state/<file>`.

abstract class OnboardingLocalDataSource {
  Future<bool> hasCompletedOnboarding();

  Future<void> setOnboardingCompleted();

  Future<void> resetOnboarding();
}

/// File-backed implementation (no extra dependency — reuses `path_provider`,
/// which the project already ships for the panorama pipeline).
class FileOnboardingLocalDataSource implements OnboardingLocalDataSource {
  static const String _fileName = 'onboarding.json';

  /// Conceptual key from the brief; stored as a JSON field.
  static const String flagKey = 'sitewise_mobile_onboarding_completed';

  bool? _cache;

  Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/sitewise/state');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/$_fileName');
  }

  @override
  Future<bool> hasCompletedOnboarding() async {
    if (_cache != null) return _cache!;
    try {
      final file = await _file();
      if (!await file.exists()) return _cache = false;
      final data = jsonDecode(await file.readAsString());
      final completed = data is Map && data[flagKey] == true;
      return _cache = completed;
    } catch (_) {
      // Unsupported platform / missing plugin (e.g. widget tests): report
      // "not completed" instead of crashing the boot sequence.
      return _cache ?? false;
    }
  }

  @override
  Future<void> setOnboardingCompleted() async {
    _cache = true;
    await _write(true);
  }

  @override
  Future<void> resetOnboarding() async {
    _cache = false;
    await _write(false);
  }

  Future<void> _write(bool completed) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode({flagKey: completed}), flush: true);
    } catch (_) {
      // Best effort: the in-memory cache keeps the current session coherent.
    }
  }
}

/// In-memory implementation for widget tests and unsupported platforms.
class InMemoryOnboardingLocalDataSource implements OnboardingLocalDataSource {
  bool completed;

  InMemoryOnboardingLocalDataSource({this.completed = false});

  @override
  Future<bool> hasCompletedOnboarding() async => completed;

  @override
  Future<void> setOnboardingCompleted() async => completed = true;

  @override
  Future<void> resetOnboarding() async => completed = false;
}
