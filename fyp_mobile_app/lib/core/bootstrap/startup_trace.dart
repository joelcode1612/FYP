import 'dart:io';

import 'package:flutter/foundation.dart';

/// Lightweight, development-only cold-start timing.
///
/// The trace starts at the Dart entrypoint, not at process start. On Android
/// [start] also estimates how long the OS/engine had already been running
/// before Dart got control (Linux `/proc` fields), which is the closest
/// obtainable "engine startup" figure without adding native code. All state
/// is in memory, every write is guarded by [kDebugMode], and the output
/// contains only phase names and elapsed milliseconds — never tokens, keys,
/// URLs, email addresses or response bodies.
///
/// Intended comparison baseline (device logcat, 2026-11-09 21:53 run):
/// `Start proc` -> engine connected ~1.8 s -> `Supabase init completed`
/// ~56 s later -> `Displayed ... +59s772ms`. The original implementation
/// awaited that initialization before `runApp`, so the screen stayed blank
/// for the entire interval.
abstract final class StartupTrace {
  static final Stopwatch _clock = Stopwatch();
  static final Map<String, int> _marks = <String, int>{};
  static final Set<String> _reported = <String>{};
  static bool _running = false;
  static int? _preDartMs;

  static bool get enabled => kDebugMode;

  /// Starts the clock. Calling this twice (hot restart, embedding) is a no-op.
  static void start() {
    if (!kDebugMode || _running) return;
    _running = true;
    _preDartMs = _processAgeMs();
    _clock.start();
    _marks['dart_entry'] = 0;
  }

  /// Records the first occurrence of [phase] (milliseconds since Dart entry).
  static void mark(String phase) {
    if (!kDebugMode || !_running) return;
    _marks.putIfAbsent(phase, () => _clock.elapsedMilliseconds);
  }

  /// Wraps an asynchronous phase with a start/end pair. Exceptions propagate
  /// unchanged — this is measurement only, never error handling.
  static Future<T> measure<T>(String phase, Future<T> Function() body) async {
    if (!kDebugMode) return body();
    mark('${phase}_start');
    try {
      return await body();
    } finally {
      mark('${phase}_end');
    }
  }

  /// Prints one line per [reason]. Repeated calls with the same reason do not
  /// spam logcat when several widgets resolve the same startup state.
  static void report(String reason) {
    if (!kDebugMode || !_reported.add(reason)) return;
    debugPrint('SiteWise startup [$reason]: $summary');
  }

  static String get summary {
    if (!_running) return 'trace not started';
    final out = StringBuffer();
    if (_preDartMs != null) out.write('engine_to_dart=${_preDartMs}ms ');
    out.write('elapsed=${_clock.elapsedMilliseconds}ms ');
    for (final phase in const <String>[
      'secure_storage',
      'secure_session_read',
      'supabase_initialize',
      'bootstrap',
      'session_restore',
      'identity_verification',
    ]) {
      final from = _marks['${phase}_start'];
      final to = _marks['${phase}_end'];
      final value = from == null || to == null ? 'n/a' : '${to - from}ms';
      out.write('$phase=$value ');
    }
    out.write('first_frame=${_msOrNa(_marks['first_frame'])} ');
    out.write('auth_done=${_msOrNa(_marks['session_restore_end'])}');
    return out.toString();
  }

  static String _msOrNa(int? value) => value == null ? 'n/a' : '${value}ms';

  /// Approximate milliseconds since the Android process was forked, measured
  /// at the Dart entrypoint: `/proc/uptime` minus `/proc/self/stat` field 22
  /// (`starttime`, in USER_HZ ticks; 100 on Android). Returns null on any
  /// non-Android platform or unreadable proc entry — diagnostics must never
  /// be able to break startup.
  static int? _processAgeMs() {
    if (!Platform.isAndroid) return null;
    try {
      final uptime = double.tryParse(
        File(
          '/proc/uptime',
        ).readAsStringSync().trim().split(RegExp(r'\s+')).first,
      );
      final stat = File('/proc/self/stat').readAsStringSync();
      final commEnd = stat.lastIndexOf(')');
      if (uptime == null || commEnd < 0) return null;
      // The comm field can contain spaces and ')' — split only the tail.
      final fields = stat.substring(commEnd + 1).trim().split(RegExp(r'\s+'));
      // fields[0] is proc field 3 (state), so field 22 is index 19.
      if (fields.length < 20) return null;
      final ticks = int.tryParse(fields[19]);
      if (ticks == null) return null;
      const ticksPerSecond = 100;
      final ageSeconds = uptime - ticks / ticksPerSecond;
      if (ageSeconds < 0 || ageSeconds > 3600) return null;
      return (ageSeconds * 1000).round();
    } on Object {
      return null;
    }
  }
}
