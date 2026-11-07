import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/assessment_stepper.dart';
import '../../widgets/m3_kit.dart';

/// **ASSESSMENT / STEP 2 OF 3** — "Evidence matching".
///
/// Option A evidence screen. The backend owns study-area determination,
/// campaign matching, freshness, geographic relevance and data quality — and
/// none of that pipeline exists in this app yet, so this screen states exactly
/// that rather than simulating matches. What it *can* truthfully show: the
/// linked property (real repository record) and the study area as listed
/// listing data, clearly separated from the unverified survey evidence.
///
/// No campaign states are invented: the only supported state today is
/// "requires backend check" and the UI says so.

class EntrepreneurEvidenceMobilePage extends StatelessWidget {
  final AppCubit appState;
  const EntrepreneurEvidenceMobilePage({super.key, required this.appState});

  @override
  Widget build(BuildContext context) {
    final draft = ServiceLocator.assessmentSession.draft;
    return MobileAppShell(
      appState: appState,
      title: 'Evidence',
      currentRoute: '/entrepreneur/assess',
      body: draft == null
          ? _noDraft(context)
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                SitewiseM3.gutter,
                20,
                SitewiseM3.gutter,
                122,
              ),
              children: [
                const FlowBackLink(label: 'Business details'),
                const SizedBox(height: 14),
                Text('ASSESSMENT / STEP 2 OF 3', style: SitewiseM3Type.eyebrow),
                const SizedBox(height: 7),
                Semantics(
                  header: true,
                  child: Text('Evidence matching', style: SitewiseM3Type.h1),
                ),
                const SizedBox(height: 8),
                Text(
                  'The live system would locate the correct study-area '
                  'campaign and evaluate its relevance.',
                  style: SitewiseM3Type.lead,
                ),
                const SizedBox(height: 18),
                const AssessmentStepper(step: 1),
                const SizedBox(height: 18),
                M3Card(
                  child: Column(
                    children: [
                      _TimelineRow(
                        done: true,
                        title: 'Property linked',
                        body: '${draft.property.title} · ${draft.property.id}',
                      ),
                      const Divider(height: 22, color: SitewiseM3.divider),
                      _TimelineRow(
                        done: true,
                        title: 'Study area (listing data)',
                        body:
                            '${draft.property.address}, ${draft.property.city}',
                      ),
                      const Divider(height: 22, color: SitewiseM3.divider),
                      const _TimelineRow(
                        done: false,
                        title: 'Survey evidence requires backend check',
                        body: 'No campaign matching or respondent validation '
                            'is connected yet.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                M3Card(
                  padding: const EdgeInsets.all(13),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Local resident survey',
                              style: TextStyle(
                                fontFamily: kFontFamily,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800,
                                color: SitewiseM3.rowTitle,
                              ),
                            ),
                            SizedBox(height: 3),
                            Text(
                              'Demo state · unavailable',
                              style: TextStyle(
                                fontFamily: kFontFamily,
                                fontSize: 11,
                                color: SitewiseM3.rowDesc,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const _AmberTag(label: 'Not verified'),
                    ],
                  ),
                ),
                const M3Banner(
                  icon: Icons.error_outline_rounded,
                  text: 'No live population, competition or demand evidence '
                      'has been calculated in this step.',
                ),
                const SizedBox(height: 18),
                M3PrimaryButton(
                  label: 'View assessment summary',
                  onTap: () =>
                      Navigator.of(context).pushNamed(
                        '/entrepreneur/assessment-summary',
                      ),
                ),
              ],
            ),
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
          message: 'Start an assessment from a listing or the Assess tab '
              'before matching evidence.',
          actionLabel: 'Your assessments',
          onAction: () => Navigator.of(context).pushNamedAndRemoveUntil(
            '/entrepreneur/assess',
            (route) => route.isFirst,
          ),
        ),
      ],
    );
  }
}

/// One `timrow`: status dot + strong title + explanatory line.
class _TimelineRow extends StatelessWidget {
  final bool done;
  final String title;
  final String body;

  const _TimelineRow({
    required this.done,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: done ? SitewiseM3.greenWash : SitewiseM3.quiet,
            shape: BoxShape.circle,
          ),
          child: Icon(
            done ? Icons.check_rounded : Icons.schedule_rounded,
            size: 15,
            color: done ? SitewiseM3.green : SitewiseM3.muted,
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: SitewiseM3.ink,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                body,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 11.5,
                  height: 1.45,
                  color: SitewiseM3.rowDesc,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Amber status pill built from the existing M3 status tokens.
class _AmberTag extends StatelessWidget {
  final String label;

  const _AmberTag({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: SitewiseM3.amberWash,
        borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
        border: Border.all(color: SitewiseM3.amber.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: SitewiseM3.amber,
        ),
      ),
    );
  }
}
