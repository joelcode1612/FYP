/// The entrypoint for the **server** environment.
///
/// Every request is answered here: the router resolves the URL, the page is
/// rendered to HTML, and the interactive leaves are emitted as `@client`
/// anchors that `main.client.dart` hydrates in the browser. Nothing here runs
/// in the browser, and nothing in `main.client.dart` runs on the server.
library;

import 'package:jaspr/dom.dart';
// `server.dart` already exports the core API, with the server flavour of
// `runApp` and `Document` (the plain `jaspr.dart` import would make both
// ambiguous).
import 'package:jaspr/server.dart';

import 'app.dart';
import 'data/api_config.dart';
import 'data/api_proxy.dart';
import 'data/app_locator.dart';
import 'data/auth_service.dart';
import 'data/ssr_service.dart';
import 'data/workspaces.dart';

// This file is generated automatically by Jaspr, do not remove or edit.
import 'main.server.options.dart';

void main() {
  // Same-origin API proxy: browser /api/* and /health requests are forwarded to
  // the intended FastAPI backend (FYP/backend, port 8000). Registering the
  // middleware before runApp means it wraps Jaspr's whole SSR/static cascade
  // without changing any rendered HTML.
  ServerApp.addMiddleware(createApiProxy(kBackendApiBase));

  Jaspr.initializeApp(
    options: defaultServerOptions,
    // One isolate per render: the request-scoped `WebAuth` session and the
    // `AppLocator` singletons are statics, and isolates keep two concurrent
    // visitors from overwriting each other's identity.
    useIsolates: true,
  );

  runApp(const _DocumentShell());
}

/// The HTML document and the per-request bootstrap that precedes it.
///
/// Building this root component is the first thing that happens for a request,
/// so it is where the cookies are read back into the session/selection state —
/// before the router (a child) evaluates its guard.
class _DocumentShell extends StatelessComponent {
  const _DocumentShell();

  @override
  Component build(BuildContext context) {
    final cookies = context.cookies;
    WebAuth.installServerSession(cookies);
    AppLocator.installUiState(cookies);
    Workspaces.seed(AppLocator.grantedRoles);

    // Anonymous request for a workspace: answer with a real 302 to the sign-in
    // screen and keep the destination. The router drops `next` when it sets the
    // header itself (it only forwards the matched path), so it is done here.
    final path = context.url.split('?').first;
    if (_workspacePath.hasMatch(path) && WebAuth.profile == null) {
      redirectTo(context, '/login?next=${Uri.encodeComponent(context.url)}');
    }

    return Document(
      title: 'Sitewise — F&B Location Intelligence',
      lang: 'en',
      meta: {
        'description': kSiteDescription,
        'theme-color': '#0f172a',
        'robots': 'index, follow',
        // Public API base for the browser bridge. Empty = same-origin (the
        // proxy above forwards /api/*). A deployment can override it with
        // SITEWISE_PUBLIC_API_BASE; the value is emitted before auth_bundle.js
        // (which is deferred) so the bridge always reads the correct value.
        'sitewise-api': kPublicApiBase,
      },
      head: [
        link(rel: 'icon', type: 'image/png', href: 'assets/sitewise-icon-32.png'),
        link(rel: 'apple-touch-icon', href: 'assets/sitewise-icon-180.png'),
        link(rel: 'stylesheet', type: 'text/css', href: 'styles.css'),
        link(rel: 'preconnect', href: 'https://fonts.googleapis.com'),
        link(
          rel: 'preconnect',
          href: 'https://fonts.gstatic.com',
          attributes: const {'crossorigin': 'anonymous'},
        ),
        link(
          rel: 'stylesheet',
          href: 'https://fonts.googleapis.com/css2?family=Material+Symbols+Outlined:opsz,wght,FILL,GRAD@24,400,0,0&display=block',
        ),
        link(
          rel: 'stylesheet',
          href: 'https://fonts.googleapis.com/css2?family=Material+Symbols+Rounded:opsz,wght,FILL,GRAD@24,400,0,0&display=block',
        ),
        script(src: 'vendor/three.min.js', defer: true),
        script(src: 'three_scene.js', defer: true),
        script(src: 'reveal.js', defer: true),
        script(src: 'auth_bundle.js', defer: true),
      ],
      body: Component.fragment([
        const _NoScript(),
        // The hydrated app is the body content itself; no wrapper element, so
        // server markup and client markup are the same nodes.
        const SitewiseApp(),
      ]),
    );
  }
}

class _NoScript extends StatelessComponent {
  const _NoScript();

  @override
  Component build(BuildContext context) => Component.element(
    tag: 'noscript',
    children: [
      Component.text(
        'Sitewise uses JavaScript for filtering, saving and comparisons. '
        'Pages, listings and navigation still read without it.',
      ),
    ],
  );
}

/// Paths that belong to a signed-in workspace.
final RegExp _workspacePath = RegExp(r'^/(entrepreneur|owner|admin|agent)(/|$)');
