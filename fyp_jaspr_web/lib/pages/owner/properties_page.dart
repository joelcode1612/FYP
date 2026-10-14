import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/property_card.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web properties: 3-column desktop grid with an add-property action.
///
/// Ported from `owner_properties_web_page.dart` in the Flutter web tree. The
/// Flutter version's FloatingActionButton becomes a topbar action link; the
/// grid is the same owner-scoped list from [OwnerCubit], each card linking to
/// the detail route with a `?id=` query param.
class PropertiesPage extends StatefulComponent {
  const PropertiesPage({super.key});

  @override
  State<PropertiesPage> createState() => _PropertiesPageState();
}

class _PropertiesPageState extends State<PropertiesPage> {
  late final OwnerCubit vm;

  @override
  void initState() {
    super.initState();
    vm = AppLocator.newOwnerCubit();
    unawaited(vm.load());
  }

  @override
  void dispose() {
    unawaited(vm.close());
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    return CubitBuilder<OwnerCubit, OwnerState>(
      cubit: vm,
      builder: (context, _) {
        return AppLayout(
          role: AppRole.owner,
          currentRoute: '/owner/properties',
          title: 'My Properties',
          subtitle: AppRole.owner.label,
          actions: const [
            ActionLink(
              'Add property',
              href: '/owner/add-property',
              icon: 'add',
            ),
          ],
          child: vm.loading
              ? const _Loading()
              : div(classes: 'card-grid', [
                  for (final p in vm.properties)
                    PropertyCard(
                      property: p,
                      href: '/owner/property-detail?id=${p.id}',
                    ),
                ]),
        );
      },
    );
  }
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) {
    return div(classes: 'card', [
      p(classes: 'body muted', [Component.text('Loading…')]),
    ]);
  }
}
