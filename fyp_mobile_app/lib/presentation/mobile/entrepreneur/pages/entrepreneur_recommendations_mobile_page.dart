import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_empty_state.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/mobile_property_card.dart';
import '../../widgets/mobile_section_header.dart';
import '../../widgets/mobile_skeleton.dart';

/// Mobile recommendations: "locations recommended for your business", each with
/// a plain-language reason. No model internals are shown.

class EntrepreneurRecommendationsMobilePage extends ConsumerStatefulWidget {
  const EntrepreneurRecommendationsMobilePage({super.key});

  @override
  ConsumerState<EntrepreneurRecommendationsMobilePage> createState() =>
      _EntrepreneurRecommendationsMobilePageState();
}

class _EntrepreneurRecommendationsMobilePageState
    extends ConsumerState<EntrepreneurRecommendationsMobilePage> {
  @override
  void initState() {
    super.initState();
    // The load publishes synchronously; a kick from initState would modify
    // the provider while the widget tree is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(entrepreneurNotifierProvider.notifier).loadRecommendations();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Two slices, two rebuilds: the ranked list repaints on entrepreneur
    // state, the card toggles on the app-wide saved/compare sets.
    final appState = ref.watch(appNotifierProvider);
    final model = ref.watch(entrepreneurNotifierProvider);
    return MobileAppShell(
            title: 'Recommendations',
            currentRoute: '/entrepreneur/recommendations',
            body: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                MobileSectionHeader(
                  title: 'Recommended for your business',
                  subtitle:
                      '${model.preferences.businessType} · up to RM${model.preferences.maxBudgetRm.toStringAsFixed(0)}',
                  actionLabel: 'Preferences',
                  onAction: () => Navigator.of(
                    context,
                  ).pushNamed('/entrepreneur/preferences'),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Ranked by how well each location fits your concept, budget and '
                  'target customers.',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.45,
                    color: SitewiseColors.muted,
                  ),
                ),
                const SizedBox(height: 16),
                if (model.loading)
                  const MobilePropertyListSkeleton(
                    padding: EdgeInsets.zero,
                    count: 3,
                  )
                else if (model.recommendations.isEmpty)
                  SitewiseEmptyState(
                    icon: Icons.auto_awesome_outlined,
                    title: 'No matches yet',
                    message:
                        'Loosen your budget or size filters to see more shoplots.',
                    actionLabel: 'Edit preferences',
                    onAction: () => Navigator.of(
                      context,
                    ).pushNamed('/entrepreneur/preferences'),
                  )
                else
                  for (var i = 0; i < model.recommendations.length; i++) ...[
                    MobilePropertyCard(
                      property: model.recommendations[i].property,
                      rankBanner:
                          '${i + 1}. ${model.recommendations[i].reason}',
                      saved: appState.saved.contains(
                        model.recommendations[i].property.id,
                      ),
                      onToggleSaved: () => ref
                          .read(appNotifierProvider.notifier)
                          .toggleSaved(model.recommendations[i].property.id),
                      compared: appState.compared.contains(
                        model.recommendations[i].property.id,
                      ),
                      onToggleCompare: () => ref
                          .read(appNotifierProvider.notifier)
                          .toggleCompared(model.recommendations[i].property.id),
                      onTap: () => Navigator.of(context).pushNamed(
                        '/entrepreneur/property-detail',
                        arguments: model.recommendations[i].property.id,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _WhyItFits(reasons: model.recommendations[i].whyRecommended),
                    const SizedBox(height: 18),
                  ],
              ],
            ),
    );
  }
}

/// Plain-language "why this fits" chips — the explainability surface.
class _WhyItFits extends StatelessWidget {
  final List<String> reasons;

  const _WhyItFits({required this.reasons});

  @override
  Widget build(BuildContext context) {
    if (reasons.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: SitewiseColors.geoWash,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: SitewiseColors.geoBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Why this fits',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: SitewiseColors.ink,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final reason in reasons)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: SitewiseColors.surface,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: SitewiseColors.geoBorder),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.check_circle_rounded,
                        size: 12,
                        color: SitewiseColors.success,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        reason,
                        style: const TextStyle(
                          fontSize: 11,
                          color: SitewiseColors.ink,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
