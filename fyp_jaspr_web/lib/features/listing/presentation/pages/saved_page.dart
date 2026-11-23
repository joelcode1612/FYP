import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:sitewise_jaspr_web/features/compare/presentation/components/compare_shortlist.dart';
import 'package:sitewise_jaspr_web/features/listing/presentation/components/property_card.dart';
import 'package:sitewise_jaspr_web/features/listing/data/api_property_repository.dart'
    as web_catalogue;
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';
import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/shared/presentation/layouts/app_layout.dart';

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
class SavedPage extends StatefulComponent {
  const SavedPage({super.key});

  @override
  State<SavedPage> createState() => _SavedPageState();
}

class _SavedPageState extends State<SavedPage> {
  String? _saveError;
  Set<String>? _requestedIds;
  Future<List<CommercialProperty>>? _listings;

  Future<List<CommercialProperty>> _loadListings(Set<String> ids) {
    if (_listings == null || _requestedIds!.length != ids.length ||
        !_requestedIds!.containsAll(ids)) {
      _requestedIds = Set.of(ids);
      _listings = AppLocator.isSignedIn
          ? web_catalogue.ApiPropertyRepository.listingsByIds(ids)
          : AppLocator.properties.listings();
    }
    return _listings!;
  }

  Future<void> _toggleSaved(BuildContext context, String id) async {
    final notifier = context.read(appNotifierProvider.notifier);
    if (!AppLocator.isSignedIn) {
      notifier.toggleSaved(id);
      return;
    }
    final failure = await notifier.persistSaved(id, wantSaved: false);
    if (mounted) setState(() => _saveError = failure);
  }

  @override
  Component build(BuildContext context) {
    final savedState = context.watch(appNotifierProvider);
    final saved = savedState.saved;
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
        if (_saveError case final error?)
          div(attributes: {'role': 'alert'}, [Component.text(error)]),
        if (savedState.savedLoading)
          const Skeleton(variant: 'block', count: 3)
        else if (savedState.savedError case final error?)
          EmptyState(
            title: 'Saved properties unavailable',
            body: error,
            action: ActionButton('Try again', onClick: () {
              setState(() => _listings = null);
              context.read(appNotifierProvider.notifier).loadSaved(includeUnresolved: true);
            }),
          )
        else if (saved.isEmpty)
          EmptyState(
            title: 'No favourites yet',
            body:
                'Save a property while browsing to keep it here. Saved '
                'items are kept with your account when you are signed in, '
                'or for this session otherwise, and can be removed again '
                'from this page.',
            action: const ActionLink(
              'Browse properties',
              href: '/entrepreneur/explore',
              variant: 'primary',
            ),
          )
        else
          FutureBuilder<List<CommercialProperty>>(
            future: _loadListings(saved),
            builder: (c, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return div(classes: 'pgrid', [
                  const Skeleton(variant: 'block', count: 6),
                ]);
              }
              if (snap.hasError) {
                return EmptyState(
                  title: 'Property details unavailable',
                  body: 'Your saved list could not be matched to the catalogue.',
                  action: ActionButton('Try again', onClick: () {
                    setState(() => _listings = null);
                  }),
                );
              }
              final all = snap.data ?? const <CommercialProperty>[];
              final live = all
                  .where((property) => saved.contains(property.id))
                  .toList();
              final liveIds = live.map((property) => property.id).toSet();
              final gone = saved.where((id) => !liveIds.contains(id)).toList();

              return div(classes: 'stack stack--sections', [
                p(classes: 'small', [
                  Component.text(
                    '${live.length} saved. Saved items are held for this '
                    'session.',
                  ),
                ]),
                ?compareShortlistStatus(compared),
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
                        href: '/entrepreneur/property-detail?id=${property.id}',
                        assessHref:
                            '/entrepreneur/assessments?id=${property.id}',
                        saved: true,
                        compared: compared.contains(property.id),
                        onToggleSaved: () => _toggleSaved(context, property.id),
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
                            onClick: () => _toggleSaved(context, id),
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
