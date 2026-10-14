/// The entrypoint for the **client** environment.
///
/// The [main] method will only be executed on the client when loading the page.
/// To run code on the server during pre-rendering, check the `main.server.dart`
/// file.
///
/// This is the missing half of static-mode hydration: the server pre-renders
/// the HTML (see `main.server.dart`), and this entrypoint — compiled to
/// `main.client.dart.js` and injected via the generated `clientId` — mounts and
/// hydrates the `@client`-annotated root component (`SitewiseApp`) so the page
/// becomes interactive (BLoC streams, clicks, forms). Without it, `jaspr serve`
/// serves the raw `index.html` for `/` and the SSR'd pages stay static.
library;

// Client-specific Jaspr import.
import 'package:jaspr/client.dart';

import 'main.client.options.dart';

void main() {
  // Initializes the client environment with the generated default options.
  Jaspr.initializeApp(options: defaultClientOptions);

  // Starts the app.
  //
  // [ClientApp] automatically loads and renders all components annotated with
  // @client.
  runApp(const ClientApp());
}
