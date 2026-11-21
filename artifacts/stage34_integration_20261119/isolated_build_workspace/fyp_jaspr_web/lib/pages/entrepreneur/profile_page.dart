import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/auth_service.dart';
import '../../layouts/app_layout.dart';

/// Entrepreneur account profile: contact details and recommendation settings.
/// The Workspaces card is intentionally omitted from this role-specific page.
@client
class ProfilePage extends StatefulComponent {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  /// The last server-confirmed values. `WebAuth.profile` is not refreshed by a
  /// PATCH, so Discard uses the last successfully saved baseline.
  late String _savedConcept;
  late String _savedPhone;

  late String _concept;
  late String _phone;
  late String _email;
  bool _saving = false;
  String? _savedMessage;
  String? _errorMessage;
  String? _conceptError;
  String? _phoneError;

  @override
  void initState() {
    super.initState();
    // Identity comes from the backend-verified account profile.
    final profile = WebAuth.profile ?? <String, dynamic>{};
    _savedConcept = (profile['full_name'] as String?) ?? '';
    _savedPhone = (profile['phone_number'] as String?) ?? '';
    _concept = _savedConcept;
    _phone = _savedPhone;
    _email = (profile['email'] as String?) ?? '';
  }

  bool get _dirty => _concept != _savedConcept || _phone != _savedPhone;

  /// `phone_number` has max_length=20 in the backend user model.
  bool _validate() {
    final name = _concept.trim();
    final phone = _phone.trim();
    setState(() {
      _conceptError = name.isEmpty ? 'A concept name is required.' : null;
      _phoneError = phone.length > 20
          ? 'A contact number must be 20 characters or fewer.'
          : null;
    });
    return _conceptError == null && _phoneError == null;
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_validate()) return;
    setState(() {
      _saving = true;
      _savedMessage = null;
      _errorMessage = null;
    });
    try {
      // PATCH /api/v1/users/me persists the verified profile fields.
      final response = await WebAuth.request(
        '/api/v1/users/me',
        method: 'PATCH',
        body: {'full_name': _concept.trim(), 'phone_number': _phone.trim()},
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _savedConcept = (response['full_name'] as String?) ?? _concept.trim();
        _savedPhone = (response['phone_number'] as String?) ?? _phone.trim();
        _concept = _savedConcept;
        _phone = _savedPhone;
        _savedMessage =
            'Profile saved. Your account name and contact number are stored.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorMessage =
            'Your profile could not be saved. Nothing was changed on the '
            'server — check your connection and try again.';
      });
    }
  }

  void _discard() {
    setState(() {
      _concept = _savedConcept;
      _phone = _savedPhone;
      _savedMessage = null;
      _errorMessage = null;
      _conceptError = null;
      _phoneError = null;
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
              attributes: {'type': 'email', 'value': _email, 'readonly': ''},
            ),
            span(classes: 'hint', [
              Component.text('Email changes go through account recovery.'),
            ]),
          ]),
          div(classes: 'field', [
            span(classes: 'field__label', [Component.text('Concept name')]),
            input(
              attributes: {
                'type': 'text',
                'value': _concept,
                if (_conceptError != null) 'aria-invalid': 'true',
                if (_conceptError != null)
                  'aria-describedby': 'concept-name-error',
              },
              events: events<String>(
                onInput: (v) => setState(() => _concept = v),
              ),
            ),
            if (_conceptError != null)
              span(
                classes: 'field__error',
                attributes: const {'id': 'concept-name-error'},
                [Component.text(_conceptError!)],
              )
            else
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
                if (_phoneError != null) 'aria-invalid': 'true',
                if (_phoneError != null) 'aria-describedby': 'contact-error',
              },
              events: events<String>(
                onInput: (v) => setState(() => _phone = v),
              ),
            ),
            if (_phoneError != null)
              span(
                classes: 'field__error',
                attributes: const {'id': 'contact-error'},
                [Component.text(_phoneError!)],
              )
            else
              span(classes: 'hint', [
                Component.text('Optional. Up to 20 characters.'),
              ]),
          ]),
          div(classes: 'actions-row', [
            ActionButton(
              _saving ? 'Saving…' : 'Save profile',
              onClick: _saving ? null : _save,
            ),
            ActionButton(
              'Discard changes',
              variant: 'secondary',
              onClick: (_saving || !_dirty) ? null : _discard,
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

        // --- Recommendation settings -----------------------------------------
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
        ]),
      ]),
    );
  }
}
