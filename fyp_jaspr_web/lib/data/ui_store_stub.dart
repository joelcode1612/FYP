/// Server half of the per-visitor UI store: decode-only.
///
/// The cookie is written by the browser (`ui_store_browser.dart`); the SSR pass
/// only ever reads it, straight off the request.
library;

import 'dart:convert';

import 'package:shared_logic/shared_logic.dart' show BusinessPreferences;

const String kUiCookie = 'sitewise_ui';
const String kPrefsCookie = 'sitewise_prefs';

/// Cookie values are short lists of ids; anything longer is trimmed so the
/// cookie stays well inside the 4 KB browser limit.
const int kMaxSaved = 40;

typedef UiState = ({
  Set<String> saved,
  Set<String> compared,
  Set<String> roles,
});

const UiState emptyUiState = (saved: {}, compared: {}, roles: {});

typedef PrefState = ({
  String businessType,
  String propertyType,
  double minBudgetRm,
  double maxBudgetRm,
  double minSizeSqft,
  double maxSizeSqft,
  List<String> requirements,
});

abstract final class UiStore {
  static UiState read(Map<String, String> cookies) {
    final raw = cookies[kUiCookie];
    if (raw == null || raw.isEmpty) return emptyUiState;
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return emptyUiState;
      Set<String> ids(Object? list, [int limit = 1 << 30]) => {
        for (final id in (list as List? ?? const []).take(limit))
          if (id is String && id.isNotEmpty) id,
      };
      return (
        saved: ids(value['s'], kMaxSaved),
        compared: ids(value['c'], 3),
        roles: <String>{}, // Never restore client-written role grants
      );
    } on Object {
      return emptyUiState;
    }
  }

  /// No-op on the server: the server cannot set a cookie on someone else's
  /// navigation, and the value it read is already correct.
  static void write(UiState state) {}

  /// Decodes the entrepreneur's stored recommendation preferences. Returns
  /// null when no stored copy exists — callers keep their defaults then.
  static PrefState? readPreferences(Map<String, String> cookies) {
    final raw = cookies[kPrefsCookie];
    if (raw == null || raw.isEmpty) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return null;
      double toDoubleOf(Object? v) => v is num
          ? v.toDouble()
          : (double.tryParse('$v') ?? 0);
      return (
        businessType: '${value['bt'] ?? ''}',
        propertyType: '${value['pt'] ?? ''}',
        minBudgetRm: toDoubleOf(value['nb']),
        maxBudgetRm: toDoubleOf(value['xb']),
        minSizeSqft: toDoubleOf(value['ns']),
        maxSizeSqft: toDoubleOf(value['xs']),
        requirements: [
          for (final r in (value['rq'] as List? ?? const []))
            if (r is String && r.isNotEmpty) r,
        ],
      );
    } on Object {
      return null;
    }
  }

  /// No-op on the server (the browser writes its own cookie).
  static void writePreferences(BusinessPreferences prefs) {}
}
