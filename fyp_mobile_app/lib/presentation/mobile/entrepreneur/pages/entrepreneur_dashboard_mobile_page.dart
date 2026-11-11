import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../core/theme/sitewise_theme.dart';
import '../../shell/mobile_app_shell.dart';
import '../../../shared/widgets/sitewise_inline_notice.dart';
import '../../widgets/m3_kit.dart';

/// Mobile entrepreneur Home — the first screen after sign-in.
///
/// Follows `Sitewise_Mobile_Material3_Mock_Data.html`'s `home()` layout:
/// greeting → light-blue discovery feature → "Your overview" metric pair →
/// data-provenance note → "Quick actions" rows. The five-tab shell, brand
/// lockup header and pill-indicator bottom bar come from [MobileAppShell].
///
/// **No invented records.** Both overview tiles are wired to real state:
/// `entrepreneurNotifierProvider`'s `recommendations` (ranked from the property
/// repository) and `appNotifierProvider`'s `saved` (the user's shortlist). Labels say what the data is —
/// "Recommendations" and "Saved spaces" — rather than copying the prototype's
/// "Assessments" / "My properties", which would imply entities this app does
/// not have.
///
/// Loading/refresh: both counts are server-owned, so this screen loads them on
/// entry and again on pull-to-refresh or the header refresh button. A failed
/// read renders "—" plus the reason and a retry — never a zero that looks like
/// "no matches" / "nothing saved".
///
/// Everything else reachable from the old Home (saved, compare, preferences,
/// recommendations, tours) stays reachable from the Profile and
/// Recommendations tabs, so this is a layout change only, not a loss of routes.

class EntrepreneurDashboardMobilePage extends ConsumerStatefulWidget {
  const EntrepreneurDashboardMobilePage({super.key});

  @override
  ConsumerState<EntrepreneurDashboardMobilePage> createState() =>
      _EntrepreneurDashboardMobilePageState();
}

class _EntrepreneurDashboardMobilePageState
    extends ConsumerState<EntrepreneurDashboardMobilePage> {
  @override
  void initState() {
    super.initState();
    // The load publishes synchronously; a kick from initState would modify
    // the provider while the widget tree is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _load();
    });
  }

  /// Both tiles are server-owned: the ranked matches and the account's saved
  /// shortlist. They used to be loaded separately — the shortlist not at all
  /// from this screen — so Home could show "0 saved spaces" for an account with
  /// a populated shortlist.
  Future<void> _load() async {
    await Future.wait([
      ref.read(appNotifierProvider.notifier).loadSaved(),
      ref.read(entrepreneurNotifierProvider.notifier).loadRecommendations(),
    ]);
  }

  void _open(String route, {Object? arguments}) =>
      Navigator.of(context).pushNamed(route, arguments: arguments);

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appNotifierProvider);
    final model = ref.watch(entrepreneurNotifierProvider);
    final recommendations = model.recommendations.length;
    final saved = appState.saved.length;
    final compared = appState.compared.length;

    // A failed read is not a zero. Each tile falls back to "—" and the reason
    // is stated above it with a retry.
    final recommendationsKnown = model.error == null;
    final savedKnown = appState.savedError == null;
    final failure = model.error ?? appState.savedError;
    final busy = model.loading || appState.savedLoading;

    // The tab host keeps Home alive, so editing preferences on Profile never
    // re-ranked the match count. The provider is invalidated by
    // `onPreferencesUpdated`, which makes this the re-entry signal.
    ref.listen<BusinessPreferences>(businessPreferencesProvider, (
      previous,
      next,
    ) {
      if (previous == null) return;
      ref.read(entrepreneurNotifierProvider.notifier).loadRecommendations();
    });

    return MobileAppShell(
      title: 'Home',
      currentRoute: '/entrepreneur',
      actions: [
        IconButton(
          tooltip: 'Refresh home',
          icon: const Icon(Icons.refresh_rounded),
          onPressed: busy ? null : _load,
        ),
      ],
      body: RefreshIndicator(
        color: SitewiseColors.action,
        onRefresh: _load,
        child: M3Content(
          children: [
            // ── GREETING ────────────────────────────────────────────────
            const M3ScreenHeading(
              eyebrow: 'Your location workspace',
              title: 'Welcome to Sitewise.',
              lead:
                  'Find the right location. Make decisions with better '
                  'evidence.',
            ),

            // ── DISCOVERY FEATURE ──────────────────────────────────────
            M3FeatureCard(
              kicker: 'Business location intelligence',
              title: 'Your next great location starts here.',
              body:
                  'Explore F&B spaces and connect each property to a '
                  'demand assessment.',
              ctaLabel: 'Browse recommendations',
              onCta: () => _open('/entrepreneur/recommendations'),
            ),

            // ── OVERVIEW ───────────────────────────────────────────────
            const M3SectionRow(
              title: 'Your overview',
              overline: 'LIVE WORKSPACE',
            ),
            if (failure != null)
              SitewiseInlineNotice(
                message: failure,
                busy: busy,
                onRetry: _load,
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: M3MetricTile(
                    label: 'Recommendations',
                    value: recommendationsKnown ? '$recommendations' : '—',
                    caption: recommendationsKnown
                        ? 'Matched to your preferences'
                        : 'Could not be loaded',
                    icon: Icons.assignment_outlined,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: M3MetricTile(
                    label: 'Saved spaces',
                    value: savedKnown ? '$saved' : '—',
                    caption: savedKnown
                        ? 'Shortlisted property records'
                        : 'Could not be loaded',
                    icon: Icons.storefront_outlined,
                    teal: true,
                  ),
                ),
              ],
            ),
            M3DataNote(
              text: recommendationsKnown && savedKnown
                  ? 'Live workspace loaded · $recommendations matched '
                        'recommendations, $saved saved spaces and $compared '
                        'properties in comparison. Counts come from the shared '
                        'property repository and your shortlist.'
                  : 'Some workspace counts could not be loaded. Pull down or '
                        'tap Retry to read them again — the figures are not '
                        'shown as zero.',
            ),

            // ── QUICK ACTIONS ──────────────────────────────────────────
            const M3SectionRow(title: 'Quick actions'),
            M3QuickActionRow(
              icon: Icons.assignment_outlined,
              title: 'Demand assessments',
              subtitle: 'Check progress and insights',
              onTap: () => _open('/entrepreneur/assess'),
            ),
            M3QuickActionRow(
              icon: Icons.storefront_outlined,
              title: 'Manage my spaces',
              subtitle: 'Review your shortlisted property records',
              onTap: () => _open('/entrepreneur/spaces'),
            ),

            // ── SECONDARY LINKS ────────────────────────────────────────
            // The prototype ends at Quick actions. These two compact links
            // keep the pre-existing Saved / Compare routes one tap away
            // now that they are no longer bottom-nav tabs.
            const M3SectionRow(title: 'Your shortlist'),
            M3QuickActionRow(
              icon: Icons.bookmark_border_rounded,
              title: 'Saved properties',
              subtitle: savedKnown ? '$saved saved for later' : 'Unavailable',
              onTap: () => _open('/entrepreneur/saved'),
            ),
            M3QuickActionRow(
              icon: Icons.compare_arrows_rounded,
              title: 'Compare properties',
              subtitle: '$compared of ${AppState.maxCompare} selected',
              onTap: () => _open('/entrepreneur/compare'),
            ),
          ],
        ),
      ),
    );
  }
}
