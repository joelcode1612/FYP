import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/auth_service.dart';
import '../../layouts/app_layout.dart';

/// Web admin profile: centred account card.
///
/// Ported from `admin_profile_web_page.dart`, which was static demo data with a
/// "Save changes" button that only showed a SnackBar. The Jaspr port repeated
/// the fiction locally (`setState(() => _saved = true)`) and hardcoded an
/// identity — "Aina Razak" / `aina@sitewise.my` — that belonged to nobody.
///
/// This version reads the signed-in administrator from the backend-verified
/// profile, connects the inputs, and saves through
/// `PATCH /api/v1/users/me`. Success is shown only after the server has
/// answered, and the confirmation is backed by the row it echoes back.
///
/// Role and account status are displayed read-only. They are protected
/// server-side (`SELF_EDITABLE_PROFILE_FIELDS` is exactly `full_name`,
/// `phone_number` and `profile_picture_url`; anything else is a 403), so this
/// form offers no way to change them — an administrator's own role is managed
/// through the audited administrative endpoint, not an ordinary profile form.
@client
class ProfilePage extends StatefulComponent {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  /// The last server-confirmed values. Discard restores these, so after a
  /// successful save it returns to what is actually stored rather than to the
  /// values the page opened with.
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

  String get _email => (WebAuth.profile?['email'] as String?) ?? 'Not recorded';

  String get _role => (WebAuth.profile?['role'] as String?) ?? 'unknown';

  String get _initial {
    final trimmed = _savedName.trim();
    return trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();
  }

  /// Mirrors the real column limits rather than inventing rules: `full_name`
  /// is the account's display name and `phone_number` is
  /// `max_length=20` in `db/models/user.py`, which Postgres would otherwise
  /// reject as a 500.
  bool _validate() {
    final name = _name.trim();
    final phone = _phone.trim();
    setState(() {
      _nameError = name.isEmpty ? 'A display name is required.' : null;
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
      // Only the two self-editable fields are sent. Email, role and account
      // status are omitted deliberately: including them is a 403.
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
            'Profile saved. Your display name and contact number are stored '
            'on your account.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        // What was typed is kept, so a failed save costs no re-entry.
        _errorMessage =
            'Your profile could not be saved. Nothing was changed on the '
            'server — check your connection and try again.';
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

  bool get _dirty => _name != _savedName || _phone != _savedPhone;

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/profile',
      title: 'Profile',
      eyebrow: 'Account',
      subtitle: 'Your administrator account details and sign-in information.',
      child: div(classes: 'w-60', [
        div(classes: 'card stack', [
          span(classes: 'avatar', [Component.text(_initial)]),
          span(classes: 'title', [
            Component.text(
              _savedName.isEmpty ? 'Name not recorded' : _savedName,
            ),
          ]),
          span(classes: 'body muted', [
            Component.text('$_email · Administrator'),
          ]),

          _field(
            id: 'display-name',
            labelText: 'Display name',
            value: _name,
            error: _nameError,
            hint: 'Shown across the administrator console.',
            onInput: (v) => setState(() => _name = v),
          ),
          _field(
            id: 'contact-number',
            labelText: 'Contact number',
            value: _phone,
            error: _phoneError,
            hint: 'Optional. Up to 20 characters.',
            type: 'tel',
            onInput: (v) => setState(() => _phone = v),
          ),

          // Read-only, and labelled as such: the role is a protected attribute
          // this form has no business changing.
          _readonlyField(
            id: 'account-email',
            labelText: 'Email address',
            value: _email,
            hint: 'Email changes go through account recovery.',
          ),
          _readonlyField(
            id: 'account-role',
            labelText: 'Role',
            value: _role,
            hint:
                'Assigned by the platform. Role and account status cannot be '
                'changed from a profile form.',
          ),

          div(classes: 'row', [
            ActionButton(
              _saving ? 'Saving…' : 'Save changes',
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
    String type = 'text',
  }) {
    return div(classes: 'field', [
      span(classes: 'field__label', [Component.text(labelText)]),
      input(
        type: type == 'tel' ? InputType.tel : InputType.text,
        id: id,
        name: id,
        attributes: {
          'value': value,
          'aria-label': labelText,
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
