import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/auth_icons.dart';
import '../components/dom_helpers.dart';
import '../components/letter_reveal.dart';
import '../components/ui.dart';
import '../data/auth_service.dart';

/// "Set Up Your Sitewise Staff Account" / password reset — the native
/// Supabase recovery/invite flow.
///
/// The user arrives with a valid Supabase session from the recovery (or
/// agent-invite) email link; this screen collects New Password + Confirm and
/// calls `auth.updateUser`. No custom token, no plaintext password anywhere:
/// Supabase owns the link, the session and the credential update. After a
/// successful update the auth bridge routes by the server-assigned role
/// (staff accounts still without a verified TOTP factor land on the
/// enrollment screen first).
@client
class ResetPasswordPage extends StatefulComponent {
  const ResetPasswordPage({super.key});

  @override
  State<ResetPasswordPage> createState() => _ResetState();
}

class _ResetState extends State<ResetPasswordPage> {
  String _password = '';
  String _confirm = '';
  final Map<String, String> _errors = {};
  String _alert = '';
  String _alertTone = 'info';
  bool _busy = false;
  bool _show = false;

  static const int _minPasswordLength = 8;

  Future<void> _submit() async {
    if (_busy) return;
    final e = <String, String>{};
    if (_password.isEmpty) {
      e['password'] = 'Enter a new password.';
    } else if (_password.length < _minPasswordLength) {
      e['password'] = 'Use at least $_minPasswordLength characters.';
    }
    if (_confirm.isEmpty) {
      e['confirm'] = 'Confirm your new password.';
    } else if (_confirm != _password) {
      e['confirm'] = 'Passwords do not match.';
    }
    setState(() {
      _errors
        ..clear()
        ..addAll(e);
      if (e.isEmpty) {
        _alert = 'Saving your new password…';
        _alertTone = 'info';
      } else {
        _alert = 'Please fix the highlighted fields.';
        _alertTone = 'err';
      }
    });
    if (e.isNotEmpty) return;
    setState(() => _busy = true);
    try {
      await WebAuth.updatePassword(_password);
      // The bridge routes by role on success; nothing else to do here.
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _alert = error.toString();
          _alertTone = 'err';
        });
      }
    }
  }

  Component _field({
    required String forId,
    required String errKey,
    required String labelText,
    required String placeholder,
    required void Function(String) onInput,
  }) => div(classes: 'lp-group', [
    label(
      classes: 'lp-label',
      attributes: {'for': forId},
      [Component.text(labelText)],
    ),
    div(classes: 'lp-field${_errors[errKey] != null ? ' is-invalid' : ''}', [
      span(classes: 'lp-ico', attributes: const {'aria-hidden': 'true'}, [
        authIconLock(),
      ]),
      input(
        type: _show ? InputType.text : InputType.password,
        id: forId,
        attributes: {
          'placeholder': placeholder,
          'autocomplete': 'new-password',
        },
        events: events<String>(onInput: (v) => setState(() => onInput(v))),
      ),
      button(
        classes: 'lp-eye',
        attributes: {
          'type': 'button',
          'aria-label': 'Toggle password visibility',
          'aria-pressed': _show ? 'true' : 'false',
        },
        events: events(onClick: () => setState(() => _show = !_show)),
        [Icon(_show ? 'visibility_off' : 'visibility', size: 'sm')],
      ),
    ]),
    span(
      classes: 'lp-err${_errors[errKey] == null ? ' is-hidden' : ''}',
      attributes: const {'role': 'alert'},
      [textNode(_errors[errKey])],
    ),
  ]);

  @override
  Component build(BuildContext context) {
    return main_(
      classes: 'login-page is-staff',
      attributes: const {'aria-label': 'Set a new password'},
      [
        div(classes: 'stf-wrap', [
          div(classes: 'stf-shell', [
            section(classes: 'stf-card', [
              div(classes: 'auth-topbar', [
                AppLink(
                  to: '/login',
                  classes: 'auth-back',
                  attributes: const {'aria-label': 'Back to sign in'},
                  children: [Icon('chevron_left', size: 'sm')],
                ),
              ]),
              LetterRevealHeading.text(
                'Set a New Password',
                level: 2,
                classes: 'stf-card-title',
              ),
              p(classes: 'stf-card-sub', [
                Component.text(
                  'Choose a strong password for your Sitewise account. This '
                  'works for first-time staff setup and password resets.',
                ),
              ]),
              div(
                classes:
                    'lp-alert $_alertTone${_alert.isEmpty ? ' is-hidden' : ''}',
                attributes: const {'role': 'alert'},
                [textNode(_alert)],
              ),
              _field(
                forId: 'rst-password',
                errKey: 'password',
                labelText: 'New Password',
                placeholder: 'At least $_minPasswordLength characters',
                onInput: (v) => _password = v,
              ),
              _field(
                forId: 'rst-confirm',
                errKey: 'confirm',
                labelText: 'Confirm Password',
                placeholder: 'Repeat the new password',
                onInput: (v) => _confirm = v,
              ),
              button(
                classes: 'lp-submit stf-submit',
                attributes: {'type': 'button', if (_busy) 'disabled': 'true'},
                events: events(onClick: _submit),
                [
                  Component.text(_busy ? 'Saving…' : 'Save password'),
                  if (!_busy) Icon('arrow_forward', size: 'sm'),
                ],
              ),
            ]),
          ]),
        ]),
      ],
    );
  }
}
