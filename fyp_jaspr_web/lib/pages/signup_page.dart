import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/auth_icons.dart';
import '../components/auth_navbar.dart';
import '../components/dom_helpers.dart';
import '../components/ui.dart';
import '../data/auth_service.dart';

/// Account-creation surface.
///
/// Shares the [LoginPage] shell (`lp-*`): the site [AuthNavbar] floated over a
/// full-bleed photographic backdrop under a left-to-right dark scrim, the
/// value-proposition column on the left and the white credential card on the
/// right. Only the backdrop differs: signup paints the KL street scene
/// (`assets/signup-city.jpg`) instead of `login-bg.jpg`, via
/// `.signup-page .lp-bg`.
///
/// The card itself is the shared `lp-*` shell; signup adds nothing beyond the
/// side-by-side password row (`su-pw-row`) and its hint.
///
/// Same no-backend posture as [LoginPage]: client-side validation only.
/// Required / email-format / password-length / mismatch checks surface inline
/// `lp-err` messages plus a non-blocking `lp-alert`, and a clean submit reports
/// that account creation is unavailable.
class SignupPage extends StatefulComponent {
  const SignupPage({super.key});

  @override
  State<SignupPage> createState() => _SignupState();
}

class _SignupState extends State<SignupPage> {
  String _name = '';
  String _email = '';
  String _password = '';
  String _confirm = '';
  bool _showPw = false;
  bool _showConfirm = false;
  final Map<String, String> _errors = {};
  String _alert = '';
  String _alertTone = 'info';
  bool _busy = false;

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  static const int _minPasswordLength = 8;

  /// Self-service signup creates an entrepreneur workspace only; property
  /// owners are onboarded through the admin side.
  static const String _signupRole = 'entrepreneur';

  Future<void> _submit() async {
    if (_busy) return;
    final e = <String, String>{};
    if (_name.trim().isEmpty) e['name'] = 'Enter your full name.';
    if (!_emailRe.hasMatch(_email)) e['email'] = 'Enter a valid email address.';
    if (_password.isEmpty) {
      e['password'] = 'Create a password.';
    } else if (_password.length < _minPasswordLength) {
      e['password'] = 'Use at least $_minPasswordLength characters.';
    }
    if (_confirm.isEmpty) {
      e['confirm'] = 'Confirm your password.';
    } else if (_confirm != _password) {
      e['confirm'] = 'Passwords do not match.';
    }

    setState(() {
      _errors
        ..clear()
        ..addAll(e);
      if (e.isEmpty) {
        _alert = 'Creating your account…';
        _alertTone = 'info';
      } else {
        _alert = 'Please fix the highlighted fields.';
        _alertTone = 'err';
      }
    });
    if (e.isNotEmpty) return;
    setState(() => _busy = true);
    try {
      final message = await WebAuth.signup(
        _email.trim(),
        _password,
        _name.trim(),
        _signupRole,
      );
      if (mounted) {
        setState(() {
          _alert = message;
          _alertTone = 'info';
        });
      }
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
      await WebAuth.google(_signupRole);
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

  // ------------------------------------------------------------------ hero

  Component _feature(Component icon, String title, String body) =>
      div(classes: 'lp-feature', [
        div(classes: 'lp-feat-icon', [icon]),
        div([
          h3([Component.text(title)]),
          p([Component.text(body)]),
        ]),
      ]);

  Component _hero() => div(classes: 'lp-left', [
    p(classes: 'lp-eyebrow', [
      Component.text('Commercial Property & Location Intelligence'),
    ]),
    h1(classes: 'lp-hero', [
      Component.text('Discover the right property.'),
      br(),
      span(classes: 'lp-accent', [
        Component.text('Assess its business potential.'),
      ]),
    ]),
    p(classes: 'lp-desc', [
      Component.text(
        'Find suitable commercial properties and evaluate locations through '
        'geospatial analysis, surrounding F&B demand, accessibility and '
        'AI-powered suitability insights.',
      ),
    ]),
    div(classes: 'lp-features', [
      _feature(
        const Icon('search', filled: false),
        'Discover commercial properties',
        'Search and filter properties based on location, property '
            'characteristics, rental details and business requirements.',
      ),
      _feature(
        const Icon('map', filled: false),
        'Evaluate location potential',
        'Analyse surrounding population, F&B competitors, accessibility, '
            'amenities and local market conditions.',
      ),
      _feature(
        const Icon('monitoring', filled: false),
        'Understand AI recommendations',
        'Compare property suitability scores, explore assessment results and '
        'understand the factors behind each recommendation.',
      ),
    ]),
  ]);

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

  // ------------------------------------------------------------------ panel

  Component _panel() => div(classes: 'lp-right', [
    section(classes: 'lp-card', [
      h2(classes: 'lp-card-title', [
        Component.text('Create your Sitewise account'),
      ]),
      p(classes: 'lp-card-sub', [
        Component.text(
          'Find and evaluate commercial F&B properties with greater '
          'confidence.',
        ),
      ]),

      div(
        classes: 'lp-alert $_alertTone${_alert.isEmpty ? ' is-hidden' : ''}',
        attributes: const {'role': 'alert'},
        [textNode(_alert)],
      ),

      div(classes: 'lp-social-row', [
        button(
          classes: 'lp-social',
          attributes: {
            'type': 'button',
            if (!WebAuth.configured || _busy) 'disabled': 'true',
            'aria-label': WebAuth.configured
                ? 'Continue with Google'
                : 'Google sign-up (not configured)',
          },
          events: events(onClick: _google),
          [authSocialGoogle(), Component.text('Continue with Google')],
        ),
      ]),
      p(classes: 'lp-social-note', [
        Component.text(
          WebAuth.configured
              ? 'Google sign-up is managed by Supabase.'
              : 'Social sign-up is not configured in this deployment.',
        ),
      ]),

      div(classes: 'lp-divider', [
        span(classes: 'lp-line', attributes: {'aria-hidden': 'true'}, []),
        span(classes: 'lp-divider-text', [Component.text('or')]),
        span(classes: 'lp-line', attributes: {'aria-hidden': 'true'}, []),
      ]),

      _field(
        forId: 'su-name',
        labelText: 'Full name',
        errKey: 'name',
        icon: authIconUser(),
        placeholder: 'Enter your full name',
        type: InputType.text,
        autocomplete: 'name',
        onInput: (v) => _name = v,
      ),

      _field(
        forId: 'su-email',
        labelText: 'Work or personal email',
        errKey: 'email',
        icon: authIconEmail(),
        placeholder: 'Enter your email address',
        type: InputType.email,
        autocomplete: 'email',
        onInput: (v) => _email = v,
      ),

      div(classes: 'su-pw-row', [
        _field(
          forId: 'su-password',
          labelText: 'Create password',
          errKey: 'password',
          icon: authIconLock(),
          placeholder: 'Create password',
          type: _showPw ? InputType.text : InputType.password,
          autocomplete: 'new-password',
          onInput: (v) => _password = v,
          trailing: _eye(
            show: _showPw,
            onToggle: () => setState(() => _showPw = !_showPw),
          ),
        ),
        _field(
          forId: 'su-confirm',
          labelText: 'Confirm password',
          errKey: 'confirm',
          icon: authIconLockCheck(),
          placeholder: 'Confirm',
          type: _showConfirm ? InputType.text : InputType.password,
          autocomplete: 'new-password',
          onInput: (v) => _confirm = v,
          trailing: _eye(
            show: _showConfirm,
            onToggle: () => setState(() => _showConfirm = !_showConfirm),
          ),
        ),
      ]),
      p(classes: 'su-hint', [
        Component.text(
          'At least $_minPasswordLength characters with a mix of letters, '
          'numbers and symbols.',
        ),
      ]),

      button(
        classes: 'lp-submit',
        attributes: {'type': 'button', if (_busy) 'disabled': 'true'},
        events: events(onClick: _submit),
        [
          Component.text(_busy ? 'Creating account…' : 'Create account'),
          Icon('arrow_forward', size: 'sm'),
        ],
      ),

      p(classes: 'lp-switch', [
        Component.text('Already have an account? '),
        AppLink(to: '/login', children: [Component.text('Sign in')]),
      ]),
    ]),
  ]);

  // ------------------------------------------------------------------ build

  @override
  Component build(BuildContext context) {
    return main_(
      classes: 'login-page signup-page',
      attributes: const {'aria-label': 'Create a SiteWise account'},
      [
        div(classes: 'lp-bg', attributes: const {'aria-hidden': 'true'}, []),
        div(
          classes: 'lp-overlay',
          attributes: const {'aria-hidden': 'true'},
          [],
        ),
        const AuthNavbar(),
        div(classes: 'lp-content', [_hero(), _panel()]),
      ],
    );
  }
}
