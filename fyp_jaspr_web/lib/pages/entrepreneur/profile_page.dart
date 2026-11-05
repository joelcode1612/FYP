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

  /// The access-request dialog. Only the owner workspace can be requested from
  /// here: an entrepreneur asking for the administrator console is a privilege
  /// escalation, and no demo should pretend otherwise.
  bool _requestOpen = false;
  bool _granted = false;

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
        if (_requestOpen) _requestDialog(),
      ]),
    );
  }

  /// Which workspaces this account can open, and the only request it can make.
  ///
  /// The previous version linked straight to `/owner` and `/admin`. The route
  /// guard sends either back to the signed-in role's home — `/api/me` returns
  /// one role per account and `profiles.role` has a CHECK constraint — so those
  /// two buttons could never work. They are replaced by the request flow, which
  /// is honest about what it does and does not do.
  Component _workspacePanel() {
    final openable = Workspaces.openable;
    return section(classes: 'panel', [
      h2([Component.text('Workspaces')]),
      p(classes: 'body', [
        Component.text(
          'One account holds one server-assigned role. The switcher in the '
          'avatar menu lists every workspace this session may open — today that '
          'is exactly one, because the backend cannot yet record a second.',
        ),
      ]),
      div(classes: 'aside-list', [
        for (final role in openable)
          AsideRow(
            badge: role.label.substring(0, 1),
            tone: Workspaces.isDemoGrant(role) ? 'amber' : 'teal',
            title: role.label,
            caption: Workspaces.isDemoGrant(role)
                ? '${role.portal} · demo grant, cleared on reload'
                : '${role.portal} · assigned by the backend',
            end: AppLink(
              to: role.homeRoute,
              classes: 'text-action',
              children: [Component.text('Open')],
            ),
          ),
      ]),
      if (!Workspaces.canOpen(AppRole.owner)) ...[
        div(classes: 'actions-row', [
          ActionButton(
            'Request owner workspace',
            variant: 'secondary',
            onClick: () => setState(() {
              _requestOpen = true;
              _granted = false;
            }),
          ),
        ]),
      ] else if (Workspaces.isDemoGrant(AppRole.owner))
        div(classes: 'actions-row', [
          ActionButton(
            'Give up demo access',
            variant: 'secondary',
            onClick: () => setState(() {
              Workspaces.revoke(AppRole.owner);
              _granted = false;
            }),
          ),
        ]),
      div(classes: 'notice notice-info', [
        Component.text(
          'An administrator role is not offered here. Escalating your own '
          'account is exactly what the verification queue exists to prevent, '
          'so it is not a thing a screen like this can grant.',
        ),
      ]),
    ]);
  }

  Component _requestDialog() {
    return SitewiseDialog(
      title: 'Request the owner workspace',
      ariaLabel: 'Request the owner workspace',
      wide: true,
      onClose: () => setState(() => _requestOpen = false),
      body: div(classes: 'stack', [
        p(classes: 'body', [
          Component.text(
            _granted
                ? 'Granted for this browser session. The avatar menu now lists '
                      'the owner workspace; reloading the page revokes it.'
                : 'A real request needs an approval workflow that does not '
                      'exist yet: no access_requests table, no administrator '
                      'queue for it, and a role CHECK that rejects anything '
                      'besides entrepreneur, owner and admin. Confirming below '
                      'opens the workspace as a demonstration only.',
          ),
        ]),
        DataTable(
          columns: const [DataColumn('Step'), DataColumn('Status')],
          rows: [
            [
              Component.text('Record the request'),
              Component.text('No table stores it'),
            ],
            [
              Component.text('Administrator decides'),
              Component.text('No queue renders pending requests'),
            ],
            [
              Component.text('Backend honours two roles'),
              Component.text(
                'profiles.role accepts one value, and /api/me returns it',
              ),
            ],
            [
              Component.text('Frontend switches'),
              Component.text('Ready — the switcher and guard already work'),
            ],
          ],
        ),
      ]),
      actions: [
        ActionButton(
          'Cancel',
          variant: 'secondary',
          onClick: () => setState(() => _requestOpen = false),
        ),
        if (_granted)
          ActionLink('Open owner workspace', href: '/owner', variant: 'primary')
        else
          ActionButton(
            'Grant demo access',
            onClick: () => setState(() {
              Workspaces.grant(AppRole.owner);
              _granted = true;
            }),
          ),
      ],
    );
  }
}
