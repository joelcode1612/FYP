import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/staff_security_shell.dart';
import '../components/ui.dart';
import '../data/auth_service.dart';

/// Renders the five supplied design states: challenge, successful, enrollment,
/// invalid code and expired code. All success transitions are provider-backed.
/// The same component is used by /staff/verify and /staff/mfa.
class StaffSecurityFlow extends StatefulComponent {
  final bool enrollment;
  const StaffSecurityFlow({super.key, this.enrollment = false});

  @override
  State<StaffSecurityFlow> createState() => _StaffSecurityFlowState();
}

enum _Screen {
  loading, verify, enroll, invalid, expired, success,
  unavailable, sessionExpired, roleDenied, accountBlocked,
}

class _StaffSecurityFlowState extends State<StaffSecurityFlow> {
  _Screen _screen = _Screen.loading;
  bool _busy = false;
  String _code = '';
  String? _message;
  Timer? _redirectTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      // The auth bundle keeps retrying while the Supabase configuration is
      // unavailable (and its `ready` promise only settles on success), so
      // bound the wait here to guarantee an actionable state.
      await WebAuth.initialize().timeout(const Duration(seconds: 15));
      if (!WebAuth.configured) {
        throw StateError('The authentication configuration is unavailable.');
      }
      if (component.enrollment) {
        await WebAuth.mfaEnrollStart();
        if (mounted) setState(() => _screen = _Screen.enroll);
      } else {
        final status = await WebAuth.mfaChallengeStart();
        if (!mounted) return;
        if (status == 'enroll') {
          // Auth service routes to /staff/mfa when the account needs setup.
          setState(() => _screen = _Screen.loading);
        } else if (status == 'verified') {
          _success();
        } else {
          setState(() => _screen = _Screen.verify);
        }
      }
    } catch (error) {
      // The JS bridge logs the original technical error to the browser
      // console in development (safe metadata only — never tokens, codes or
      // QR data). Here it is mapped to a specific, safe UI state; the raw
      // error text is never rendered.
      final type = _classify(error);
      if (!mounted) return;
      if (type == _Screen.enroll) {
        // "Authenticator already enrolled": the bridge navigated to
        // /staff/verify — let the navigation land instead of flashing a card.
        return;
      }
      setState(() {
        _screen = type;
        _message = switch (type) {
          _Screen.sessionExpired =>
            'Your sign-in session has expired. Please sign in again.',
          _Screen.roleDenied =>
            'This account does not have Agent or Administrator access, so it cannot use staff verification.',
          _Screen.accountBlocked =>
            'Your account is not active. Contact a Sitewise administrator before signing in.',
          _Screen.enroll =>
            'Your account still needs authenticator setup.',
          _ =>
            'The verification service could not be reached. Check your connection and try again.',
        };
      });
    }
  }

  /// Maps a thrown bridge error to a screen. The text comes from the auth
  /// bridge's own messages (plus Supabase/network strings), so matching is
  /// ordered most-specific-first. Classification only — never rendered.
  _Screen _classify(Object error) {
    final text = error.toString().toLowerCase();
    bool has(List<String> needles) => needles.any(text.contains);
    // Session / identity problems outrank everything downstream.
    if (has([
      'sign-in session expired',
      'sign in to continue',
      'session expired',
      'identity changed',
    ])) {
      return _Screen.sessionExpired;
    }
    // Portal / role violations.
    if (has([
      'staff role is required',
      'not a staff account',
      'staff accounts sign in through',
    ])) {
      return _Screen.roleDenied;
    }
    // Account lifecycle (backend-crafted status messages).
    if (has([
      'pending approval',
      'suspended',
      'account status could not be verified',
    ])) {
      return _Screen.accountBlocked;
    }
    // Success-adjacent navigation from the bridge (verified factor exists).
    if (has(['already enrolled'])) return _Screen.enroll;
    // Code-lifecycle failures get their dedicated card.
    if (has(['code has expired', 'code expired', 'challenge expired'])) {
      return _Screen.expired;
    }
    // Transport / service availability.
    if (has([
      'failed to fetch',
      'networkerror',
      'timeout',
      'timed out',
      'the authentication configuration',
      'data service',
      'could not complete this request',
      'assurance',
      'factors unavailable',
      'could not start mfa challenge',
      'could not start the authenticator setup',
      'could not verify the enrollment code',
      'was not confirmed',
      'timeoutexception',
      'unable to start',
    ])) {
      return _Screen.unavailable;
    }
    // Everything else (e.g. Supabase "Invalid TOTP code detected") is a
    // code-level rejection.
    return _Screen.invalid;
  }

  Future<void> _verify() async {
    if (_busy) return;
    if (!RegExp(r'^\d{6}$').hasMatch(_code)) {
      setState(() => _message = 'Enter all six digits from your authenticator app.');
      return;
    }
    setState(() { _busy = true; _message = null; });
    try {
      if (component.enrollment) {
        await WebAuth.mfaEnrollVerify(_code);
      } else {
        await WebAuth.mfaChallengeVerify(_code);
      }
      if (mounted) _success();
    } catch (error) {
      if (!mounted) return;
      final type = _classify(error);
      setState(() {
        _busy = false;
        _code = '';
        _screen = type;
        _message = switch (type) {
          _Screen.expired => 'Your code has expired. Enter the newest code from the app.',
          _Screen.sessionExpired => 'Your sign-in session has expired. Please sign in again.',
          _Screen.roleDenied => 'This account does not have Agent or Administrator access.',
          _Screen.accountBlocked => 'Your account is not active. Contact a Sitewise administrator.',
          _Screen.unavailable => 'Unable to contact the authentication service. Try again.',
          _ => 'The code is incorrect. Check the current code and try again.',
        };
      });
    }
  }

  void _success() {
    setState(() { _screen = _Screen.success; _busy = false; _message = null; _code = ''; });
    _redirectTimer?.cancel();
    _redirectTimer = Timer(const Duration(milliseconds: 1600), () async {
      try {
        await WebAuth.complete();
      } catch (_) {
        if (mounted) {
          setState(() {
            _screen = _Screen.unavailable;
            _message = 'Your code was verified, but your staff workspace could not load. Try again.';
          });
        }
      }
    });
  }

  Future<void> _retry() async {
    setState(() { _busy = false; _code = ''; _message = null; });
    // Expired challenge must be renewed; invalid TOTP can also be retried
    // with a fresh challenge, which is safer across repeated attempts.
    if (component.enrollment) {
      setState(() => _screen = _Screen.enroll);
    } else {
      setState(() => _screen = _Screen.loading);
      await _init();
    }
  }

  Future<void> _cancel() async {
    try { await WebAuth.signout(); } catch (_) {
      if (mounted) setState(() { _screen = _Screen.unavailable; _message = 'Unable to sign out. Please retry.'; });
    }
  }

  @override
  void dispose() {
    _redirectTimer?.cancel();
    super.dispose();
  }

  Component _digitBoxes() => div(classes: 'smfa-code-row', [
    for (var i = 0; i < 6; i++)
      div(classes: 'smfa-code-box${_code.length == i ? ' is-next' : ''}', [
        Component.text(i < _code.length ? _code[i] : ''),
      ]),
    // A single real input supports paste and native one-time-code autofill.
    input(
      type: InputType.text,
      id: 'smfa-code',
      classes: 'smfa-code-input',
      attributes: {
        'aria-label': 'Six-digit authenticator code',
        'autocomplete': 'one-time-code',
        'inputmode': 'numeric',
        'pattern': '[0-9]*',
        'maxlength': '6',
        'value': _code,
      },
      events: events<String>(onInput: (v) {
        final digits = v.replaceAll(RegExp(r'\D'), '');
        setState(() {
          _code = digits.length > 6 ? digits.substring(0, 6) : digits;
          _message = null;
        });
      }),
    ),
  ]);

  Component _action(String label, Future<void> Function() action, {bool secondary = false}) =>
      button(
        classes: secondary ? 'smfa-secondary' : 'smfa-primary',
        attributes: {'type': 'button', if (_busy) 'disabled': 'true'},
        events: events(onClick: action),
        [Component.text(label)],
      );

  Component _titleIcon(String name, String variant) => div(classes: 'smfa-status-icon $variant', [Icon(name)]);

  Component _verifyCard() => div(classes: 'smfa-card', [
    _titleIcon('shield', 'blue'),
    h2([Component.text('Verify Your Identity')]),
    p(classes: 'smfa-description', [Component.text('Enter the 6-digit verification code from your authenticator app to continue.')]),
    label(attributes: const {'for': 'smfa-code'}, [Component.text('Authenticator code')]),
    _digitBoxes(),
    if (_message != null) p(classes: 'smfa-inline-error', attributes: const {'role': 'alert'}, [Component.text(_message!)]),
    _action(_busy ? 'Verifying…' : 'Verify code', _verify),
    _action('Back to staff sign-in', _cancel, secondary: true),
  ]);

  Component _enrollCard() => div(classes: 'smfa-card is-enroll', [
    p(classes: 'smfa-progress', [Component.text('1  Set up     •     2  Verify     •     3  Complete')]),
    _titleIcon('qr_code_scanner', 'blue'),
    h2([Component.text('Set Up Your Authenticator')]),
    p(classes: 'smfa-description', [Component.text('Scan this code with Google Authenticator, Microsoft Authenticator or a similar app.')]),
    if (WebAuth.mfaEnrollQr != null)
      div(classes: 'smfa-qr-frame', [img(src: WebAuth.mfaEnrollQr!, alt: 'Authenticator app enrollment QR code', width: 160, height: 160)]),
    if (WebAuth.mfaEnrollSecret != null)
      details([
        summary([Component.text('Can’t scan? Enter setup key manually')]),
        p(classes: 'smfa-secret', [Component.text(WebAuth.mfaEnrollSecret!)]),
      ]),
    p(classes: 'smfa-support', [Component.text('After adding SiteWise to the authenticator app, enter its six-digit code.')]),
    label(attributes: const {'for': 'smfa-code'}, [Component.text('Verification code')]),
    _digitBoxes(),
    if (_message != null) p(classes: 'smfa-inline-error', attributes: const {'role': 'alert'}, [Component.text(_message!)]),
    _action(_busy ? 'Checking…' : 'Verify & complete', _verify),
    _action('Cancel setup', _cancel, secondary: true),
  ]);

  Component _successCard() => div(classes: 'smfa-card smfa-result', [
    _titleIcon('check', 'green'),
    h2([Component.text('Verification Successful')]),
    p(classes: 'smfa-description', [Component.text('Your identity has been verified. Redirecting to your authorized staff workspace…')]),
    div(classes: 'smfa-loader', attributes: const {'aria-label': 'Loading your workspace'}, []),
    p(classes: 'smfa-support', [Component.text('Access is granted only after the server validates your role and security level.')]),
  ]);

  Component _failureCard({required bool expired}) => div(classes: 'smfa-card smfa-result', [
    _titleIcon(expired ? 'schedule' : 'error', expired ? 'amber' : 'red'),
    h2([Component.text(expired ? 'Verification Code Expired' : 'Invalid Verification Code')]),
    p(classes: 'smfa-description', [Component.text(expired
        ? 'This code is no longer valid. Use the newest code shown in your authenticator app.'
        : 'The code you entered could not be verified. Please try again.')]),
    div(classes: 'smfa-alert ${expired ? 'warning' : 'danger'}', attributes: const {'role': 'alert'}, [
      Icon(expired ? 'warning' : 'error_outline', size: 'sm'),
      Component.text(_message ?? 'Please try a fresh six-digit code.'),
    ]),
    _action('Try again', _retry),
    _action('Back to staff sign-in', _cancel, secondary: true),
  ]);

  Component _utilityCard() {
    final isRoleIssue =
        _screen == _Screen.roleDenied || _screen == _Screen.accountBlocked;
    return div(classes: 'smfa-card smfa-result', [
      _titleIcon(
        switch (_screen) {
          _Screen.sessionExpired => 'lock_clock',
          _Screen.roleDenied => 'badge',
          _Screen.accountBlocked => 'lock_person',
          _ => 'wifi_off',
        },
        'amber',
      ),
      h2([
        Component.text(switch (_screen) {
          _Screen.sessionExpired => 'Session Expired',
          _Screen.roleDenied => 'Staff Access Only',
          _Screen.accountBlocked => 'Account Not Active',
          _ => 'Verification Unavailable',
        }),
      ]),
      p(classes: 'smfa-description', [Component.text(_message ?? 'Checking your authentication session…')]),
      _action(
        _screen == _Screen.sessionExpired || isRoleIssue
            ? 'Back to staff sign-in'
            : 'Try again',
        _screen == _Screen.sessionExpired || isRoleIssue ? _cancel : _retry,
      ),
    ]);
  }

  @override
  Component build(BuildContext context) => StaffSecurityShell(
    card: switch (_screen) {
      _Screen.loading => div(classes: 'smfa-card smfa-result', [
        _titleIcon('shield', 'blue'),
        h2([Component.text('Preparing Secure Verification')]),
        p(classes: 'smfa-description', [Component.text('Checking your authenticator setup and session…')]),
        div(classes: 'smfa-loader', []),
      ]),
      _Screen.verify => _verifyCard(),
      _Screen.enroll => _enrollCard(),
      _Screen.invalid => _failureCard(expired: false),
      _Screen.expired => _failureCard(expired: true),
      _Screen.success => _successCard(),
      _ => _utilityCard(),
    },
  );
}
