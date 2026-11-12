import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../data/app_locator.dart';
import 'ui.dart';

/// Server availability only: no sample record, count, report or local approval.
@client
class Project1ReadPanel extends StatefulComponent {
  final String assessmentId;
  final String section;
  const Project1ReadPanel({super.key, required this.assessmentId, required this.section});

  @override
  State<Project1ReadPanel> createState() => _Project1ReadPanelState();
}

class _Project1ReadPanelState extends State<Project1ReadPanel> {
  late Future<Project1Readiness> _future = _read();

  Future<Project1Readiness> _read() => AppLocator.project1Read.read(
    assessmentId: component.assessmentId.isEmpty ? null : component.assessmentId,
  );

  @override
  void didUpdateComponent(covariant Project1ReadPanel oldComponent) {
    super.didUpdateComponent(oldComponent);
    if (oldComponent.assessmentId != component.assessmentId) _future = _read();
  }

  @override
  Component build(BuildContext context) => FutureBuilder<Project1Readiness>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const p(attributes: {'role': 'status'}, [Component.text('Checking availability…')]);
      }
      final data = snapshot.hasError ? null : snapshot.data;
      if (data == null) {
        return EmptyState(
          title: 'Availability could not be verified',
          body: 'Check your sign-in and connection, then try again. No research data has been loaded.',
          action: ActionButton('Retry', onClick: () => setState(() { _future = _read(); })),
        );
      }
      final artifact = switch (component.section) {
        'review' => data.review,
        'questionnaire' => data.questionnaire,
        'report' => data.report,
        'activity' => data.activity,
        _ => throw StateError('Unknown Project1 section.'),
      };
      return section(classes: 'panel stack stack--sm', [
        h2([Component.text(switch (component.section) {
          'review' => 'Business review held',
          'questionnaire' => 'Questionnaire held',
          'report' => 'Report held',
          _ => 'Activity history unavailable',
        })]),
        p(attributes: {'role': 'status', 'aria-live': 'polite'}, [Component.text(artifact.message)]),
        if (data.assessmentId != null)
          p(classes: 'small asw-muted', [Component.text('Assessment ${data.assessmentId}')]),
        ActionButton('Check again', variant: 'secondary', onClick: () => setState(() { _future = _read(); })),
      ]);
    },
  );
}
