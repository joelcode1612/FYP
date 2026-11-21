import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'ui.dart';

/// Segmented control that switches between the public (entrepreneur) sign-in
/// and the restricted Agent & Admin staff sign-in.
///
/// Both options are plain [AppLink]s, so switching is a normal in-app
/// navigation — `jaspr_router` upgrades the anchor to client-side routing, so
/// the page does not fully reload — and the chosen portal is reflected in the
/// URL (`/login` vs `/login?portal=staff`). That keeps a single source of truth
/// for which portal is active and avoids a second, divergent sign-in page.
class AuthPortalSwitcher extends StatelessComponent {
  /// `'entrepreneur'` or `'staff'` — whichever is currently shown.
  final String current;

  const AuthPortalSwitcher({super.key, required this.current});

  @override
  Component build(BuildContext context) {
    final isStaff = current == 'staff';
    return div(
      classes: 'portal-switch',
      attributes: const {'role': 'tablist', 'aria-label': 'Choose sign-in portal'},
      [
        AppLink(
          to: '/login',
          classes: 'portal-switch__opt${isStaff ? '' : ' is-active'}',
          attributes: {
            'role': 'tab',
            'aria-selected': isStaff ? 'false' : 'true',
          },
          children: [
            Icon('storefront', size: 'sm'),
            Component.text('Entrepreneur Portal'),
          ],
        ),
        AppLink(
          to: '/login?portal=staff',
          classes: 'portal-switch__opt${isStaff ? ' is-active' : ''}',
          attributes: {
            'role': 'tab',
            'aria-selected': isStaff ? 'true' : 'false',
          },
          children: [
            Icon('shield', size: 'sm'),
            Component.text('Agent & Admin Portal'),
          ],
        ),
      ],
    );
  }
}
