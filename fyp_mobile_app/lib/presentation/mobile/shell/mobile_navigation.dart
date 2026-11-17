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
/// The two roles read the SAME workspace through differently-named slots: an
/// Owner's listing slot is "Properties" and its inbox slot is "Messages",
/// while an Agent's are "Listings" and "Enquiries" plus a real "Schedule"
/// page. The routes are the shared `/provider/listings` and
/// `/provider/enquiries` pages, so there is exactly one of each — never a
/// per-role duplicate screen.
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
    route: '/provider/enquiries',
    icon: Icons.chat_bubble_outline_rounded,
    label: 'Messages',
  ),
  MobileDestination(
    route: '/provider/profile',
    icon: Icons.person_outline_rounded,
    label: 'Profile',
  ),
];

/// Agent dock destinations. `Schedule` is a real dock page — it renders the
/// workspace's honest empty state, because SiteWise does not record viewings
/// or follow-up appointments yet (no schedule endpoint exists server-side).
///
/// This dock carries no Add slot, which does NOT mean an agent cannot create a
/// listing: the agent opens the owner's own `/provider/add-property` form from
/// the `Add Property` action on the shared listing screen. One form, two
/// entry points — never a second create screen per role.
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
    route: '/provider/enquiries',
    icon: Icons.mail_outline_rounded,
    label: 'Enquiries',
  ),
  MobileDestination(
    route: '/provider/schedule',
    icon: Icons.calendar_today_outlined,
    label: 'Schedule',
  ),
  MobileDestination(
    route: '/provider/profile',
    icon: Icons.person_outline_rounded,
    label: 'Profile',
  ),
];

/// The Provider dock for [role]: agents get the Schedule dock, owners keep the
/// centre Add action. Anything unexpected resolves to the owner dock, which
/// is the workspace's base configuration.
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
/// `ProviderTabHost` pushes the form as a drill-in over whichever tab was open,
/// so it needs to tell "hand me back to the listing screen" apart from a plain
/// cancel, which must leave the original tab selected.
const String addPropertyDoneResult = 'provider-listings';

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
