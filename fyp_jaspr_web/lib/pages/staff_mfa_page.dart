import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/auth_portal_switcher.dart';
import '../components/dom_helpers.dart';
import '../components/ui.dart';
import '../data/auth_service.dart';

/// "Secure Your Staff Account" — the mandatory TOTP enrollment screen of the
/// confirmed first-time staff workflow (Step 6).
///
/// Shown after a staff sign-in when no verified TOTP factor exists: Supabase
/// generates the QR code + secret (`mfa.enroll`), the agent confirms with a
/// live six-digit code (`mfa.challenge` + `mfa.verify`), and only the verified
/// factor satisfies the staff MFA requirement (aal2). Nothing custom is
/// stored: secrets live in Supabase Auth, never in Sitewise tables.
@client
class StaffMfaPage extends StatefulComponent {
  const StaffMfaPage({super.key});

  @override
  State<StaffMfaPage> createState() => _StaffMfaState();
}

class _StaffMfaState extends State<StaffMfaPage> {
  bool _started = false;
  bool _busy = false;
  String _code = '';
  String _alert = '';
  String _alertTone = 'info';
  String? _error;
  // Per-document latch: hydration can re-mount this @client subtree, and
  // _initialize() may call WebAuth.complete() (which navigates). Running it
  // twice would start two enrollments or two redirects.
  static bool _initializing = false;

  @override
  void initState() {
    super.initState();
    if (_initializing) return;
    _initializing = true;
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await WebAuth.initialize();
      if (!WebAuth.configured) {
        setState(() => _error = WebAuth.error);
        return;
      }
      // A staff account that already has a verified factor has nothing to
      // enroll — the bridge routes it to the staff workspace.
      if (!WebAuth.mfaEnrollmentRequired) {
        await WebAuth.complete();
        return;
      }
      await _start();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _start() async {
    try {
      await WebAuth.mfaEnrollStart();
      setState(() {
        _started = true;
        _alert = 'Scan the QR code with your authenticator app, then enter '
            'the 6-digit code to confirm enrollment.';
        _alertTone = 'info';
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _verify() async {
    if (_busy) return;
    final code = _code.trim();
    if (code.length != 6 || int.tryParse(code) == null) {
      setState(() {
        _alert = 'Enter the 6-digit code from your authenticator app.';
        _alertTone = 'err';
      });
      return;
    }
    setState(() {
      _busy = true;
      _alert = 'Verifying your code…';
      _alertTone = 'info';
    });
    try {
      await WebAuth.mfaEnrollVerify(code);
      // On success the auth bridge routes to the staff workspace.
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _alert = 'That code did not verify. Check your authenticator and '
              'try again.';
          _alertTone = 'err';
        });
      }
    }
  }

  @override
  Component build(BuildContext context) {
    final qr = WebAuth.mfaEnrollQr;
    final secret = WebAuth.mfaEnrollSecret;
    return main_(
      classes: 'login-page is-staff',
      attributes: const {'aria-label': 'Staff multi-factor enrollment'},
      [
        div(classes: 'stf-wrap', [
          div(classes: 'stf-shell', [
            section(classes: 'stf-card', [
              const AuthPortalSwitcher(current: 'staff'),
              h2(classes: 'stf-card-title', [
                Component.text('Secure Your Staff Account'),
              ]),
              p(classes: 'stf-card-sub', [
                Component.text(
                  'Multi-factor authentication is mandatory for agents and '
                  'administrators. Enroll an authenticator app to continue.',
                ),
              ]),
              div(classes: 'stf-callout', [
                Icon('shield', size: 'sm'),
                div(classes: 'stf-callout__body', [
                  strong([Component.text('One-time setup:')]),
                  Component.text(
                    ' scan with Google Authenticator, Microsoft Authenticator, '
                    'or any TOTP-compatible app.',
                  ),
                ]),
              ]),
              div(
                classes:
                    'lp-alert $_alertTone${_alert.isEmpty ? ' is-hidden' : ''}',
                attributes: const {'role': 'alert'},
                [textNode(_alert)],
              ),
              if (_error != null)
                div(classes: 'lp-alert err', [
                  Component.text('Enrollment could not start: $_error'),
                ]),
              if (_started && qr != null)
                div(classes: 'stf-qr', [
                  span(classes: 'stf-qr__frame', [
                    img(
                      src: qr,
                      alt: 'TOTP enrollment QR code',
                      width: 180,
                      height: 180,
                    ),
                  ]),
                  if (secret != null)
                    p(classes: 'stf-qr__secret', [
                      Component.text('Can\u2019t scan? Enter this key instead: '),
                      strong([Component.text(_chunkSecret(secret))]),
                    ]),
                ]),
              div(classes: 'lp-group', [
                label(
                  classes: 'lp-label',
                  attributes: const {'for': 'stf-mfa-code'},
                  [Component.text('Verification code')],
                ),
                div(classes: 'lp-field', [
                  span(classes: 'lp-ico', attributes: const {'aria-hidden': 'true'}, [
                    Icon('lock', size: 'sm'),
                  ]),
                  input(
                    type: InputType.text,
                    id: 'stf-mfa-code',
                    attributes: const {
                      'placeholder': '6-digit code',
                      'autocomplete': 'one-time-code',
                      'inputmode': 'numeric',
                      'maxlength': '6',
                    },
                    events:
                        events<String>(onInput: (v) => setState(() => _code = v)),
                  ),
                ]),
              ]),
              button(
                classes: 'lp-submit stf-submit',
                attributes: {'type': 'button', if (_busy) 'disabled': 'true'},
                events: events(onClick: _verify),
                [
                  Component.text(_busy ? 'Verifying…' : 'Confirm enrollment'),
                  if (!_busy) Icon('arrow_forward', size: 'sm'),
                ],
              ),
              div(classes: 'stf-mfa-note', [
                Icon('lock', size: 'sm'),
                div(classes: 'stf-mfa-note__body', [
                  strong([Component.text('Multi-Factor Authentication (MFA)')]),
                  Component.text(
                    ' is required for all staff accounts. Lost your device? '
                    'Contact a Sitewise Administrator to reset your factor.',
                  ),
                ]),
              ]),
            ]),
          ]),
        ]),
      ],
    );
  }

  /// Groups the secret into 4-character chunks for manual entry.
  static String _chunkSecret(String secret) {
    final clean = secret.replaceAll(RegExp(r'\s+'), '');
    final parts = <String>[];
    for (var i = 0; i < clean.length; i += 4) {
      parts.add(clean.substring(i, i + 4 > clean.length ? clean.length : i + 4));
    }
    return parts.join(' ');
  }
}
