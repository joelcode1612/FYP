import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'auth_icons.dart';
import 'auth_portal_switcher.dart';
import 'dom_helpers.dart';
import 'ui.dart';
import '../data/auth_service.dart';

/// Entrepreneur credential sign-in — the public white card on the right.
///
/// Behaviour is unchanged from the previous [LoginPage]: client-side email /
/// password validation with inline `lp-err` messages and a non-blocking
/// `lp-alert`, disabled-until-configured social buttons (no fake successful
/// login), remember-me (visual only) and a submit that calls the real
/// [WebAuth] bridge. The only addition is the [AuthPortalSwitcher] at the top
/// of the card so the user can reach the staff portal.
class EntrepreneurSignInForm extends StatefulComponent {
  const EntrepreneurSignInForm({super.key});

  @override
  State<EntrepreneurSignInForm> createState() => _EntrepreneurSignInState();
}

class _EntrepreneurSignInState extends State<EntrepreneurSignInForm> {
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
        _alert = 'Signing in…';
        _alertTone = 'info';
      } else {
        _alert = 'Please fix the highlighted fields.';
        _alertTone = 'err';
      }
    });
    if (e.isNotEmpty) return;
    setState(() => _busy = true);
    try {
      // Entrepreneur portal context: the JS bridge rejects staff (agent/admin)
      // accounts here and directs them to the Agent & Admin portal, where the
      // mandatory TOTP MFA gate is enforced. No staff MFA is imposed on
      // entrepreneurs.
      await WebAuth.password(_email.trim(), _password, _remember, null, 'entrepreneur');
    } catch (error) {
      if (mounted) {
        setState(() {
          _alert = error.toString();
          _alertTone = 'err';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _google() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await WebAuth.google(_remember);
    } catch (error) {
      if (mounted) {
        setState(() {
          _alert = error.toString();
          _alertTone = 'err';
          _busy = false;
        });
      }
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
        attributes: {'placeholder': placeholder, 'autocomplete': autocomplete},
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

  // Social providers. Each control carries a `data-provider` attribute so the
  // `auth_bundle.js` bridge can target Google alone when it re-enables social
  // sign-in after the Supabase config loads — it must NOT touch Apple, which is
  // permanently disabled in this deployment. Google is interactive only when
  // Supabase Google sign-in is configured; Apple is always presented disabled
  // with an honest "(not configured)" label — no fake successful login.
  Component _socialGoogle() {
    final bool enabled = WebAuth.configured && !_busy;
    final Map<String, String> attrs = {
      'type': 'button',
      'data-provider': 'google',
      'aria-label': 'Continue with Google',
    };
    if (!enabled) attrs['disabled'] = 'true';
    return button(
      key: const Key('social-google'),
      classes: 'lp-social lp-social--google',
      attributes: attrs,
      [authSocialGoogle(), Component.text('Continue with Google')],
      events: enabled ? events(onClick: _google) : null,
    );
  }

  // Apple is always disabled in this deployment. Rendered as a presentational
  // control with an explicit `aria-disabled="true"` + `.is-disabled` styling and
  // an honest "(not configured)" label so assistive tech announces the real
  // state. Because it has no `data-provider="google"`, the auth bridge never
  // re-enables it.
  Component _socialApple() {
    final Map<String, String> attrs = {
      'role': 'button',
      'data-provider': 'apple',
      'aria-label': 'Continue with Apple (not configured)',
      'aria-disabled': 'true',
      'tabindex': '-1',
    };
    return div(
      key: const Key('social-apple'),
      classes: 'lp-social lp-social--apple is-disabled',
      attributes: attrs,
      [authSocialApple(), Component.text('Continue with Apple')],
    );
  }

  @override
  Component build(BuildContext context) {
    return section(classes: 'lp-card', [
      const AuthPortalSwitcher(current: 'entrepreneur'),

      h2(classes: 'lp-card-title', [Component.text('Sign in to SiteWise')]),
      p(classes: 'lp-card-sub', [
        Component.text(
          'Welcome back! Sign in to access your account and continue '
          'your F&B property journey.',
        ),
      ]),

      div(
        classes: 'lp-alert $_alertTone${_alert.isEmpty ? ' is-hidden' : ''}',
        attributes: const {'role': 'alert'},
        [textNode(_alert)],
      ),

      // Social providers: not configured in this deployment, so the buttons
      // are disabled with an explicit explanation (no fake successful login).
      div(classes: 'lp-social-row', [
        _socialGoogle(),
        _socialApple(),
      ]),
      p(classes: 'lp-social-note', [
        Component.text(
          WebAuth.configured
              ? 'Google sign-in is managed by Supabase. Apple sign-in is not configured.'
              : 'Social sign-in is not configured in this deployment.',
        ),
      ]),

      div(classes: 'lp-divider', [
        span(classes: 'lp-line', attributes: {'aria-hidden': 'true'}, []),
        span(classes: 'lp-divider-text', [Component.text('or')]),
        span(classes: 'lp-line', attributes: {'aria-hidden': 'true'}, []),
      ]),

      _field(
        forId: 'lp-email',
        labelText: 'Email address',
        errKey: 'email',
        icon: authIconEmail(),
        placeholder: 'Enter your email address',
        type: InputType.email,
        autocomplete: 'email',
        onInput: (v) => _email = v,
      ),

      _field(
        forId: 'lp-password',
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

      p(classes: 'lp-forgot', [
        AppLink(
          to: '/forgot',
          children: [Component.text('Forgot password?')],
        ),
      ]),

      div(classes: 'lp-remember', [
        input(
          type: InputType.checkbox,
          id: 'lp-remember',
          classes: 'lp-checkbox',
          checked: _remember,
          events: events(
            onClick: () => setState(() => _remember = !_remember),
          ),
        ),
        label(
          classes: 'lp-remember-text',
          attributes: const {'for': 'lp-remember'},
          [
            strong([Component.text('Remember me on this device')]),
            small([
              Component.text('Keep me signed in for a faster experience.'),
            ]),
          ],
        ),
      ]),

      button(
        classes: 'lp-submit',
        attributes: {'type': 'button', if (_busy) 'disabled': 'true'},
        events: events(onClick: _submit),
        [Component.text('Sign in'), Icon('arrow_forward', size: 'sm')],
      ),

      p(classes: 'lp-switch', [
        Component.text("Don't have an account? "),
        AppLink(
          to: '/signup',
          children: [Component.text('Create one now')],
        ),
      ]),
    ]);
  }
}
