import 'package:provider/provider.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../application/state/app_view_model.dart';
import '../../../../application/state/auth_view_model.dart';
import '../../../../core/routing/auth_route_guard.dart';
import '../../../../core/routing/mobile_role.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_brand.dart';
import '../../../shared/widgets/sitewise_cta_button.dart';
import '../../../shared/widgets/sitewise_icon.dart';
import '../widgets/auth_field.dart';
import '../widgets/auth_provider_button.dart';
import '../widgets/auth_tabs.dart';
import '../widgets/auth_terms_row.dart';

/// Mobile authentication feature: Log In / Sign Up in one screen.
///
/// Presentation only — every credential call goes through the shared
/// [AuthViewModel], which drives the auth state machine and the Supabase
/// repository. This screen
/// never reads a token, guesses a role, or navigates on an unverified session:
/// it reacts to that state and only enters a workspace once the backend
/// has confirmed the profile.
class MobileAuthPage extends StatefulWidget {
  final AuthTab initialTab;

  const MobileAuthPage({super.key, this.initialTab = AuthTab.login});

  @override
  State<MobileAuthPage> createState() => _MobileAuthPageState();
}

enum _NoticeTone { info, warning, error }

class _MobileAuthPageState extends State<MobileAuthPage> {
  static final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  late final AuthViewModel _auth = context.read<AuthViewModel>();

  late AuthTab _tab = widget.initialTab;
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _name = TextEditingController();
  bool _hidePassword = true;
  bool _hideConfirm = true;
  bool _terms = false;
  String? _fieldError;

  @override
  void initState() {
    super.initState();
    // The cold-start gate normally does this first; calling it again is a
    // no-op, so a direct jump to /auth still resolves an existing session.
    _auth.start();
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    _name.dispose();
    super.dispose();
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
    final ok = _tab == AuthTab.login
        ? await _auth.signIn(email: email, password: pass)
        : await _auth.signUp(
            email: email,
            password: pass,
            fullName: _name.text.trim(),
          );
    if (!ok || !mounted) return;
    final user = _auth.state.user;
    if (user != null) _enterWorkspace(user);
  }

  Future<void> _provider(AuthProvider provider) async {
    setState(() => _fieldError = null);
    final ok = await _auth.signInWithProvider(provider);
    if (!ok || !mounted) return;
    final user = _auth.state.user;
    if (user != null) _enterWorkspace(user);
  }

  /// Mobile ships the Entrepreneur workspace only. The role comes from the
  /// backend profile, never from this screen, so a web-only account is turned
  /// away here instead of being routed into a dashboard that does not exist.
  void _enterWorkspace(SitewiseUser user) {
    final home = mobileHomeRouteFor(user.role);
    context.read<AppViewModel>().setRole(user.role);
    if (home == null) {
      setState(() => _fieldError = mobileUnsupportedRoleMessage(user.role));
      return;
    }
    final pending = AuthPendingDestination.takeFor(user.role);
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil(pending ?? home, (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final isLogin = _tab == AuthTab.login;
    // Selecting the auth state itself repaints on a status, message or
    // pending-address change — and never while the user is just typing.
    return Selector<AuthViewModel, AuthState>(
      selector: (_, auth) => auth.state,
      builder: (context, state, _) {
        final busy = state.status == AuthStatus.authenticating;
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
                        AuthTabs(
                          tab: _tab,
                          onChanged: (v) {
                            if (busy) return;
                            setState(() {
                              _tab = v;
                              _fieldError = null;
                            });
                          },
                        ),
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
                              ? 'Log in to Sitewise and continue exploring better F&B locations.'
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
                          onSubmitted: isLogin && !busy
                              ? (_) => _submit()
                              : null,
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
                              ? (isLogin
                                    ? 'Logging in...'
                                    : 'Creating account...')
                              : (isLogin ? 'Log in' : 'Sign up'),
                          onPressed: busy ? null : _submit,
                        ),
                        const SizedBox(height: 18),
                        const AuthDividerText(),
                        const SizedBox(height: 11),
                        AuthProviderButton(
                          provider: AuthProvider.apple,
                          onPressed: busy
                              ? null
                              : () => _provider(AuthProvider.apple),
                        ),
                        const SizedBox(height: 9),
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
                                    ? "Don't have an account? "
                                    : 'Already have an account? ',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: SitewiseColors.muted,
                                ),
                              ),
                              GestureDetector(
                                onTap: busy
                                    ? null
                                    : () => setState(() {
                                        _tab = isLogin
                                            ? AuthTab.signUp
                                            : AuthTab.login;
                                        _fieldError = null;
                                      }),
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
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
      child: Row(
        children: [
          Material(
            color: Colors.white,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => Navigator.of(context).maybePop(),
              child: const SizedBox(
                width: 40,
                height: 40,
                child: Icon(Icons.arrow_back_rounded, size: 19),
              ),
            ),
          ),
          const Spacer(),
          const SitewiseBrand(),
          const Spacer(),
          const SizedBox(width: 40),
        ],
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

  const _Notice({
    required this.state,
    required this.isLogin,
    required this.fieldError,
  });

  @override
  Widget build(BuildContext context) {
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
        return _NoticeContent(
          tone: _NoticeTone.error,
          title: 'Sign-in service unavailable',
          body:
              '${state.message ?? 'Sitewise could not reach the sign-in service.'} '
              'No access was granted.',
        );
      default:
        // Wrong credentials and duplicate emails keep the user on this form;
        // the cubit reports why in `state.message`, local validation in
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
