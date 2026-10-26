import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../layouts/app_layout.dart';

/// Entrepreneur account, laid out as the source's
/// `sitewise-entrepreneur/profile.html`.
///
/// ```text
/// .detail-grid
///   .panel    Contact details — labelled .field rows + .actions-row
///   .analysis .panel Recommendation settings · .panel Workspace
/// ```
///
/// The previous version was one centred card with two unlabelled inputs and no
/// link to the preferences that actually drive ranking, so the account page gave
/// the user no route to the settings it referred to.
class ProfilePage extends StatefulComponent {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  String _concept = 'Nasi House';
  String _phone = '';
  bool _saved = false;

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/profile',
      title: 'Profile & preferences',
      eyebrow: 'Account',
      subtitle:
          'Your account details and the preferences feeding your '
          'recommendations.',
      child: div(classes: 'detail-grid', [
        // --- Contact details -------------------------------------------------
        section(classes: 'panel', [
          h2([Component.text('Contact details')]),
          div(classes: 'field', [
            span(classes: 'field__label', [Component.text('Email address')]),
            input(
              attributes: {
                'type': 'email',
                'value': 'sarah@nasihouse.my',
                'readonly': '',
              },
            ),
            span(classes: 'hint', [
              Component.text('Email changes go through account recovery.'),
            ]),
          ]),
          div(classes: 'field', [
            span(classes: 'field__label', [Component.text('Concept name')]),
            input(
              attributes: {'type': 'text', 'value': _concept},
              events: events<String>(onInput: (v) => _concept = v),
            ),
          ]),
          div(classes: 'field', [
            span(classes: 'field__label', [Component.text('Contact number')]),
            input(
              attributes: {
                'type': 'tel',
                'value': _phone,
                'placeholder': '+60 12 345 6789',
              },
              events: events<String>(onInput: (v) => _phone = v),
            ),
          ]),
          div(classes: 'actions-row', [
            ActionButton(
              'Save profile',
              onClick: () => setState(() => _saved = true),
            ),
            ActionButton(
              'Discard changes',
              variant: 'secondary',
              onClick: () => setState(() {
                _concept = 'Nasi House';
                _phone = '';
                _saved = false;
              }),
            ),
          ]),
          if (_saved)
            div(classes: 'notice notice-info', [
              Component.text('Profile updated.'),
            ]),
        ]),

        // --- Recommendation settings + workspace ------------------------------
        div(classes: 'analysis', [
          section(classes: 'panel', [
            h2([Component.text('Recommendation settings')]),
            p(classes: 'body', [
              Component.text(
                'Your budget, floor area and property type determine which '
                'listings are eligible before any location scoring happens.',
              ),
            ]),
            div(classes: 'actions-row', [
              const ActionLink(
                'Edit preferences',
                href: '/entrepreneur/preferences',
                variant: 'primary',
              ),
              const ActionLink(
                'See shortlist',
                href: '/entrepreneur/recommendations',
                variant: 'secondary',
              ),
            ]),
          ]),
          section(classes: 'panel', [
            h2([Component.text('Workspace')]),
            p(classes: 'body', [
              Component.text(
                'You are signed in as an F&B entrepreneur. Switch to the '
                'property owner view to manage listings, or to the '
                'administrator console to review submissions.',
              ),
            ]),
            div(classes: 'actions-row', [
              const ActionLink(
                'Property owner view',
                href: '/owner',
                variant: 'secondary',
              ),
              const ActionLink(
                'Administrator console',
                href: '/admin',
                variant: 'secondary',
              ),
            ]),
          ]),
        ]),
      ]),
    );
  }
}
