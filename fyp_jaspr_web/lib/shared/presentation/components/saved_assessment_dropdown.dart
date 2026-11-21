import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

/// One server-returned, authenticated saved M2 assessment.
///
/// [revision] is the current revision shown by the saved-assessment list.
/// The UI never invents an assessment, revision, or authorization decision.
class SavedAssessmentChoice {
  final String assessmentId;
  final int revision;

  const SavedAssessmentChoice({
    required this.assessmentId,
    required this.revision,
  });

  String get displayLabel => '$assessmentId · revision $revision';
}

/// A controlled Jaspr dropdown for the Activity History page.
///
/// Keep this component inside the existing hydrated/client M2ActivityPanel.
/// Populate [assessments] from the existing authenticated M2 assessment list.
/// [selectedAssessmentId] MUST come from parent state. On selection, the
/// parent must load the selected assessment's actual persisted history.
///
/// This is presentation-only: it does not issue HTTP requests or grant access.
class SavedAssessmentDropdown extends StatefulComponent {
  final List<SavedAssessmentChoice> assessments;
  final String? selectedAssessmentId;
  final void Function(String assessmentId) onSelectAssessment;
  final bool loading;
  final String? error;
  final String optionsId;

  const SavedAssessmentDropdown({
    super.key,
    required this.assessments,
    required this.selectedAssessmentId,
    required this.onSelectAssessment,
    this.loading = false,
    this.error,
    this.optionsId = 'activity-saved-assessment-options',
  });

  @override
  State<SavedAssessmentDropdown> createState() =>
      _SavedAssessmentDropdownState();
}

class _SavedAssessmentDropdownState extends State<SavedAssessmentDropdown> {
  bool _open = false;

  SavedAssessmentChoice? _findSelected() {
    for (final assessment in component.assessments) {
      if (assessment.assessmentId == component.selectedAssessmentId) {
        return assessment;
      }
    }
    return null;
  }

  @override
  void didUpdateComponent(covariant SavedAssessmentDropdown previous) {
    super.didUpdateComponent(previous);
    if (previous.selectedAssessmentId != component.selectedAssessmentId ||
        (!previous.loading && component.loading)) {
      _open = false;
    }
  }

  void _choose(SavedAssessmentChoice choice) {
    if (component.loading ||
        choice.assessmentId == component.selectedAssessmentId) {
      setState(() => _open = false);
      return;
    }

    // Only a server-supplied choice can reach this callback.
    setState(() => _open = false);
    component.onSelectAssessment(choice.assessmentId);
  }

  @override
  Component build(BuildContext context) {
    final selected = _findSelected();
    final isEmpty = component.assessments.isEmpty;
    final canOpen = !component.loading && !isEmpty;
    final hasUnresolvedSelection =
        !component.loading &&
        component.error == null &&
        component.selectedAssessmentId != null &&
        selected == null;
    final displayLabel =
        selected?.displayLabel ??
        (hasUnresolvedSelection
            ? 'Selected assessment is outside the recent saved list'
            : (component.loading
                  ? 'Loading saved assessments…'
                  : component.error != null
                  ? 'Saved assessment activity unavailable'
                  : isEmpty
                  ? 'No saved assessments'
                  : 'Select a saved assessment'));

    return div(
      classes: 'sah-assessment-selector',
      attributes: {'data-testid': 'saved-assessment-selector'},
      [
        div(classes: 'sah-assessment-selector-label', [
          span(
            classes: 'sah-document-icon',
            attributes: {'aria-hidden': 'true'},
            [Component.text('▤')],
          ),
          span([Component.text('Saved assessment')]),
        ]),
        div(classes: 'sah-assessment-picker', [
          button(
            classes: 'sah-assessment-trigger',
            disabled: !canOpen,
            onClick: () => setState(() => _open = !_open),
            attributes: {
              'type': 'button',
              'aria-label': 'Choose a saved assessment',
              'aria-expanded': _open ? 'true' : 'false',
              if (_open) 'aria-controls': component.optionsId,
              'data-testid': 'saved-assessment-trigger',
            },
            [
              span(classes: 'sah-assessment-current', [
                Component.text(displayLabel),
              ]),
              span(
                classes: 'sah-chevron ${_open ? 'sah-chevron-open' : ''}',
                attributes: {'aria-hidden': 'true'},
                [Component.text('⌄')],
              ),
            ],
          ),
          if (_open && canOpen)
            div(
              classes: 'sah-assessment-menu',
              id: component.optionsId,
              attributes: {
                'role': 'group',
                'aria-label': 'Your saved assessments',
                'data-testid': 'saved-assessment-options',
              },
              [
                for (final choice in component.assessments)
                  button(
                    classes:
                        'sah-assessment-option '
                        '${choice.assessmentId == component.selectedAssessmentId ? 'sah-assessment-option-selected' : ''}',
                    onClick: () => _choose(choice),
                    attributes: {
                      'type': 'button',
                      'aria-label': choice.displayLabel,
                      'aria-current':
                          choice.assessmentId == component.selectedAssessmentId
                          ? 'true'
                          : 'false',
                      'data-assessment-id': choice.assessmentId,
                    },
                    [
                      span(classes: 'sah-assessment-option-label', [
                        Component.text(choice.displayLabel),
                      ]),
                      if (choice.assessmentId == component.selectedAssessmentId)
                        span(
                          classes: 'sah-assessment-check',
                          attributes: {'aria-hidden': 'true'},
                          [Component.text('✓')],
                        ),
                    ],
                  ),
              ],
            ),
        ]),
        if (component.loading)
          p(classes: 'sah-assessment-state', [
            Component.text('Loading saved assessment…'),
          ]),
        if (component.error != null)
          p(
            classes: 'sah-assessment-error',
            attributes: {'role': 'alert'},
            [Component.text(component.error!)],
          ),
        if (hasUnresolvedSelection)
          p(
            classes: 'sah-assessment-error',
            attributes: {'role': 'status'},
            [
              Component.text(
                'The selected assessment is outside the recent list. '
                'Its direct history link may still be valid.',
              ),
            ],
          ),
      ],
    );
  }
}
