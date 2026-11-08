import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/dashboard_kit.dart';
import '../../components/ui.dart';
import '../../data/auth_service.dart';
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
  late String _concept;
  late String _phone;
  late String _email;
  bool _saving = false;
  String? _savedMessage;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    // The identity comes from the backend-verified profile (GET /auth/me) —
    // never a hardcoded demo account. Missing values degrade to blanks.
    final profile = WebAuth.profile ?? <String, dynamic>{};
    _concept = (profile['full_name'] as String?) ?? '';
    _phone = (profile['phone_number'] as String?) ?? '';
    _email = (profile['email'] as String?) ?? '';
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _savedMessage = null;
      _errorMessage = null;
    });
    try {
      // PATCH /api/v1/users/me: the server persists the permitted fields and
      // echoes the updated profile back, so the confirmation below is backed
      // by the stored row — not local widget state.
      await WebAuth.request(
        '/api/v1/users/me',
        method: 'PATCH',
        body: {
          'full_name': _concept.trim(),
          'phone_number': _phone.trim(),
        },
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _savedMessage =
            'Profile saved. Your account name and contact number are stored.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorMessage =
            'Your profile could not be saved. Please check your connection '
            'and try again.';
      });
    }
  }

  void _discard() {
    setState(() {
      final profile = WebAuth.profile ?? <String, dynamic>{};
      _concept = (profile['full_name'] as String?) ?? '';
      _phone = (profile['phone_number'] as String?) ?? '';
      _savedMessage = null;
      _errorMessage = null;
    });
  }

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
                'value': _email,
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
              events: events<String>(onInput: (v) => setState(() => _concept = v)),
            ),
            span(classes: 'hint', [
              Component.text('Saved to your account as your display name.'),
            ]),
          ]),
          div(classes: 'field', [
            span(classes: 'field__label', [Component.text('Contact number')]),
            input(
              attributes: {
                'type': 'tel',
                'value': _phone,
                'placeholder': '+60 12 345 6789',
              },
              events: events<String>(onInput: (v) => setState(() => _phone = v)),
            ),
          ]),
          div(classes: 'actions-row', [
            ActionButton(
              _saving ? 'Saving…' : 'Save profile',
              onClick: _save,
            ),
            ActionButton(
              'Discard changes',
              variant: 'secondary',
              onClick: _discard,
            ),
          ]),
          if (_savedMessage != null)
            div(classes: 'notice notice-info', [
              Component.text(_savedMessage!),
            ]),
          if (_errorMessage != null)
            div(classes: 'notice notice-warn', [
              Component.text(_errorMessage!),
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
