/// Browser entrypoint. The HTML shell is web/index.html; the app mounts in #app.
library;

import 'package:jaspr/client.dart';

import 'app.dart';
import 'main.client.options.dart';
import 'data/auth_service.dart';

Future<void> main() async {
  Jaspr.initializeApp(options: defaultClientOptions);
  await WebAuth.initialize();
  runApp(const SitewiseApp(), attachTo: '#app');
}
