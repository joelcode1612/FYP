import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart' show AppRole;

import '../../components/admin_review_split.dart';
import '../../layouts/app_layout.dart';

/// Web listings, ported to the source `admin/review.html` split layout.
///
/// The queue is the server's unified verification projection: search, the
/// per-dimension status facets, sorting and pagination all run against
/// `/api/v1/staff/properties/`, and the detail column loads
/// `/api/v1/staff/properties/{id}/verification` for the selected listing.
/// The old `/admin/verification` and `/admin/ownership` routes redirect here.
@client
class ListingsPage extends StatelessComponent {
  const ListingsPage({super.key});

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/listings',
      // The page header is rendered by `AppLayout`; a page must not render
      // its own `PageHead` or the title appears twice.
      title: 'Listings',
      eyebrow: 'Verification',
      subtitle:
          'Every commercial property on the platform, across all owners. '
          'Review each listing and its ownership evidence as two independent '
          'decisions.',
      // ReviewSplit scopes its own watches, so the chrome never rebuilds on a
      // notification.
      child: const div(
        classes: 'stack stack--sections',
        [ReviewSplit()],
      ),
    );
  }
}
