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
/// Flutter version's FloatingActionButton becomes a `PageHead` action; the grid
/// is the same owner-scoped list from [OwnerCubit], each card linking to the
/// detail route with a `?id=` query param.
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
        final properties = vm.properties;

        return AppLayout(
          role: AppRole.owner,
          currentRoute: '/owner/properties',
          // The page header is rendered by `AppLayout`; a page must not render
          // its own `PageHead` or the title appears twice.
          title: 'Properties',
          subtitle:
              'The commercial spaces you have listed. Each card shows the '
              'rental asking price, built-up area and current verification '
              'state.',
          // The primary action belongs to this page's task rather than to the
          // shell, so it lands on the right of the page header.
          actions: const [
            ActionLink(
              'Add property',
              href: '/owner/add-property',
              icon: 'add',
            ),
          ],
          child: div(classes: 'stack stack--sections', [
            if (vm.loading)
              div(classes: 'card-grid', [
                const Skeleton(variant: 'block', count: 6),
              ])
            else if (properties.isEmpty)
              EmptyState(
                icon: 'apartment',
                title: 'No properties listed yet',
                body:
                    'Add your first commercial space and it will appear here. '
                    'Listings need the location, floor area and asking rental '
                    'before they can be shown to entrepreneurs.',
                action: const ActionLink(
                  'Add your first property',
                  href: '/owner/add-property',
                  icon: 'add',
                ),
              )
            else
              div(classes: 'card-grid', [
                for (final p in properties)
                  PropertyCard(
                    property: p,
                    href: '/owner/property-detail?id=${p.id}',
                  ),
              ]),
          ]),
        );
      },
    );
  }
}
