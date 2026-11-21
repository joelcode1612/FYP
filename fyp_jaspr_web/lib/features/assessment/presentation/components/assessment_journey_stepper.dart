import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';

/// Navigation only; these capabilities never authorize writes or completion.
bool canViewAssessmentStage(String key, Map<String, dynamic>? readiness) => switch (key) {
  'select_property' || 'business_requirements' => true,
  'location_evidence' => (readiness?['stage_3'] as Map?)?['enterable'] == true,
  'ai_explanation' => (readiness?['stage_4'] as Map?)?['enterable'] == true,
  'assessment_report' => (readiness?['stage_5'] as Map?)?['preview_enterable'] == true,
  _ => false,
};

/// Five-stage assessment timeline, based on the SiteWise location-assessment
/// reference image. It does not compute or change assessment progress:
/// every stage, status and percentage comes from the backend's persisted
/// [AssessmentRecord].
///
/// Every stage opens its own checkpoint view in the workspace via
/// [onOpenStage] — the five checkpoints are independent, one visible at a
/// time. No shortcut grants completion or bypasses server validation.
class AssessmentJourneyStepper extends StatelessComponent {
  final AssessmentRecord record;
  final bool busy;
  /// Versioned readiness returned by FastAPI, not legacy timestamps.
  final Map<String, dynamic>? workflowReadiness;
  final bool governedWorkflow;

  /// The stage whose checkpoint is on screen. Null falls back to the
  /// record's own current stage.
  final String? selectedStageKey;
  final void Function(String stageKey) onOpenStage;

  const AssessmentJourneyStepper({
    super.key,
    required this.record,
    required this.busy,
    this.workflowReadiness,
    this.governedWorkflow = false,
    this.selectedStageKey,
    required this.onOpenStage,
  });

  @override
  Component build(BuildContext context) {
    return section(
      classes: 'sw-assessment-journey',
      attributes: const {'aria-label': 'Location assessment stages'},
      [
        div(classes: 'sw-assessment-journey__heading', [
          div(classes: 'sw-assessment-journey__heading-text', [
            Icon('layers', size: 'sm'),
            span(classes: 'sw-assessment-journey__eyebrow', [
              Component.text('Assessment progress'),
            ]),
          ]),
          div(classes: 'sw-assessment-journey__count', [
            strong([Component.text(governedWorkflow
                ? workflowReadiness == null
                    ? 'Checking progress…'
                    : '${((workflowReadiness!['stage_1'] as Map?)?['complete'] == true ? 1 : 0) + ((workflowReadiness!['stage_2'] as Map?)?['complete'] == true ? 1 : 0)} / ${record.totalStages}'
                : '${record.completedStages} / ${record.totalStages}')]),
            span([Component.text(' completed')]),
          ]),
        ]),
        div(classes: 'sw-assessment-journey__scroll', [
          ol(classes: 'sw-assessment-journey__steps', [
            for (final stage in record.stages) _stage(stage),
          ]),
        ]),
      ],
    );
  }

  Component _stage(AssessmentStage stage) {
    final label = displayLabel(stage.key, stage.title);
    final selectedKey = selectedStageKey ?? record.currentStageKey;
    final isSelected = stage.key == selectedKey;
    final stage1Complete = (workflowReadiness?['stage_1'] as Map?)?['complete'] == true;
    final stage2Complete = (workflowReadiness?['stage_2'] as Map?)?['complete'] == true;
    final governedComplete = stage.key == 'select_property'
        ? stage1Complete
        : stage.key == 'business_requirements' && stage2Complete;
    final available = !governedWorkflow || canViewAssessmentStage(stage.key, workflowReadiness);
    final state = governedWorkflow
        ? governedComplete
            ? 'complete'
            // The checkpoint on screen is always the current one, even when the
            // server has not marked it enterable: its panel states the block.
            : isSelected
                ? 'current'
                : !available
                    ? 'unavailable'
                    : 'upcoming'
        : stage.isComplete
        ? 'complete'
        : stage.isUnavailable
            ? 'unavailable'
            : isSelected
                ? 'current'
                : 'upcoming';
    final statusLabel = switch (state) {
      'complete' => 'Completed',
      'unavailable' => 'Unavailable',
      'current' => 'Current stage',
      _ => 'Not started',
    };

    final contents = <Component>[
      span(classes: 'sw-assessment-journey__circle', [
        Component.text(state == 'complete' ? '✓' : '${stage.number}'),
      ]),
      span(classes: 'sw-assessment-journey__step-title', [
        Component.text(label),
      ]),
    ];

    final attrs = <String, String>{
      'aria-label': 'Step ${stage.number}: $label — $statusLabel',
      if (isSelected) 'aria-current': 'step',
      if (stage.isUnavailable && stage.unavailableReason != null)
        'title': stage.unavailableReason!,
    };

    final classes = 'sw-assessment-journey__control';
    // Every stage opens its own checkpoint view in the workspace; the
    // deep-link hand-offs to the property, explanation and report pages live
    // inside those checkpoints instead of leaving the workspace from here.
    Component control;
    if (!busy && (governedWorkflow ? available : !stage.isUnavailable)) {
      control = button(
        classes: classes,
        attributes: {...attrs, 'type': 'button'},
        events: events(onClick: () => onOpenStage(stage.key)),
        contents,
      );
    } else {
      control = div(
        classes: classes,
        attributes: attrs,
        contents,
      );
    }

    return li(classes: 'sw-assessment-journey__step sw-assessment-journey__step--$state', [
      control,
    ]);
  }

  /// Client-side step labels. The backend keys are the contract; the label for
  /// `location_evidence` follows the step-3 redesign (business review and
  /// research goals), the label for `ai_explanation` follows the step-4
  /// redesign (research question review), and the label for
  /// `assessment_report` follows the step-5 redesign (publish questionnaire),
  /// so the stepper, the breadcrumb and the step heading agree.
  static String displayLabel(String key, String serverLabel) => switch (key) {
    'select_property' => 'Select property',
    'business_requirements' => 'Business preferences',
    'location_evidence' => 'Business review and research goals',
    'ai_explanation' => 'Question review',
    'assessment_report' => 'Questionnaire preview',
    _ => serverLabel,
  };
}
