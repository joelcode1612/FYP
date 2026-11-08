import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/dashboard_kit.dart';
import '../../components/ui.dart';
import '../../data/workspaces.dart';
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
@client
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
          _workspacePanel(),
        ]),
      ]),
    );
  }

  /// Workspaces are based on backend-assigned roles, not demo role cookies.
  /// Property management stays under the Entrepreneur role and is authorized
  /// per property by FastAPI rather than by a separate owner role.
  Component _workspacePanel() {
    return section(classes: 'panel', [
      h2([Component.text('Workspaces')]),
      p(classes: 'body', [
        Component.text(
          'Workspaces follow your verified account role. Property management '
          'is available through My Properties when your ownership is verified.',
        ),
      ]),
      div(classes: 'aside-list', [
        for (final role in Workspaces.openable)
          AsideRow(
            badge: role.label.substring(0, 1),
            tone: 'teal',
            title: role.label,
            caption: '${role.portal} · verified account role',
            end: AppLink(
              to: role.homeRoute,
              classes: 'text-action',
              children: [Component.text('Open')],
            ),
          ),
      ]),
      div(classes: 'actions-row', [
        const ActionLink(
          'My Properties',
          href: '/entrepreneur/my-properties',
          variant: 'secondary',
        ),
      ]),
    ]);
  }
}
