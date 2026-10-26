import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/auth_icons.dart';
import '../components/dom_helpers.dart';
import '../components/letter_reveal.dart';
import '../components/ui.dart';

/// Account-creation surface — split marketing layout.
///
/// Left: a city-scene panel with the value proposition and three benefit rows.
/// Right: the form card (name, email, password, confirm, account type, planned
/// concept, terms).
///
/// Same no-backend posture as [LoginPage]: client-side validation only, and a
/// submit reports that account creation is disabled. The scene behind the
/// headline is an inline SVG rather than a photograph, so the page ships with
/// no image payload and no external requests.
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
  String _accountType = 'entrepreneur';
  String _concept = '';
  bool _agreed = false;
  final Map<String, String> _errors = {};
  String _alert = '';
  String _alertTone = 'info';

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  static const List<String> _concepts = [
    'Specialty Café',
    'Quick-Service Restaurant',
    'Cloud Kitchen',
    'Casual Dining',
    'Bakery & Patisserie',
  ];

  void _submit() {
    final e = <String, String>{};
    if (_name.trim().isEmpty) e['name'] = 'Enter your full name.';
    if (!_emailRe.hasMatch(_email)) e['email'] = 'Enter a valid email address.';
    if (_password.isEmpty) {
      e['password'] = 'Create a password.';
    } else if (_password.length < 6) {
      e['password'] = 'Use at least 6 characters.';
    }
    if (_confirm.isEmpty) {
      e['confirm'] = 'Confirm your password.';
    } else if (_confirm != _password) {
      e['confirm'] = 'Passwords do not match.';
    }
    if (!_agreed) e['terms'] = 'Please accept the Terms of Service.';

    setState(() {
      _errors
        ..clear()
        ..addAll(e);
      if (e.isEmpty) {
        _alert =
            'Demo build — account creation is disabled. No account is created '
            'or stored.';
        _alertTone = 'info';
      } else {
        _alert = 'Please fix the highlighted fields.';
        _alertTone = 'err';
      }
    });
  }

  // ------------------------------------------------------------------ brand

  Component _brandMark() => Component.element(
    tag: 'img',
    classes: 'su-brand__mark-img',
    attributes: {
      'src': 'assets/sitewise-mark-64.png',
      'alt': 'Sitewise',
      'width': '30',
      'height': '30',
      'aria-hidden': 'true',
    },
    children: [],
  );

  // ------------------------------------------------------------------ scene

  /// The hero backdrop is the user-supplied city photograph (the same scene
  /// used across the marketing site), cleaned of composited copy and cropped
  /// to the panel. It fills `.su-hero__art` (absolute, object-fit: cover) and
  /// sits behind the white legibility scrim (`.su-hero::after`).
  Component _heroArt() => Component.element(
    tag: 'img',
    classes: 'su-hero__art',
    attributes: {
      'src': 'assets/signup-city.jpg',
      'alt': '',
      'aria-hidden': 'true',
      'fetchpriority': 'high',
    },
    children: [],
  );

  // ------------------------------------------------------------------ hero

  Component _benefit(String icon, String title, String body) =>
      div(classes: 'su-benefit', [
        span(classes: 'su-benefit__icon', [Icon(icon)]),
        div([
          h3([Component.text(title)]),
          p([Component.text(body)]),
        ]),
      ]);

  Component _hero() => aside(
    classes: 'su-hero',
    attributes: const {'aria-label': 'Why Sitewise'},
    [
      _heroArt(),
      div(classes: 'su-hero__inner', [
        span(classes: 'su-eyebrow', [
          Component.text('COMMERCIAL F&B LOCATION INTELLIGENCE'),
        ]),
        h1(classes: 'su-hero__title', [
          Component.text('Find the right '),
          span(classes: 'su-accent', [Component.text('space')]),
          Component.text(' for your '),
          span(classes: 'su-accent', [Component.text('business.')]),
        ]),
        p(classes: 'su-hero__lead', [
          Component.text(
            'Compare commercial properties through location context, '
            'surrounding demand and explainable suitability insights.',
          ),
        ]),
        div(classes: 'su-benefits', [
          _benefit(
            'search',
            'Explore with context',
            'Search and filter commercial properties based on location, '
                'surrounding amenities and F&B demand.',
          ),
          _benefit(
            'map',
            'Compare locations',
            'Review access, nearby F&B competition and area indicators in one '
                'place.',
          ),
          _benefit(
            'monitoring',
            'Understand recommendations',
            'See the factors behind property suitability with explainable AI '
                'insights.',
          ),
        ]),
      ]),
    ],
  );

  // --------------------------------------------------------------- controls

  Component _eye({required bool show, required void Function() onToggle}) =>
      button(
        classes: 'su-eye',
        attributes: const {
          'type': 'button',
          'aria-label': 'Toggle password visibility',
        },
        events: events(onClick: onToggle),
        [
          show
              ? Icon('visibility_off', size: 'sm')
              : Icon('visibility', size: 'sm'),
        ],
      );

  Component _fieldBlock({
    required String labelText,
    required String errKey,
    required String placeholder,
    required InputType type,
    required String autocomplete,
    required void Function(String) onInput,
    Component? leading,
    Component? trailing,
    String? hint,
    bool optional = false,
  }) {
    final err = _errors[errKey];
    return div(classes: 'su-field', [
      label(classes: 'su-field__label', [
        span(classes: 'su-label', [
          Component.text(labelText),
          if (optional)
            span(classes: 'su-optional', [Component.text(' (optional)')]),
        ]),
        div(classes: 'su-control${err != null ? ' is-invalid' : ''}', [
          if (leading != null) span(classes: 'su-control__icon', [leading]),
          input(
            type: type,
            attributes: {
              'placeholder': placeholder,
              'autocomplete': autocomplete,
              'aria-label': labelText,
            },
            events: events<String>(onInput: (v) => setState(() => onInput(v))),
          ),
          ?trailing,
        ]),
      ]),
      if (hint != null) p(classes: 'su-hint', [Component.text(hint)]),
      span(classes: 'su-err${err == null ? ' is-hidden' : ''}', [
        textNode(err),
      ]),
    ]);
  }

  Component _typeCard(String id, String icon, String title, String desc) {
    final selected = _accountType == id;
    return button(
      classes: 'su-type${selected ? ' is-selected' : ''}',
      attributes: {
        'type': 'button',
        'role': 'radio',
        'aria-checked': selected ? 'true' : 'false',
      },
      events: events(onClick: () => setState(() => _accountType = id)),
      [
        span(classes: 'su-type__icon', [Icon(icon)]),
        span(classes: 'su-type__body', [
          span(classes: 'su-type__title', [Component.text(title)]),
          span(classes: 'su-type__desc', [Component.text(desc)]),
        ]),
        span(classes: 'su-radio', []),
      ],
    );
  }

  // ------------------------------------------------------------------ panel

  Component _panel() => main_(classes: 'su-panel', [
    div(classes: 'su-card', [
      LetterRevealHeading.text(
        'Create your Sitewise account',
        level: 2,
        classes: 'su-title',
      ),
      p(classes: 'su-sub', [
        Component.text(
          'Find and evaluate commercial F&B properties with greater confidence.',
        ),
      ]),
      div(
        classes: 'su-alert $_alertTone${_alert.isEmpty ? ' is-hidden' : ''}',
        attributes: const {'role': 'alert'},
        [textNode(_alert)],
      ),
      _fieldBlock(
        labelText: 'Full name',
        errKey: 'name',
        placeholder: 'Enter your full name',
        type: InputType.text,
        autocomplete: 'name',
        onInput: (v) => _name = v,
        leading: authIconUser(),
      ),
      _fieldBlock(
        labelText: 'Work or personal email',
        errKey: 'email',
        placeholder: 'Enter your email address',
        type: InputType.email,
        autocomplete: 'email',
        onInput: (v) => _email = v,
        leading: authIconEmail(),
      ),
      _fieldBlock(
        labelText: 'Create password',
        errKey: 'password',
        placeholder: 'Create a password',
        type: _showPw ? InputType.text : InputType.password,
        autocomplete: 'new-password',
        onInput: (v) => _password = v,
        leading: authIconLock(),
        trailing: _eye(
          show: _showPw,
          onToggle: () => setState(() => _showPw = !_showPw),
        ),
        hint:
            'At least 6 characters with a mix of letters, numbers and symbols.',
      ),
      _fieldBlock(
        labelText: 'Confirm password',
        errKey: 'confirm',
        placeholder: 'Confirm your password',
        type: _showConfirm ? InputType.text : InputType.password,
        autocomplete: 'new-password',
        onInput: (v) => _confirm = v,
        leading: authIconLockCheck(),
        trailing: _eye(
          show: _showConfirm,
          onToggle: () => setState(() => _showConfirm = !_showConfirm),
        ),
      ),
      div(classes: 'su-field', [
        span(classes: 'su-label', [Component.text('Account type')]),
        div(
          classes: 'su-types',
          attributes: const {
            'role': 'radiogroup',
            'aria-label': 'Account type',
          },
          [
            _typeCard(
              'entrepreneur',
              'storefront',
              'F&B Entrepreneur',
              'Explore locations, compare properties and get AI-assisted '
                  'suitability recommendations.',
            ),
            _typeCard(
              'owner',
              'domain',
              'Commercial Property Owner',
              'Manage commercial listings and submit 360° property tours for '
                  'review.',
            ),
          ],
        ),
      ]),
      div(classes: 'su-field', [
        label(classes: 'su-field__label', [
          span(classes: 'su-label', [
            Component.text('Planned F&B concept'),
            span(classes: 'su-optional', [Component.text(' (optional)')]),
          ]),
          div(classes: 'su-control su-control--select', [
            span(classes: 'su-control__icon', [Icon('restaurant')]),
            select(
              [
                option(
                  [Component.text('Select your F&B concept')],
                  value: '',
                  selected: _concept.isEmpty,
                ),
                for (final c in _concepts)
                  option(
                    [Component.text(c)],
                    value: c,
                    selected: _concept == c,
                  ),
              ],
              classes: 'su-select',
              attributes: const {'aria-label': 'Planned F&B concept'},
              onChange: (vals) =>
                  setState(() => _concept = vals.isEmpty ? '' : vals.first),
            ),
            span(classes: 'su-control__chevron', [Icon('expand_more')]),
          ]),
        ]),
        p(classes: 'su-hint', [
          Component.text('You can update this later in your profile.'),
        ]),
      ]),
      div(classes: 'su-terms', [
        input<bool>(
          type: InputType.checkbox,
          id: 'su-terms',
          checked: _agreed,
          attributes: const {
            'aria-label': 'I agree to the Terms of Service and Privacy Policy',
          },
          onChange: (v) => setState(() => _agreed = v),
        ),
        p([
          Component.text('I agree to the '),
          a(href: '#', [Component.text('Terms of Service')]),
          Component.text(' and '),
          a(href: '#', [Component.text('Privacy Policy')]),
          Component.text('.'),
        ]),
      ]),
      span(classes: 'su-err${_errors['terms'] == null ? ' is-hidden' : ''}', [
        textNode(_errors['terms']),
      ]),
      button(
        classes: 'su-submit',
        attributes: const {'type': 'button'},
        events: events(onClick: _submit),
        [Component.text('Create account'), Icon('arrow_forward', size: 'sm')],
      ),
      div(classes: 'su-note', [
        span(classes: 'su-note__icon', [Icon('verified_user', size: 'sm')]),
        p([
          Component.text(
            'Your details are used to set up your SiteWise account. You can '
            'complete or update your profile details later.',
          ),
        ]),
      ]),
    ]),
  ]);

  // ------------------------------------------------------------------ build

  @override
  Component build(BuildContext context) {
    return div(classes: 'signup-page', [
      header(classes: 'su-topbar', [
        div(classes: 'su-topbar__inner', [
          a(href: '/', classes: 'su-brand', [
            span(classes: 'su-brand__mark', [_brandMark()]),
            span(classes: 'su-brand__name', [Component.text('SiteWise')]),
          ]),
          div(classes: 'su-topbar__actions', [
            span(classes: 'su-topbar__hint', [
              Component.text('Already have an account?'),
            ]),
            a(href: '/login', classes: 'su-signin', [
              Component.text('Sign in'),
            ]),
          ]),
        ]),
      ]),
      div(classes: 'su-body', [_hero(), _panel()]),
    ]);
  }
}
