import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/auth_icons.dart';
import '../components/dom_helpers.dart';
import '../components/letter_reveal.dart';
import '../components/ui.dart';

/// Password-reset request surface — the Jaspr port of
/// `sitewise-entrepreneur/forgot-password.html`.
///
/// No email backend exists, so "Continue" only runs client-side email-format
/// validation and reports that reset is disabled (no reset email is sent).
///
/// Deliberately *not* `@client`: `SitewiseApp` is the client entry point for
/// every route, and Jaspr asserts that no client anchor nests inside another
/// one (`component_anchors.dart`), which would break hydration of the page.
class ForgotPasswordPage extends StatefulComponent {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotState();
}

class _ForgotState extends State<ForgotPasswordPage> {
  String _email = '';
  final Map<String, String> _errors = {};
  String _alert = '';
  String _alertTone = 'info';

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  void _submit() {
    final e = <String, String>{};
    if (!_emailRe.hasMatch(_email)) e['email'] = 'Enter a valid email address.';
    setState(() {
      _errors
        ..clear()
        ..addAll(e);
      if (e.isEmpty) {
        _alert =
            'Demo build — password reset is disabled. No reset email is sent.';
        _alertTone = 'info';
      } else {
        _alert = 'Please fix the highlighted field.';
        _alertTone = 'err';
      }
    });
  }

  Component _field({
    required String errKey,
    required Component icon,
    required String placeholder,
    required InputType type,
    required String autocomplete,
    required void Function(String) onInput,
  }) => div(
    classes: 'auth-field${_errors[errKey] != null ? ' is-invalid' : ''}',
    [
      span(classes: 'ico', [icon]),
      label(classes: 'auth-sr', [Component.text(placeholder)]),
      input(
        type: type,
        attributes: {'placeholder': placeholder, 'autocomplete': autocomplete},
        events: events<String>(onInput: (v) => setState(() => onInput(v))),
      ),
    ],
  );

  @override
  Component build(BuildContext context) {
    return main_(classes: 'auth-page', [
      section(classes: 'auth-card', [
        div(classes: 'auth-topbar', [
          AppLink(
            to: '/login',
            classes: 'auth-back',
            attributes: const {'aria-label': 'Back to log in'},
            children: [Icon('chevron_left', size: 'sm')],
          ),
          span(classes: 'auth-brand', [
            span(classes: 'mark', [authBrandMark()]),
            Component.text('SITEWISE'),
          ]),
        ]),
        LetterRevealHeading.text(
          'Forgot Password',
          level: 1,
          classes: 'auth-title',
        ),
        p(classes: 'auth-sub', [
          Component.text(
            'Enter your email address to receive a reset link and regain '
            'access to your account.',
          ),
        ]),
        div(
          classes:
              'auth-alert $_alertTone${_alert.isEmpty ? ' is-hidden' : ''}',
          attributes: const {'role': 'alert'},
          [textNode(_alert)],
        ),
        _field(
          errKey: 'email',
          icon: authIconEmail(),
          placeholder: 'Email address',
          type: InputType.email,
          autocomplete: 'email',
          onInput: (v) => _email = v,
        ),
        span(
          classes: 'auth-err${_errors['email'] == null ? ' is-hidden' : ''}',
          [textNode(_errors['email'])],
        ),
        button(
          classes: 'auth-submit',
          attributes: const {'type': 'button'},
          events: events(onClick: _submit),
          [Component.text('Continue')],
        ),
        p(classes: 'auth-switch', [
          Component.text('Remembered it? '),
          AppLink(to: '/login', children: [Component.text('Back to log in')]),
        ]),
      ]),
    ]);
  }
}
