import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

/// Data is supplied by the existing authenticated SITEWISE API/repository.
/// This component neither creates nor modifies assessment records.
enum AssessmentCardStatus { draft, inProgress, completed, onHold }

/// Which report belongs to an assessment. The host derives this from the
/// persisted `report_available` flag and the server-computed stage progress;
/// it is never inferred from the visual status of the row.
enum AssessmentReportState { available, preview, unavailable }

/// Presentation model deliberately named differently from the existing
/// AssessmentListItem in assessment_report_selector_page.dart to avoid
/// conflicting types when both components are imported.
class AssessmentCardSummary {
  final String id;
  final String name;
  final int rentalCount;
  final DateTime updatedAt;
  final AssessmentCardStatus status;

  /// Optional backend-provided rental names / localities for search only.
  final List<String> searchTerms;

  /// The report this assessment owns, shown on every row so the page answers
  /// "which report belongs to which assessment" without a create action.
  final String reportLabel;
  final AssessmentReportState reportState;

  const AssessmentCardSummary({
    required this.id,
    required this.name,
    required this.rentalCount,
    required this.updatedAt,
    required this.status,
    this.searchTerms = const [],
    required this.reportLabel,
    required this.reportState,
  });
}

/// A presentation-only, searchable assessment list. The hosting page owns the
/// selection and opens the assessment's report through [onSelectAssessment].
/// It does NOT render another SITEWISE sidebar.
///
/// LOCAL CHANGE for the SiteWise integration:
///   * `component.` instead of Flutter's `widget.` — Jaspr's [State] exposes
///     the component as `component`.
///   * The uploaded "+ New Assessment" button is **deleted**, not hidden: there
///     is no callback left that could render it. Clicking a row is the only
///     action here, and it opens that assessment's report. Starting a new
///     assessment stays on the workspace routes.
///   * Each row carries a report label/state so the list itself indicates which
///     report belongs to which assessment.
///   * A row whose assessment has no report to open is `disabled`, so a click
///     can never do nothing silently.
class AssessmentListComponent extends StatefulComponent {
  final List<AssessmentCardSummary> assessments;
  final String? selectedAssessmentId;

  /// Called with the clicked assessment's id. The host navigates to that
  /// assessment's report page.
  final void Function(String assessmentId) onSelectAssessment;

  const AssessmentListComponent({
    required this.assessments,
    required this.onSelectAssessment,
    this.selectedAssessmentId,
    super.key,
  });

  @override
  State<AssessmentListComponent> createState() =>
      _AssessmentListComponentState();
}

class _AssessmentListComponentState extends State<AssessmentListComponent> {
  String searchQuery = '';
  String statusFilter = 'all';
  String sortOrder = 'recent';

  String _statusText(AssessmentCardStatus status) => switch (status) {
        AssessmentCardStatus.draft => 'Draft',
        AssessmentCardStatus.inProgress => 'In progress',
        AssessmentCardStatus.completed => 'Completed',
        AssessmentCardStatus.onHold => 'On hold',
      };

  String _statusClass(AssessmentCardStatus status) => switch (status) {
        AssessmentCardStatus.draft => 'draft',
        AssessmentCardStatus.inProgress => 'in-progress',
        AssessmentCardStatus.completed => 'completed',
        AssessmentCardStatus.onHold => 'on-hold',
      };

  String _reportStateText(AssessmentReportState state) => switch (state) {
        AssessmentReportState.available => 'Available',
        AssessmentReportState.preview => 'Preview only',
        AssessmentReportState.unavailable => 'Not available yet',
      };

  String _reportStateClass(AssessmentReportState state) => switch (state) {
        AssessmentReportState.available => 'ready',
        AssessmentReportState.preview => 'preview',
        AssessmentReportState.unavailable => 'pending',
      };

  String _dateLabel(DateTime date) {
    const months = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    // Render date in the same display timezone that the host supplies.
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  List<AssessmentCardSummary> get _visibleAssessments {
    final query = searchQuery.trim().toLowerCase();
    final result = component.assessments.where((item) {
      final haystack = [item.id, item.name, ...item.searchTerms]
          .join(' ').toLowerCase();
      return (query.isEmpty || haystack.contains(query)) &&
          (statusFilter == 'all' || item.status.name == statusFilter);
    }).toList();

    result.sort((left, right) {
      switch (sortOrder) {
        case 'oldest':
          return left.updatedAt.compareTo(right.updatedAt);
        case 'name':
          return left.name.toLowerCase().compareTo(right.name.toLowerCase());
        case 'rentals':
          return right.rentalCount.compareTo(left.rentalCount);
        default:
          return right.updatedAt.compareTo(left.updatedAt);
      }
    });
    return result;
  }

  Component _assessmentRow(AssessmentCardSummary item) {
    final isSelected = component.selectedAssessmentId == item.id;
    final rentalCount = item.rentalCount < 0 ? 0 : item.rentalCount;
    final reportStateText = _reportStateText(item.reportState);
    // "Not available yet" means there is no report page to open, so the row is
    // rendered disabled rather than accepting a click that goes nowhere.
    final canOpenReport =
        item.reportState != AssessmentReportState.unavailable;

    return button(
      [
        div([
          div([Component.text('▤')], classes: 'swal-icon'),
          div([
            strong([Component.text(item.name)], classes: 'swal-name'),
            span([Component.text(item.id)], classes: 'swal-id'),
            span([
              Component.text('Report: ${item.reportLabel} · $reportStateText'),
            ], classes: 'swal-report ${_reportStateClass(item.reportState)}'),
          ], classes: 'swal-identity'),
        ], classes: 'swal-title'),
        span([
          Component.text(
            '$rentalCount ${rentalCount == 1 ? 'rental' : 'rentals'}',
          ),
        ], classes: 'swal-rental-count'),
        div([
          span([Component.text('Updated')]),
          span([Component.text(_dateLabel(item.updatedAt))]),
        ], classes: 'swal-updated'),
        span([
          Component.text(_statusText(item.status)),
        ], classes: 'swal-status ${_statusClass(item.status)}'),
        span([Component.text('›')], classes: 'swal-chevron'),
      ],
      classes: isSelected ? 'swal-row selected' : 'swal-row',
      attributes: {
        'type': 'button',
        'aria-pressed': '$isSelected',
        'aria-disabled': '${!canOpenReport}',
        if (!canOpenReport) 'disabled': 'disabled',
        'aria-label': canOpenReport
            ? "Open ${item.name}'s report, $rentalCount selected rentals, "
                '${_statusText(item.status)}, ${item.reportLabel} '
                '$reportStateText'
            : '${item.name}, ${item.reportLabel} $reportStateText',
      },
      onClick:
          canOpenReport ? () => component.onSelectAssessment(item.id) : null,
    );
  }

  @override
  Component build(BuildContext context) {
    final visible = _visibleAssessments;

    return section([
      div([
        h2([
          Component.text('▤ Assessments (${component.assessments.length})'),
        ]),
        // No create control: the header holds the count plus a cue that a row
        // opens its report, so there is no create button left to remove.
        p([
          Component.text('Select an assessment to open its report.'),
        ], classes: 'swal-hint'),
      ], classes: 'swal-header'),
      div([
        input<String>(
          type: InputType.text,
          value: searchQuery,
          classes: 'swal-search',
          attributes: {
            'placeholder': 'Search name, ID, area or rental',
            'aria-label': 'Search assessments',
          },
          onInput: (value) => setState(() => searchQuery = value),
        ),
        select(
          [
            option([Component.text('All statuses')], value: 'all'),
            option([Component.text('Draft')], value: 'draft'),
            option([Component.text('In progress')], value: 'inProgress'),
            option([Component.text('Completed')], value: 'completed'),
            option([Component.text('On hold')], value: 'onHold'),
          ],
          value: statusFilter,
          classes: 'swal-select',
          onChange: (values) => setState(() {
            statusFilter = values.isEmpty ? 'all' : values.first;
          }),
        ),
        select(
          [
            option([Component.text('Most recent')], value: 'recent'),
            option([Component.text('Oldest first')], value: 'oldest'),
            option([Component.text('Name A–Z')], value: 'name'),
            option([Component.text('Most rentals')], value: 'rentals'),
          ],
          value: sortOrder,
          classes: 'swal-select',
          onChange: (values) => setState(() {
            sortOrder = values.isEmpty ? 'recent' : values.first;
          }),
        ),
      ], classes: 'swal-filters'),
      div([
        if (visible.isEmpty)
          p([
            Component.text('No assessments match these filters.'),
          ], classes: 'swal-empty')
        else
          for (final assessment in visible) _assessmentRow(assessment),
      ], classes: 'swal-list'),
    ], classes: 'swal-panel');
  }
}
