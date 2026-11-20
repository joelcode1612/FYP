/// Development-only authentication bypass for the Jaspr client app.
///
/// Two independent gates must BOTH pass before any auth check is skipped:
///
/// 1. Compile time: the build must be made with
///    `--dart-define=SITEWISE_DEV_AUTH_BYPASS=true`. A normal `jaspr build`
///    has no such define, so the whole branch is compiled out and every
///    guard stays exactly as it was.
/// 2. Runtime: the page must be served from a local development origin.
///    Even if a build that carries the flag is deployed, the bypass is inert
///    on any real hostname.
///
/// This deliberately does NOT touch the FastAPI backend: every protected
/// `/api/v1/*` call is still verified server-side. The bypass only stops the
/// client-side router and widgets from demanding a login before rendering.
library;

/// Opt-in switch, read at compile time from a `--dart-define`.
///
/// Server-side code uses this directly because `Uri.base` under the VM is a
/// file URI, not the request URL. `jaspr serve` is a dev-only tool, so the
/// extra localhost check there is done against the request host instead.
const bool devAuthBypassRequested = bool.fromEnvironment(
  'SITEWISE_DEV_AUTH_BYPASS',
  defaultValue: false,
);

bool isLocalDevHost(String host) {
  final h = host.toLowerCase();
  return h == 'localhost' || h == '127.0.0.1' || h == '::1' || h == '[::1]';
}

/// True only for a local dev origin; `Uri.base` is the document URL in a
/// browser build and a file URI under the VM, where host is empty.
bool get devAuthBypassEnabled =>
    devAuthBypassRequested && isLocalDevHost(Uri.base.host);

/// Server-side equivalent for the dormant SSR entry and its shelf middleware.
/// [hostHeader] is the raw `Host` header (may include a port).
bool devAuthBypassForHost(String? hostHeader) {
  if (!devAuthBypassRequested || hostHeader == null) return false;
  final raw = hostHeader.trim();
  String host = raw;
  if (raw.startsWith('[')) {
    final end = raw.indexOf(']');
    if (end != -1) host = raw.substring(0, end + 1);
  } else {
    final colon = raw.indexOf(':');
    if (colon != -1) host = raw.substring(0, colon);
  }
  return isLocalDevHost(host);
}

/// A local, clearly-fake Entrepreneur identity used for presentation only.
///
/// It carries NO bearer token. [AppLocator.isSignedIn] is forced to false
/// while the bypass is active, so pages fall back to their local/cookie
/// state instead of firing authenticated writes that would fail with 401.
const Map<String, dynamic> devAuthProfile = <String, dynamic>{
  'role': 'entrepreneur',
  'email': 'dev@localhost',
  'full_name': 'Local Developer',
  'name': 'Local Developer',
  'user_id': 'dev-bypass',
  'account_status': 'active',
};

/// Snapshot shape returned by the JS auth bridge. Supplying it locally keeps
/// every `WebAuth` getter working without ever loading `auth_bundle.js`.
Map<String, dynamic> get devAuthBypassState => <String, dynamic>{
  'configured': true,
  'profile': devAuthProfile,
  'error': '',
  'mfaRequired': false,
  'mfaEnrollmentRequired': false,
  'mfaEnrollQr': null,
  'mfaEnrollSecret': null,
};
