import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart' show AppRole;

import 'package:sitewise_jaspr_web/features/property_verification/presentation/components/admin_review_split.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';
import 'package:sitewise_jaspr_web/shared/presentation/layouts/app_layout.dart';

/// Administrative property directory and verification queue.
@client
class ListingsPage extends StatefulComponent {
  const ListingsPage({super.key});

  @override
  State<ListingsPage> createState() => _ListingsPageState();
}

class _ListingsPageState extends State<ListingsPage> {
  _ListingsTab _tab = _ListingsTab.allProperties;

  Component _navigationItem({
    required _ListingsTab tab,
    required String label,
    required String icon,
  }) {
    final selected = _tab == tab;
    return button(
      classes: 'al2-nav${selected ? ' is-active' : ''}',
      attributes: {'type': 'button', 'aria-pressed': selected.toString()},
      events: events(onClick: () => setState(() => _tab = tab)),
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
          'Manage property listings and verification requests in one workspace.',
      child: div(classes: 'admin-listings-v2 stack', [
        div(classes: 'al2-navigation', [
          _navigationItem(
            tab: _ListingsTab.allProperties,
            label: 'All properties',
            icon: 'inventory_2',
          ),
          _navigationItem(
            tab: _ListingsTab.verificationQueue,
            label: 'Verification queue',
            icon: 'domain_verification',
          ),
        ]),
        if (_tab == _ListingsTab.allProperties)
          const ReviewSplit(key: ValueKey('all-properties'), scope: 'all')
        else
          const ReviewSplit(
            key: ValueKey('verification-queue'),
            scope: 'queue',
          ),
      ]),
    );
  }
}

enum _ListingsTab { allProperties, verificationQueue }
