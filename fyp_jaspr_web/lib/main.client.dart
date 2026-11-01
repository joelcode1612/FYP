/// Browser entrypoint. The HTML shell is web/index.html; the app mounts in #app.
library;

import 'dart:async';

import 'package:jaspr/client.dart';

import 'app.dart';
import 'data/auth_service.dart';
import 'main.client.options.dart';

void main() {
  Jaspr.initializeApp(options: defaultClientOptions);
  runApp(const _AuthBootstrap(), attachTo: '#app');
}

/// Renders public routes immediately while the optional authentication bridge
/// retrieves its configuration. Previously `main` waited for that request
/// before mounting the router, making every link — including Sign up — appear
/// unresponsive whenever the local API was slow or stopped.
class _AuthBootstrap extends StatefulComponent {
  const _AuthBootstrap();

  @override
  State<_AuthBootstrap> createState() => _AuthBootstrapState();
}

class _AuthBootstrapState extends State<_AuthBootstrap> {
  @override
  void initState() {
    super.initState();
    unawaited(_initializeAuth());
  }

  Future<void> _initializeAuth() async {
    try {
      await WebAuth.initialize();
    } catch (_) {
      // Auth actions expose their own actionable error. Public routes must
      // remain usable even if the optional local API cannot be reached.
    }
    if (mounted) setState(() {});
  }

  @override
  Component build(BuildContext context) => const SitewiseApp();
}
