import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../layouts/app_layout.dart';

/// Web admin profile: centred account card.
///
/// Ported from `admin_profile_web_page.dart`. The Flutter page is static demo
/// data with a "Save changes" button that only shows a SnackBar; here the same
/// button sets a success flag and renders an inline success card instead
/// (guide pattern — no auto-navigation). The Flutter `TextField`s become
/// labelled `<input>`s.
@client
class ProfilePage extends StatefulComponent {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool _saved = false;

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
          span(classes: 'avatar', [Component.text('A')]),
          span(classes: 'title', [Component.text('Aina Razak')]),
          span(classes: 'body muted', [
            Component.text('aina@sitewise.my · Administrator'),
          ]),
          _field('display-name', 'Display name'),
          _field('contact-number', 'Contact number'),
          div(classes: 'row', [
            ActionButton('Save changes', onClick: () => _save()),
          ]),
          if (_saved)
            div(classes: 'card stack', [
              span(classes: 'small text-success', [
                Component.text('Profile updated.'),
              ]),
              const ActionLink(
                'Back to profile',
                href: '/admin/profile',
                variant: 'secondary',
              ),
            ]),
        ]),
      ]),
    );
  }

  void _save() {
    setState(() => _saved = true);
  }

  Component _field(String id, String labelText) {
    return label(
      [
        span(classes: 'small', [Component.text(labelText)]),
        input(
          type: InputType.text,
          id: id,
          name: id,
          classes: 'input',
          attributes: {'aria-label': labelText},
        ),
      ],
      htmlFor: id,
      classes: 'stack',
    );
  }
}
