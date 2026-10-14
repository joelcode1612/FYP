import 'package:flutter/foundation.dart';

/// Development logging for the 360° module. All lines are prefixed with
/// `[360]`; disable via [enabled] for production.

abstract final class CaptureLog {
  static bool enabled = true;

  static void log(String message) {
    if (enabled) debugPrint('[360] $message');
  }
}
