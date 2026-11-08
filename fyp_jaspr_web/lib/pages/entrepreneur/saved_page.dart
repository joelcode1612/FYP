import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/property_card.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web saved shortlist, laid out as the source's `favourites.html`.
///
/// ```text
/// .page-head   "Favourites" · "Saved properties" · count
/// .notice      delisted records are kept, not silently dropped
/// .pgrid       live favourites
/// section      "No longer available" (saved ids with no current listing)
/// ```
///
/// The saved set is a session-scoped id set, so a saved id whose listing has
/// disappeared is shown as unavailable rather than filtered away. No title or
/// address is invented for it: the source's snapshot fields are not stored in
/// this build.
@client
class SavedPage extends StatelessComponent {
  const SavedPage({super.key});

  @override
  Component build(BuildContext context) {
    final saved = context.watch(appNotifierProvider.select((app) => app.saved));
    final compared = context.watch(
      appNotifierProvider.select((app) => app.compared),
    );

    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/saved',
      title: 'Saved properties',
      eyebrow: 'Favourites',
      subtitle:
          'Your shortlist. Bookmark any listing to keep it here while you '
          'weigh it against the others.',
      child: div(classes: 'stack stack--sections', [
        if (saved.isEmpty)
          EmptyState(
            title: 'No favourites yet',
            body:
                'Save a property while browsing to keep it here. Saved '
                'items are held for this session and can be removed again '
                'from this page.',
            action: const ActionLink(
              'Browse properties',
              href: '/entrepreneur/explore',
              variant: 'primary',
            ),
          )
        else
          FutureBuilder<List<CommercialProperty>>(
            future: AppLocator.properties.listings(),
            builder: (c, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return div(classes: 'pgrid', [
                  const Skeleton(variant: 'block', count: 6),
                ]);
              }
              final all = snap.data ?? const <CommercialProperty>[];
              final live = all
                  .where((property) => saved.contains(property.id))
                  .toList();
              final liveIds = live.map((property) => property.id).toSet();
              final gone = saved
                  .where((id) => !liveIds.contains(id))
                  .toList();

              return div(classes: 'stack stack--sections', [
                p(classes: 'small', [
                  Component.text(
                    '${live.length} saved. Saved items are held for this '
                    'session.',
                  ),
                ]),
                if (gone.isNotEmpty)
                  div(classes: 'notice notice-warn', [
                    Component.text(
                      '${gone.length} saved '
                      '${gone.length == 1 ? 'property is' : 'properties are'} '
                      'no longer published (delisted, unapproved or no '
                      'longer available), so '
                      '${gone.length == 1 ? 'it cannot' : 'they cannot'} be '
                      'opened.',
                    ),
                  ]),
                if (live.isNotEmpty)
                  div(classes: 'pgrid', [
                    for (final property in live)
                      PropertyCard(
                        property: property,
                        href:
                            '/entrepreneur/property-detail?id=${property.id}',
                        saved: true,
                        compared: compared.contains(property.id),
                        onToggleSaved: () => context
                            .read(appNotifierProvider.notifier)
                            .toggleSaved(property.id),
                        onToggleCompared: () => context
                            .read(appNotifierProvider.notifier)
                            .toggleCompared(property.id),
                      ),
                  ])
                else
                  const EmptyState(
                    title: 'No saved listing is currently available',
                    body:
                        'Every saved property has been delisted or is no '
                        'longer approved. You can remove the records below.',
                  ),
                if (gone.isNotEmpty)
                  section(classes: 'section', [
                    h2([Component.text('No longer available')]),
                    div(classes: 'analysis', [
                      for (final id in gone)
                        div(classes: 'a-card', [
                          h3([Component.text('Saved listing')]),
                          p(classes: 'what', [
                            Component.text(
                              'Listing $id is no longer published. Its '
                              'title and address were not stored in this '
                              'build.',
                            ),
                          ]),
                          ActionButton(
                            'Remove from favourites',
                            variant: 'secondary',
                            icon: 'delete',
                            onClick: () => context
                                .read(appNotifierProvider.notifier)
                                .toggleSaved(id),
                          ),
                        ]),
                    ]),
                  ]),
              ]);
            },
          ),
      ]),
    );
  }
}
