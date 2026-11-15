import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../core/auth/account_purpose.dart';
import '../../../../core/auth/signup_password_policy.dart';
import '../../../../core/config/dev_auth_bypass.dart';
import '../../../../core/routing/auth_route_guard.dart' show postAuthNavigation;
import '../../../../core/routing/mobile_role.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_bottom_sheet.dart';
import '../../../shared/widgets/sitewise_cta_button.dart';
import '../../../shared/widgets/sitewise_icon.dart';
import '../widgets/auth_field.dart';
import '../widgets/auth_provider_button.dart';
import '../widgets/auth_terms_row.dart';
import '../widgets/signup_decorations.dart';
import '../widgets/signup_password_rules.dart';
import '../widgets/signup_role_card.dart';
import '../widgets/signup_step_indicator.dart';

/// The two in-page stages of the mobile registration funnel.
///
/// There is deliberately NO "Verify" stage. The trusted backend provisions a
/// new Entrepreneur identity already email-confirmed, and Supabase issues a
/// genuine session from a real password sign-in, so an email-verification
/// screen would be a dead end. Owner / Agent accounts are staff: their third
/// step is the existing authenticator (MFA) screen, which is a ROUTE after
/// registration, not a third page in this funnel — so the indicator shows it
/// as an upcoming step without ever labelling it "Verify".
enum SignupStage { accountType, accountDetails }

/// Complete mobile registration flow:
/// Account Type -> Account Details -> (MFA for staff) -> workspace.
///
/// One [State] owns every [TextEditingController] for the whole funnel, so
/// stepping back from Details to Account Type (by arrow or by Android's
/// system back) never clears the name, email, passwords, consent or purpose.
/// No account is created at Step 1.
///
/// All credential work goes through the existing [AuthNotifier] ->
/// [AuthService] -> [AuthRepository] chain. This page never reads a token,
/// never invents a role, never marks an address verified, and never navigates
/// to a workspace on anything other than a backend-validated
/// [AuthStatus.authenticated] session.
class SignupMobilePage extends ConsumerStatefulWidget {
  const SignupMobilePage({super.key});

  @override
  ConsumerState<SignupMobilePage> createState() => _SignupMobilePageState();
}

class _SignupMobilePageState extends ConsumerState<SignupMobilePage> {
  static final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  SignupStage _stage = SignupStage.accountType;
  AccountPurpose? _purpose;

  // Deliberately kept for the lifetime of this page: no form value is
  // persisted to preferences, and passwords never leave these controllers.
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _hidePassword = true;
  bool _hideConfirm = true;
  bool _terms = false;

  /// Guards against a second account creation from a double tap and against
  /// an email signup and Google OAuth running at the same time.
  bool _submitting = false;
  String? _error;

  bool _enteredWorkspace = false;
  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    // Live password-rule indicators and the confirm-password mismatch hint.
    _password.addListener(_onFieldChanged);
    _confirm.addListener(_onFieldChanged);
    // The startup gate normally restores a session first. Calling start()
    // again is a no-op, and the shared notifier is re-entrant safe: a deep
    // link straight to /signup still validates any saved session through
    // GET /api/v1/auth/me before this page considers a workspace.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || devAuthBypassEnabled) return;
      await ref.read(authNotifierProvider.notifier).start();
      if (!mounted) return;
      // A listener only fires on *changes*. If a session was restored before
      // this page mounted, validate it through the same provider and enter
      // the workspace once, guarded by _enteredWorkspace.
      final state = ref.read(authNotifierProvider);
      final user = state.user;
      if (state.isAuthenticated && user != null) {
        _enterVerifiedWorkspace(user);
      }
    });
  }

  @override
  void dispose() {
    _password.removeListener(_onFieldChanged);
    _confirm.removeListener(_onFieldChanged);
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _onFieldChanged() {
    if (mounted && _stage == SignupStage.accountDetails) setState(() {});
  }

  // ── Navigation ──────────────────────────────────────────────────────────

  /// The only back handler: the top-left arrow and Android's system back both
  /// land here, so they cannot disagree about where Back goes. Form state is
  /// deliberately preserved when stepping back from Account Details.
  void _handleBack() {
    switch (_stage) {
      case SignupStage.accountType:
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        } else {
          _exitToLogin();
        }
      case SignupStage.accountDetails:
        setState(() {
          _stage = SignupStage.accountType;
          _error = null;
        });
    }
  }

  /// Clears the stack to exactly one Login route.
  void _exitToLogin() {
    if (_exiting) return;
    _exiting = true;
    Navigator.of(context).pushNamedAndRemoveUntil(
      '/auth',
      (Route<dynamic> route) => false,
      arguments: 'login',
    );
  }

  /// Workspace entry for an authenticated session (restored session, a new
  /// registration, or Google OAuth). Only the backend-assigned role and the
  /// server-verified assurance level are used — the account purpose is never
  /// consulted here, and no local boolean grants access.
  void _enterVerifiedWorkspace(SitewiseUser user) {
    if (_enteredWorkspace || !mounted) return;
    final navigation = postAuthNavigation(user);
    if (navigation == null) {
      setState(() => _error = mobileUnsupportedRoleMessage(user.role));
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

  // ── Business rules ──────────────────────────────────────────────────────

  /// Entrepreneur registration is two steps. An Owner / Agent account has a
  /// third, security step — the authenticator screen opened after a genuine
  /// session exists. It is never presented as email confirmation.
  List<String> get _stepLabels => switch (_purpose) {
    AccountPurpose.ownerAgent => const <String>[
      'Account Type',
      'Account Details',
      'Authenticator',
    ],
    _ => const <String>['Account Type', 'Account Details'],
  };

  String? _validateDetails() {
    if (_purpose == null) return 'Choose how you plan to use SiteWise.';
    if (_name.text.trim().length < 2) return 'Please enter your full name.';
    if (!_emailPattern.hasMatch(_email.text.trim())) {
      return 'Please enter a valid email address.';
    }
    if (!SignupPasswordPolicy.isValid(_password.text)) {
      return SignupPasswordPolicy.requirementMessage;
    }
    if (_password.text != _confirm.text) return 'Passwords do not match.';
    if (!_terms) {
      return 'Please agree to the Terms of Service and Privacy Policy.';
    }
    return null;
  }

  /// Translates the shared auth state into a safe sentence. Provider text,
  /// HTTP codes, endpoint addresses and raw exceptions never reach the UI.
  String _failureMessage(AuthState state) {
    if (state.status == AuthStatus.error) {
      return switch (state.errorKind) {
        AuthErrorKind.configuration =>
          'This app build is missing its sign-up settings. '
              'Please contact support.',
        AuthErrorKind.timeout =>
          'SiteWise is taking too long to respond. Please try again.',
        AuthErrorKind.tls =>
          'A secure connection could not be established. Please try again.',
        AuthErrorKind.server =>
          'Account registration is not available with this project\'s email '
              'settings. Please contact SiteWise support.',
        _ =>
          'Unable to connect to SiteWise. Check your connection and try again.',
      };
    }
    if (state.status == AuthStatus.emailConfirmationRequired) {
      // Defensive only: registration now yields a genuine session. If the
      // provider ever answers that confirmation is still owed, say so
      // honestly instead of pretending the account is authenticated.
      return 'Your account was created, but this project still requires email '
          'confirmation before sign-in. Please contact SiteWise support.';
    }
    return state.message ??
        'We could not create your account. Please check your details and '
            'try again.';
  }

  void _continue() {
    if (_purpose == null) {
      setState(() => _error = 'Choose how you plan to use SiteWise.');
      return;
    }
    setState(() {
      _stage = SignupStage.accountDetails;
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final problem = _validateDetails();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final email = _email.text.trim();
    setState(() {
      _submitting = true;
      _error = null;
    });
    final ok = await ref
        .read(authNotifierProvider.notifier)
        .signUp(
          email: email,
          password: _password.text,
          fullName: _name.text.trim(),
          accountPurpose: _purpose!.wireValue,
          acceptTerms: _terms,
        );
    if (!mounted) return;
    final state = ref.read(authNotifierProvider);
    setState(() => _submitting = false);
    if (ok && state.isAuthenticated && state.user != null) {
      // The listener also reacts; _enteredWorkspace makes this idempotent, so
      // a listener that only fires on *changes* can never strand a signup.
      _enterVerifiedWorkspace(state.user!);
      return;
    }
    setState(() => _error = _failureMessage(state));
  }

  Future<void> _google() async {
    if (_submitting) return;
    if (_purpose == null) {
      setState(() => _error = 'Choose how you plan to use SiteWise first.');
      return;
    }
    if (!_terms) {
      setState(
        () => _error =
            'Please agree to the Terms of Service and Privacy Policy.',
      );
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final ok = await ref
        .read(authNotifierProvider.notifier)
        .signInWithProvider(
          AuthProvider.google,
          accountPurpose: _purpose!.wireValue,
        );
    if (!mounted) return;
    final state = ref.read(authNotifierProvider);
    setState(() => _submitting = false);
    if (ok && state.isAuthenticated && state.user != null) {
      _enterVerifiedWorkspace(state.user!);
      return;
    }
    setState(() => _error = _failureMessage(state));
  }

  void _openLegal(String document) {
    showSitewiseBottomSheet<void>(
      context,
      title: document,
      builder: (_) => Text(
        'The $document is not bundled in the mobile app yet. '
        'Please contact SiteWise support for a copy.',
        style: const TextStyle(
          fontSize: 13,
          height: 1.5,
          color: SitewiseColors.text,
        ),
      ),
    );
  }

  // ── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // A restored or newly verified session is the only thing that may open a
    // protected dashboard. Deferred so no provider is mutated during build.
    ref.listen<AuthState>(authNotifierProvider, (previous, next) {
      if (!next.isAuthenticated) return;
      final user = next.user;
      if (user == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _enterVerifiedWorkspace(user);
      });
    });

    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        backgroundColor: SitewiseColors.background,
        body: SafeArea(
          child: Column(
            children: <Widget>[
              SignupHeader(onBack: _handleBack),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                child: SignupStepIndicator(
                  currentStep: _stage.index,
                  labels: _stepLabels,
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  child: switch (_stage) {
                    SignupStage.accountType => _accountTypeStep(),
                    SignupStage.accountDetails => _accountDetailsStep(),
                  },
                ),
              ),
              if (_stage == SignupStage.accountType) const SignupCityscape(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _title(String text) => Text(
    text,
    style: const TextStyle(
      fontFamily: kFontFamily,
      fontSize: 27,
      fontWeight: FontWeight.w800,
      color: SitewiseColors.ink,
      letterSpacing: -.7,
    ),
  );

  Widget _description(String text) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        height: 1.5,
        color: SitewiseColors.muted,
      ),
    ),
  );

  Widget _errorOrEmpty() => _error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: SignupErrorBanner(message: _error!),
        );

  Widget _loginLink() => Center(
    child: Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        const Text(
          'Already have an account? ',
          style: TextStyle(fontSize: 12, color: SitewiseColors.muted),
        ),
        GestureDetector(
          onTap: _submitting ? null : _exitToLogin,
          child: const Text(
            'Log in',
            style: TextStyle(
              fontSize: 12,
              color: SitewiseColors.action,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _accountTypeStep() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _title('Create Your Account'),
      _description(
        'Join SiteWise to discover or manage commercial properties for '
        'F&B businesses.',
      ),
      const SizedBox(height: 22),
      _errorOrEmpty(),
      const Text(
        "I'm joining as...",
        style: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w800,
          color: SitewiseColors.ink,
        ),
      ),
      const SizedBox(height: 13),
      for (final purpose in AccountPurpose.values) ...<Widget>[
        SignupRoleCard(
          icon: purpose == AccountPurpose.entrepreneur
              ? Icons.storefront_rounded
              : Icons.apartment_rounded,
          title: purpose.label,
          description: purpose.description,
          selected: _purpose == purpose,
          onTap: () => setState(() {
            _purpose = purpose;
            _error = null;
          }),
        ),
        const SizedBox(height: 12),
      ],
      const SizedBox(height: 6),
      const SignupInfoNote(
        message:
            'Property listings can only be created and managed by authorized '
            'Property Owners or Agents.',
      ),
      const SizedBox(height: 22),
      SitewiseCtaButton(
        label: _submitting ? 'Please wait…' : 'Continue  →',
        onPressed: _submitting ? null : _continue,
      ),
      const SizedBox(height: 16),
      _loginLink(),
    ],
  );

  Widget _visibilityToggle({
    required bool hidden,
    required VoidCallback onTap,
  }) => IconButton(
    onPressed: onTap,
    icon: SitewiseIcon(
      hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
      intent: SitewiseIconIntent.field,
      semanticLabel: hidden ? 'Show password' : 'Hide password',
    ),
  );

  Widget _accountDetailsStep() {
    final mismatch = _confirm.text.isNotEmpty &&
        _confirm.text != _password.text &&
        _password.text.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _title('Your Account Details'),
        _description('Create your SiteWise account to get started.'),
        const SizedBox(height: 20),
        _errorOrEmpty(),
        AuthField(
          label: 'Full Name',
          required: true,
          controller: _name,
          hint: 'Enter your full name',
          icon: Icons.person_outline_rounded,
          textInputAction: TextInputAction.next,
          autofillHints: const <String>[AutofillHints.name],
        ),
        const SizedBox(height: 14),
        AuthField(
          label: 'Email Address',
          required: true,
          controller: _email,
          hint: 'name@example.com',
          icon: Icons.mail_outline_rounded,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          autofillHints: const <String>[AutofillHints.email],
        ),
        const SizedBox(height: 14),
        AuthField(
          label: 'Password',
          required: true,
          controller: _password,
          hint: 'Create a password',
          icon: Icons.lock_outline_rounded,
          obscure: _hidePassword,
          textInputAction: TextInputAction.next,
          autofillHints: const <String>[AutofillHints.newPassword],
          suffix: _visibilityToggle(
            hidden: _hidePassword,
            onTap: () => setState(() => _hidePassword = !_hidePassword),
          ),
        ),
        SignupPasswordRules(password: _password.text),
        const SizedBox(height: 14),
        AuthField(
          label: 'Confirm Password',
          required: true,
          controller: _confirm,
          hint: 'Confirm your password',
          icon: Icons.lock_outline_rounded,
          obscure: _hideConfirm,
          textInputAction: TextInputAction.done,
          onSubmitted: _submitting ? null : (_) => _submit(),
          suffix: _visibilityToggle(
            hidden: _hideConfirm,
            onTap: () => setState(() => _hideConfirm = !_hideConfirm),
          ),
        ),
        if (mismatch)
          const Padding(
            padding: EdgeInsets.only(top: 7, left: 2),
            child: Text(
              'Passwords do not match.',
              style: TextStyle(fontSize: 11.5, color: SitewiseColors.danger),
            ),
          ),
        const SizedBox(height: 12),
        AuthTermsRow(
          value: _terms,
          onChanged: _submitting ? (_) {} : (v) => setState(() => _terms = v),
          onOpenTerms: () => _openLegal('Terms of Service'),
          onOpenPrivacy: () => _openLegal('Privacy Policy'),
        ),
        const SizedBox(height: 14),
        SitewiseCtaButton(
          label: _submitting ? 'Creating account…' : 'Create Account',
          busy: _submitting,
          onPressed: _submitting ? null : _submit,
        ),
        const SizedBox(height: 16),
        const AuthDividerText(label: 'Or sign up with'),
        const SizedBox(height: 12),
        AuthProviderButton(
          provider: AuthProvider.google,
          onPressed: _submitting ? null : _google,
        ),
        const SizedBox(height: 16),
        _loginLink(),
      ],
    );
  }
}
