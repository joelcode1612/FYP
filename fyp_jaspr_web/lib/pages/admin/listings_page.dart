import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/property_card.dart';
import '../../components/ui.dart';
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

  /// Clears the search box — the escape hatch named by the empty state.
  void _clearQuery() => setState(() => query = '');

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
          // The page header is rendered by `AppLayout`; a page must not render
          // its own `PageHead` or the title appears twice.
          title: 'Listings',
          subtitle:
              'Every commercial property on the platform, across all owners. '
              'Open a listing to review its details or decide whether it '
              'should be verified.',
          child: div(classes: 'stack stack--sections', [
            SearchInput(
              label: 'Search listings',
              placeholder: 'Search by title or city…',
              ariaLabel: 'Search listings by title or city',
              onInput: (value) => setState(() => query = value),
            ),

            if (vm.loading)
              // Placeholders keep the grid's height while the request is in
              // flight, instead of swapping text for content and reflowing.
              div(classes: 'card-grid', [
                const Skeleton(variant: 'block', count: 6),
              ])
            else if (items.isEmpty)
              EmptyState(
                icon: query.isEmpty ? 'apartment' : 'search_off',
                title: query.isEmpty
                    ? 'No listings on the platform'
                    : 'No listings match that search',
                body: query.isEmpty
                    ? 'Listings submitted by property owners will appear here '
                          'once they are published.'
                    : 'Nothing matched "$query". Try a different title or '
                          'city, or clear the search to see all listings.',
                action: query.isEmpty
                    ? null
                    : ActionButton(
                        'Clear search',
                        icon: 'close',
                        variant: 'secondary',
                        onClick: _clearQuery,
                      ),
              )
            else
              div(classes: 'card-grid', [
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
