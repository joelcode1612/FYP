import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/core/routing/app_routes.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/shared/presentation/layouts/entrepreneur_tab_scope.dart';
import 'package:fyp/shared/presentation/layouts/mobile_app_shell.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_inline_notice.dart';
import 'package:fyp/shared/presentation/components/m3_kit.dart';

/// Shows the entrepreneur's saved and comparison selections. Home does not
/// run the legacy demo recommendation use case; the Recommendations tab owns
/// live recommendation search and its applied filters.
class EntrepreneurDashboardMobilePage extends ConsumerStatefulWidget {
  const EntrepreneurDashboardMobilePage({super.key});

  @override
  ConsumerState<EntrepreneurDashboardMobilePage> createState() =>
      _EntrepreneurDashboardMobilePageState();
}

class _EntrepreneurDashboardMobilePageState
    extends ConsumerState<EntrepreneurDashboardMobilePage> {
  bool _savedReadStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    if (!_savedReadStarted && mounted) {
      setState(() => _savedReadStarted = true);
    }
    await ref.read(appNotifierProvider.notifier).loadSaved();
  }

  void _open(String route, {Object? arguments}) =>
      Navigator.of(context).pushNamed(route, arguments: arguments);

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appNotifierProvider);
    final saved = appState.saved.length;
    final compared = appState.compared.length;
    final busy = !_savedReadStarted || appState.savedLoading;
    final failure = appState.savedError;
    final savedKnown = !busy && failure == null;

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
            const M3ScreenHeading(
              eyebrow: 'Your location workspace',
              title: 'Welcome to Sitewise.',
              lead: 'Find the right location. Make decisions with better '
                  'evidence.',
            ),
            M3FeatureCard(
              kicker: 'Business location intelligence',
              title: 'Your next great location starts here.',
              body: 'Explore F&B spaces and connect each property to a '
                  'demand assessment.',
              ctaLabel: 'Browse recommendations',
              onCta: () => _open('/entrepreneur/recommendations'),
            ),
            const M3SectionRow(
              title: 'Your overview',
              overline: 'MY WORKSPACE',
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
                    label: 'Favourites',
                    value: savedKnown ? '$saved' : '—',
                    caption: busy
                        ? 'Loading saved properties…'
                        : savedKnown
                            ? 'Properties you saved'
                            : 'Could not be loaded',
                    icon: Icons.bookmark_border_rounded,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: M3MetricTile(
                    label: 'Comparison',
                    value: '$compared/${AppState.maxCompare}',
                    caption: 'Properties selected',
                    icon: Icons.compare_arrows_rounded,
                    teal: true,
                  ),
                ),
              ],
            ),
            const M3DataNote(
              text: 'Save properties and compare up to three locations '
                  'before making your decision.',
            ),
            const M3SectionRow(title: 'Quick actions'),
            M3QuickActionRow(
              icon: Icons.assignment_outlined,
              title: 'Demand assessments',
              subtitle: 'Check progress and insights',
              onTap: () =>
                  EntrepreneurTabScope.open(context, AppRoutes.assessmentHome),
            ),
            // PROJECT1 research-question review. Home has no selected M2
            // assessment and no confirmed objective, so it cannot supply the
            // persisted ids a ResearchQuestionTarget requires. Pushing the
            // route without them produced a screen that could never prepare;
            // state the reason here instead of offering a dead action.
            const M3DataNote(
              text:
                  'Research questions open from a confirmed objective in your '
                  'M2 assessment. Home has no assessment selected, so it does '
                  'not attach an objective to that screen.',
            ),
            M3QuickActionRow(
              icon: Icons.bookmark_border_rounded,
              title: 'My favourites',
              subtitle: 'Open the properties you saved',
              onTap: () =>
                  EntrepreneurTabScope.open(context, '/entrepreneur/favourites'),
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
