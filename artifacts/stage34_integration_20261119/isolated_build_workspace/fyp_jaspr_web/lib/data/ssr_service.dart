/// The two response-side helpers that only exist while rendering on the server.
///
/// `app.dart` is compiled for both targets, and `package:jaspr/server.dart`
/// drags in `dart:io` + shelf, so the server-only calls live behind this
/// conditional export instead of being imported directly by the router.
library;

export 'ssr_stub.dart' if (dart.library.js_interop) 'ssr_browser.dart';
