/// Browser entrypoint — the whole application.
///
/// With `jaspr: mode: client` there is no server render: FastAPI (the unified
/// app server) delivers this script via `web/index.html`, and `runApp` mounts
/// the full router into `<body>` — every route, guard and cubit lives here.
///
/// Navigation is client-side (History API). A hard refresh of a nested route
/// lands on FastAPI's SPA fallback, which returns `index.html`, and this
/// entrypoint boots the router at that URL.
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:jaspr/client.dart';

import 'package:sitewise_jaspr_web/app.dart';
import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/features/authentication/data/auth_service.dart';

/// `window.location.replace` — a hard navigation, used only to re-enter a
/// destination the router already recorded (see [_resumeAfterLateAuth]).
@JS('window')
external _Window get _window;

extension type _Window(JSObject _) implements JSObject {
  external _Location get location;
}

extension type _Location(JSObject _) implements JSObject {
  external void replace(JSString url);
}

/// Backstop above the bridge's own worst case. The bridge retries its config
/// fetch four times (5 s timeout each, 600 ms apart) before giving up and
/// resolving, so a cap at or below that ceiling mounts mid-flight.
const _authCeiling = Duration(seconds: 15);

Future<void> main() async {
  Jaspr.initializeApp();

  // Saved/compare selections are read from the browser cookie so the first
  // frame already shows the visitor's state.
  AppLocator.installUiState();

  // Resolve the session *before* mounting, so the router guard and every page
  // that reads the profile (identity line, owner id, workspace redirects) see
  // the real one on its first build.
  //
  // DD-068: this used to cap the wait at 3 s, which is *below* the bridge's own
  // bounded worst case. When the config fetch was slow the cap fired first,
  // `runApp` mounted with `profile == null`, and the guard sent a perfectly
  // valid session to `/login?next=…` — with no `/api/v1/auth/me` ever issued,
  // because the mount beat the bridge to it. The cap is now a backstop above
  // the bridge's ceiling rather than a race the app loses.
  var settled = true;
  try {
    await WebAuth.initialize().timeout(_authCeiling);
  } catch (_) {
    // Anonymous boot: sign-in surfaces report their own errors when the user
    // submits, and protected workspaces redirect to /login (fail closed).
    settled = false;
  }

  // The cookie's compare shortlist is scoped to the account that wrote it:
  // a session that does not match must not inherit someone else's selection.
  AppLocator.applyAccountScope();

  // A signed-in account's saved shortlist comes from the server, not the
  // cookie — merged before mount so the first frame already shows it.
  await AppLocator.mergeAccountSaved();

  runApp(const SitewiseApp());

  // Only reachable when the backstop fired. The bridge is still running; when
  // it settles, re-enter the destination the guard already recorded instead of
  // stranding a signed-in user on the sign-in screen.
  if (!settled) unawaited(_resumeAfterLateAuth());
}

/// Re-enters the `next=` destination once a late auth bridge settles.
///
/// Deliberately narrow, so it cannot become a way around the guard: it runs
/// only on `/login`, only with a recorded `next`, and only when the bridge now
/// reports a real profile. An anonymous visitor has no profile and is left
/// exactly where the guard put them.
Future<void> _resumeAfterLateAuth() async {
  try {
    // Single-flight in the bridge: this awaits the promise already in progress,
    // it does not start a second initialization.
    await WebAuth.initialize();
  } catch (_) {
    return;
  }
  if (WebAuth.profile == null) return;

  final uri = Uri.base;
  if (uri.path != '/login') return;
  final next = uri.queryParameters['next'];
  if (next == null || next.isEmpty) return;
  // A hard navigation re-boots the app with the session already resolved, so
  // the guard evaluates once, with the profile present.
  _window.location.replace(next.toJS);
}
