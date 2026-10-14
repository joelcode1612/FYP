import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../layouts/app_layout.dart';

/// Web entrepreneur profile: centred account card.
///
/// Ported from `entrepreneur_profile_web_page.dart` in the Flutter web tree.
/// The Flutter version shows a SnackBar on save; here the confirmation is an
/// inline success line under the button (works without JavaScript). The card
/// is capped at 640px like the Flutter `WebContentColumn(maxWidth: 640)`.
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
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/profile',
      title: 'Profile',
      subtitle: AppRole.entrepreneur.label,
      child: div(
        attributes: const {'style': 'max-width:640px'},
        classes: 'stack',
        [
          div(classes: 'card stack', [
            div(
              attributes: const {
                'style': 'width:60px;height:60px;font-size:24px',
              },
              classes: 'avatar',
              [Component.text('S')],
            ),
            span(classes: 'title', [Component.text('Sarah Lim')]),
            p(classes: 'body', [
              Component.text('sarah@nasihouse.my · F&B Entrepreneur'),
            ]),
            div(classes: 'stack', [
              span(classes: 'small', [Component.text('Concept name')]),
              input(
                classes: 'input',
                attributes: {'type': 'text', 'aria-label': 'Concept name'},
              ),
            ]),
            div(classes: 'stack', [
              span(classes: 'small', [Component.text('Contact number')]),
              input(
                classes: 'input',
                attributes: {'type': 'text', 'aria-label': 'Contact number'},
              ),
            ]),
            div(classes: 'btn-row', [
              ActionButton(
                'Save changes',
                onClick: () => setState(() => _saved = true),
              ),
              if (_saved)
                span(classes: 'small text-success', [
                  Component.text('Profile updated.'),
                ]),
            ]),
          ]),
        ],
      ),
    );
  }
}
