import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../layouts/app_layout.dart';

/// Web owner profile: centred account card.
///
/// Ported from `owner_profile_web_page.dart` in the Flutter web tree. The
/// Flutter page is read-only demo chrome: static identity copy and two
/// uncontrolled `TextField`s whose Save button only shows a SnackBar. Here
/// the same copy and fields render as inputs, and Save flips an inline
/// success notice — no persistence in either tree.
///
/// The centred `maxWidth: 640` column becomes a `w-50` wrapper inside the
/// 1080px app content column.
class ProfilePage extends StatefulComponent {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  String _company = '';
  String _contact = '';

  /// Replaces the Flutter SnackBar('Profile updated.') with an inline note.
  bool _saved = false;

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.owner,
      currentRoute: '/owner/profile',
      title: 'Profile',
      subtitle: AppRole.owner.label,
      child: div(classes: 'w-50', [
        div(classes: 'card stack', [
          div(classes: 'avatar', [Component.text('D')]),
          h2(classes: 'title-lg', [Component.text('Daniel Wong')]),
          p(classes: 'small', [
            Component.text('daniel@wongproperties.my · Owner'),
          ]),
          _field(
            labelText: 'Company name',
            field: input(
              type: InputType.text,
              classes: 'input',
              value: _company,
              attributes: {'id': 'profile-company'},
              events: events<String>(onInput: (v) => _company = v),
            ),
          ),
          _field(
            labelText: 'Contact number',
            field: input(
              type: InputType.tel,
              classes: 'input',
              value: _contact,
              attributes: {'id': 'profile-contact'},
              events: events<String>(onInput: (v) => _contact = v),
            ),
          ),
          ActionButton(
            'Save changes',
            onClick: () => setState(() => _saved = true),
          ),
          if (_saved)
            p(classes: 'body text-success', [
              Component.text('Profile updated.'),
            ]),
        ]),
      ]),
    );
  }
}

Component _field({required String labelText, required Component field}) {
  return div(classes: 'stack', [
    span(classes: 'overline', [Component.text(labelText)]),
    field,
  ]);
}
