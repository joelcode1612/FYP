import 'dart:async';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import '../components/ui.dart';
import '../data/auth_service.dart';

/// Supabase OAuth / invite / recovery landing point.
///
/// The Supabase client exchanges the PKCE code automatically on load
/// (`detectSessionInUrl`), so by the time this page runs the session exists.
/// Routing rules:
/// * recovery + invite links carry `?next=/reset-password` -> the
///   new-password screen (works for both entrepreneur resets and first-time
///   staff setup);
/// * everything else -> `WebAuth.complete()`, which loads the SERVER-assigned
///   profile and sends staff accounts without a verified TOTP factor to the
///   enrollment screen.
@client
class AuthCallbackPage extends StatefulComponent {
  const AuthCallbackPage({super.key});
  @override
  State<AuthCallbackPage> createState() => _CallbackState();
}

class _CallbackState extends State<AuthCallbackPage> {
  String? error;
  // A hydrated @client subtree can be re-mounted by the framework. A static
  // latch is per browser document (one Dart isolate), so it survives a fresh
  // State instance. Without it the PKCE exchange / profile fetch / redirect
  // would run twice, producing a second full page load. The JS bridge also
  // memoizes complete(); both layers guard the same one-shot operation.
  static bool _started = false;

  @override
  void initState() {
    super.initState();
    if (_started) return;
    _started = true;
    unawaited(_finish());
  }

  Future<void> _finish() async {
    try {
      await WebAuth.initialize();
      // `next` (e.g. /reset-password from recovery + invite links) is routed
      // inside the auth bridge; everything else follows the server-assigned
      // role, with staff-without-MFA landing on the enrollment screen.
      await WebAuth.complete(Uri.base.queryParameters['next']);
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
        // Expired/invalid email links must give the user a way back to the
        // portal they came from - the Agent & Admin sign-in above all.
        : div(classes: 'empty__links', [
            const ActionLink(
              'Back to Staff Sign-in',
              href: '/staff/signin',
              icon: 'arrow_back',
            ),
            const ActionLink('Go to sign in', href: '/login', variant: 'ghost'),
          ]),
  );
}
