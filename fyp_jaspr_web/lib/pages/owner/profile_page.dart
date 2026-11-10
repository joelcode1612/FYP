import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/auth_service.dart';
import '../../layouts/app_layout.dart';

/// Owner account, laid out as the source's `sitewise-owner/profile.html`.
///
/// ```text
/// .detail-grid
///   .panel   Contact details — labelled .field rows + .actions-row
///   .analysis .panel Workspace · .panel Notifications
/// ```
///
/// The previous version hardcoded an identity ("Daniel Wong" /
/// `daniel@wongproperties.my`), assigned its fields in `onInput` without
/// `setState`, and confirmed a save by flipping a local boolean — so it
/// reported success without ever contacting the server.
///
/// This version reads the signed-in owner from the backend-verified profile and
/// saves through `PATCH /api/v1/users/me`. Success is shown only after the
/// server answers; a failure keeps what was typed and states that nothing was
/// stored. Email and role stay read-only, matching the server's
/// `SELF_EDITABLE_PROFILE_FIELDS` allow-list (`full_name`, `phone_number`,
/// `profile_picture_url`).
@client
class ProfilePage extends StatefulComponent {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  /// The last server-confirmed values, so Discard returns to what is actually
  /// stored rather than to whatever the page happened to open with.
  late String _savedName;
  late String _savedPhone;

  late String _name;
  late String _phone;

  bool _saving = false;
  String? _savedMessage;
  String? _errorMessage;
  String? _nameError;
  String? _phoneError;

  @override
  void initState() {
    super.initState();
    final profile = WebAuth.profile ?? const <String, dynamic>{};
    _savedName = (profile['full_name'] as String?) ?? '';
    _savedPhone = (profile['phone_number'] as String?) ?? '';
    _name = _savedName;
    _phone = _savedPhone;
  }

  String get _email => (WebAuth.profile?['email'] as String?) ?? '';

  String get _role => (WebAuth.profile?['role'] as String?) ?? 'unknown';

  bool get _dirty => _name != _savedName || _phone != _savedPhone;

  /// `phone_number` is `max_length=20` in `db/models/user.py`; checking it here
  /// turns a database rejection into a readable field error.
  bool _validate() {
    final name = _name.trim();
    final phone = _phone.trim();
    setState(() {
      _nameError = name.isEmpty ? 'A full name is required.' : null;
      _phoneError = phone.length > 20
          ? 'A contact number must be 20 characters or fewer.'
          : null;
    });
    return _nameError == null && _phoneError == null;
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
      // Only the self-editable fields are sent; email and role are omitted
      // deliberately, because including them is a 403.
      final response = await WebAuth.request(
        '/api/v1/users/me',
        method: 'PATCH',
        body: {'full_name': _name.trim(), 'phone_number': _phone.trim()},
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        // Re-baseline from what the server stored, not from what was typed.
        _savedName = (response['full_name'] as String?) ?? _name.trim();
        _savedPhone = (response['phone_number'] as String?) ?? _phone.trim();
        _name = _savedName;
        _phone = _savedPhone;
        _savedMessage =
            'Profile saved. Your name and contact number are stored.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorMessage =
            'Your profile could not be saved. Nothing was changed on the '
            'server — your entries are kept below.';
      });
    }
  }

  void _discard() {
    setState(() {
      _name = _savedName;
      _phone = _savedPhone;
      _savedMessage = null;
      _errorMessage = null;
      _nameError = null;
      _phoneError = null;
    });
  }

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
          _readonlyField(
            id: 'owner-email',
            labelText: 'Email address',
            value: _email.isEmpty ? 'Not recorded' : _email,
            hint: 'Email changes go through account recovery.',
          ),
          _field(
            id: 'owner-name',
            labelText: 'Full name',
            value: _name,
            error: _nameError,
            onInput: (v) => setState(() => _name = v),
          ),
          _field(
            id: 'owner-phone',
            labelText: 'Phone',
            value: _phone,
            error: _phoneError,
            hint: 'Optional. Up to 20 characters.',
            type: InputType.tel,
            placeholder: '+60 12 345 6789',
            onInput: (v) => setState(() => _phone = v),
          ),
          _readonlyField(
            id: 'owner-role',
            labelText: 'Role',
            value: _role,
            hint:
                'Assigned by the platform. Role and account status cannot be '
                'changed from a profile form.',
          ),
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

  Component _field({
    required String id,
    required String labelText,
    required String value,
    required void Function(String) onInput,
    String? error,
    String? hint,
    InputType type = InputType.text,
    String? placeholder,
  }) {
    return div(classes: 'field', [
      span(classes: 'field__label', [Component.text(labelText)]),
      input(
        type: type,
        id: id,
        name: id,
        attributes: {
          'value': value,
          'placeholder': ?placeholder,
          if (error != null) 'aria-invalid': 'true',
          if (error != null) 'aria-describedby': '$id-error',
        },
        events: events<String>(onInput: onInput),
      ),
      if (error != null)
        span(
          classes: 'field__error',
          attributes: {'id': '$id-error'},
          [Component.text(error)],
        )
      else if (hint != null)
        span(classes: 'hint', [Component.text(hint)]),
    ]);
  }

  Component _readonlyField({
    required String id,
    required String labelText,
    required String value,
    String? hint,
  }) {
    return div(classes: 'field', [
      span(classes: 'field__label', [Component.text(labelText)]),
      input(
        type: InputType.text,
        id: id,
        name: id,
        attributes: {'value': value, 'readonly': '', 'aria-label': labelText},
      ),
      if (hint != null) span(classes: 'hint', [Component.text(hint)]),
    ]);
  }
}
