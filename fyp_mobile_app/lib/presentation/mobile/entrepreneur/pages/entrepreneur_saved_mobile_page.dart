import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_empty_state.dart';
import '../../../shared/widgets/sitewise_inline_notice.dart';
import '../../shell/entrepreneur_tab_scope.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/async_section.dart';
import '../../widgets/mobile_property_card.dart';
import '../../widgets/mobile_section_header.dart';
import '../../widgets/mobile_skeleton.dart';

/// Mobile saved shortlist.
///
/// Three defects this screen used to have, all fixed here:
///
///  * the shortlist was never read from `public.favourite_property`, so a
///    saved property disappeared on the next launch — [AppNotifier.loadSaved]
///    now runs on entry and on pull-to-refresh;
///  * `FutureBuilder(future: ServiceLocator.properties.listings())` inside
///    `build()` re-issued the catalogue request on every rebuild and offered no
///    retry — [AsyncSection] owns the request instead;
///  * `saved.isEmpty` short-circuited to "Nothing saved yet" even while the
///    read was in flight or had just failed, turning an error into an empty
///    success state. Loading, empty and error are now distinct.
class EntrepreneurSavedMobilePage extends ConsumerStatefulWidget {
  const EntrepreneurSavedMobilePage({super.key});

  @override
  ConsumerState<EntrepreneurSavedMobilePage> createState() =>
      _EntrepreneurSavedMobilePageState();
}

class _EntrepreneurSavedMobilePageState
    extends ConsumerState<EntrepreneurSavedMobilePage> {
  final GlobalKey<AsyncSectionState<List<CommercialProperty>>> _catalogueKey =
      GlobalKey<AsyncSectionState<List<CommercialProperty>>>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(appNotifierProvider.notifier).loadSaved();
    });
  }

  /// Pull-to-refresh re-reads BOTH sources: the shortlist (authoritative on the
  /// server) and the catalogue rows it resolves against.
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
      SnackBar(
        content: Text(
          failure ?? 'Removed from your shortlist.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appNotifierProvider);

    return MobileAppShell(
      title: 'Saved',
      currentRoute: '/entrepreneur/saved',
      body: RefreshIndicator(
        color: SitewiseColors.action,
        onRefresh: _refresh,
        child: AsyncSection<List<CommercialProperty>>(
          key: _catalogueKey,
          // A real repository read. In a live build this is the catalogue API;
          // a failure throws and is reported instead of rendering as "empty".
          load: () => ServiceLocator.properties.listings(),
          isEmpty: (_) => appState.saved.isEmpty,
          emptyBuilder: (_) => SitewiseEmptyState(
            icon: Icons.bookmark_border_rounded,
            title: 'Nothing saved yet',
            message: 'Save properties you want to compare later.',
            actionLabel: 'Browse recommendations',
            onAction: () => EntrepreneurTabScope.open(
              context,
              '/entrepreneur/recommendations',
            ),
          ),
          loadingBuilder: (_) => const MobilePropertyListSkeleton(),
          errorTitle: 'Your shortlist could not be loaded',
          builder: (context, catalogue) {
            final items =
                catalogue.where((p) => appState.saved.contains(p.id)).toList();
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                if (appState.savedError != null)
                  SitewiseInlineNotice(
                    message: appState.savedError!,
                    busy: appState.savedLoading,
                    onRetry: () =>
                        ref.read(appNotifierProvider.notifier).loadSaved(),
                  ),
                MobileSectionHeader(
                  title: 'Saved properties',
                  subtitle:
                      '${items.length} ${items.length == 1 ? 'property' : 'properties'} in your shortlist',
                ),
                const SizedBox(height: 14),
                if (items.isEmpty)
                  const SitewiseEmptyState(
                    icon: Icons.bookmark_border_rounded,
                    title: 'Shortlist is empty',
                    message: 'Saved items were removed or are unavailable.',
                  ),
                for (final p in items) ...[
                  MobilePropertyCard(
                    property: p,
                    saved: true,
                    onToggleSaved: () => _unsave(p.id),
                    compared: appState.compared.contains(p.id),
                    onToggleCompare: () => ref
                        .read(appNotifierProvider.notifier)
                        .toggleCompared(p.id),
                    onTap: () => Navigator.of(context).pushNamed(
                      '/entrepreneur/property-detail',
                      arguments: p.id,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
