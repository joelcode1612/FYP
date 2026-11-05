/// Server half of the per-visitor UI store: decode-only.
///
/// The cookie is written by the browser (`ui_store_browser.dart`); the SSR pass
/// only ever reads it, straight off the request.
library;

import 'dart:convert';

const String kUiCookie = 'sitewise_ui';

/// Cookie values are short lists of ids; anything longer is trimmed so the
/// cookie stays well inside the 4 KB browser limit.
const int kMaxSaved = 40;

typedef UiState = ({
  Set<String> saved,
  Set<String> compared,
  Set<String> roles,
});

const UiState emptyUiState = (saved: {}, compared: {}, roles: {});

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
        roles: ids(value['g'], 4),
      );
    } on Object {
      return emptyUiState;
    }
  }

  /// No-op on the server: the server cannot set a cookie on someone else's
  /// navigation, and the value it read is already correct.
  static void write(UiState state) {}
}
