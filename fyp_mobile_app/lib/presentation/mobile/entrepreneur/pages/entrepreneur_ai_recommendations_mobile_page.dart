import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:shared_logic/shared_logic.dart' hide RecommendationExplanation;
import '../../../../application/personalised_recommendations_providers.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../widgets/m3_kit.dart';

/// Entrepreneur **AI recommendations** (personalised Layer 2/3 pipeline).
///
/// Distinct from the requirement-fit Recommendations tab: this screen ranks
/// the research catalogue against the entrepreneur's SAVED preferences via
/// `POST /api/v1/recommendations/generate`, retrieves the durable latest
/// batch via `GET .../me/generated`, and presents the two explanation layers
/// strictly separated:
///
/// * the rule engine's preference reasons / cautions / component details;
/// * the PU research model's Permutation SHAP payload when the exact
///   47-feature vector resolved — with an explicit fallback line when it
///   did not (absence is a first-class state, never a silent zero).
///
/// Navigation honours the verified `listing_ref` contract: the canonical id
/// opens assessment and research surfaces; the bigint listing id is used for
/// the detail page only when the backend says `detail_available` (approved +
/// published); otherwise the note is shown instead of a dead link.
class EntrepreneurAiRecommendationsMobilePage extends ConsumerStatefulWidget {
  const EntrepreneurAiRecommendationsMobilePage({super.key});

  @override
  ConsumerState<EntrepreneurAiRecommendationsMobilePage> createState() =>
      _EntrepreneurAiRecommendationsMobilePageState();
}

class _EntrepreneurAiRecommendationsMobilePageState
    extends ConsumerState<EntrepreneurAiRecommendationsMobilePage> {
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _started) return;
      _started = true;
      ref.read(personalisedBatchProvider.notifier).loadExisting();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(personalisedBatchProvider);
    final notifier = ref.read(personalisedBatchProvider.notifier);

    return Scaffold(
      backgroundColor: SitewiseColors.background,
      appBar: AppBar(
        title: const Text('AI recommendations'),
        backgroundColor: SitewiseColors.surface,
        foregroundColor: SitewiseColors.ink,
      ),
      body: _Body(state: state, notifier: notifier),
    );
  }
}

class _Body extends ConsumerWidget {
  final PersonalisedBatchState state;
  final PersonalisedBatchNotifier notifier;

  const _Body({required this.state, required this.notifier});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    }
    if (state.status == PersonalisedBatchStatus.unavailable ||
        state.status == PersonalisedBatchStatus.error) {
      return _ErrorView(
        message: state.error ?? 'The recommendation service is unavailable.',
        onRetry: () => notifier.loadExisting(),
        onGenerate: () => notifier.generate(),
        canGenerate: state.status == PersonalisedBatchStatus.error,
      );
    }
    final batch = state.batch;
    if (batch == null || batch.results.isEmpty) {
      return _EmptyView(onGenerate: () => notifier.generate());
    }
    return RefreshIndicator(
      color: SitewiseColors.action,
      onRefresh: () => notifier.generate(),
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        itemCount: batch.results.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _BatchHeader(
              count: batch.resultCount,
              generatedAt: batch.generatedAt,
              reused: state.reusedExistingBatch,
            );
          }
          final item = batch.results[index - 1];
          return _AiRecommendationCard(item: item);
        },
      ),
    );
  }
}

class _BatchHeader extends StatelessWidget {
  final int count;
  final String? generatedAt;
  final bool reused;

  const _BatchHeader({
    required this.count,
    this.generatedAt,
    required this.reused,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$count personalised ${count == 1 ? 'match' : 'matches'}',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: SitewiseColors.ink,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            reused
                ? 'Your latest saved matches — inputs unchanged, nothing recomputed.'
                : 'Ranked from your saved requirements. Preference fit and the '
                    'PU research index are reported separately.',
            style: const TextStyle(fontSize: 11, color: SitewiseColors.muted),
          ),
        ],
      ),
    );
  }
}

class _AiRecommendationCard extends ConsumerWidget {
  final GeneratedRecommendation item;

  const _AiRecommendationCard({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prop = item.property;
    final prefPct = item.preferenceMatchScore == null
        ? null
        : (item.preferenceMatchScore! * 100);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: SitewiseColors.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _openExplanation(context, item.resultId),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: SitewiseColors.border),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (item.rank != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xCC0B0F19),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Text(
                          '#${item.rank}',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    const Spacer(),
                    Text(
                      item.finalScore.toStringAsFixed(3),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: SitewiseColors.ink,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  prop.title.isEmpty ? prop.propertyId : prop.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                    height: 1.3,
                    color: SitewiseColors.ink,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    if (prop.city.isNotEmpty) prop.city,
                    if (prop.state.isNotEmpty) prop.state,
                    if (prop.propertyType.isNotEmpty) prop.propertyType,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: SitewiseColors.muted,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _ScoreCell(
                      label: 'Preference fit',
                      value: prefPct == null
                          ? 'unknown'
                          : '${prefPct.toStringAsFixed(0)}%',
                    ),
                    const SizedBox(width: 18),
                    _ScoreCell(
                      label: 'PU index',
                      value: (item.puAssociationScore * 100).toStringAsFixed(1),
                    ),
                    const Spacer(),
                    Text(
                      'Final ${item.finalScore.toStringAsFixed(3)}',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: SitewiseColors.muted,
                      ),
                    ),
                  ],
                ),
                if (item.preferenceReasons.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  for (final reason in item.preferenceReasons.take(2))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.check_rounded,
                              size: 13, color: SitewiseColors.success),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              reason,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                height: 1.35,
                                color: SitewiseColors.ink,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                if (item.cautions.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline_rounded,
                          size: 13, color: SitewiseColors.muted),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          item.cautions.first,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 10.5,
                            height: 1.35,
                            color: SitewiseColors.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _openExplanation(context, item.resultId),
                        icon: const Icon(Icons.insights_rounded, size: 16),
                        label: const Text('Why recommended'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: SitewiseColors.action,
                          side: const BorderSide(
                            color: SitewiseColors.borderStrong,
                          ),
                          textStyle: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _AssessButton(item: item),
                  ],
                ),
                const SizedBox(height: 8),
                // Opens the research insights for this unit by its CANONICAL
                // id (EP-/MD-). The numeric listing id addresses a different
                // record and must never be passed here.
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pushNamed(
                      '/entrepreneur/property-detail',
                      arguments: item.propertyId,
                    ),
                    icon: const Icon(Icons.place_outlined, size: 16),
                    label: const Text('View property insights'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: SitewiseColors.ink,
                      side: const BorderSide(
                        color: SitewiseColors.borderStrong,
                      ),
                      textStyle: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openExplanation(BuildContext context, String resultId) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: SitewiseColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _ExplanationSheet(resultId: resultId),
    );
  }
}

class _AssessButton extends StatelessWidget {
  final GeneratedRecommendation item;

  const _AssessButton({required this.item});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () {
        Navigator.of(context).pushNamed(
          '/entrepreneur/assessment-setup',
          arguments: item.propertyId,
        );
      },
      icon: const Icon(Icons.assignment_outlined, size: 16),
      label: const Text('Assess'),
      style: OutlinedButton.styleFrom(
        foregroundColor: SitewiseColors.action,
        side: const BorderSide(color: SitewiseColors.borderStrong),
        textStyle: const TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _ExplanationSheet extends ConsumerWidget {
  final String resultId;

  const _ExplanationSheet({required this.resultId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(explanationProvider(resultId));
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .82,
      maxChildSize: .95,
      minChildSize: .5,
      builder: (context, controller) => async.when(
        loading: () => const Center(
          child: Padding(
            padding: EdgeInsets.all(40),
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
        error: (err, _) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Could not load the explanation',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: SitewiseColors.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '$err',
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: SitewiseColors.muted,
              ),
            ),
          ],
        ),
        data: (explanation) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 26),
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: SitewiseColors.borderStrong,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Why this was recommended',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: SitewiseColors.ink,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              explanation.propertyId,
              style: const TextStyle(
                fontSize: 12,
                color: SitewiseColors.muted,
              ),
            ),
            const SizedBox(height: 14),
            const _SectionLabel('Preference match (rule engine)'),
            if (explanation.preferenceReasons.isEmpty)
              const Text(
                'No preference components were scorable for this match — '
                'unknown inputs are excluded, never treated as zero.',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.45,
                  color: SitewiseColors.muted,
                ),
              )
            else
              for (final reason in explanation.preferenceReasons)
                _Bullet(text: reason, color: SitewiseColors.ink),
            if (explanation.cautions.isNotEmpty) ...[
              const SizedBox(height: 10),
              const _SectionLabel('Cautions'),
              for (final caution in explanation.cautions.take(4))
                _Bullet(text: caution, color: SitewiseColors.muted),
            ],
            const SizedBox(height: 12),
            const _SectionLabel('Component breakdown'),
            for (final entry in explanation.components.entries)
              _ComponentRow(name: entry.key, detail: entry.value),
            const SizedBox(height: 16),
            const _SectionLabel('PU research model (SHAP)'),
            if (explanation.shap != null &&
                explanation.shapStatus.available) ...[
              Text(
                'Permutation SHAP on the PU research association score. '
                'Baseline + contributions reconstruct the score '
                '(verified server-side, error < 1e-6). Research index only — '
                'not a success probability.',
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.45,
                  color: SitewiseColors.muted,
                ),
              ),
              const SizedBox(height: 8),
              for (final feature
                  in explanation.shap!.topPositive.take(3))
                _ShapRow(
                  label: explanation.labelFor(feature.feature),
                  contribution: feature.contribution,
                  positive: true,
                ),
              for (final feature
                  in explanation.shap!.topNegative.take(3))
                _ShapRow(
                  label: explanation.labelFor(feature.feature),
                  contribution: feature.contribution,
                  positive: false,
                ),
            ] else ...[
              const Text(
                'SHAP is unavailable for this property.',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: SitewiseColors.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                explanation.shapStatus.reason ??
                    'The exact 47-feature research vector could not be '
                        'resolved, so no feature-level explanation is shown. '
                        'Nothing is invented to fill the gap.',
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.45,
                  color: SitewiseColors.muted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 9.5,
        fontWeight: FontWeight.w800,
        letterSpacing: .7,
        color: SitewiseColors.muted,
      ),
    ),
  );
}

class _Bullet extends StatelessWidget {
  final String text;
  final Color color;

  const _Bullet({required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.45,
              color: color,
            ),
          ),
        ),
      ],
    ),
  );
}

class _ComponentRow extends StatelessWidget {
  final String name;
  final ComponentDetail detail;

  const _ComponentRow({required this.name, required this.detail});

  @override
  Widget build(BuildContext context) {
    final value = detail.value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Text(
              name.replaceAll('_', ' '),
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: SitewiseColors.ink,
              ),
            ),
          ),
          SizedBox(
            width: 42,
            child: Text(
              value == null ? 'n/a' : value.toStringAsFixed(2),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: value == null
                    ? SitewiseColors.muted
                    : SitewiseColors.action,
              ),
            ),
          ),
          Expanded(
            child: Text(
              detail.status == 'unknown'
                  ? detail.caution ?? detail.reason
                  : detail.reason,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10,
                height: 1.35,
                color: SitewiseColors.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShapRow extends StatelessWidget {
  /// Plain-English name supplied by the backend, so the sheet never shows a
  /// raw model column such as `pop_500m`.
  final String label;
  final double contribution;
  final bool positive;

  const _ShapRow({
    required this.label,
    required this.contribution,
    required this.positive,
  });

  @override
  Widget build(BuildContext context) {
    final color = positive ? SitewiseColors.success : SitewiseColors.danger;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(
            positive ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                color: SitewiseColors.ink,
              ),
            ),
          ),
          Text(
            '${contribution >= 0 ? '+' : ''}${contribution.toStringAsFixed(4)}',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScoreCell extends StatelessWidget {
  final String label;
  final String value;

  const _ScoreCell({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 8.5,
          fontWeight: FontWeight.w800,
          letterSpacing: .6,
          color: SitewiseColors.muted,
        ),
      ),
      Text(
        value,
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w800,
          color: SitewiseColors.ink,
        ),
      ),
    ],
  );
}

class _EmptyView extends StatelessWidget {
  final VoidCallback onGenerate;

  const _EmptyView({required this.onGenerate});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.auto_awesome_outlined,
              size: 34, color: SitewiseColors.muted),
          const SizedBox(height: 10),
          const Text(
            'No personalised matches yet',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: SitewiseColors.ink,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Generate a ranked batch from your saved requirements. Results '
            'are stored for your account and stay available offline of this '
            'session.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.5,
              color: SitewiseColors.muted,
            ),
          ),
          const SizedBox(height: 14),
          M3PrimaryButton(label: 'Generate recommendations', onTap: onGenerate),
        ],
      ),
    ),
  );
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final VoidCallback onGenerate;
  final bool canGenerate;

  const _ErrorView({
    required this.message,
    required this.onRetry,
    required this.onGenerate,
    required this.canGenerate,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded, size: 32, color: SitewiseColors.muted),
          const SizedBox(height: 10),
          const Text(
            'Could not load AI recommendations',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: SitewiseColors.ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 11.5,
              height: 1.45,
              color: SitewiseColors.muted,
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 17),
            label: const Text('Retry'),
          ),
          if (canGenerate) ...[
            const SizedBox(height: 8),
            M3PrimaryButton(label: 'Generate a batch', onTap: onGenerate),
          ],
        ],
      ),
    ),
  );
}
