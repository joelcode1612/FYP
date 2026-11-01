import 'dart:async';
import 'package:jaspr/jaspr.dart';
import '../components/ui.dart';
import '../data/auth_service.dart';

class AuthCallbackPage extends StatefulComponent {
  const AuthCallbackPage({super.key});
  @override
  State<AuthCallbackPage> createState() => _CallbackState();
}

class _CallbackState extends State<AuthCallbackPage> {
  String? error;
  @override
  void initState() {
    super.initState();
    unawaited(_finish());
  }

  Future<void> _finish() async {
    try {
      await WebAuth.complete();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  @override
  Component build(BuildContext context) => EmptyState(
    title: error == null ? 'Completing sign-in…' : 'Sign-in could not finish',
    body: error ?? 'Verifying your account and loading your profile.',
    action: error == null
        ? null
        : const ActionLink('Back to sign in', href: '/login'),
  );
}
