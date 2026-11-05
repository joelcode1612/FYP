import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/service_locator.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/m3_kit.dart';

/// Mobile entrepreneur Home — the first screen after sign-in.
///
/// Follows `Sitewise_Mobile_Material3_Mock_Data.html`'s `home()` layout:
/// greeting → light-blue discovery feature → "Your overview" metric pair →
/// data-provenance note → "Quick actions" rows. The five-tab shell, brand
/// lockup header and pill-indicator bottom bar come from [MobileAppShell].
///
/// **No invented records.** Both overview tiles are wired to real state:
/// `EntrepreneurCubit.recommendations` (ranked from the property repository)
/// and `AppCubit.saved` (the user's shortlist). Labels say what the data is —
/// "Recommendations" and "Saved spaces" — rather than copying the prototype's
/// "Assessments" / "My properties", which would imply entities this app does
/// not have.
///
/// Everything else reachable from the old Home (saved, compare, preferences,
/// recommendations, tours) stays reachable from the Profile and Listing tabs,
/// so this is a layout change only, not a loss of routes.

class EntrepreneurDashboardMobilePage extends StatefulWidget {
  final AppCubit appState;
  const EntrepreneurDashboardMobilePage({super.key, required this.appState});

  @override
  State<EntrepreneurDashboardMobilePage> createState() =>
      _EntrepreneurDashboardMobilePageState();
}

class _EntrepreneurDashboardMobilePageState
    extends State<EntrepreneurDashboardMobilePage> {
  final vm = ServiceLocator.newEntrepreneurCubit();

  @override
  void initState() {
    super.initState();
    vm.loadRecommendations();
  }

  @override
  void dispose() {
    unawaited(vm.close());
    super.dispose();
  }

  void _open(String route, {Object? arguments}) =>
      Navigator.of(context).pushNamed(route, arguments: arguments);

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AppCubit, AppState>(
      bloc: widget.appState,
      builder: (ctx, _) => BlocBuilder<EntrepreneurCubit, EntrepreneurState>(
        bloc: vm,
        builder: (ctx, _) {
          final recommendations = vm.recommendations.length;
          final saved = widget.appState.saved.length;
          final compared = widget.appState.compared.length;

          return MobileAppShell(
            appState: widget.appState,
            title: 'Home',
            currentRoute: '/entrepreneur',
            body: M3Content(
              children: [
                // ── GREETING ────────────────────────────────────────────────
                const M3ScreenHeading(
                  eyebrow: 'Your location workspace',
                  title: 'Welcome to Sitewise.',
                  lead: 'Find the right location. Make decisions with better '
                      'evidence.',
                ),

                // ── DISCOVERY FEATURE ──────────────────────────────────────
                M3FeatureCard(
                  kicker: 'Business location intelligence',
                  title: 'Your next great location starts here.',
                  body: 'Explore F&B spaces and connect each property to a '
                      'demand assessment.',
                  ctaLabel: 'Explore listings',
                  onCta: () => _open('/entrepreneur/explore'),
                ),

                // ── OVERVIEW ───────────────────────────────────────────────
                const M3SectionRow(
                  title: 'Your overview',
                  overline: 'LIVE WORKSPACE',
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: M3MetricTile(
                        label: 'Recommendations',
                        value: '$recommendations',
                        caption: 'Matched to your preferences',
                        icon: Icons.assignment_outlined,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: M3MetricTile(
                        label: 'Saved spaces',
                        value: '$saved',
                        caption: 'Shortlisted property records',
                        icon: Icons.storefront_outlined,
                        teal: true,
                      ),
                    ),
                  ],
                ),
                M3DataNote(
                  text: 'Live workspace loaded · $recommendations matched '
                      'recommendations, $saved saved spaces and $compared '
                      'properties in comparison. Counts come from the shared '
                      'property repository and your shortlist.',
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
                  subtitle: '$saved saved for later',
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
          );
        },
      ),
    );
  }
}
