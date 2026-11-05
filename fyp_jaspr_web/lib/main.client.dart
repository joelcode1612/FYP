/// Browser entrypoint — **hydration only**.
///
/// The page the browser received is already complete: `main.server.dart`
/// rendered it, and the `@client` leaves are marked in the markup with
/// `<!--@Name-->` … `<!--/@Name-->`. `ClientApp` finds those markers and mounts
/// the real component into each one, which is what attaches event handlers,
/// cubit subscriptions and local state.
///
/// There is deliberately **no router here**. Navigation is a normal document
/// request handled by the server, so the app behaves as a multi-page site and
/// every URL stays shareable and refreshable on its own.
library;

import 'dart:async';

import 'package:jaspr/client.dart';

import 'data/app_locator.dart';
import 'data/auth_service.dart';
import 'main.client.options.dart';

Future<void> main() async {
  Jaspr.initializeApp(options: defaultClientOptions);

  // Saved/compare selections and demo role grants are read from the cookie the
  // server rendered with, so the first client frame agrees with the markup.
  AppLocator.installUiState();

  // Resolve the session *before* mounting. Hydrated subtrees render once and
  // are not rebuilt when a parent changes, so a page that reads the profile
  // (identity line, owner id) must see the real one on its first build. The
  // wait is capped: a dead API must not leave the page permanently inert.
  try {
    await WebAuth.initialize().timeout(const Duration(seconds: 3));
  } catch (_) {
    // Public pages hydrate anonymously; sign-in surfaces report their own
    // errors when the user submits.
  }

  // `ClientApp` re-attaches to the server-rendered nodes at each `@client`
  // marker instead of creating a second app over them.
  runApp(const ClientApp());
}
