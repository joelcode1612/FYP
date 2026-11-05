import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/m3_kit.dart';

/// **Assess** — the third tab of the consolidated five-tab navigation.
///
/// The reference prototype shows stored "assessment records" with a status and
/// a created date. This app has **no persisted assessment entity** (verified
/// against `shared_logic`: `EvaluationReport` is a shape, not a record). Rather
/// than invent records, this screen shows the *real* demand evidence the app
/// can produce today: every property in the repository with its
/// [LocationAnalysis] (suitability, verdict, demand summary, competitor count),
/// generated on demand by `RecommendationService.analysis`.
///
/// Tapping a row opens the existing real evaluation report route. The banner
/// states plainly that no assessment history is stored yet.

class EntrepreneurAssessMobilePage extends StatelessWidget {
  final AppCubit appState;
  const EntrepreneurAssessMobilePage({super.key, required this.appState});

  @override
  Widget build(BuildContext context) {
    return MobileAppShell(
      appState: appState,
      title: 'Assess',
      currentRoute: '/entrepreneur/assess',
      body: M3Content(
        children: [
          const M3ScreenHeading(
            eyebrow: 'Location intelligence',
            title: 'My assessments',
            lead: 'Demand evidence generated on demand from the property '
                'repository and source-linked competition data.',
          ),
          M3PrimaryButton(
            label: 'Start an assessment',
            onTap: () =>
                Navigator.of(context).pushNamed('/entrepreneur/explore'),
          ),
          const SizedBox(height: 8),
          FutureBuilder<List<_Assessment>>(
            future: _load(),
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.only(top: 28),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final items = snap.data ?? const <_Assessment>[];
              if (items.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.only(top: 22),
                  child: M3EmptyState(
                    icon: Icons.assignment_outlined,
                    title: 'No assessments available yet',
                    message: 'Once property records are loaded, demand '
                        'assessments appear here automatically.',
                    actionLabel: 'Browse listings',
                    onAction: () => Navigator.of(context)
                        .pushNamed('/entrepreneur/explore'),
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  M3SectionRow(
                    title: 'Available assessments',
                    overline: '${items.length} READY',
                  ),
                  for (final a in items) ...[
                    _AssessmentCard(
                      item: a,
                      onTap: () => Navigator.of(context).pushNamed(
                        '/entrepreneur/report',
                        arguments: a.property.id,
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              );
            },
          ),
          const M3Banner(
            icon: Icons.info_outline_rounded,
            text: 'Assessments are generated from live location intelligence '
                'and are not stored as historical records yet. Each '
                'assessment opens a full evaluation report for that property.',
          ),
        ],
      ),
    );
  }

  /// Real data only: repository listings + one [LocationAnalysis] per property.
  /// A property whose analysis fails is skipped rather than shown with made-up
  /// evidence.
  static Future<List<_Assessment>> _load() async {
    final properties = await ServiceLocator.properties.listings();
    final out = <_Assessment>[];
    for (final p in properties) {
      try {
        final analysis = await ServiceLocator.recommendations.analysis(p.id);
        out.add(_Assessment(p, analysis));
      } catch (_) {
        // No demand evidence for this property — do not fabricate any.
      }
    }
    return out;
  }
}

class _Assessment {
  final CommercialProperty property;
  final LocationAnalysis analysis;
  const _Assessment(this.property, this.analysis);
}

class _AssessmentCard extends StatelessWidget {
  final _Assessment item;
  final VoidCallback onTap;

  const _AssessmentCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = item.property;
    final a = item.analysis;
    final scoreColor = SitewiseScoreRamp.colorFor(a.suitabilityScore);
    return M3Card(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 43,
                height: 43,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: SitewiseM3.rowIconBg,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(
                  Icons.assignment_outlined,
                  size: 23,
                  color: SitewiseM3.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Archivo',
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: SitewiseM3.rowTitle,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${p.city}, ${p.state} · ${p.propertyType}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Archivo',
                        fontSize: 11,
                        color: SitewiseM3.rowDesc,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.arrow_forward_ios_rounded,
                size: 16,
                color: Color(0xFF4E6E9E),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _ScoreChip(
                label: '${a.suitabilityScore.toStringAsFixed(0)} / 100',
                color: scoreColor,
              ),
              M3Tag(label: a.verdict, positive: a.suitabilityScore >= 60),
              M3Tag(label: '${a.competitorCount} competitors'),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            a.demandSummary.isEmpty
                ? 'Demand evidence is available in the full report.'
                : a.demandSummary,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Archivo',
              fontSize: 11.5,
              height: 1.5,
              color: SitewiseM3.noteText,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScoreChip extends StatelessWidget {
  final String label;
  final Color color;

  const _ScoreChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'Archivo',
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}
