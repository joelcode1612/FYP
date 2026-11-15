import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'assessment_overview_page.dart';
import '../../components/research_workflow_panel.dart';

/// Entry + four-step research workflow shell.
///
/// `step: null` renders the assessment list BEFORE Step 1.
/// `step: 1` renders the application's EXISTING authenticated M2 editor,
/// supplied by the host in `m2Editor`; this wrapper does not recreate it.
/// `step: 2..4` render the source-bound research components.
///
/// No route, database write or authority is created by this component.
/// The host must map the REAL M2 assessment ID (not the property-workspace ID).
///
/// LOCAL ADAPTATION: the uploaded file marked this `@client`, but its
/// `List<ResearchAssessmentOverviewRecord>`, `Component?` and callback
/// parameters cannot be serialized by Jaspr's client codegen, and every
/// `@client` shell in this app takes primitive params only. It is therefore a
/// plain StatelessComponent mounted under the primitive-param `@client`
/// `AssessmentWorkspacePage`. It still runs fully client-side.
class ResearchAssessmentFlowPage extends StatelessComponent {
  final int? step;
  final String? selectedAssessmentId;
  final List<ResearchAssessmentOverviewRecord> assessments;
  final bool overviewLoading;
  final String? overviewError;
  final ResearchWorkflowSnapshot? researchSnapshot;
  final Component? m2Editor;
  final Set<int> accessibleSteps; // permissioned progression from backend
  final VoidCallback? onCreateAssessment;
  final VoidCallback? onRefreshOverview;
  final ResumeResearchAssessment? onOpenAssessment;
  final InspectResearchAssessment? onViewHistory;
  final VoidCallback? onBackToOverview;
  final void Function(String assessmentId, int step)? onNavigateStep;
  final bool canReviewCandidates;
  final ConfirmResearchObjective? onConfirmObjective;
  final RecordFindingDisposition? onRecordFinding;
  final RaiseResearchUncertainty? onRaiseUncertainty;
  final ReviseResearchObjective? onReviseObjective;
  final ReviewResearchCandidate? onReviewCandidate;
  final RequestResearchPublication? onRequestPublish;
  final WithholdResearchPublication? onWithholdPublish;
  final Future<void> Function()? onRefreshResearch;

  const ResearchAssessmentFlowPage({
    super.key,
    required this.step,
    this.selectedAssessmentId,
    this.assessments = const [],
    this.overviewLoading = false,
    this.overviewError,
    this.researchSnapshot,
    this.m2Editor,
    this.accessibleSteps = const {},
    this.onCreateAssessment,
    this.onRefreshOverview,
    this.onOpenAssessment,
    this.onViewHistory,
    this.onBackToOverview,
    this.onNavigateStep,
    this.canReviewCandidates = false,
    this.onConfirmObjective,
    this.onRecordFinding,
    this.onRaiseUncertainty,
    this.onReviseObjective,
    this.onReviewCandidate,
    this.onRequestPublish,
    this.onWithholdPublish,
    this.onRefreshResearch,
  }) : assert(step == null || (step >= 1 && step <= 4));

  static const _labels = [
    'Business & M2',
    'BDJ Findings & Objectives',
    'Research Question Review',
    'Customer Questionnaire',
  ];

  Component _navigateButton(String label, int targetStep, {
    bool back = false,
  }) => button(
    classes: 'af-button ${back ? 'af-button--outline' : ''}',
    disabled: selectedAssessmentId == null ||
      !accessibleSteps.contains(targetStep) || onNavigateStep == null,
    onClick: selectedAssessmentId == null ||
      !accessibleSteps.contains(targetStep) || onNavigateStep == null
      ? null : () => onNavigateStep!(selectedAssessmentId!, targetStep),
    attributes: {'type': 'button'},
    [Component.text(label)],
  );

  @override
  Component build(BuildContext context) {
    if (step == null) {
      return ResearchAssessmentOverviewPage(
        assessments: assessments,
        loading: overviewLoading,
        loadError: overviewError,
        onNewAssessment: onCreateAssessment,
        onRefresh: onRefreshOverview,
        onResume: onOpenAssessment,
        onViewHistory: onViewHistory,
      );
    }

    final hasCorrectSnapshot = (step == 1 && selectedAssessmentId != null) ||
      (selectedAssessmentId != null && researchSnapshot != null &&
       researchSnapshot!.assessmentId == selectedAssessmentId);

    return section(classes: 'af-workspace', attributes: {
      'data-testid': 'research-four-step-workflow',
    }, [
      div(classes: 'af-page-header', [
        div([
          p(classes: 'af-eyebrow', [Component.text('Assessment workspace')]),
          h1([Component.text('Step $step — ${_labels[step! - 1]}')]),
          if (selectedAssessmentId != null)
            p(classes: 'af-muted', [Component.text(
              'Assessment $selectedAssessmentId'
            )]),
        ]),
        button(classes: 'af-button af-button--outline',
          disabled: onBackToOverview == null,
          onClick: onBackToOverview,
          attributes: {'type': 'button'},
          [Component.text('All assessments')]),
      ]),
      nav(classes: 'af-stepper', attributes: {
        'aria-label': 'Four-step research assessment workflow',
      }, [
        for (var i = 0; i < _labels.length; i++)
          div(classes: 'af-step ${step == i + 1 ? 'af-step--active' : ''}', [
            span(classes: 'af-step-number', [Component.text('${i + 1}')]),
            span([Component.text(_labels[i])]),
          ]),
      ]),
      if (!hasCorrectSnapshot)
        div(classes: 'af-error', [Component.text(
          'Cannot verify that the selected M2 assessment matches the '
          'research workflow snapshot. No review or release actions are shown.'
        )])
      else if (step == 1)
        m2Editor ?? div(classes: 'af-error', [Component.text(
          'The existing M2EntryPanel has not been supplied by the host. '
          'Connect the real versioned editor; do not insert a fake questionnaire.'
        )])
      else if (researchSnapshot != null)
        ResearchWorkflowPanel(
          key: ValueKey('research-${researchSnapshot!.assessmentId}-$step'),
          step: step!,
          snapshot: researchSnapshot!,
          hideInternalHeading: true,
          canReviewCandidates: canReviewCandidates,
          onConfirmObjective: onConfirmObjective,
          onRecordFinding: onRecordFinding,
          onRaiseUncertainty: onRaiseUncertainty,
          onReviseObjective: onReviseObjective,
          onReviewCandidate: onReviewCandidate,
          onRequestPublish: onRequestPublish,
          onWithholdPublish: onWithholdPublish,
          onRefresh: onRefreshResearch,
        ),
      div(classes: 'af-footer', [
        if (step! > 1) _navigateButton('Back to Step ${step! - 1}', step! - 1, back: true),
        if (step! < 4) _navigateButton('Continue to Step ${step! + 1}', step! + 1),
        if (step == 4)
          p(classes: 'af-muted', [Component.text(
            'Questionnaire publication is controlled by separate scientific, '
            'fielding and release authorization checks. Preview is not publication.'
          )]),
      ]),
    ]);
  }
}
