import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import 'package:fyp/core/routing/auth_route_guard.dart';
import 'package:fyp/core/routing/mobile_role.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_brand.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_cta_button.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_icon.dart';
import 'package:fyp/features/authentication/presentation/widgets/auth_field.dart';
import 'package:fyp/features/authentication/presentation/widgets/auth_provider_button.dart';
import 'package:fyp/features/authentication/presentation/widgets/auth_tabs.dart';
import 'package:fyp/features/authentication/presentation/widgets/auth_terms_row.dart';
import 'package:fyp/features/authentication/presentation/widgets/signup_role_card.dart';

// SITEWISE_OWNER_INVITE_UI_V1

/// Mobile authentication feature: Log In / Sign Up in one screen.
///
/// The mode is chosen by the `/auth` route argument and by the inline account
/// link at the foot of the form. The header is brand-only: there is no return
/// control and no top Log In / Sign Up switch.
///
/// Presentation only — every credential call goes through the shared
/// [AuthNotifier], which drives the auth state machine and the Supabase
/// repository. This screen
/// never reads a token, guesses a role, or navigates on an unverified session:
/// it reacts to that state and only enters a workspace once the backend
/// has confirmed the profile.
class MobileAuthPage extends ConsumerStatefulWidget {
  final AuthTab initialTab;

  const MobileAuthPage({super.key, this.initialTab = AuthTab.login});

  @override
  ConsumerState<MobileAuthPage> createState() => _MobileAuthPageState();
}

enum _NoticeTone { info, warning, error }

class _MobileAuthPageState extends ConsumerState<MobileAuthPage> {
  static final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  late AuthTab _tab = widget.initialTab;
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _name = TextEditingController();
  bool _hidePassword = true;
  bool _hideConfirm = true;
  bool _terms = false;
  String? _fieldError;

  /// Set once a workspace entry navigation has been queued for this page
  /// instance, so a Retry that restores a saved session and a manual sign-in
  /// can never both trigger a push.
  bool _retryingConnection = false;

  bool _enteredWorkspace = false;

  @override
  void initState() {
    super.initState();
    // §5/§4: the remembered address (device scope, never a secret) is
    // rehydrated so a failed or interrupted sign-in does not cost retyping.
    // Passwords are deliberately NOT persisted anywhere.
    ServiceLocator.drafts.loadDraftEmail().then((email) {
      if (!mounted || email == null || email.isEmpty) return;
      if (_email.text.isNotEmpty) return; // never clobber live typing
      _email.text = email;
    });
    // The cold-start gate normally does this first; calling it again is a
    // no-op, so a direct jump to /auth still resolves an existing session.
    // Deferred because the notifier publishes synchronously and initState
    // runs while the widget tree is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(authNotifierProvider.notifier).start();
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _retryConnection() async {
    if (_retryingConnection) return;
    setState(() => _retryingConnection = true);
    try {
      // Keep the existing notifier's session-restore and error handling.
      await ref.read(authNotifierProvider.notifier).retry();
    } catch (_) {
      // No credentials or internal diagnostics are displayed here.
      // The auth notifier remains responsible for the connection state.
    } finally {
      if (mounted) setState(() => _retryingConnection = false);
    }
  }

  bool _validate() {
    final email = _email.text.trim();
    final pass = _password.text;
    if (!_emailPattern.hasMatch(email)) {
      return _fail('Please enter a valid email address.');
    }
    if (pass.length < 6) {
      return _fail('Password must contain at least 6 characters.');
    }
    if (_tab == AuthTab.signUp) {
      if (_name.text.trim().length < 2) {
        return _fail('Please enter your full name.');
      }
      if (pass != _confirm.text) return _fail('Passwords do not match.');
      if (!_terms) {
        return _fail(
          'Please agree to the Terms of Service and Privacy Policy.',
        );
      }
    }
    _fieldError = null;
    return true;
  }

  bool _fail(String message) {
    setState(() => _fieldError = message);
    return false;
  }

  Future<void> _submit() async {
    if (!_validate()) return;
    final email = _email.text.trim();
    final pass = _password.text;
    // §5: remember the address BEFORE the request — a failed sign-in (wrong
    // password, unreachable service) must not cost retyping it. The address
    // is the only credential-adjacent value persisted, and it is not a
    // secret; the password never leaves the controller.
    ServiceLocator.drafts.saveDraftEmail(email);
    final auth = ref.read(authNotifierProvider.notifier);
    final ok = _tab == AuthTab.login
        ? await auth.signIn(email: email, password: pass)
        : await auth.signUp(
            email: email,
            password: pass,
            fullName: _name.text.trim(),
            // The backend re-checks consent; it is never assumed locally.
            acceptTerms: _terms,
          );
    if (!ok || !mounted) return;
    final user = ref.read(authNotifierProvider).user;
    if (user != null) _enterWorkspace(user);
  }

  Future<void> _provider(AuthProvider provider) async {
    setState(() => _fieldError = null);
    final ok = await ref
        .read(authNotifierProvider.notifier)
        .signInWithProvider(provider);
    if (!ok || !mounted) return;
    final user = ref.read(authNotifierProvider).user;
    if (user != null) _enterWorkspace(user);
  }

  /// One decision, shared with signup and the cold-start gate: the trusted
  /// backend role chooses the workspace, and the server-verified `aal` claim
  /// decides whether an Agent must complete MFA first. An Entrepreneur never
  /// sees MFA or an email-confirmation step; an Administrator is turned away
  /// here because the Admin workspace is web-only and unchanged.
  void _enterWorkspace(SitewiseUser user) {
    if (_enteredWorkspace) return;
    final navigation = postAuthNavigation(user);
    if (navigation == null) {
      setState(() => _fieldError = mobileUnsupportedRoleMessage(user.role));
      return;
    }
    _enteredWorkspace = true;
    ref.read(appNotifierProvider.notifier).setRole(user.role);
    Navigator.of(context).pushNamedAndRemoveUntil(
      navigation.route,
      (_) => false,
      arguments: navigation.arguments,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLogin = _tab == AuthTab.login;
    // Watching the auth state repaints on a status, message or
    // pending-address change — and never while the user is just typing.
    final state = ref.watch(authNotifierProvider);
    final busy = state.status == AuthStatus.authenticating;
    // A Retry that restores a saved session (the backend was briefly
    // unreachable at startup) must carry the user onward exactly like a fresh
    // sign-in does — the manual _submit/_provider paths already navigate, so
    // those transitions are skipped here.
    ref.listen<AuthState>(authNotifierProvider, (previous, next) {
      if (next.status != AuthStatus.authenticated &&
          next.status != AuthStatus.staffOnboarding) {
        return;
      }
      if (previous?.status == AuthStatus.authenticating) return;
      if (!mounted) return;
      final user = next.user;
      if (user != null) _enterWorkspace(user);
    });
    return Scaffold(
      backgroundColor: SitewiseColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _header(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 26),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 22),
                    Text(
                      isLogin ? 'Welcome Back' : 'Create your account',
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: SitewiseColors.ink,
                        letterSpacing: -.7,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      isLogin
                          ? 'Sign in to your SiteWise account.'
                          : 'Join Sitewise to explore, compare and evaluate commercial F&B locations.',
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.45,
                        color: SitewiseColors.muted,
                      ),
                    ),
                    const SizedBox(height: 21),
                    _Notice(
                      state: state,
                      isLogin: isLogin,
                      fieldError: _fieldError,
                      onRetry: _retryConnection,
                      retrying: _retryingConnection,
                    ),
                    AuthField(
                      label: 'Email address',
                      controller: _email,
                      hint: 'Enter your email',
                      icon: Icons.mail_outline_rounded,
                      keyboardType: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: 13),
                    if (!isLogin) ...[
                      AuthField(
                        label: 'Full name',
                        controller: _name,
                        hint: 'Enter your full name',
                        icon: Icons.person_outline_rounded,
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 13),
                    ],
                    AuthField(
                      label: 'Password',
                      controller: _password,
                      hint: isLogin
                          ? 'Enter your password'
                          : 'Create a password',
                      icon: Icons.lock_outline_rounded,
                      obscure: _hidePassword,
                      textInputAction: isLogin
                          ? TextInputAction.done
                          : TextInputAction.next,
                      onSubmitted: isLogin && !busy ? (_) => _submit() : null,
                      suffix: IconButton(
                        onPressed: () =>
                            setState(() => _hidePassword = !_hidePassword),
                        icon: SitewiseIcon(
                          _hidePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          intent: SitewiseIconIntent.field,
                          semanticLabel: _hidePassword
                              ? 'Show password'
                              : 'Hide password',
                        ),
                      ),
                    ),
                    if (!isLogin) ...[
                      const SizedBox(height: 13),
                      AuthField(
                        label: 'Confirm Password',
                        controller: _confirm,
                        hint: 'Confirm your password',
                        icon: Icons.lock_outline_rounded,
                        obscure: _hideConfirm,
                        textInputAction: TextInputAction.done,
                        onSubmitted: busy ? null : (_) => _submit(),
                        suffix: IconButton(
                          onPressed: () =>
                              setState(() => _hideConfirm = !_hideConfirm),
                          icon: SitewiseIcon(
                            _hideConfirm
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            intent: SitewiseIconIntent.field,
                            semanticLabel: _hideConfirm
                                ? 'Show password'
                                : 'Hide password',
                          ),
                        ),
                      ),
                    ],
                    if (isLogin)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(
                            context,
                          ).pushNamed('/forgot-password'),
                          child: const Text(
                            'Forgot password?',
                            style: TextStyle(
                              color: SitewiseColors.action,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      )
                    else
                      AuthTermsRow(
                        value: _terms,
                        onChanged: (v) {
                          if (busy) return;
                          setState(() => _terms = v);
                        },
                      ),
                    const SizedBox(height: 7),
                    SitewiseCtaButton(
                      label: busy
                          ? (isLogin ? 'Logging in...' : 'Creating account...')
                          : (isLogin ? 'Log in' : 'Sign up'),
                      onPressed: busy ? null : _submit,
                    ),
                    const SizedBox(height: 18),
                    const AuthDividerText(),
                    const SizedBox(height: 11),
                    // Mobile supports Google and email/password only. The
                    // Apple button was removed: this build registers no
                    // Apple OAuth flow, so the control could only fail.
                    AuthProviderButton(
                      provider: AuthProvider.google,
                      onPressed: busy
                          ? null
                          : () => _provider(AuthProvider.google),
                    ),

                    const SizedBox(height: 15),
                    Center(
                      child: Wrap(
                        children: [
                          Text(
                            isLogin
                                ? 'New entrepreneur? '
                                : 'Already have an account? ',
                            style: const TextStyle(
                              fontSize: 12,
                              color: SitewiseColors.muted,
                            ),
                          ),
                          GestureDetector(
                            onTap: busy
                                ? null
                                : () {
                                    if (isLogin) {
                                      // Public Entrepreneur registration is
                                      // a route, not a tab: keeping it out of
                                      // this screen preserves the brand-only
                                      // Login header and avoids a second
                                      // sign-up implementation.
                                      Navigator.of(
                                        context,
                                      ).pushNamed('/signup');
                                    } else {
                                      setState(() {
                                        _tab = AuthTab.login;
                                        _fieldError = null;
                                      });
                                    }
                                  },
                            child: Text(
                              isLogin ? 'Sign up' : 'Log in',
                              style: const TextStyle(
                                fontSize: 12,
                                color: SitewiseColors.action,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    const SignupInfoNote(
                      message:
                          'Property Owners and Agents must complete their '
                          'administrator invitation before signing in.',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Brand-only header. The return control was removed deliberately: this is
  /// a root destination reached from the start gate, landing and onboarding,
  /// so there is no previous screen to return to. The 40px box preserves the
  /// header height and keeps the wordmark centred as before.
  Widget _header() {
    return const Padding(
      padding: EdgeInsets.fromLTRB(12, 4, 12, 2),
      child: SizedBox(
        height: 40,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [SitewiseBrand()],
        ),
      ),
    );
  }
}

/// Inline status area: server outcomes (email confirmation, suspended
/// account, expired session, service unavailable) and this screen's own
/// validation message surface here instead of in a transient snackbar, so the
/// reason stays visible while the user acts on it.
class _Notice extends StatelessWidget {
  final AuthState state;
  final bool isLogin;
  final String? fieldError;
  final VoidCallback onRetry;
  final bool retrying;

  const _Notice({
    required this.state,
    required this.isLogin,
    required this.fieldError,
    required this.onRetry,
    required this.retrying,
  });

  @override
  Widget build(BuildContext context) {
    if (retrying || state.status == AuthStatus.error) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _CompactBackendNotice(
          errorKind: state.errorKind,
          retrying: retrying,
          onRetry: onRetry,
        ),
      );
    }
    final notice = _noticeFor();
    if (notice == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: _NoticeCard(
        tone: notice.tone,
        title: notice.title,
        body: notice.body,
      ),
    );
  }

  _NoticeContent? _noticeFor() {
    switch (state.status) {
      case AuthStatus.emailConfirmationRequired:
        return _NoticeContent(
          tone: _NoticeTone.info,
          title: 'Confirm your email',
          body:
              'We sent a confirmation link to '
              '${state.email ?? 'the address you entered'}. '
              'Confirm it, then sign in here.',
        );
      case AuthStatus.accountInactive:
        return _NoticeContent(
          tone: _NoticeTone.warning,
          title: 'Account not active',
          body: state.message ?? 'This account cannot sign in right now.',
        );
      case AuthStatus.sessionExpired:
        return _NoticeContent(
          tone: _NoticeTone.warning,
          title: 'Session expired',
          body: state.message ?? 'Please sign in again.',
        );
      case AuthStatus.error:
        return null;

      default:
        // Wrong credentials and duplicate emails keep the user on this form;
        // the notifier reports why in `state.message`, local validation in
        // `fieldError`. Either way the reason stays visible.
        final message =
            fieldError ??
            (state.status == AuthStatus.unauthenticated ? state.message : null);
        if (message == null) return null;
        return _NoticeContent(
          tone: _NoticeTone.error,
          title: isLogin ? 'Could not sign in' : 'Could not create account',
          body: message,
        );
    }
  }
}

/// Compact, actionable service warning for login and signup.
/// Never exposes host configuration, API ports, ADB instructions or raw errors.
class _CompactBackendNotice extends StatelessWidget {
  final AuthErrorKind errorKind;
  final bool retrying;
  final VoidCallback onRetry;

  const _CompactBackendNotice({
    required this.errorKind,
    required this.retrying,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final configuration = !retrying && errorKind == AuthErrorKind.configuration;
    final message = retrying
        ? 'Checking the SiteWise connection…'
        : switch (errorKind) {
            AuthErrorKind.configuration =>
              'This app build is missing its sign-in settings. Please contact support.',
            AuthErrorKind.timeout =>
              'SiteWise is taking too long to respond. Please try again.',
            AuthErrorKind.tls =>
              'A secure connection could not be established. Please try again.',
            _ =>
              'Unable to connect to SiteWise. Check your connection and try again.',
          };
    final title = retrying
        ? 'Reconnecting…'
        : configuration
        ? 'Sign-in setup required'
        : 'Connection unavailable';

    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 7),
        decoration: BoxDecoration(
          color: SitewiseColors.warningWash,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: SitewiseColors.borderStrong),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              configuration
                  ? Icons.info_outline_rounded
                  : Icons.wifi_off_rounded,
              size: 19,
              color: SitewiseColors.warning,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: SitewiseColors.ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    message,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: SitewiseColors.muted,
                    ),
                  ),
                  if (!configuration)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: retrying ? null : onRetry,
                        icon: retrying
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh_rounded, size: 17),
                        label: Text(retrying ? 'Checking…' : 'Retry'),
                        style: TextButton.styleFrom(
                          foregroundColor: SitewiseColors.action,
                          minimumSize: const Size(70, 36),
                          tapTargetSize: MaterialTapTargetSize.padded,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoticeContent {
  final _NoticeTone tone;
  final String title;
  final String body;

  const _NoticeContent({
    required this.tone,
    required this.title,
    required this.body,
  });
}

class _NoticeCard extends StatelessWidget {
  final _NoticeTone tone;
  final String title;
  final String body;

  const _NoticeCard({
    required this.tone,
    required this.title,
    required this.body,
  });

  static const _icons = <_NoticeTone, IconData>{
    _NoticeTone.info: Icons.mark_email_unread_outlined,
    _NoticeTone.warning: Icons.error_outline_rounded,
    _NoticeTone.error: Icons.lock_outline_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final (wash, accent) = switch (tone) {
      _NoticeTone.info => (SitewiseColors.infoWash, SitewiseColors.action),
      _NoticeTone.warning => (
        SitewiseColors.warningWash,
        SitewiseColors.warning,
      ),
      _NoticeTone.error => (SitewiseColors.dangerWash, SitewiseColors.danger),
    };
    return Semantics(
      liveRegion: true,
      label: '$title. $body',
      child: Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: wash,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: SitewiseColors.borderStrong),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(_icons[tone], size: 18, color: accent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: SitewiseColors.ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    body,
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.45,
                      color: SitewiseColors.ink,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
