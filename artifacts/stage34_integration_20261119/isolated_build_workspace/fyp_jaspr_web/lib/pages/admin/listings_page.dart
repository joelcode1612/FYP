import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart' show AppRole;

import '../../components/admin_review_split.dart';
import '../../components/agent_change_requests_panel.dart';
import '../../components/ui.dart';
import '../../layouts/app_layout.dart';

/// Web listings, ported to the source `admin/review.html` split layout.
///
/// The queue is the server's unified verification projection: search, the
/// per-dimension status facets, sorting and pagination all run against
/// `/api/v1/staff/properties/`, and the detail column loads
/// `/api/v1/staff/properties/{id}/verification` for the selected listing.
/// The old `/admin/verification` and `/admin/ownership` routes redirect here.
@client
class ListingsPage extends StatefulComponent {
  const ListingsPage({super.key});

  @override
  State<ListingsPage> createState() => _ListingsPageState();
}

class _ListingsPageState extends State<ListingsPage> {
  /// 0 = initial property verification (workflow A), 1 = agent listing
  /// changes (workflow B). The two use different tables and stay separate.
  int _tab = 0;

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
      child: div(classes: 'stack stack--sections', [
        div(classes: 'actions-row', [
          ActionButton(
            'Property verification',
            variant: _tab == 0 ? 'primary' : 'secondary',
            onClick: () => setState(() => _tab = 0),
          ),
          ActionButton(
            'Agent change requests',
            variant: _tab == 1 ? 'primary' : 'secondary',
            onClick: () => setState(() => _tab = 1),
          ),
        ]),
        // ReviewSplit scopes its own watches, so the chrome never rebuilds on
        // a notification.
        if (_tab == 0) const ReviewSplit() else const AgentChangeRequestsPanel(),
      ]),
    );
  }
}
