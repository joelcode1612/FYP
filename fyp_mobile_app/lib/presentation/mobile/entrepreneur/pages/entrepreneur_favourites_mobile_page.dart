import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_inline_notice.dart';
import '../../shell/entrepreneur_tab_scope.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/async_section.dart';
import '../../widgets/compare_shortlist.dart';
import '../../widgets/m3_kit.dart';
import '../../widgets/mobile_property_card.dart';
import '../../widgets/mobile_skeleton.dart';

/// **Favourites** — the fourth tab of the five-tab Entrepreneur dock.
///
/// It replaces the "My Spaces" tab. A favourite is a row in
/// `public.favourite_property` written through the authenticated
/// `/api/v1/saved-properties` endpoints, so this screen adds no model,
/// endpoint or table: the bookmark state is the shared [AppState.saved] set,
/// which is why saving in Recommendations, in Property Details and here always
/// shows the same answer, and why it survives an app restart.
///
/// Cards resolve against the same property repository the catalogue uses
/// ([ServiceLocator]'s `properties.listings()`), and the states stay distinct:
/// a failed read reports the failure with a retry, an empty list invites the
/// user to save something, and refs the server reports as delisted never
/// render as ghost cards.
class EntrepreneurFavouritesMobilePage extends ConsumerStatefulWidget {
  const EntrepreneurFavouritesMobilePage({super.key});

  @override
  ConsumerState<EntrepreneurFavouritesMobilePage> createState() =>
      _EntrepreneurFavouritesMobilePageState();
}

class _EntrepreneurFavouritesMobilePageState
    extends ConsumerState<EntrepreneurFavouritesMobilePage> {
  final GlobalKey<AsyncSectionState<List<CommercialProperty>>> _catalogueKey =
      GlobalKey<AsyncSectionState<List<CommercialProperty>>>();

  @override
  void initState() {
    super.initState();
    // The list is server-owned; without this read the tab would only ever show
    // what the current session happened to tap.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(appNotifierProvider.notifier).loadSaved();
    });
  }

  /// Pull-to-refresh re-reads BOTH sources: the favourites (authoritative on
  /// the server) and the catalogue rows they resolve against.
  Future<void> _refresh() async {
    await Future.wait([
      ref.read(appNotifierProvider.notifier).loadSaved(),
      _catalogueKey.currentState?.refresh() ?? Future<void>.value(),
    ]);
  }

  Future<void> _unsave(String id) async {
    final messenger = ScaffoldMessenger.of(context);
    final failure = await ref
        .read(appNotifierProvider.notifier)
        .persistSaved(id, wantSaved: false);
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text(failure ?? 'Removed from favourites.')),
    );
  }

  /// The existing Property Details route, opened with the catalogue id, so the
  /// screen keeps every location and suitability result it already shows.
  void _openDetails(String id) => Navigator.of(context).pushNamed(
    '/entrepreneur/property-detail',
    arguments: id,
  );

  Widget _loading() => Column(
    children: [
      for (var i = 0; i < 3; i++) ...[
        const MobilePropertyCardSkeleton(),
        const SizedBox(height: 12),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appNotifierProvider);
    final total = appState.saved.length;
    final countKnown = appState.savedError == null;

    return MobileAppShell(
      title: 'Favourites',
      currentRoute: '/entrepreneur/favourites',
      body: RefreshIndicator(
        color: SitewiseColors.action,
        onRefresh: _refresh,
        child: M3Content(
          children: [
            const M3ScreenHeading(
              eyebrow: 'Saved properties',
              title: 'My Favourites',
              lead: "Properties you've saved for later.",
            ),
            const SizedBox(height: 18),
            if (appState.savedError != null)
              SitewiseInlineNotice(
                message: appState.savedError!,
                busy: appState.savedLoading,
                onRetry: () =>
                    ref.read(appNotifierProvider.notifier).loadSaved(),
              ),
            M3SectionRow(
              title: 'Favourite properties',
              overline: countKnown
                  ? '$total ${total == 1 ? 'FAVOURITE' : 'FAVOURITES'}'
                  : 'NOT LOADED',
            ),
            const SizedBox(height: 12),
            if (appState.savedLoading && total == 0)
              _loading()
            else if (total == 0 && !countKnown)
              // The notice above carries the reason and the retry; showing an
              // empty list here would read as "nothing saved".
              const SizedBox.shrink()
            else if (total == 0)
              M3EmptyState(
                icon: Icons.bookmark_border_rounded,
                title: 'No favourite properties yet',
                message:
                    'Save properties from Recommendations to find them here later.',
                actionLabel: 'Explore Recommendations',
                onAction: () => EntrepreneurTabScope.open(
                  context,
                  '/entrepreneur/recommendations',
                ),
              )
            else
              // A failed refresh keeps the last list on screen with the reason
              // and retry above it, rather than blanking the tab.
              AsyncSection<List<CommercialProperty>>(
                key: _catalogueKey,
                load: () => ServiceLocator.properties.listings(),
                errorTitle: 'Your favourites could not be loaded',
                loadingBuilder: (_) => _loading(),
                builder: (context, catalogue) {
                  final items = catalogue
                      .where((p) => appState.saved.contains(p.id))
                      .toList();
                  if (items.isEmpty) {
                    return const M3EmptyState(
                      icon: Icons.bookmark_border_rounded,
                      title: 'Records unavailable',
                      message:
                          'Your favourites are no longer present in the '
                          'property catalogue.',
                    );
                  }
                  return Column(
                    children: [
                      if (items.length < total)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text(
                            '${total - items.length} of your '
                            '${total == 1 ? 'favourite is' : 'favourites are'} '
                            'no longer listed in the property catalogue.',
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: SitewiseColors.muted,
                            ),
                          ),
                        ),
                      for (final p in items) ...[
                        MobilePropertyCard(
                          property: p,
                          saved: true,
                          onToggleSaved: () => _unsave(p.id),
                          compared: appState.compared.contains(p.id),
                          onToggleCompare: () =>
                              toggleComparedWithFeedback(ref, context, p.id),
                          onViewDetails: () => _openDetails(p.id),
                          onTap: () => _openDetails(p.id),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
