import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/auth_navbar.dart';
import '../components/entrepreneur_hero.dart';
import '../components/entrepreneur_signin_form.dart';
import '../components/staff_auth_page.dart';

/// Sign-in surface for both portals.
///
/// The page is a thin container: it renders the shared [AuthNavbar], the shared
/// photographic band, and picks the credential card from the [portal] argument.
/// Both portals reuse the same [EntrepreneurHero] value-proposition column, so
/// the Agent & Admin portal is a two-column split with the restricted
/// [StaffSignInForm] on glass instead of a centered card. Every staff-only
/// difference lives behind `.login-page.is-staff` in `styles.css`, which is why
/// the entrepreneur markup below is unchanged.
///
/// [portal] is driven by the `?portal=staff` query parameter (see `app.dart`),
/// which `jaspr_router` navigates to client-side — so switching portals
/// re-renders this container without a full page reload, and the active portal
/// is reflected in the URL. This enhances the existing sign-in page rather than
/// duplicating it.
@client
class LoginPage extends StatelessComponent {
  /// `'entrepreneur'` (default) or `'staff'`. Sourced from the route's query
  /// string; `null` is treated as the entrepreneur portal.
  final String? portal;

  const LoginPage({super.key, this.portal});

  @override
  Component build(BuildContext context) {
    final isStaff = portal == 'staff';
    return main_(
      classes: 'login-page${isStaff ? ' is-staff' : ''}',
      attributes: {
        'aria-label': isStaff
            ? 'Staff sign in to SiteWise'
            : 'Sign in to SiteWise',
      },
      [
        // Full-bleed backdrop + scrim. Both portals share the photographic
        // band; only the scrim gradient and the right-hand card differ, and
        // those differences are scoped under `.is-staff` in styles.css.
        div(classes: 'lp-bg', attributes: const {'aria-hidden': 'true'}, []),
        div(classes: 'lp-overlay', attributes: const {'aria-hidden': 'true'}, []),
        const AuthNavbar(),
        div(
          classes: 'lp-content',
          [
            const EntrepreneurHero(),
            if (isStaff)
              div(classes: 'stf-shell', [const StaffSignInForm()])
            else
              const EntrepreneurSignInForm(),
          ],
        ),
      ],
    );
  }
}
