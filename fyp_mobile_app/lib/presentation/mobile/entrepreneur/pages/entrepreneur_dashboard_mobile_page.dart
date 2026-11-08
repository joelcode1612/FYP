import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../application/state/app_view_model.dart';
import '../../../../application/state/entrepreneur_view_model.dart';
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
/// `EntrepreneurViewModel.recommendations` (ranked from the property
/// repository) and `AppViewModel.saved` (the user's shortlist). Labels say what the data is —
/// "Recommendations" and "Saved spaces" — rather than copying the prototype's
/// "Assessments" / "My properties", which would imply entities this app does
/// not have.
///
/// Everything else reachable from the old Home (saved, compare, preferences,
/// recommendations, tours) stays reachable from the Profile and Listing tabs,
/// so this is a layout change only, not a loss of routes.

class EntrepreneurDashboardMobilePage extends StatefulWidget {
  const EntrepreneurDashboardMobilePage({super.key});

  @override
  State<EntrepreneurDashboardMobilePage> createState() =>
      _EntrepreneurDashboardMobilePageState();
}

class _EntrepreneurDashboardMobilePageState
    extends State<EntrepreneurDashboardMobilePage> {
  final EntrepreneurViewModel vm = ServiceLocator.newEntrepreneurViewModel();

  @override
  void initState() {
    super.initState();
    vm.loadRecommendations();
  }

  @override
  void dispose() {
    vm.dispose();
    super.dispose();
  }

  void _open(String route, {Object? arguments}) =>
      Navigator.of(context).pushNamed(route, arguments: arguments);

  @override
  Widget build(BuildContext context) {
    // The page owns [vm] (created in initState, disposed below), so the
    // provider exposes it by value and never disposes it twice.
    return ChangeNotifierProvider<EntrepreneurViewModel>.value(
      value: vm,
      child: Consumer<AppViewModel>(
        builder: (ctx, appState, _) => Consumer<EntrepreneurViewModel>(
          builder: (ctx, model, _) {
            final recommendations = model.recommendations.length;
            final saved = appState.saved.length;
            final compared = appState.compared.length;

            return MobileAppShell(
              title: 'Home',
              currentRoute: '/entrepreneur',
              body: M3Content(
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
                    text:
                        'Live workspace loaded · $recommendations matched '
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
      ),
    );
  }
}
