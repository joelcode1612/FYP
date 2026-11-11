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
/// The entrepreneur workspace follows the consolidated five-tab model:
/// **Home / Recommendations / Assess / Spaces / Profile**.
///
/// The second tab used to be "Listing" (the Explore browser). Discovery is now
/// one destination — Recommendations — because the recommendation search
/// carries browsing too: with no criteria it returns a plain catalogue browse,
/// so two tabs for one job only split the same data across two screens.
/// `/entrepreneur/explore` still resolves (see `app_routes.dart`) so old links
/// and the map deep link keep working.
///
/// Saved and Compare remain reachable from Profile, Home quick links and the
/// Spaces tab — they are not top-level destinations.
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
          route: '/entrepreneur/recommendations',
          icon: Icons.recommend_outlined,
          label: 'Recommendations',
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
