
import 'dart:convert';

import 'package:flutter/services.dart';

/// Loads public SiteWise mobile configuration from a JSON asset.
///
/// Call load() once before AppBootstrap.start() and runApp().
abstract final class MobileRuntimeConfig {
  static Map<String, dynamic> _values = const {};

  static Future<void> load() async {
    final raw = await rootBundle.loadString(
      'assets/config/sitewise_dev.json',
    );

    final decoded = jsonDecode(raw);

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Invalid SiteWise configuration JSON.',
      );
    }

    _values = Map<String, dynamic>.unmodifiable(decoded);
  }

  /// Returns a configuration string, or its fallback.
  static String value(
      String key, {
        String fallback = '',
      }) {
    final result = _values[key];

    if (result == null) {
      return fallback;
    }

    final text = result.toString().trim();

    return text.isEmpty ? fallback : text;
  }

  /// Accepts either JSON true/false or "true"/"false".
  static bool boolean(
      String key, {
        bool fallback = false,
      }) {
    final result = _values[key];

    if (result is bool) {
      return result;
    }

    if (result is String) {
      switch (result.trim().toLowerCase()) {
        case 'true':
          return true;
        case 'false':
          return false;
      }
    }

    return fallback;
  }
}
