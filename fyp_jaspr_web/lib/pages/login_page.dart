import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/auth_icons.dart';
import '../components/dom_helpers.dart';
import '../components/ui.dart';

/// Credential sign-in surface — Jaspr port of the updated sign-in design
/// (`sitewise_login.html`, top navbar removed per the design brief).
///
/// Layout: full-bleed photographic backdrop (`assets/login-bg.jpg`, extracted
/// from the reference's inline data URI) under a left-to-right dark scrim, the
/// value-proposition column on the left, and the white credential card on the
/// right. There is deliberately **no top navigation bar**; registration is
/// reached through the card's "Create one now" link.
///
/// The project deliberately has **no password backend**, so this is the
/// design's visual + client-side validation only: email-format / required
/// checks surface inline `lp-err` messages and a non-blocking `lp-alert`.
/// Submitting simply reports that sign-in is disabled (matches the prototype's
/// "no account is created or stored" posture). The social buttons are disabled
/// ("not configured"), exactly as in the source — no fake successful login.
///
/// The "Remember me" control is visual-only: no session persistence exists in
/// this deployment, so nothing is stored on any surface.
///
/// Deliberately *not* `@client`: `SitewiseApp` is the client entry point for
/// every route, and Jaspr asserts that no client anchor nests inside another
/// one (`component_anchors.dart`), which would break hydration of the page.
class LoginPage extends StatefulComponent {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginState();
}

class _LoginState extends State<LoginPage> {
  String _email = '';
  String _password = '';
  bool _show = false;
  bool _remember = true;
  final Map<String, String> _errors = {};
  String _alert = '';
  String _alertTone = 'info';

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  void _submit() {
    final e = <String, String>{};
    if (!_emailRe.hasMatch(_email)) e['email'] = 'Enter a valid email address.';
    if (_password.isEmpty) e['password'] = 'Password is required.';
    setState(() {
      _errors
        ..clear()
        ..addAll(e);
      if (e.isEmpty) {
        _alert =
            'Demo build — sign-in is disabled. No account is created or stored.';
        _alertTone = 'info';
      } else {
        _alert = 'Please fix the highlighted fields.';
        _alertTone = 'err';
      }
    });
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

  Component _social(Component icon, String provider) => button(
    classes: 'lp-social',
    attributes: {
      'type': 'button',
      'disabled': 'true',
      'aria-label': '$provider sign-in (not configured)',
      'title': 'Not configured in this deployment',
    },
    [icon, Component.text('Continue with $provider')],
  );

  @override
  Component build(BuildContext context) {
    return main_(
      classes: 'login-page',
      attributes: const {'aria-label': 'Sign in to SiteWise'},
      [
        // Full-bleed backdrop + scrim (decorative, hidden from a11y tree).
        div(classes: 'lp-bg', attributes: const {'aria-hidden': 'true'}, []),
        div(
          classes: 'lp-overlay',
          attributes: const {'aria-hidden': 'true'},
          [],
        ),

        div(classes: 'lp-content', [
          // ---------------------------------------------------------- hero
          div(classes: 'lp-left', [
            p(classes: 'lp-eyebrow', [
              Component.text('Commercial F&B Location Intelligence'),
            ]),
            h1(classes: 'lp-hero', [
              Component.text('Welcome back to'),
              br(),
              span(classes: 'lp-accent', [Component.text('SiteWise.')]),
            ]),
            p(classes: 'lp-desc', [
              Component.text(
                'Sign in to continue exploring commercial F&B properties, '
                'save your favourite listings and get personalised location '
                'recommendations.',
              ),
            ]),
            div(classes: 'lp-features', [
              _feature(
                const Icon('map', filled: false),
                'Find Better Locations',
                'Explore high-potential areas for your F&B business.',
              ),
              _feature(
                const Icon('bookmark', filled: false),
                'Manage Your Shortlists',
                'Keep track of saved commercial properties.',
              ),
              _feature(
                const Icon('monitoring', filled: false),
                'Data-Driven Decisions',
                'Use location insights to compare opportunities.',
              ),
            ]),
          ]),

          // ---------------------------------------------------------- card
          div(classes: 'lp-right', [
            section(classes: 'lp-card', [
              h2(classes: 'lp-card-title', [
                Component.text('Sign in to SiteWise'),
              ]),
              p(classes: 'lp-card-sub', [
                Component.text(
                  'Welcome back! Sign in to access your account and continue '
                  'your F&B property journey.',
                ),
              ]),

              div(
                classes:
                    'lp-alert $_alertTone${_alert.isEmpty ? ' is-hidden' : ''}',
                attributes: const {'role': 'alert'},
                [textNode(_alert)],
              ),

              // Social providers: not configured in this deployment, so the
              // buttons are disabled with an explicit explanation (no fake
              // successful sign-in).
              div(classes: 'lp-social-row', [
                _social(authSocialGoogle(), 'Google'),
                _social(authSocialApple(), 'Apple'),
              ]),
              p(classes: 'lp-social-note', [
                Component.text(
                  'Social sign-in is not configured in this deployment.',
                ),
              ]),

              div(classes: 'lp-divider', [
                span(
                  classes: 'lp-line',
                  attributes: {'aria-hidden': 'true'},
                  [],
                ),
                span(classes: 'lp-divider-text', [Component.text('or')]),
                span(
                  classes: 'lp-line',
                  attributes: {'aria-hidden': 'true'},
                  [],
                ),
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
                a(href: '/forgot', [Component.text('Forgot password?')]),
              ]),

              div(classes: 'lp-remember', [
                // Controlled via Jaspr's dedicated `checked` param: hydration
                // syncs input.checked against an attribute value of exactly
                // 'true', which this param emits (a raw `'checked'` attribute
                // would be read as false and silently unchecked).
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
                      Component.text(
                        'Keep me signed in for a faster experience.',
                      ),
                    ]),
                  ],
                ),
              ]),

              button(
                classes: 'lp-submit',
                attributes: const {'type': 'button'},
                events: events(onClick: _submit),
                [Component.text('Sign in'), Icon('arrow_forward', size: 'sm')],
              ),

              p(classes: 'lp-switch', [
                Component.text("Don't have an account? "),
                a(href: '/signup', [Component.text('Create one now')]),
              ]),
            ]),
          ]),
        ]),
      ],
    );
  }
}
