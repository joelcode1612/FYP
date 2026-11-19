import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart' show AppRole;

import '../../components/admin_review_split.dart';
import '../../components/agent_change_requests_panel.dart';
import '../../components/ui.dart';
import '../../layouts/app_layout.dart';

/// Administrative property directory and agent change-request workspace.
/// Each workflow retains its original FastAPI endpoints and review actions.
@client
class ListingsPage extends StatefulComponent {
  const ListingsPage({super.key});

  @override
  State<ListingsPage> createState() => _ListingsPageState();
}

class _ListingsPageState extends State<ListingsPage> {
  /// 0 = property/ownership verification; 1 = agent change requests.
  int _tab = 0;

  Component _navigationItem({
    required int index,
    required String label,
    required String icon,
  }) {
    final selected = _tab == index;
    return button(
      classes: 'al2-nav${selected ? ' is-active' : ''}',
      attributes: {
        'type': 'button',
        'aria-pressed': selected.toString(),
      },
      events: events(onClick: () => setState(() => _tab = index)),
      [
        Icon(icon, size: 'sm'),
        span([Component.text(label)]),
      ],
    );
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/listings',
      title: 'Property listings',
      eyebrow: 'Admin / Property management',
      subtitle:
          'Manage verification decisions and review agent-proposed changes '
          'from one workspace.',
      child: div(classes: 'admin-listings-v2 stack', [
        div(classes: 'al2-navigation', [
          _navigationItem(
            index: 0,
            label: 'Property reviews',
            icon: 'domain_verification',
          ),
          _navigationItem(
            index: 1,
            label: 'Agent changes',
            icon: 'edit_document',
          ),
        ]),
        if (_tab == 0)
          const ReviewSplit()
        else
          div(classes: 'al2-agent-workspace', [
            const AgentChangeRequestsPanel(),
          ]),
      ]),
    );
  }
}
