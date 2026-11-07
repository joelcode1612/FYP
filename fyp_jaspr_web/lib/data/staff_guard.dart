/// Server-side authorization guard for STAFF workspaces (F4 hardening).
///
/// The SSR pass used to admit `/admin` and `/agent` purely from the unsigned
/// `sitewise_session` cookie: a forged cookie — or a real password-only (`aal1`)
/// session — could render the staff shell without the backend ever confirming
/// the role or the MFA assurance level. The cookie is base64, NOT signed, so it
/// is attacker-controlled and must never be an authorization input.
///
/// For staff paths this middleware validates the request's bearer token against
/// the FastAPI backend (`GET /api/v1/auth/me`), enforces **active + staff role +
/// aal2** from the server's verified response, and rewrites the session cookie
/// to that verified profile before the render isolate reads it back in
/// `installServerSession`. The forged cookie is therefore never consulted for a
/// staff authorization decision, and `aal2` is taken only from the signed token
/// the backend verified — never from a cookie, body, query or frontend flag.
///
/// Scope: only the privileged staff surface (`/admin`, `/agent`) is guarded
/// here. Non-staff workspace chrome (`/entrepreneur`, `/owner`) keeps its
/// existing cookie-driven render, but every privileged DATA call is still gated
/// by the backend on the bearer token, and a forged staff role cannot escalate:
/// the staff paths it would redirect to are themselves guarded. Fails CLOSED —
/// an absent/invalid token or an unreachable backend redirects to sign-in.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shelf/shelf.dart' as shelf;

import 'auth_stub.dart' show kSessionCookie, kTokenCookie;

/// Privileged staff workspaces. The MFA routes (`/staff/*`) are deliberately
/// excluded so the verify/enrollment screens are never guarded into a loop.
final RegExp _staffPath = RegExp(r'^/(admin|agent)(/|$)');

const Set<String> _staffRoles = {'agent', 'admin'};

/// Legacy aliases normalised exactly as the backend's `rbac.canonical_role`.
const Map<String, String> _roleAliases = {
  'administrator': 'admin',
  'property_owner': 'entrepreneur',
  'user': 'entrepreneur',
};

String _canonicalRole(String? role) =>
    role == null ? '' : (_roleAliases[role] ?? role);

String _homeFor(String role) => switch (role) {
  'admin' => '/admin',
  'agent' => '/agent',
  _ => '/entrepreneur',
};

/// Loopback calls go direct; anything else honours the process proxy (mirrors
/// `auth_stub.dart`, so a corporate proxy cannot 502 a local backend call).
http.Client _defaultClient() => IOClient(
  HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..findProxy = (uri) => uri.host == 'localhost' || uri.host == '127.0.0.1'
        ? 'DIRECT'
        : HttpClient.findProxyFromEnvironment(uri),
);

/// Returns a shelf middleware that authorizes staff workspace requests against
/// the backend before Jaspr renders them.
shelf.Middleware createStaffGuard(Uri backend, {http.Client? client}) {
  final upstream = client ?? _defaultClient();
  return (shelf.Handler inner) {
    return (shelf.Request request) async {
      final path = request.requestedUri.path;
      if (!_staffPath.hasMatch(path)) return inner(request);

      final login = '/login?next=${Uri.encodeComponent(request.requestedUri.toString())}';
      final token = _parseCookies(request.headers['cookie'])[kTokenCookie];
      // No bearer token: the unsigned session cookie alone never admits staff.
      if (token == null || token.isEmpty) return _redirect(login);

      final identity = await _identity(backend, upstream, token);
      // Invalid/expired token or backend unreachable: fail closed.
      if (identity == null) return _redirect(login);

      final role = _canonicalRole(identity['role'] as String?);
      final status = (identity['account_status'] as String? ?? '').toLowerCase();
      final aal = identity['assurance_level'] as String?;
      if (role.isEmpty || status != 'active') return _redirect(login);
      // A verified non-staff account belongs in its own workspace, not here.
      if (!_staffRoles.contains(role)) return _redirect(_homeFor(role));
      // Staff role confirmed, but this session has not completed MFA.
      if (aal != 'aal2') return _redirect('/staff/verify');
      // The admin workspace is administrator-only: an agent (even at aal2)
      // belongs in /agent. Administrators may act in /agent, mirroring the
      // backend's require_admin_mfa / require_agent_mfa split.
      final isAdminPath = path == '/admin' || path.startsWith('/admin/');
      if (isAdminPath && role != 'admin') return _redirect(_homeFor(role));

      // Verified staff at aal2: replace the unsigned cookie with the
      // backend-verified profile so the render isolate installs a trustworthy
      // role. All other cookies (token, UI state) are preserved.
      final rewritten = _withCookie(
        request.headers['cookie'],
        kSessionCookie,
        _encodeSession(identity),
      );
      return inner(request.change(headers: {'cookie': rewritten}));
    };
  };
}

/// Verifies the bearer against the backend and returns its authoritative
/// profile, or null when the token is rejected or the backend is unreachable.
Future<Map<String, dynamic>?> _identity(
  Uri backend,
  http.Client client,
  String token,
) async {
  try {
    final response = await client
        .get(
          backend.replace(path: '/api/v1/auth/me'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    return decoded is Map<String, dynamic> ? decoded : null;
  } on Object {
    return null;
  }
}

Map<String, String> _parseCookies(String? header) {
  final out = <String, String>{};
  if (header == null) return out;
  for (final part in header.split(';')) {
    final trimmed = part.trim();
    final eq = trimmed.indexOf('=');
    if (eq <= 0) continue;
    out[trimmed.substring(0, eq)] = trimmed.substring(eq + 1);
  }
  return out;
}

String _withCookie(String? header, String name, String value) {
  final cookies = _parseCookies(header)..[name] = value;
  return cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
}

/// Mirrors `encodeSession` in tool/auth_client.js so `installServerSession`
/// decodes it: base64url (unpadded) of the public profile fields only.
String _encodeSession(Map<String, dynamic> identity) {
  final json = jsonEncode({
    'user_id': identity['user_id'],
    'role': _canonicalRole(identity['role'] as String?),
    'name': identity['full_name'],
    'email': identity['email'],
  });
  return base64Url.encode(utf8.encode(json)).replaceAll('=', '');
}

shelf.Response _redirect(String location) =>
    shelf.Response(302, headers: {'location': location});