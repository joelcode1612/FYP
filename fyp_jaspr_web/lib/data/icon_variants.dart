/// Which Material Symbols variant each icon needs in order to match the
/// Flutter mobile tree.
///
/// Flutter's `Icons.*` is not one style — it is several families crossed with a
/// filled/unfilled flag, and the mobile tree uses three combinations:
///
/// | Flutter              | Material Symbols          |
/// |----------------------|---------------------------|
/// | `Icons.foo_outlined` | Outlined family, `FILL` 0 — the `.ms` default |
/// | `Icons.foo_rounded`  | Rounded family,  `FILL` 0 — needs `.ms--rounded` |
/// | `Icons.foo`          | Outlined family, `FILL` 1 — needs `.ms--fill` |
///
/// The mobile tree is the source of truth, so the exceptions are recorded here
/// in one table rather than each call site guessing. An icon absent from both
/// sets is the plain `_outlined` case and needs nothing.
///
/// Every entry cites the `Icons.*` name it mirrors so the mapping can be
/// re-checked against the mobile source. Before changing a variant, confirm the
/// actual name in `fyp_mobile_app` — `groups` was nearly listed as rounded
/// until the mobile landing content turned out to use `Icons.groups_outlined`.
library;

/// Icons the Flutter tree renders **filled** (`Icons.foo`, no `_outlined`).
const Set<String> kFilledIcons = {
  // fyp_mobile_app .../mobile_navigation.dart — Icons.threesixty
  'threesixty',

  // fyp_mobile_app .../mobile_navigation.dart — Icons.compare_arrows
  'compare_arrows',

  // Flutter's saved state is Icons.bookmark_rounded (filled); the unsaved state
  // is Icons.bookmark_border_rounded, which stays outlined + rounded.
  'bookmark',

  // Icons.place_outlined is the chip icon, but the map marker in the mobile
  // tree is Icons.location_pin (filled). Web `place` is only ever a pin.
  'place',

  // Icons.location_on — mobile topbar brand pin and featured banner.
  'location_on',

  // Icons.search — sitewise_search_bar.dart
  'search',

  // Icons.alt_route — landing_content.dart
  'alt_route',

  // Icons.add — owner_properties_mobile_page.dart
  'add',

  // Icons.send — owner_tours_mobile_page.dart, tour_preview_mobile_page.dart
  'send',

  // Icons.edit — owner_property_detail_mobile_page.dart
  'edit',

  // Icons.camera_alt — owner_tours_mobile_page.dart
  'camera_alt',
};

/// Icons the Flutter tree renders from the **Rounded** family
/// (`Icons.foo_rounded`).
const Set<String> kRoundedIcons = {
  // Icons.chevron_right_rounded — used throughout the mobile tree.
  'chevron_right',

  // Icons.close_rounded — compare / detail pages.
  'close',

  // Icons.check_rounded — recommendations page.
  'check',

  // Icons.list_rounded — explore map/list toggle.
  'list',

  // Icons.mail_outline_rounded — owner dashboard contact row.
  'mail_outline',

  // Icons.bookmark_border_rounded — the *unsaved* bookmark state. Paired with
  // `bookmark` above: together they reproduce Flutter's saved/unsaved pair.
  'bookmark_border',

  // Icons.notifications_none_rounded — topbar bell.
  'notifications',
};

/// True when [name] should render filled.
bool isFilledIcon(String name) => kFilledIcons.contains(name);

/// True when [name] should render from the Rounded family.
bool isRoundedIcon(String name) => kRoundedIcons.contains(name);
