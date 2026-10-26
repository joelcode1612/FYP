import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../layouts/app_layout.dart';

/// Owner account, laid out as the source's `sitewise-owner/profile.html`.
///
/// ```text
/// .detail-grid
///   .panel   Contact details — labelled .field rows + .actions-row
///   .analysis .panel Workspace · .panel Notifications
/// ```
///
/// The previous version was a single centred card with two unlabelled
/// `overline` captions and no right-hand column, so the "switch to the
/// entrepreneur view" and notification-policy notes the source carries were
/// missing entirely.
class ProfilePage extends StatefulComponent {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  String _name = 'Daniel Wong';
  String _phone = '';
  bool _saved = false;

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.owner,
      currentRoute: '/owner/profile',
      title: 'Profile & settings',
      eyebrow: 'Account',
      subtitle: 'Your owner account details and contact information.',
      child: div(classes: 'detail-grid', [
        // --- Contact details ------------------------------------------------
        section(classes: 'panel', [
          h2([Component.text('Contact details')]),
          div(classes: 'field', [
            span(classes: 'field__label', [Component.text('Email address')]),
            input(
              attributes: {
                'type': 'email',
                'value': 'daniel@wongproperties.my',
                'readonly': '',
              },
            ),
            span(classes: 'hint', [
              Component.text('Email changes go through account recovery.'),
            ]),
          ]),
          div(classes: 'field', [
            span(classes: 'field__label', [Component.text('Full name')]),
            input(
              attributes: {'type': 'text', 'value': _name},
              events: events<String>(onInput: (v) => _name = v),
            ),
          ]),
          div(classes: 'field', [
            span(classes: 'field__label', [Component.text('Phone')]),
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
                _name = 'Daniel Wong';
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

        // --- Workspace + notifications ---------------------------------------
        div(classes: 'analysis', [
          section(classes: 'panel', [
            h2([Component.text('Workspace')]),
            p(classes: 'body', [
              Component.text(
                'You are signed in as a property owner. Switch to the '
                'entrepreneur view to browse listings, or to the administrator '
                'console to review submissions.',
              ),
            ]),
            div(classes: 'actions-row', [
              const ActionLink(
                'Entrepreneur view',
                href: '/entrepreneur',
                variant: 'secondary',
              ),
              const ActionLink(
                'Administrator console',
                href: '/admin',
                variant: 'secondary',
              ),
            ]),
          ]),
          section(classes: 'panel', [
            h2([Component.text('Notifications')]),
            p(classes: 'body', [
              Component.text(
                'This prototype has no email or push service. Verification '
                'status changes appear on your listings and tours pages as soon '
                'as an administrator records a decision.',
              ),
            ]),
          ]),
        ]),
      ]),
    );
  }
}
