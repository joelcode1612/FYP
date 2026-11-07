import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'auth_icons.dart';
import 'auth_portal_switcher.dart';
import 'dom_helpers.dart';
import 'ui.dart';
import '../data/auth_service.dart';

/// Restricted staff sign-in card — the right-hand glass panel of the Agent &
/// Admin sign-in split, matching the design reference (city photograph behind,
/// translucent dark card, amber "Staff Access Only" callout, dark fields, MFA
/// notice footer).
///
/// `.stf-card--portal` carries the glass treatment; the plain `.stf-card` base
/// is shared with the staff MFA and password-reset pages and is left alone.
///
/// Uses the same Supabase identity service as the public portal (no second
/// credential database) and the same [WebAuth.password] bridge; the backend
/// resolves the real `agent` / `admin` role and [WebAuth] routes to the
/// matching workspace. There is no public self-registration and no role
/// selector — those are server-side decisions.
class StaffSignInForm extends StatefulComponent {
  const StaffSignInForm({super.key});

  @override
  State<StaffSignInForm> createState() => _StaffSignInState();
}

class _StaffSignInState extends State<StaffSignInForm> {
  String _email = '';
  String _password = '';
  bool _show = false;
  bool _remember = true;
  final Map<String, String> _errors = {};
  String _alert = '';
  String _alertTone = 'info';
  bool _busy = false;

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  Future<void> _submit() async {
    if (_busy) return;
    final e = <String, String>{};
    if (!_emailRe.hasMatch(_email)) e['email'] = 'Enter a valid email address.';
    if (_password.isEmpty) e['password'] = 'Password is required.';
    setState(() {
      _errors
        ..clear()
        ..addAll(e);
      if (e.isEmpty) {
        _alert = 'Signing in securely…';
        _alertTone = 'info';
      } else {
        _alert = 'Please fix the highlighted fields.';
        _alertTone = 'err';
      }
    });
    if (e.isNotEmpty) return;
    setState(() => _busy = true);
    try {
      // Password is the first factor. The staff portal context makes the JS
      // bridge reject non-staff accounts before any routing, and staff with
      // AAL1 sessions are routed to /staff/verify or first-time users to
      // /staff/mfa.
      await WebAuth.password(_email.trim(), _password, _remember, null, 'staff');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _alert = error.toString();
        _alertTone = 'err';
        _busy = false;
      });
    }
  }

  // ----------------------------------------------------------------- fields

  Component _field({
    required String forId,
    required String labelText,
    required String errKey,
    required Component icon,
    required String placeholder,
    required InputType type,
    required String autocomplete,
    required void Function(String) onInput,
    Component? trailing,
    String? inputMode,
  }) => div(classes: 'lp-group', [
    label(
      classes: 'lp-label',
      attributes: {'for': forId},
      [Component.text(labelText)],
    ),
    div(classes: 'lp-field${_errors[errKey] != null ? ' is-invalid' : ''}', [
      span(classes: 'lp-ico', attributes: {'aria-hidden': 'true'}, [icon]),
      input(
        type: type,
        id: forId,
        attributes: {
          'placeholder': placeholder,
          'autocomplete': autocomplete,
          'inputmode': ?inputMode,
        },
        events: events<String>(onInput: (v) => setState(() => onInput(v))),
      ),
      ?trailing,
    ]),
    span(
      classes: 'lp-err${_errors[errKey] == null ? ' is-hidden' : ''}',
      attributes: {'role': 'alert'},
      [textNode(_errors[errKey])],
    ),
  ]);

  Component _eye({required bool show, required void Function() onToggle}) =>
      button(
        classes: 'lp-eye',
        attributes: {
          'type': 'button',
          'aria-label': 'Toggle password visibility',
          'aria-pressed': show ? 'true' : 'false',
        },
        events: events(onClick: onToggle),
        [
          show
              ? Icon('visibility_off', size: 'sm')
              : Icon('visibility', size: 'sm'),
        ],
      );

  @override
  Component build(BuildContext context) {
    return section(classes: 'stf-card stf-card--portal', [
      const AuthPortalSwitcher(current: 'staff'),

      h2(classes: 'stf-card-title', [Component.text('Sign In')]),
      p(classes: 'stf-card-sub', [
        Component.text('Access for Agents and Administrators only.'),
      ]),

      // Amber "Staff Access Only" callout — accounts are provisioned by an
      // administrator; first-time users set a password from the invite email.
      div(classes: 'stf-callout', [
        Icon('shield', size: 'sm'),
        div(classes: 'stf-callout__body', [
          strong([Component.text('Staff Access Only:')]),
          Component.text(
            ' Accounts are created by a SiteWise Administrator. First-time '
            'users, please set your password via the email we sent.',
          ),
        ]),
      ]),

      div(
        classes: 'lp-alert $_alertTone${_alert.isEmpty ? ' is-hidden' : ''}',
        attributes: const {'role': 'alert'},
        [textNode(_alert)],
      ),

      _field(
        forId: 'stf-email',
        labelText: 'Email',
        errKey: 'email',
        icon: authIconEmail(),
        placeholder: 'Enter your email',
        type: InputType.email,
        autocomplete: 'email',
        onInput: (v) => _email = v,
      ),

      _field(
        forId: 'stf-password',
        labelText: 'Password',
        errKey: 'password',
        icon: authIconLock(),
        placeholder: 'Enter your password',
        type: _show ? InputType.text : InputType.password,
        autocomplete: 'current-password',
        onInput: (v) => _password = v,
        trailing: _eye(
          show: _show,
          onToggle: () => setState(() => _show = !_show),
        ),
      ),

      div(classes: 'stf-row', [
        div(classes: 'lp-remember', [
          input(
            type: InputType.checkbox,
            id: 'stf-remember',
            classes: 'lp-checkbox',
            checked: _remember,
            events: events(
              onClick: () => setState(() => _remember = !_remember),
            ),
          ),
          label(
            classes: 'lp-remember-text',
            attributes: const {'for': 'stf-remember'},
            [Component.text('Remember me')],
          ),
        ]),
        p(classes: 'stf-forgot', [
          AppLink(
            to: '/forgot',
            children: [Component.text('Forgot Password?')],
          ),
        ]),
      ]),

      button(
        classes: 'lp-submit stf-submit',
        attributes: {'type': 'button', if (_busy) 'disabled': 'true'},
        events: events(onClick: _submit),
        [
          _busy ? Component.text('Working…') : Component.text('Sign In'),
          if (!_busy) Icon('arrow_forward', size: 'sm'),
        ],
      ),

      // MFA notice footer — explains the enforced second factor.
      div(classes: 'stf-mfa-note', [
        Icon('lock', size: 'sm'),
        div(classes: 'stf-mfa-note__body', [
          strong([Component.text('Multi-Factor Authentication (MFA)')]),
          Component.text(
            ' is required for all staff accounts. Use an authenticator app '
            'such as Google Authenticator to verify your sign in.',
          ),
        ]),
      ]),
    ]);
  }
}


