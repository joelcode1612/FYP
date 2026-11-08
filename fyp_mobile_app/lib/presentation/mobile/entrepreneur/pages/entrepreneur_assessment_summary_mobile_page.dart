import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/assessment_session.dart';
import '../../../../application/services/service_locator.dart';
import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_evidence_score.dart';
import '../../../shared/widgets/sitewise_factor_row.dart';
import '../../../shared/widgets/sitewise_secondary_button.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/assessment_stepper.dart';
import '../../widgets/m3_kit.dart';

/// **ASSESSMENT / STEP 3 OF 3** — "Assessment summary".
///
/// Option A summary: the linked property, the business inputs that were
/// entered, and the demand analysis **as the repository actually provides
/// it**. Nothing is hardcoded here — no suitability scores, demand
/// percentages or competitor counts: when `RecommendationService.analysis`
/// returns real data it is rendered, and when it fails the card says
/// "Unavailable" with the honest copy instead of inventing a result.
///
/// Save writes to the session store only. The snackbar and the hub both say
/// so; this screen never presents the save as production persistence.

class EntrepreneurAssessmentSummaryMobilePage extends StatelessWidget {
  const EntrepreneurAssessmentSummaryMobilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final draft = ServiceLocator.assessmentSession.draft;
    return MobileAppShell(
      title: 'Summary',
      currentRoute: '/entrepreneur/assess',
      body: draft == null ? _noDraft(context) : _summary(context, draft),
    );
  }

  Widget _noDraft(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        SitewiseM3.gutter,
        20,
        SitewiseM3.gutter,
        122,
      ),
      children: [
        M3EmptyState(
          icon: Icons.assignment_outlined,
          title: 'No assessment in progress',
          message:
              'Start an assessment from a listing or the Assess tab '
              'to reach its summary.',
          actionLabel: 'Your assessments',
          onAction: () => Navigator.of(context).pushNamedAndRemoveUntil(
            '/entrepreneur/assess',
            (route) => route.isFirst,
          ),
        ),
      ],
    );
  }

  Widget _summary(BuildContext context, AssessmentDraft draft) {
    final p = draft.property;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        SitewiseM3.gutter,
        20,
        SitewiseM3.gutter,
        122,
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => Navigator.of(context).pushNamedAndRemoveUntil(
              '/entrepreneur/assess',
              (route) => route.isFirst,
            ),
            icon: const Icon(Icons.arrow_back_rounded, size: 16),
            label: const Text('Assessments'),
            style: TextButton.styleFrom(
              foregroundColor: SitewiseM3.muted,
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              textStyle: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text('ASSESSMENT / STEP 3 OF 3', style: SitewiseM3Type.eyebrow),
        const SizedBox(height: 7),
        Semantics(
          header: true,
          child: Text('Assessment summary', style: SitewiseM3Type.h1),
        ),
        const SizedBox(height: 8),
        Text(
          'A traceable starting point for your location decision.',
          style: SitewiseM3Type.lead,
        ),
        const SizedBox(height: 18),
        const AssessmentStepper(step: 2),
        const SizedBox(height: 18),
        M3Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                p.title,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: SitewiseM3.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${p.city}, ${p.state} · ${p.rentalDisplay} / month',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 11.5,
                  color: SitewiseM3.muted,
                ),
              ),
              const Divider(height: 24, color: SitewiseM3.divider),
              const Row(
                children: [
                  Icon(Icons.check_rounded, size: 15, color: SitewiseM3.green),
                  SizedBox(width: 7),
                  Text(
                    'Business inputs entered',
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: SitewiseM3.ink,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${draft.concept} · ${draft.audience} · '
                'Budget RM ${draft.budgetRm?.toStringAsFixed(0)}',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 11.5,
                  height: 1.5,
                  color: SitewiseM3.rowDesc,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _DemandAnalysisCard(propertyId: p.id),
        const SizedBox(height: 12),
        const M3Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Next checks',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: SitewiseM3.ink,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'Confirm F&B licensing, premises facilities, landlord terms '
                'and the geographic coverage of any linked survey before '
                'deciding on this property.',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 11.5,
                  height: 1.55,
                  color: SitewiseM3.rowDesc,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        M3PrimaryButton(
          label: draft.saved
              ? 'Saved for this session ✓'
              : 'Save this assessment',
          icon: draft.saved
              ? Icons.check_rounded
              : Icons.bookmark_border_rounded,
          onTap: draft.saved
              ? () => Navigator.of(context).pushNamedAndRemoveUntil(
                  '/entrepreneur/assess',
                  (route) => route.isFirst,
                )
              : () => _save(context),
        ),
        const SizedBox(height: 9),
        SitewiseSecondaryButton(
          label: 'Edit business inputs',
          icon: Icons.edit_outlined,
          onPressed: () => Navigator.of(context).pushNamedAndRemoveUntil(
            '/entrepreneur/assessment-setup',
            (route) => route.isFirst,
          ),
        ),
      ],
    );
  }

  /// Session-only save, stated as such at the moment it happens.
  void _save(BuildContext context) {
    ServiceLocator.assessmentSession.markSaved();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Saved for this session. Nothing is stored permanently yet.',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil('/entrepreneur/assess', (route) => route.isFirst);
  }
}

/// Demand analysis exactly as the repository provides it: real fields when
/// the analysis resolves, an explicit Unavailable card when it does not.
class _DemandAnalysisCard extends StatelessWidget {
  final String propertyId;

  const _DemandAnalysisCard({required this.propertyId});

  Future<LocationAnalysis?> _load() async {
    try {
      return await ServiceLocator.recommendations.analysis(propertyId);
    } catch (_) {
      // No demand evidence for this property — the UI shows Unavailable.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LocationAnalysis?>(
      future: _load(),
      builder: (context, snap) {
        final a = snap.connectionState == ConnectionState.done
            ? snap.data
            : null;
        final pending = snap.connectionState != ConnectionState.done;
        return M3Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Demand analysis',
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: SitewiseM3.ink,
                      ),
                    ),
                  ),
                  _statusTag(
                    pending
                        ? 'Checking'
                        : a == null
                        ? 'Unavailable'
                        : 'Sample data',
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (pending)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (a == null) ...[
                Text(
                  'No verified resident-survey summary or deployed '
                  'suitability model is connected. No recommendation score '
                  'is shown until analysis is available.',
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 11.5,
                    height: 1.55,
                    color: SitewiseM3.rowDesc,
                  ),
                ),
              ] else ...[
                SitewiseEvidenceScore(score: a.suitabilityScore),
                const SizedBox(height: 12),
                Text(
                  a.demandSummary,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 11.5,
                    height: 1.55,
                    color: SitewiseM3.rowDesc,
                  ),
                ),
                const SizedBox(height: 10),
                M3Tag(label: '${a.competitorCount} competitors'),
                const SizedBox(height: 6),
                for (final f in a.factors) SitewiseFactorRow(factor: f),
                if (AppConfig.usesDemoData) ...[
                  const SizedBox(height: 6),
                  const M3DataNote(
                    text:
                        'Analysis is generated from sample data in this '
                        'build. It is not a live model.',
                  ),
                ],
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _statusTag(String label) {
    final unavailable = label == 'Unavailable';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: unavailable ? SitewiseM3.amberWash : SitewiseM3.quiet,
        borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
        border: Border.all(
          color: unavailable
              ? SitewiseM3.amber.withValues(alpha: 0.35)
              : SitewiseM3.line,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: unavailable ? SitewiseM3.amber : SitewiseM3.muted,
        ),
      ),
    );
  }
}
