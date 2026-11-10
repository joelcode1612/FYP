import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/auth_icons.dart';
import '../components/dom_helpers.dart';
import '../components/letter_reveal.dart';
import '../components/ui.dart';
import '../data/auth_service.dart';

/// "Set a New Password" — the native Supabase invite/recovery flow landing.
///
/// Left: brand, heading and the three-step onboarding tracker (invitation
/// received -> set password -> sign in & get activated) on the dark navy +
/// Kuala Lumpur cityscape band shared with the staff portal. Right: dark glass
/// card with the two password fields, visibility toggles, a live requirements
/// checklist and the gradient "Set Password" action. Stacks below 981px.
///
/// The user arrives with a valid Supabase session from the email link; this
/// screen collects New Password + Confirm and calls `auth.updateUser`. No
/// custom token, no plaintext password anywhere: Supabase owns the link, the
/// session and the credential update. The checklist is a UX aid only —
/// Supabase's server-side policy remains the validation authority. On success
/// the auth bridge routes by flow: invited agents end their local session on
/// /staff/signin (the account stays pending until an administrator activates
/// it), recovery sessions continue the normal sign-in completion.
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
  bool _showPassword = false;
  bool _showConfirm = false;

  static const int _minPasswordLength = 8;

  // Live checklist state. Matching the on-screen list never replaces the
  // server-side validation Supabase applies to the final credential.
  bool get _reqLength => _password.length >= _minPasswordLength;
  bool get _reqUpper => _password.contains(RegExp(r'[A-Z]'));
  bool get _reqLower => _password.contains(RegExp(r'[a-z]'));
  bool get _reqDigit => _password.contains(RegExp(r'[0-9]'));
  bool get _reqSpecial => _password.contains(RegExp(r'[^A-Za-z0-9]'));
  bool get _reqMatch => _password.isNotEmpty && _password == _confirm;

  bool get _allRequirementsMet =>
      _reqLength &&
      _reqUpper &&
      _reqLower &&
      _reqDigit &&
      _reqSpecial &&
      _reqMatch;

  Future<void> _submit() async {
    if (_busy) return;
    final e = <String, String>{};
    if (_password.isEmpty) {
      e['password'] = 'Enter a new password.';
    } else if (!_allRequirementsMet) {
      e['password'] = 'Your password does not meet all the requirements below.';
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
      // The bridge completes the flow: invited agents are signed out locally
      // and taken to /staff/signin; recovery sessions continue the normal
      // sign-in completion. A failed update throws and stays on this page.
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

  // ----------------------------------------------------------------- fields

  Component _field({
    required String forId,
    required String errKey,
    required String labelText,
    required String placeholder,
    required bool show,
    required void Function() onToggle,
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
        type: show ? InputType.text : InputType.password,
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
          'aria-pressed': show ? 'true' : 'false',
        },
        events: events(onClick: () => setState(onToggle)),
        [Icon(show ? 'visibility_off' : 'visibility', size: 'sm')],
      ),
    ]),
    span(
      classes: 'lp-err${_errors[errKey] == null ? ' is-hidden' : ''}',
      attributes: const {'role': 'alert'},
      [textNode(_errors[errKey])],
    ),
  ]);

  // ------------------------------------------------------------ step tracker

  Component _step({
    required String number,
    required String label,
    required String state,
  }) => li(classes: 'rst-step is-$state', [
    span(
      classes: 'rst-step-dot',
      attributes: {'aria-hidden': 'true'},
      [
        if (state == 'done') Icon('check', size: 'sm') else Component.text(number),
      ],
    ),
    span(classes: 'rst-step-name', [Component.text(label)]),
  ]);

  Component _requirement(String label, bool ok) => li(
    classes: 'rst-req${ok ? ' is-ok' : ''}',
    attributes: {'aria-label': '$label — ${ok ? 'met' : 'not met yet'}'},
    [
      span(
        classes: 'rst-req-ico',
        attributes: const {'aria-hidden': 'true'},
        [Icon(ok ? 'check_circle' : 'radio_button_unchecked', size: 'sm')],
      ),
      Component.text(label),
    ],
  );

  @override
  Component build(BuildContext context) {
    final requirements = <(String, bool)>[
      ('At least 8 characters', _reqLength),
      ('One uppercase letter (A–Z)', _reqUpper),
      ('One lowercase letter (a–z)', _reqLower),
      ('One number (0–9)', _reqDigit),
      ('One special character (!@#\$…)', _reqSpecial),
      ('Both passwords match', _reqMatch),
    ];
    return main_(
      classes: 'login-page is-staff',
      attributes: const {'aria-label': 'Set a new password'},
      [
        div(classes: 'lp-bg', attributes: const {'aria-hidden': 'true'}, []),
        div(classes: 'lp-overlay', attributes: const {'aria-hidden': 'true'}, []),
        div(classes: 'rst-wrap', [
          div(classes: 'rst-shell', [
            section(
              classes: 'rst-hero',
              attributes: const {'aria-label': 'Account setup progress'},
              [
                div(classes: 'rst-brand', [
                  img(
                    src: '/assets/sitewise-mark-64.png',
                    alt: 'Sitewise',
                    width: 30,
                    height: 30,
                  ),
                  strong([Component.text('SiteWise')]),
                ]),
                LetterRevealHeading.text(
                  'Set a New Password',
                  level: 1,
                  classes: 'rst-title',
                ),
                p(classes: 'rst-hero-sub', [
                  Component.text(
                    'You were invited to join SiteWise. Choose a strong '
                    'password to secure your account, then wait for an '
                    'administrator to activate it.',
                  ),
                ]),
                ol(
                  classes: 'rst-steps',
                  attributes: const {'aria-label': 'Setup steps'},
                  [
                    _step(number: '1', label: 'Invitation Received', state: 'done'),
                    _step(number: '2', label: 'Set a New Password', state: 'current'),
                    _step(number: '3', label: 'Sign In & Get Activated', state: 'todo'),
                  ],
                ),
              ],
            ),
            section(
              classes: 'stf-card rst-card',
              attributes: const {'aria-label': 'Set a new password form'},
              [
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
                  show: _showPassword,
                  onToggle: () => _showPassword = !_showPassword,
                  onInput: (v) => _password = v,
                ),
                _field(
                  forId: 'rst-confirm',
                  errKey: 'confirm',
                  labelText: 'Confirm Password',
                  placeholder: 'Repeat the new password',
                  show: _showConfirm,
                  onToggle: () => _showConfirm = !_showConfirm,
                  onInput: (v) => _confirm = v,
                ),
                ul(
                  classes: 'rst-reqs',
                  attributes: const {'aria-label': 'Password requirements'},
                  [
                    for (final (label, ok) in requirements) _requirement(label, ok),
                  ],
                ),
                button(
                  classes: 'lp-submit rst-submit',
                  attributes: {'type': 'button', if (_busy) 'disabled': 'true'},
                  events: events(onClick: _submit),
                  [
                    Component.text(_busy ? 'Setting…' : 'Set Password'),
                    if (!_busy) Icon('arrow_forward', size: 'sm'),
                  ],
                ),
                p(classes: 'rst-back', [
                  AppLink(
                    to: '/staff/signin',
                    children: [Component.text('Back to Sign In')],
                  ),
                ]),
              ],
            ),
          ]),
        ]),
      ],
    );
  }
}
