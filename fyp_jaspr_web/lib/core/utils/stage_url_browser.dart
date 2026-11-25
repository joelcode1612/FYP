/// Browser half of [replaceStageInUrl].
library;

import 'dart:js_interop';

@JS('window')
external _Window get _window;

extension type _Window(JSObject _) implements JSObject {
  external _History get history;
  external _Location get location;
}

extension type _History(JSObject _) implements JSObject {
  external void replaceState(JSAny? data, JSString unused, JSString url);
}

extension type _Location(JSObject _) implements JSObject {
  external String get href;
}

/// Rewrite `?stage=` in the address bar without reloading the page.
void replaceStageInUrl(String stage) {
  final uri = Uri.parse(_window.location.href);
  final params = Map<String, String>.from(uri.queryParameters);
  if (params['stage'] == stage) return;
  params['stage'] = stage;
  _window.history.replaceState(
      null, ''.toJS, uri.replace(queryParameters: params).toString().toJS);
}
