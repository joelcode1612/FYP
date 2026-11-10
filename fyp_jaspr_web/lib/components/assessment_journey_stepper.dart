import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../data/assessment_api.dart';

/// Five-stage assessment timeline, based on the SiteWise location-assessment
/// reference image. It does not compute or change assessment progress:
/// every stage, status and percentage comes from the backend's persisted
/// [AssessmentRecord].
///
/// For stages 2/3 it requests that the existing workspace expand its
/// respective panel. Stage 1 links to the property; stages 4/5 link to
/// the existing explanation/report pages only when their capability is not
/// unavailable. No shortcut grants completion or bypasses server validation.
class AssessmentJourneyStepper extends StatelessComponent {
  final AssessmentRecord record;
  final bool busy;
  final void Function(String stageKey) onOpenStage;

  const AssessmentJourneyStepper({
    super.key,
    required this.record,
    required this.busy,
    required this.onOpenStage,
  });

  @override
  Component build(BuildContext context) {
    final progress = record.progressPercent.clamp(0, 100);

    return section(
      classes: 'sw-assessment-journey',
      attributes: const {'aria-label': 'Location assessment stages'},
      [
        div(classes: 'sw-assessment-journey__heading', [
          div(classes: 'sw-assessment-journey__heading-text', [
            span(classes: 'sw-assessment-journey__eyebrow', [
              Component.text('YOUR ASSESSMENT JOURNEY'),
            ]),
            h2(classes: 'sw-assessment-journey__title', [
              Component.text('Five stages to your location decision'),
            ]),
          ]),
          div(classes: 'sw-assessment-journey__count', [
            strong([Component.text('${record.completedStages} / ${record.totalStages}')]),
            span([Component.text(' completed')]),
          ]),
        ]),
        div(classes: 'sw-assessment-journey__scroll', [
          ol(classes: 'sw-assessment-journey__steps', [
            for (final stage in record.stages) _stage(stage),
          ]),
        ]),
        div(classes: 'sw-assessment-journey__footer', [
          span(classes: 'sw-assessment-journey__hint', [
            Component.text('Progress is saved to your account'),
          ]),
          strong(classes: 'sw-assessment-journey__percentage', [
            Component.text('$progress%'),
          ]),
        ]),
        div(
          classes: 'sw-assessment-journey__progress',
          attributes: {
            'role': 'progressbar',
            'aria-label': 'Assessment completion',
            'aria-valuenow': '$progress',
            'aria-valuemin': '0',
            'aria-valuemax': '100',
          },
          [
            div(
              classes: 'sw-assessment-journey__progress-fill',
              styles: Styles(raw: {'width': '$progress%'}),
              [],
            ),
          ],
        ),
      ],
    );
  }

  Component _stage(AssessmentStage stage) {
    final label = _displayLabel(stage.key, stage.title);
    final state = stage.isComplete
        ? 'complete'
        : stage.isUnavailable
            ? 'unavailable'
            : stage.isCurrent
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
        Component.text(stage.isComplete ? '✓' : '${stage.number}'),
      ]),
      span(classes: 'sw-assessment-journey__step-title', [
        Component.text(label),
      ]),
      span(classes: 'sw-assessment-journey__step-status', [
        Component.text(statusLabel),
      ]),
    ];

    final attrs = <String, String>{
      'aria-label': 'Step ${stage.number}: $label — $statusLabel',
      if (stage.isCurrent) 'aria-current': 'step',
      if (stage.isUnavailable && stage.unavailableReason != null)
        'title': stage.unavailableReason!,
    };

    final classes = 'sw-assessment-journey__control';
    Component control;
    if (!busy && (stage.key == 'business_requirements' ||
                    stage.key == 'location_evidence')) {
      control = button(
        classes: classes,
        attributes: {...attrs, 'type': 'button'},
        events: events(onClick: () => onOpenStage(stage.key)),
        contents,
      );
    } else if (!busy && !stage.isUnavailable && stage.key == 'select_property') {
      control = a(
        href: '/entrepreneur/property-detail?id=${Uri.encodeQueryComponent(record.propertyId)}',
        classes: classes,
        attributes: attrs,
        contents,
      );
    } else if (!busy && !stage.isUnavailable && stage.key == 'ai_explanation') {
      control = a(
        href: '/entrepreneur/explanation?property=${Uri.encodeQueryComponent(record.propertyId)}',
        classes: classes,
        attributes: attrs,
        contents,
      );
    } else if (!busy && !stage.isUnavailable && stage.key == 'assessment_report') {
      control = a(
        href: '/entrepreneur/report?id=${Uri.encodeQueryComponent(record.propertyId)}',
        classes: classes,
        attributes: attrs,
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

  static String _displayLabel(String key, String serverLabel) => switch (key) {
    'select_property' => 'Select property',
    'business_requirements' => 'Business preferences',
    'location_evidence' => 'Location evidence',
    'ai_explanation' => 'AI explanation',
    'assessment_report' => 'Assessment report',
    _ => serverLabel,
  };
}
