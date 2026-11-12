import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../core/theme/sitewise_theme.dart';

/// Mobile equivalent of the web page's "Location Fit" + "Why this score?"
/// blocks.
///
/// Every number here comes from [PropertyInsightsModel], which the backend
/// fills from the deployed PU artifact and a permutation-SHAP decomposition of
/// that same property's feature vector. Nothing is computed on the client, and
/// nothing is shown when [PropertyInsightsModel.score] is null.
///
/// The five category tabs mirror the web page so the two apps describe the
/// same payload in the same order.
class MobileInsightsPanel extends StatefulWidget {
  final PropertyInsightsModel insights;

  const MobileInsightsPanel({super.key, required this.insights});

  @override
  State<MobileInsightsPanel> createState() => _MobileInsightsPanelState();
}

class _MobileInsightsPanelState extends State<MobileInsightsPanel> {
  bool _showAll = false;
  String? _categoryKey;

  @override
  Widget build(BuildContext context) {
    final insights = widget.insights;
    final score = insights.score;
    final lead = insights.leadCategory;
    final selectedKey = _categoryKey ?? lead?.key;
    final selected = insights.categories
        .where((c) => c.key == selectedKey)
        .cast<InsightCategoryModel?>()
        .firstWhere((c) => true, orElse: () => null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _scoreCard(insights),
        if (score != null && insights.factors.isNotEmpty) ...[
          const SizedBox(height: 18),
          const Text(
            'Why this location received this score',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: SitewiseColors.ink,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'The model compared this location with the sites it learned from.',
            style: TextStyle(fontSize: 11.5, height: 1.4, color: SitewiseColors.muted),
          ),
          const SizedBox(height: 10),
          _factorList(insights),
          if (insights.factors.length > 8)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _showAll = !_showAll),
                child: Text(
                  _showAll
                      ? 'Show fewer factors'
                      : 'Show all ${insights.factors.length} factors',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          const SizedBox(height: 14),
          const Text(
            'By category',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: SitewiseColors.ink,
            ),
          ),
          const SizedBox(height: 8),
          _categoryChips(insights, selectedKey),
          const SizedBox(height: 10),
          if (selected != null) _categoryBody(selected),
        ],
      ],
    );
  }

  // -- score ---------------------------------------------------------------

  Widget _scoreCard(PropertyInsightsModel insights) {
    final score = insights.score;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: SitewiseColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SitewiseColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'LOCATION FIT',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
              color: SitewiseColors.overline,
            ),
          ),
          const SizedBox(height: 6),
          if (score == null) ...[
            const Text(
              'Score not available',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: SitewiseColors.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              insights.reasonMessage ??
                  'This property has no usable location measurements yet.',
              style: const TextStyle(
                fontSize: 12,
                height: 1.45,
                color: SitewiseColors.muted,
              ),
            ),
          ] else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '${score.value}',
                  style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                    height: 1,
                    color: SitewiseColors.ink,
                  ),
                ),
                Text(
                  ' / ${score.scale}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: SitewiseColors.muted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              score.band,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: SitewiseColors.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${score.kindLabel} · ${insights.modelName}'
              '${insights.modelVersion == null ? '' : ' · ${insights.modelVersion}'}',
              style: const TextStyle(fontSize: 10.5, color: SitewiseColors.overline),
            ),
            const SizedBox(height: 8),
            // The caveat is part of the score, not fine print: this index is a
            // research association, never a probability of success.
            Text(
              score.meaning,
              style: const TextStyle(
                fontSize: 10.5,
                height: 1.45,
                color: SitewiseColors.muted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // -- factors -------------------------------------------------------------

  Widget _factorList(PropertyInsightsModel insights) {
    final factors = insights.factors;
    final visible = _showAll ? factors : factors.take(8).toList();
    final maxAbs = visible.fold<double>(
      0,
      (m, f) => f.contribution.abs() > m ? f.contribution.abs() : m,
    );
    return Column(
      children: [
        for (final f in visible) _factorRow(f, maxAbs),
      ],
    );
  }

  Widget _factorRow(InsightFactorModel factor, double maxAbs) {
    final share = maxAbs <= 0 ? 0.0 : factor.contribution.abs() / maxAbs;
    final up = factor.increases;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  factor.label,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.3,
                    color: SitewiseColors.text,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                factor.valueDisplay,
                style: const TextStyle(fontSize: 10.5, color: SitewiseColors.overline),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Row(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final half = constraints.maxWidth / 2;
                    final width = half * share.clamp(0.0, 1.0);
                    return SizedBox(
                      height: 8,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: Container(
                              decoration: BoxDecoration(
                                color: SitewiseColors.geoWash,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                          Positioned(
                            left: up ? half : half - width,
                            width: width,
                            top: 0,
                            bottom: 0,
                            child: Container(
                              decoration: BoxDecoration(
                                color: up ? SitewiseColors.action : SitewiseColors.warning,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                          // Baseline marker: the neutral midpoint.
                          Positioned(
                            left: half - 0.5,
                            top: 0,
                            bottom: 0,
                            width: 1,
                            child: Container(color: SitewiseColors.borderStrong),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 46,
                child: Text(
                  '${up ? '+' : ''}${factor.contribution.toStringAsFixed(3)}',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: up ? SitewiseColors.action : SitewiseColors.warning,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // -- categories ----------------------------------------------------------

  Widget _categoryChips(PropertyInsightsModel insights, String? selectedKey) {
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: insights.categories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final c = insights.categories[index];
          final active = c.key == selectedKey;
          return GestureDetector(
            onTap: () => setState(() => _categoryKey = c.key),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: active ? SitewiseColors.action : SitewiseColors.surface,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: active ? SitewiseColors.action : SitewiseColors.border,
                ),
              ),
              child: Text(
                c.label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: active ? Colors.white : SitewiseColors.text,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _categoryBody(InsightCategoryModel category) {
    if (!category.available) {
      return Text(
        category.note ?? 'No measurements are grouped under this category.',
        style: const TextStyle(fontSize: 11.5, color: SitewiseColors.muted),
      );
    }
    final direction = category.contribution > 0
        ? 'raised'
        : (category.contribution < 0 ? 'lowered' : 'had no net effect on');
    final maxAbs = category.factors.fold<double>(
      0,
      (m, f) => f.contribution.abs() > m ? f.contribution.abs() : m,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          category.question,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: SitewiseColors.ink,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          category.why,
          style: const TextStyle(
            fontSize: 11.5,
            height: 1.45,
            color: SitewiseColors.muted,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Together, the ${category.featureCount} measurements in this category '
          '$direction the score.',
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: SitewiseColors.text,
          ),
        ),
        const SizedBox(height: 6),
        for (final f in category.factors) _factorRow(f, maxAbs),
      ],
    );
  }
}
