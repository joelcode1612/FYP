import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

/// One mobile navigation destination (bottom-navigation entry).
class MobileDestination {
  final String route;
  final IconData icon;
  final String label;

  const MobileDestination({
    required this.route,
    required this.icon,
    required this.label,
  });
}

/// Bottom-navigation destinations per role.
///
/// The entrepreneur workspace follows the consolidated five-tab model from
/// `Sitewise_Mobile_Material3_Mock_Data.html`:
/// **Home / Listing / Assess / Spaces / Profile**. The previous
/// Home / Explore / Saved / Compare / Profile bar folded discovery into one
/// tab and had no home for assessments or property records. Saved and Compare
/// remain reachable from Profile and Home quick links — they are no longer
/// top-level destinations.
///
/// Admin, Property Owner and Agent get no destinations: those workspaces
/// belong to `fyp_jaspr_web`. An empty bar beats one whose routes do not
/// exist. Only the entrepreneur post-sign-in experience is a mobile shell.
List<MobileDestination> mobileDestinationsFor(AppRole role) {
  switch (role) {
    case AppRole.admin:
    case AppRole.owner:
    case AppRole.agent:
      return const [];
    case AppRole.entrepreneur:
      return const [
        MobileDestination(
          route: '/entrepreneur',
          icon: Icons.home_outlined,
          label: 'Home',
        ),
        MobileDestination(
          route: '/entrepreneur/explore',
          icon: Icons.search_rounded,
          label: 'Listing',
        ),
        MobileDestination(
          route: '/entrepreneur/assess',
          icon: Icons.assignment_outlined,
          label: 'Assess',
        ),
        MobileDestination(
          route: '/entrepreneur/spaces',
          icon: Icons.storefront_outlined,
          label: 'Spaces',
        ),
        MobileDestination(
          route: '/entrepreneur/profile',
          icon: Icons.person_outline_rounded,
          label: 'Profile',
        ),
      ];
  }
}
