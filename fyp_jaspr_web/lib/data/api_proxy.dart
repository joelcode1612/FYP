/// Same-origin reverse proxy for the intended Sitewise FastAPI backend.
///
/// The browser never needs to know the backend's host or port: it calls
/// `/api/v1/...` on the Jaspr SSR origin, and this middleware forwards the
/// request (including the Supabase bearer token) to `FYP/backend`. That removes
/// the cross-origin request, the CORS dependency and the old hardcoded
/// backend-origin fallback in the browser bundle.
///
/// Server-only (`package:shelf` / `package:http`); never imported by client code.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart' as shelf;

/// Hop-by-hop and framing headers must not be copied across a proxy boundary.
const Set<String> _skipRequestHeaders = {
  'host',
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  'content-length',
  // Ask the upstream for an uncompressed body: http.Client does not decode
  // gzip, so forwarding this header would return unreadable bytes.
  'accept-encoding',
};

const Set<String> _skipResponseHeaders = {
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  // shelf derives content-length from the body and would otherwise disagree.
  'content-length',
  'content-encoding',
};

bool _isProxiedPath(String path) =>
    path == '/health' || path == '/api' || path.startsWith('/api/');

String _joinPath(String basePath, String requestPath) {
  if (basePath.isEmpty || basePath == '/') return requestPath;
  return '${basePath.replaceAll(RegExp(r'/+$'), '')}$requestPath';
}

/// Returns a shelf middleware that forwards API/health requests to [backend].
///
/// Every other request is handed straight back to Jaspr's normal SSR + static
/// cascade, so HTML documents, CSS, JS and hydration are unaffected.
shelf.Middleware createApiProxy(Uri backend, {http.Client? client}) {
  final upstreamClient = client ?? http.Client();
  return (shelf.Handler inner) {
    return (shelf.Request request) async {
      final incoming = request.requestedUri;
      if (!_isProxiedPath(incoming.path)) return inner(request);
      return _forward(request, incoming, backend, upstreamClient);
    };
  };
}

Future<shelf.Response> _forward(
  shelf.Request request,
  Uri incoming,
  Uri backend,
  http.Client client,
) async {
  final target = Uri.parse(
    '${backend.origin}${_joinPath(backend.path, incoming.path)}'
    '${incoming.hasQuery ? '?${incoming.query}' : ''}',
  );

  final headers = <String, String>{};
  request.headers.forEach((name, value) {
    if (!_skipRequestHeaders.contains(name.toLowerCase())) {
      headers[name] = value;
    }
  });
  headers.remove('host');

  late final List<int> body;
  try {
    body = await request.read().expand((chunk) => chunk).toList();
  } on Object {
    body = const <int>[];
  }

  final upstream = http.Request(request.method, target)
    ..headers.addAll(headers)
    ..bodyBytes = body;

  try {
    final streamed = await client
        .send(upstream)
        .timeout(const Duration(seconds: 25));
    final bytes = await streamed.stream.toBytes();
    final out = <String, String>{};
    streamed.headers.forEach((name, value) {
      if (!_skipResponseHeaders.contains(name.toLowerCase())) {
        out[name] = value;
      }
    });
    return shelf.Response(streamed.statusCode, body: bytes, headers: out);
  } on Object catch (error) {
    return shelf.Response(
      502,
      body: jsonEncode({
        'detail': 'The Sitewise API at ${backend.origin} is unavailable. '
            'Start FYP/backend (uvicorn on port 8000); see serve.ps1. '
            'Error: $error',
      }),
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  }
}
