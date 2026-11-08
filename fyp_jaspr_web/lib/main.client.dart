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

import 'package:jaspr/client.dart';

import 'app.dart';
import 'data/app_locator.dart';
import 'data/auth_service.dart';

Future<void> main() async {
  Jaspr.initializeApp();

  // Saved/compare selections are read from the browser cookie so the first
  // frame already shows the visitor's state.
  AppLocator.installUiState();

  // Resolve the session *before* mounting, so the router guard and every page
  // that reads the profile (identity line, owner id, workspace redirects) see
  // the real one on its first build. The wait is capped: a dead API must not
  // leave the page permanently inert — public pages boot anonymously instead.
  try {
    await WebAuth.initialize().timeout(const Duration(seconds: 3));
  } catch (_) {
    // Anonymous boot: sign-in surfaces report their own errors when the user
    // submits, and protected workspaces redirect to /login (fail closed).
  }

  runApp(const SitewiseApp());
}
