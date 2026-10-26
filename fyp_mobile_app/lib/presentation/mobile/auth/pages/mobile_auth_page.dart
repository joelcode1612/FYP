import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_brand.dart';
import '../../../shared/widgets/sitewise_cta_button.dart';
import '../widgets/auth_field.dart';
import '../widgets/auth_provider_button.dart';
import '../widgets/auth_tabs.dart';
import '../widgets/auth_terms_row.dart';

/// Mobile authentication feature: Log In / Sign Up in one screen.
///
/// Presentation only — it calls [ServiceLocator.auth] (the application layer),
/// which talks to the repository. No Supabase/network access happens here.
/// On success it preserves the project's existing role-based routing by
/// entering `user.role.homeRoute`.

class MobileAuthPage extends StatefulWidget {
  final AppCubit appState;
  final AuthTab initialTab;

  const MobileAuthPage({
    super.key,
    required this.appState,
    this.initialTab = AuthTab.login,
  });

  @override
  State<MobileAuthPage> createState() => _MobileAuthPageState();
}

class _MobileAuthPageState extends State<MobileAuthPage> {
  late AuthTab _tab = widget.initialTab;
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _hidePassword = true;
  bool _hideConfirm = true;
  bool _terms = false;
  bool _loading = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final pass = _password.text;
    final confirm = _confirm.text;

    if (!email.contains('@')) {
      return _message('Please enter a valid email address.');
    }
    if (pass.length < 6) {
      return _message('Password must contain at least 6 characters.');
    }
    if (_tab == AuthTab.signUp) {
      if (pass != confirm) return _message('Passwords do not match.');
      if (!_terms) {
        return _message(
          'Please agree to the Terms of Service and Privacy Policy.',
        );
      }
    }

    setState(() => _loading = true);
    try {
      final user = _tab == AuthTab.login
          ? await ServiceLocator.auth.signIn(email: email, password: pass)
          : await ServiceLocator.auth.signUp(email: email, password: pass);
      if (mounted) _enterHome(user);
    } on AppFailure catch (e) {
      if (mounted) _message(e.message);
    } catch (e) {
      if (mounted) _message(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _provider(AuthProvider provider) async {
    setState(() => _loading = true);
    try {
      final user = await ServiceLocator.auth.signInWithProvider(provider);
      if (mounted) _enterHome(user);
    } on AppFailure catch (e) {
      if (mounted) _message(e.message);
    } catch (e) {
      if (mounted) _message(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Preserves existing role-based routing: Administrator / Property Owner /
  /// F&B Entrepreneur each land on their own shell.
  void _enterHome(SitewiseUser user) {
    widget.appState.setRole(user.role);
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil(user.role.homeRoute, (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final isLogin = _tab == AuthTab.login;
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
                      onChanged: (v) => setState(() => _tab = v),
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
                    AuthField(
                      label: 'Email address',
                      controller: _email,
                      hint: 'Enter your email',
                      icon: Icons.mail_outline_rounded,
                      keyboardType: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: 13),
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
                      onSubmitted: isLogin ? (_) => _submit() : null,
                      suffix: IconButton(
                        onPressed: () =>
                            setState(() => _hidePassword = !_hidePassword),
                        icon: Icon(
                          _hidePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 18,
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
                        onSubmitted: (_) => _submit(),
                        suffix: IconButton(
                          onPressed: () =>
                              setState(() => _hideConfirm = !_hideConfirm),
                          icon: Icon(
                            _hideConfirm
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            size: 18,
                          ),
                        ),
                      ),
                    ],
                    if (isLogin)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => _message(
                            'Connect this to your password reset flow.',
                          ),
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
                        onChanged: (v) => setState(() => _terms = v),
                      ),
                    const SizedBox(height: 7),
                    SitewiseCtaButton(
                      label: _loading
                          ? (isLogin ? 'Logging in...' : 'Creating account...')
                          : (isLogin ? 'Log in' : 'Sign up'),
                      onPressed: _loading ? null : _submit,
                    ),
                    const SizedBox(height: 18),
                    const AuthDividerText(),
                    const SizedBox(height: 11),
                    AuthProviderButton(
                      provider: AuthProvider.apple,
                      onPressed: _loading
                          ? null
                          : () => _provider(AuthProvider.apple),
                    ),
                    const SizedBox(height: 9),
                    AuthProviderButton(
                      provider: AuthProvider.google,
                      onPressed: _loading
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
                            onTap: () => setState(
                              () => _tab = isLogin
                                  ? AuthTab.signUp
                                  : AuthTab.login,
                            ),
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
                    if (ServiceLocator.auth.demoAccounts.isNotEmpty) ...[
                      const SizedBox(height: 22),
                      _DemoAccountsHint(
                        accounts: ServiceLocator.auth.demoAccounts,
                        onPick: (email) => setState(() => _email.text = email),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
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

/// Demo-mode helper: lists seeded accounts so the role-based routing
/// (Administrator / Property Owner / F&B Entrepreneur) can be exercised
/// without a real backend. Hidden once Supabase is connected.
class _DemoAccountsHint extends StatelessWidget {
  final List<SitewiseUser> accounts;
  final ValueChanged<String> onPick;

  const _DemoAccountsHint({required this.accounts, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final shown = accounts.take(4).toList();
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: SitewiseColors.geoWash,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: SitewiseColors.geoBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Demo accounts (any password ≥ 6 characters)',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: SitewiseColors.ink,
            ),
          ),
          const SizedBox(height: 8),
          for (final account in shown)
            InkWell(
              onTap: () => onPick(account.email),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        account.email,
                        style: const TextStyle(
                          fontSize: 11,
                          color: SitewiseColors.ink,
                        ),
                      ),
                    ),
                    Text(
                      account.role.label,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: SitewiseColors.action,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
