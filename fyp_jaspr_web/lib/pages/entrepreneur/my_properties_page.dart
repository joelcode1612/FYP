import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../layouts/app_layout.dart';

/// Entrepreneur "My Properties" workspace.
///
/// The app's data model has **no entrepreneur-owned property entity** — the
/// entrepreneur role is a searcher / assessor, not a lister. The reference
/// prototype shows sample records here; this build stays honest and renders the
/// explicit empty state until a real backend for owner-listed properties exists.
/// The CTA points at the local-draft registration wizard.
@client
class MyPropertiesPage extends StatefulComponent {
  const MyPropertiesPage({super.key});

  @override
  State<MyPropertiesPage> createState() => _MyPropertiesPageState();
}

class _MyPropertiesPageState extends State<MyPropertiesPage> {
  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/my-properties',
      title: 'My Properties',
      eyebrow: 'Workspace',
      subtitle:
          'Properties you register for your own F&B business. Records created '
          'here are kept as local drafts on this device.',
      child: div(classes: 'stack stack--sections sw-mp', [
        section(classes: 'sw-mp-empty', [
          div(classes: 'sw-mp-empty-icon', [Icon('storefront', size: 'lg')]),
          h2([Component.text('You have no property records yet')]),
          p(classes: 'sw-mp-empty-body', [
            Component.text(
              'Register a commercial premises to capture its details, location, '
              'F&B readiness and ownership information in one structured '
              'workflow. Drafts are stored locally and are not submitted to any '
              'server.',
            ),
          ]),
          AppLink(
            to: '/entrepreneur/add-property',
            classes: 'sw-mp-cta',
            children: [
              Icon('add_business', size: 'sm'),
              Component.text('Register a property'),
            ],
          ),
        ]),
      ]),
    );
  }
}
