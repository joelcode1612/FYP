/// Which Material Symbols variant each icon needs in order to match the
/// Flutter mobile tree.
///
/// Flutter's `Icons.*` is not a single style — it is several families crossed
/// with a filled/unfilled flag, and the mobile tree uses three combinations:
///
/// | Flutter            | Material Symbols          |
/// |--------------------|---------------------------|
/// | `Icons.foo_outlined` | Outlined family, `FILL` 0 — the `.ms` default |
/// | `Icons.foo_rounded`  | Rounded family,  `FILL` 0 — needs `.ms--rounded` |
/// | `Icons.foo`          | Outlined family, `FILL` 1 — needs `.ms--fill` |
///
/// The mobile tree is the source of truth, so the exceptions are recorded here
/// in one table rather than each call site guessing. An icon absent from both
/// sets is the plain `_outlined` case and needs nothing.
///
/// Only add an entry after checking the actual `Icons.*` name in
/// `fyp_mobile_app`. `groups` was nearly listed as rounded until the mobile
/// landing content turned out to use `Icons.groups_outlined`.
library;

/// Icons the Flutter tree renders **filled** (`Icons.foo`, no `_outlined`).
const Set<String> kFilledIcons = {
  // fyp_mobile_app .../mobile_navigation.dart — Icons.threesixty
  'threesixty',

  // fyp_mobile_app .../mobile_navigation.dart — Icons.compare_arrows
  'compare_arrows',

  // Flutter's saved state is Icons.bookmark_rounded (filled); the unsaved state
  // is Icons.bookmark_border_rounded, which stays outlined.
  'bookmark',
};

/// Icons the Flutter tree renders from the **Rounded** family
/// (`Icons.foo_rounded`).
const Set<String> kRoundedIcons = {
  // Flutter uses Icons.chevron_right_rounded throughout the mobile tree.
  'chevron_right',

  // Topbar bell: the mobile tree uses Icons.notifications_none_rounded.
  // Material Symbols' `notifications` at FILL 0 is the outlined bell, so the
  // name is already right — only the family needed correcting.
  'notifications',
};

/// True when [name] should render filled.
bool isFilledIcon(String name) => kFilledIcons.contains(name);

/// True when [name] should render from the Rounded family.
bool isRoundedIcon(String name) => kRoundedIcons.contains(name);
