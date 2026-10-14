import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/property_card.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web saved shortlist: 3-column desktop grid.
///
/// Ported from `entrepreneur_saved_web_page.dart` in the Flutter web tree.
/// The list is filtered by the shared `AppLocator.appCubit` saved set, and
/// both Flutter empty states ("No saved properties" / "Shortlist is empty")
/// are preserved verbatim. Cards wire the bookmark toggle only — the Flutter
/// page passes no compare callback, so no compare button is rendered.
///
/// The local `_Loading` / `_Empty` widgets this page used to carry were
/// duplicates of the shared primitives, so they now use `Skeleton` /
/// `EmptyState` directly.
class SavedPage extends StatelessComponent {
  const SavedPage({super.key});

  @override
  Component build(BuildContext context) {
    final appCubit = AppLocator.appCubit;
    return CubitBuilder<AppCubit, AppState>(
      cubit: appCubit,
      builder: (context, _) {
        return AppLayout(
          role: AppRole.entrepreneur,
          currentRoute: '/entrepreneur/saved',
          title: 'Saved properties',
          subtitle:
              'Your shortlist. Bookmark any listing to keep it here while you '
              'weigh it against the others.',
          child: div(classes: 'stack stack--sections', [
            if (appCubit.saved.isEmpty)
              EmptyState(
                icon: 'bookmark_border',
                title: 'No saved properties',
                body:
                    'Tap the bookmark on any listing to build your shortlist.',
                action: const ActionLink(
                  'Explore properties',
                  href: '/entrepreneur/explore',
                  variant: 'secondary',
                ),
              )
            else
              FutureBuilder<List<CommercialProperty>>(
                future: AppLocator.properties.listings(),
                builder: (c, snap) {
                  if (!snap.hasData) {
                    return div(classes: 'card-grid', [
                      const Skeleton(variant: 'block', count: 6),
                    ]);
                  }
                  final items = snap.data!
                      .where((property) => appCubit.saved.contains(property.id))
                      .toList();
                  if (items.isEmpty) {
                    return EmptyState(
                      icon: 'bookmark_border',
                      title: 'Shortlist is empty',
                      body: 'Saved items were removed or are unavailable.',
                    );
                  }
                  return div(classes: 'card-grid', [
                    for (final property in items)
                      PropertyCard(
                        property: property,
                        href: '/entrepreneur/property-detail?id=${property.id}',
                        saved: true,
                        onToggleSaved: () => appCubit.toggleSaved(property.id),
                      ),
                  ]);
                },
              ),
          ]),
        );
      },
    );
  }
}
