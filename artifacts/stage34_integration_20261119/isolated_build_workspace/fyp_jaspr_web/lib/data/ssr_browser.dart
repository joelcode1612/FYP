/// Browser implementation of the response helpers: the status line is already
/// on the wire, so there is nothing to set after hydration.
library;

import 'package:jaspr/jaspr.dart';

void setStatusCode(BuildContext context, int code) {}

/// The console has no status line of its own; the server already sent one.
void redirectTo(BuildContext context, String location) {}

Map<String, String> requestCookies(BuildContext context) => const {};
