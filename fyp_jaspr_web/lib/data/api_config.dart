/// Server-only API configuration — the single source of truth for how the
/// Jaspr SSR process reaches the intended Sitewise FastAPI backend.
///
/// This file is imported ONLY by `main.server.dart` and `auth_stub.dart` (the VM
/// implementation of the auth/data bridge). It uses `dart:io`, so it must never
/// be reachable from `auth_browser.dart` / the client build.
library;

import 'dart:io' show Platform;

/// Origin of the intended backend (`FYP/backend`, uvicorn on port 8000).
///
/// Used by two server-side consumers:
///  * the same-origin `/api/*` proxy installed in `main.server.dart`, and
///  * the SSR HTTP client in `auth_stub.dart` that replays the request's bearer
///    token when a page is rendered on the server.
///
/// Override for a differently hosted backend with `SITEWISE_API_BASE`. The
/// value is NEVER embedded in a browser asset — the browser talks to this
/// server, which proxies to the backend.
final Uri kBackendApiBase = Uri.parse(
  Platform.environment['SITEWISE_API_BASE'] ?? 'http://127.0.0.1:8000',
);

/// Public API base the browser should use, emitted as `<meta name="sitewise-api">`.
///
/// Empty (the default) means **same-origin**: the browser requests `/api/v1/...`
/// on the Jaspr server and the server-side proxy forwards it. No host or port is
/// baked into the JS bundle, so there is no cross-origin request and no CORS
/// dependency. Set `SITEWISE_PUBLIC_API_BASE` only when the API is deliberately
/// served from another origin (that origin must allow this site via CORS).
final String kPublicApiBase = () {
  final value = Platform.environment['SITEWISE_PUBLIC_API_BASE'] ?? '';
  return value.trim().replaceAll(RegExp(r'/+$'), '');
}();
