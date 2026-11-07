/// Browser half of the per-visitor UI store: reads and writes the cookie.
library;

import 'dart:convert';
import 'dart:js_interop';

@JS('document')
external _Document get _document;

extension type _Document(JSObject _) implements JSObject {
  external JSString get cookie;
  external set cookie(JSString value);
  external JSString get baseURI;
}

const String kUiCookie = 'sitewise_ui';
const int kMaxSaved = 40;

typedef UiState = ({
  Set<String> saved,
  Set<String> compared,
  Set<String> roles,
});

const UiState emptyUiState = (saved: {}, compared: {}, roles: {});

Map<String, String> _cookies() {
  final out = <String, String>{};
  for (final part in _document.cookie.toDart.split(';')) {
    final index = part.indexOf('=');
    if (index <= 0) continue;
    out[part.substring(0, index).trim()] = part.substring(index + 1).trim();
  }
  return out;
}

abstract final class UiStore {
  static UiState read(Map<String, String> cookies) {
    final raw = _cookies()[kUiCookie];
    if (raw == null || raw.isEmpty) return emptyUiState;
    try {
      final value = jsonDecode(Uri.decodeFull(raw));
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

  static void write(UiState state) {
    final value = jsonEncode({
      's': state.saved.take(kMaxSaved).toList(),
      'c': state.compared.take(3).toList(),
    });
    final secure = _document.baseURI.toDart.startsWith('https:') ? '; Secure' : '';
    _document.cookie =
        '$kUiCookie=${Uri.encodeComponent(value)}; Path=/; SameSite=Lax; Max-Age=28800$secure'
            .toJS;
  }
}
