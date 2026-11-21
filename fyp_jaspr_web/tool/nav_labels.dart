// Prints the entrepreneur top-bar destinations exactly as the shell renders
// them. Used to verify a navigation edit without a signed-in browser session.
//
//   dart run tool/nav_labels.dart
import 'package:sitewise_jaspr_web/data/navigation.dart';
import 'package:sitewise_jaspr_web/data/site_content.dart';

void main() {
  for (final role in [AppRole.entrepreneur, AppRole.admin]) {
    final labels = webDestinationsFor(role).map((d) => d.label).toList();
    print('$role -> $labels');
  }
}
