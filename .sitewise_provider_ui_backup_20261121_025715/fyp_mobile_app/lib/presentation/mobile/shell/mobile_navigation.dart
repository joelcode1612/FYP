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

/// Owner (Provider) dock destinations.
///
/// The Provider dock uses the SAME [MobileBottomNav] `m3: true` rendering as
/// the entrepreneur workspace, so height, inset, sliding indicator, motion,
/// selected states, safe-area and touch targets are identical by construction.
///
/// **Add** is the centre destination and is an ACTION, not a page in the
/// persistent stack: `ProviderTabHost` pushes `/provider/add-property` when it
/// is chosen and leaves the current tab selected behind the form.
///
/// **Performance** is deliberately not a tab for either role. It stays a
/// registered route (`/provider/performance`) inside the workspace stack and
/// is reached from the Dashboard's quick actions, so a provider never loses it.
///
/// The Enquiries/Messages and Schedule destinations were removed with those
/// features. The routes are the shared `/provider/listings` and
/// `/provider/add-property` surfaces, so there is exactly one of each — never
/// a per-role duplicate screen. An agent's dock swaps Add for Tasks (see
/// [providerAgentDestinations]); this owner dock is unchanged.
const List<MobileDestination> providerOwnerDestinations = [
  MobileDestination(
    route: '/provider',
    icon: Icons.home_outlined,
    label: 'Home',
  ),
  MobileDestination(
    route: '/provider/listings',
    icon: Icons.storefront_outlined,
    label: 'Properties',
  ),
  MobileDestination(
    route: '/provider/add-property',
    icon: Icons.add_circle_outline,
    label: 'Add',
  ),
  MobileDestination(
    route: '/provider/profile',
    icon: Icons.person_outline_rounded,
    label: 'Profile',
  ),
];

/// Agent dock destinations: **Home | Listings | Tasks | Profile**.
///
/// The agent's third slot is Tasks, not Add: an agent does not create the
/// listings they work on, an administrator assigns them, so a create-form tab
/// would be an action this role cannot perform. Tasks is the destination that
/// points at the work the assignment actually generates
/// (`/provider/tasks`).
///
/// `/provider/add-property` remains a registered route — drafts a listing
/// screen or the Tasks card resumes are still pushed as drill-ins, and the
/// owner dock keeps Add as its centre destination. Enquiries and Schedule are
/// NOT destinations here and are not resurrected as placeholders: the screens
/// were removed with those features.
const List<MobileDestination> providerAgentDestinations = [
  MobileDestination(
    route: '/provider',
    icon: Icons.home_outlined,
    label: 'Home',
  ),
  MobileDestination(
    route: '/provider/listings',
    icon: Icons.layers_outlined,
    label: 'Listings',
  ),
  MobileDestination(
    route: '/provider/tasks',
    icon: Icons.assignment_outlined,
    label: 'Tasks',
  ),
  MobileDestination(
    route: '/provider/profile',
    icon: Icons.person_outline_rounded,
    label: 'Profile',
  ),
];

/// The Provider dock for [role]: the owner keeps
/// Home | Properties | Add | Profile, while an agent gets
/// Home | Listings | Tasks | Profile. Anything unexpected resolves to the
/// owner dock, which is the workspace's base configuration.
List<MobileDestination> providerDestinationsFor(AppRole role) => switch (role) {
  AppRole.agent => providerAgentDestinations,
  _ => providerOwnerDestinations,
};

/// The pop result the Add Property form returns when the provider explicitly
/// finished and asked for their listings.
///
/// Both roles are returned to their own property listing, which is the SAME
/// shared page (`/provider/listings`) under different dock labels —
/// "Properties" for an owner, "Listings" for an agent.
///
/// The blank Add Property form is now a persistent stack page, but a draft
/// resumed from Home/Listings is still pushed as a drill-in. That drill-in
/// hands back [addPropertyDoneResult] when the provider explicitly finished;
/// a plain cancel returns to the tab that was open before.
const String addPropertyDoneResult = 'provider-listings';

/// Result used when the Add Property form's dock sends the user back to an
/// existing provider tab. It is a command to the shell, not a screen result:
/// popping with this value avoids pushing a second copy of the workspace.
const String providerTabResultPrefix = 'provider-tab:';

String providerTabResult(String route) => '$providerTabResultPrefix$route';

String? providerTabFromResult(Object? result) =>
    result is String && result.startsWith(providerTabResultPrefix)
    ? result.substring(providerTabResultPrefix.length)
    : null;

/// Bottom-navigation destinations per role.
///
/// The entrepreneur workspace follows the consolidated five-tab model:
/// **Home / Recommendations / Assess / Favourites / Profile**.
///
/// The second tab used to be "Listing" (the Explore browser). Discovery is now
/// one destination — Recommendations — because the recommendation search
/// carries browsing too: with no criteria it returns a plain catalogue browse,
/// so two tabs for one job only split the same data across two screens.
/// `/entrepreneur/explore` still resolves (see `app_routes.dart`) so old links
/// and the map deep link keep working.
///
/// The fourth tab used to be "Spaces" (shortlist plus comparison counters). It
/// is **Favourites** now: one destination for the properties saved from
/// Recommendations. Compare remains reachable from Profile and Home quick links;
/// `/entrepreneur/spaces` still resolves to this tab.
///
/// Owner and Agent now have a real MOBILE workspace (the shared Provider
/// workspace), so they get a role-scoped Provider dock via
/// [providerDestinationsFor]. Admin has no mobile workspace at all and
/// therefore gets no bar.
List<MobileDestination> mobileDestinationsFor(AppRole role) {
  switch (role) {
    case AppRole.admin:
      return const [];
    case AppRole.owner:
    case AppRole.agent:
      return providerDestinationsFor(role);
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
          route: '/entrepreneur/favourites',
          icon: Icons.bookmark_border_rounded,
          label: 'Favourites',
        ),
        MobileDestination(
          route: '/entrepreneur/profile',
          icon: Icons.person_outline_rounded,
          label: 'Profile',
        ),
      ];
  }
}
