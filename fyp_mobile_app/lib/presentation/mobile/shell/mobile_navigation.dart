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
/// Admin / owner keep their own destination sets; only the entrepreneur
/// post-sign-in experience opts into the Material 3 reference.
List<MobileDestination> mobileDestinationsFor(AppRole role) {
  switch (role) {
    case AppRole.admin:
      return const [
        MobileDestination(
          route: '/admin',
          icon: Icons.dashboard_outlined,
          label: 'Dashboard',
        ),
        MobileDestination(
          route: '/admin/users',
          icon: Icons.people_outline,
          label: 'Users',
        ),
        MobileDestination(
          route: '/admin/verification',
          icon: Icons.verified_outlined,
          label: 'Verify',
        ),
        MobileDestination(
          route: '/admin/listings',
          icon: Icons.business_outlined,
          label: 'Listings',
        ),
        MobileDestination(
          route: '/admin/profile',
          icon: Icons.person_outline,
          label: 'Profile',
        ),
      ];
    case AppRole.owner:
      return const [
        MobileDestination(
          route: '/owner',
          icon: Icons.home_outlined,
          label: 'Home',
        ),
        MobileDestination(
          route: '/owner/properties',
          icon: Icons.store_outlined,
          label: 'Properties',
        ),
        MobileDestination(
          route: '/owner/add-property',
          icon: Icons.add_business_outlined,
          label: 'Add',
        ),
        MobileDestination(
          route: '/owner/tours',
          icon: Icons.threesixty,
          label: 'Tours',
        ),
        MobileDestination(
          route: '/owner/profile',
          icon: Icons.person_outline,
          label: 'Profile',
        ),
      ];
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
    case AppRole.agent:
      // No mobile agent screens exist, and an agent cannot sign in yet (the
      // profiles table rejects the role). The workspace is web-only, so the
      // bottom bar stays empty rather than pointing at routes that 404.
      return const [];
  }
}
