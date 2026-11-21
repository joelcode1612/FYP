/// Server implementation of the response helpers (see `ssr_service.dart`).
library;

import 'package:jaspr/server.dart';

/// Sets the HTTP status of the rendered document.
void setStatusCode(BuildContext context, int code) =>
    context.setStatusCode(code);

/// Sends the browser somewhere else with a real `302`.
///
/// `jaspr_router` builds the `Location` from the matched path and drops the
/// query string, so `/login?next=…` has to be set here instead of coming back
/// out of the router's redirect callback.
void redirectTo(BuildContext context, String location) {
  context.setStatusCode(302);
  context.setHeader('Location', location);
}

/// Cookies sent with the current request; empty in tests.
Map<String, String> requestCookies(BuildContext context) => context.cookies;
