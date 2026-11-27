import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'package:sitewise_jaspr_web/features/assessment/application/stage_labels.dart';
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
            // One number, from one place: the persisted record. This used to
            // sum stage_1 and stage_2 out of workflowReadiness for governed
            // workflows, which capped the count at 2 for every assessment and
            // disagreed with the dashboard the moment stage 2 completed.
            strong([Component.text('${record.completedStages} / ${record.totalStages}')]),
            span([
              Component.text(record.stagesRemaining == 0
                  ? ' completed'
                  : ' completed · ${record.stagesRemaining} remaining'),
            ]),
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
    // Completeness comes from the persisted record -- the same value the count
    // above, the dashboard and the report read. workflowReadiness decides
    // *enterability* only (see canViewAssessmentStage). Deriving the ticks from
    // readiness was what pinned stages 3, 4 and 5 to "not complete" forever:
    // only stage_1 and stage_2 were ever consulted.
    final governedComplete = stage.isComplete;
    final available = !governedWorkflow || canViewAssessmentStage(stage.key, workflowReadiness);
    // When the server sends its finer verdict, render that. A stage held by a
    // missing contract or a governance gate is not "not started": it is blocked,
    // and saying so is the difference between "do the work" and "wait for a
    // decision". Falls back to the legacy mapping when `state` is absent.
    final state = governedWorkflow
        ? stage.state == 'BLOCKED' || stage.state == 'NOT_AVAILABLE'
            ? 'unavailable'
            : governedComplete
                ? 'complete'
                : stage.state == 'IN_PROGRESS'
                    ? 'current'
                    // The checkpoint on screen is always the current one, even
                    // when the server has not marked it enterable: its panel
                    // states the block.
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
      'unavailable' => 'Blocked',
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
      // No per-step blocker sentence. It printed the same "Complete the … stage
      // first" line under the step, under a page banner and again in the panel
      // on screen, and on this assessment it named the stage the reader was
      // already looking at. The step's own state still comes from the server.
    ];

    final attrs = <String, String>{
      'aria-label': 'Step ${stage.number}: $label — $statusLabel',
      if (isSelected) 'aria-current': 'step',
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
  ///
  /// The map itself lives in `application/stage_labels.dart`, because the
  /// blocker sentences ("Complete the business review and research goals stage
  /// first") have to name the same step the same way.
  static String displayLabel(String key, String serverLabel) =>
      stageDisplayLabel(key, serverLabel);
}
