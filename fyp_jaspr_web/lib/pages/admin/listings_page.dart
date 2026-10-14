import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/property_card.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web listings: search plus a 3-column desktop grid.
///
/// Ported from `admin_listings_web_page.dart`. Like the Flutter page, the
/// search is a local `query` over `title`/`city` (not the cubit's broader
/// `setQuery`) and data comes from the same `loadDashboard` call. Card taps
/// become links to `/admin/listing-detail?id=…`.
class ListingsPage extends StatefulComponent {
  const ListingsPage({super.key});

  @override
  State<ListingsPage> createState() => _ListingsPageState();
}

class _ListingsPageState extends State<ListingsPage> {
  late final AdminCubit vm;
  String query = '';

  @override
  void initState() {
    super.initState();
    vm = AppLocator.newAdminCubit();
    unawaited(vm.loadDashboard());
  }

  @override
  void dispose() {
    unawaited(vm.close());
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    return CubitBuilder<AdminCubit, AdminState>(
      cubit: vm,
      builder: (context, _) {
        final items = vm.listings
            .where(
              (property) =>
                  query.isEmpty ||
                  '${property.title} ${property.city}'.toLowerCase().contains(
                    query.toLowerCase(),
                  ),
            )
            .toList();
        return AppLayout(
          role: AppRole.admin,
          currentRoute: '/admin/listings',
          title: 'Listings',
          subtitle: AppRole.admin.label,
          child: div(classes: 'stack', [
            div(classes: 'row', [
              input(
                type: InputType.search,
                classes: 'input',
                attributes: {
                  'placeholder': 'Search listings…',
                  'aria-label': 'Search listings',
                },
                events: events<String>(
                  onInput: (value) => setState(() => query = value),
                ),
              ),
            ]),
            vm.loading
                ? div(classes: 'card', [
                    p(classes: 'body muted', [Component.text('Loading…')]),
                  ])
                : items.isEmpty
                ? div(classes: 'card', [
                    p(classes: 'body', [
                      Component.text('No listings match your search.'),
                    ]),
                  ])
                : div(classes: 'card-grid', [
                    for (final property in items)
                      PropertyCard(
                        property: property,
                        href: '/admin/listing-detail?id=${property.id}',
                      ),
                  ]),
          ]),
        );
      },
    );
  }
}
