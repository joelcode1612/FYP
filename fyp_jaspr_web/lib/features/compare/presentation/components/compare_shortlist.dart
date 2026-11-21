import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';

/// Route the comparison workspace is mounted on.
const String compareRoute = '/entrepreneur/compare';

/// The comparison status line a property list shows above its results.
///
/// Recommendations already tells the entrepreneur how full the shortlist is
/// before a fourth tap would be refused; Explore and Saved said nothing at all,
/// so a tap on a capped shortlist looked broken. Same sentence, same link,
/// derived from the selection rather than from transient UI state — it is right
/// after a rebuild, a navigation, or a removal made on another page.
///
/// Returns null while nothing is selected: an empty shortlist has no count to
/// report and no comparison to open.
Component? compareShortlistStatus(Set<String> compared) {
  if (compared.isEmpty) return null;
  final full = compared.length >= AppState.maxCompare;
  return div(classes: 'notice notice-info', [
    Component.text(
      '${compared.length} of ${AppState.maxCompare} in comparison'
      '${full ? ' — remove one to add another.' : '.'}',
    ),
    ActionLink('View comparison', href: compareRoute),
  ]);
}
