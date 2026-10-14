// NOTE: do NOT also import `package:jaspr/jaspr.dart` here.
//
// `jaspr/jaspr.dart` and `jaspr/server.dart` each export a `runApp` and a
// `Document` — the client stub and the server implementation respectively —
// so importing both makes every use of either name ambiguous
// (`ambiguous_import`). Server/static entry points import `server.dart` only;
// component files (which never touch `runApp`/`Document`) import `jaspr.dart`.
import 'package:jaspr/server.dart';

import 'app.dart';
import 'main.server.options.dart';

/// Entry point.
///
/// `Document` is the server/static-mode wrapper: it produces the outer
/// `<html>`/`<head>`/`<body>`. In `static` mode (see `pubspec.yaml`) this runs
/// at build time and the result is written out as real HTML per route, which
/// is what makes the page indexable — the whole point of moving off Flutter
/// Web, which paints to a canvas that crawlers cannot read.
///
/// Passing `defaultServerOptions` is required for hydration: the generated
/// options carry the `@client` `clients` map (and the `clientId` pointing at
/// `main.client.dart.js`), which the server uses to emit hydration markers and
/// inject the client script. Without it, `jaspr serve` serves a static, inert
/// page (and the bare `/` route is swallowed by the raw `index.html`).
void main() {
  Jaspr.initializeApp(options: defaultServerOptions);

  runApp(
    Document(
      title: 'Sitewise — F&B Location Intelligence',
      lang: 'en',
      viewport: 'width=device-width, initial-scale=1',
      meta: const {
        'description':
            'Sitewise — evidence-based F&B commercial property selection. '
            'Compare locations by population, accessibility, competition and demand before you commit.',
      },
      head: const [
        // The design system. All styling lives in CSS: Jaspr's Text takes only
        // a String, so there is no inline text styling to port from Flutter.
        Component.element(
          tag: 'link',
          attributes: {'rel': 'stylesheet', 'href': 'styles.css'},
        ),
        // Fonts: Sora (display) + IBM Plex Sans (body), matching the Flutter
        // theme's font families.
        Component.element(
          tag: 'link',
          attributes: {
            'rel': 'preconnect',
            'href': 'https://fonts.googleapis.com',
          },
        ),
        Component.element(
          tag: 'link',
          attributes: {
            'rel': 'preconnect',
            'href': 'https://fonts.gstatic.com',
            'crossorigin': '',
          },
        ),
        Component.element(
          tag: 'link',
          attributes: {
            'rel': 'stylesheet',
            'href':
                'https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600;700&family=Sora:wght@600;700;800&display=swap',
          },
        ),
        // Material Symbols: the web counterpart to Flutter's `Icons.*`. The
        // Flutter tree names icons like `Icons.storefront_outlined`; here the
        // same glyph is rendered as <span class="ms">storefront</span>.
        //
        // Two families are loaded because Flutter's `Icons.*` is not one style:
        //   Icons.foo_outlined -> Material Symbols Outlined (FILL 0)
        //   Icons.foo_rounded  -> Material Symbols Rounded  (FILL 0)
        //   Icons.foo          -> Material Symbols Outlined (FILL 1)
        // Loading only Outlined made every `_rounded` icon in the mobile tree
        // render with the wrong corner geometry. See lib/data/icon_variants.dart
        // for which icons need which variant.
        Component.element(
          tag: 'link',
          attributes: {
            'rel': 'stylesheet',
            'href':
                'https://fonts.googleapis.com/css2?family=Material+Symbols+Outlined:opsz,wght,FILL,GRAD@24,400,0,0&display=block',
          },
        ),
        Component.element(
          tag: 'link',
          attributes: {
            'rel': 'stylesheet',
            'href':
                'https://fonts.googleapis.com/css2?family=Material+Symbols+Rounded:opsz,wght,FILL,GRAD@24,400,0,0&display=block',
          },
        ),
      ],
      body: const SitewiseApp(),
    ),
  );
}
