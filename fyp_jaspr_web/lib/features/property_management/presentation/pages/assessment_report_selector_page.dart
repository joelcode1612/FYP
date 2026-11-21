import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../components/ui.dart' show Icon;

/// UI-facing read model; construct it from your authenticated repository/API.
/// This page never invents assessment records, rental status or admission.
enum AssessmentStatus { draft, inProgress, completed, onHold }

enum ReportAccess { unavailable, draftPreview, admitted }

class RentalSelectionSummary {
  final String id;
  final String title;
  final String locality;
  final String areaLabel;
  final String monthlyRentLabel;
  final String availabilityLabel;
  final String? thumbnailUrl;

  const RentalSelectionSummary({
    required this.id,
    required this.title,
    required this.locality,
    required this.areaLabel,
    required this.monthlyRentLabel,
    required this.availabilityLabel,
    this.thumbnailUrl,
  });
}

class AssessmentListItem {
  final String id;
  final String businessName;
  final AssessmentStatus status;
  final DateTime updatedAtUtc; // UTC for correct sorting.
  final String updatedAtLabel; // Localized/presentational date supplied by host.
  final String createdAtLabel;
  final String createdByLabel;
  final String currentStageLabel;
  final int completedStages;
  final int totalStages;
  final int businessProfileCount;

  /// Null means "not carried by this read model" and renders "—"; it is never
  /// coerced to 0, which would read as "zero recorded".
  final int? respondentCount;
  final int? responseCount;
  final int? externalSourceCount;
  final ReportAccess reportAccess;
  final List<RentalSelectionSummary> selectedRentals;

  const AssessmentListItem({
    required this.id,
    required this.businessName,
    required this.status,
    required this.updatedAtUtc,
    required this.updatedAtLabel,
    required this.createdAtLabel,
    required this.createdByLabel,
    required this.currentStageLabel,
    required this.completedStages,
    this.totalStages = 5,
    required this.businessProfileCount,
    required this.respondentCount,
    required this.responseCount,
    required this.externalSourceCount,
    required this.reportAccess,
    this.selectedRentals = const [],
  });

  int get progressPercent {
    if (totalStages <= 0) return 0;
    final ratio = completedStages / totalStages;
    return (ratio * 100).round().clamp(0, 100).toInt();
  }
}

/// Render this inside the EXISTING SITEWISE AppLayout; it has no sidebar,
/// MaterialApp-like root, authentication bootstrap or backend mutations.
/// In a server/static-rendered Jaspr app, hydrate this component according
/// to your existing client-entrypoint conventions.
///
/// LOCAL CHANGE for the SiteWise integration (two edits only):
///
///   * Deliberately **not** `@client`: the `@client` codegen only accepts
///     primitive constructor parameters, and this page takes a
///     [List] of [AssessmentListItem] plus callbacks. It is instead mounted
///     inside the `@client`, param-less [shell] (`AssessmentReportSelectorView`),
///     which is the same arrangement `ActivityHistoryPage` uses inside the
///     `@client` `M2ActivityPanel`. The search / status-filter / sort /
///     pagination state is still hydrated in the browser — it simply does not
///     need its own `@client` anchor.
///   * [respondentCount], [responseCount] and [externalSourceCount] are
///     nullable and render "—" when unknown. The web assessment read model
///     (`GET /api/v1/assessments/me`) does not carry these three counts, and
///     showing a hardcoded 0 would assert "no respondents recorded" — a claim
///     the source does not make. A null means "this build does not know",
///     which is exactly what the uploaded README requires.
///
/// UI contract (v2 redesign): the read model, the state logic and the
/// callbacks are unchanged. The redesign only touches presentation — shell
/// tokens instead of hardcoded whites (the entrepreneur shell is dark), a
/// per-row report-readiness chip and stage mini-progress so the reader can
/// tell which rows open a report before clicking, and Material Symbols
/// glyphs instead of unicode stand-ins.
class AssessmentReportSelectorPage extends StatefulComponent {
  final List<AssessmentListItem> assessments;
  final void Function(String assessmentId)? onViewReport;
  final void Function(String assessmentId)? onViewRentals;
  final void Function(String assessmentId, String rentalId)? onViewRental;
  // No create callback: this page selects an existing assessment's report.

  const AssessmentReportSelectorPage({
    required this.assessments,
    this.onViewReport,
    this.onViewRentals,
    this.onViewRental,
    super.key,
  });

  @override
  State<AssessmentReportSelectorPage> createState() =>
      _AssessmentReportSelectorState();
}

class _AssessmentReportSelectorState extends State<AssessmentReportSelectorPage> {
  static const int pageSize = 5;
  String? selectedAssessmentId;
  String search = '';
  String statusFilter = 'all';
  String sortOrder = 'recent';
  int page = 0;

  @override
  void initState() {
    super.initState();
    if (component.assessments.isNotEmpty) {
      selectedAssessmentId = component.assessments.first.id;
    }
  }

  @override
  void didUpdateComponent(covariant AssessmentReportSelectorPage oldComponent) {
    super.didUpdateComponent(oldComponent);
    if (!component.assessments.any((row) => row.id == selectedAssessmentId)) {
      selectedAssessmentId = component.assessments.isEmpty
          ? null
          : component.assessments.first.id;
    }
  }

  List<AssessmentListItem> get filtered {
    final query = search.trim().toLowerCase();
    final result = component.assessments.where((row) {
      final matchesStatus = statusFilter == 'all' ||
          row.status.name == statusFilter;
      final text = [
        row.businessName,
        row.id,
        ...row.selectedRentals.expand((r) => [r.title, r.locality, r.id]),
      ].join(' ').toLowerCase();
      return matchesStatus && (query.isEmpty || text.contains(query));
    }).toList();
    result.sort((left, right) => sortOrder == 'oldest'
        ? left.updatedAtUtc.compareTo(right.updatedAtUtc)
        : right.updatedAtUtc.compareTo(left.updatedAtUtc));
    return result;
  }

  AssessmentListItem? get selected {
    for (final a in component.assessments) {
      if (a.id == selectedAssessmentId) return a;
    }
    return component.assessments.isEmpty ? null : component.assessments.first;
  }

  String _statusText(AssessmentStatus status) => switch (status) {
        AssessmentStatus.draft => 'Draft',
        AssessmentStatus.inProgress => 'In progress',
        AssessmentStatus.completed => 'Completed',
        AssessmentStatus.onHold => 'On hold',
      };

  String _statusClass(AssessmentStatus status) => switch (status) {
        AssessmentStatus.draft => 'draft',
        AssessmentStatus.inProgress => 'progress',
        AssessmentStatus.completed => 'completed',
        AssessmentStatus.onHold => 'hold',
      };

  String _accessText(ReportAccess access) => switch (access) {
        ReportAccess.admitted => 'Report ready',
        ReportAccess.draftPreview => 'Preview only',
        ReportAccess.unavailable => 'No report yet',
      };

  String _accessClass(ReportAccess access) => switch (access) {
        ReportAccess.admitted => 'ready',
        ReportAccess.draftPreview => 'preview',
        ReportAccess.unavailable => 'none',
      };

  Component _button(
    String label,
    VoidCallback? onPressed, {
    bool primary = false,
    String? extraClasses,
  }) =>
      button(
        [Component.text(label)],
        classes: 'sra-button${primary ? ' primary' : ''}'
            '${extraClasses == null ? '' : ' $extraClasses'}',
        disabled: onPressed == null,
        onClick: onPressed,
      );

  Component _statusBadge(AssessmentStatus status) => span(
        [Component.text(_statusText(status))],
        classes: 'sra-badge ${_statusClass(status)}',
      );

  /// The row-level chip that states, before any click, whether the report
  /// opens. Same source of truth as the detail card's CTA label.
  Component _accessChip(ReportAccess access) => span(
        [
          Icon(
            switch (access) {
              ReportAccess.admitted => 'check_circle',
              ReportAccess.draftPreview => 'preview',
              ReportAccess.unavailable => 'block',
            },
            size: 'sm',
          ),
          Component.text(_accessText(access)),
        ],
        classes: 'sra-access ${_accessClass(access)}',
      );

  Component _track(int percent, {String? extraClass}) => div(
        [
          div([], classes: 'sra-progress-fill', attributes: {
            'style': 'width: $percent%;',
          }),
        ],
        classes: 'sra-progress-track${extraClass == null ? '' : ' $extraClass'}',
        attributes: {
          'role': 'progressbar',
          'aria-valuenow': '$percent',
          'aria-valuemin': '0',
          'aria-valuemax': '100',
          'aria-label': 'Assessment stage progress',
        },
      );

  Component _progress(int percent) => div([
        _track(percent),
        strong([Component.text('$percent%')]),
      ], classes: 'sra-progress');

  Component _assessmentRow(AssessmentListItem a) {
    final isSelected = a.id == selected?.id;
    return button(
      [
        div([Icon('fact_check')], classes: 'sra-icon'),
        div([
          div([
            strong([Component.text(a.businessName)]),
            _statusBadge(a.status),
          ], classes: 'sra-assessment-name-top'),
          span([Component.text(a.id)], classes: 'sra-muted sra-row-id'),
          div([
            _track(a.progressPercent, extraClass: 'mini'),
            span([Component.text('${a.completedStages}/${a.totalStages} stages')],
                classes: 'sra-muted'),
          ], classes: 'sra-row-progress'),
        ], classes: 'sra-assessment-name'),
        div([
          _accessChip(a.reportAccess),
          span([Component.text('Updated ${a.updatedAtLabel}')],
              classes: 'sra-muted sra-row-date'),
        ], classes: 'sra-row-side'),
        Icon('chevron_right', label: 'Open details'),
      ],
      classes: 'sra-assessment-row${isSelected ? ' selected' : ''}',
      attributes: {'aria-pressed': '$isSelected'},
      onClick: () => setState(() => selectedAssessmentId = a.id),
    );
  }

  /// [count] is nullable on purpose: a source that does not carry the figure
  /// renders "—", never a fabricated 0.
  Component _stat(String label, int? count, String glyph) => div([
        Icon(glyph, label: label),
        div([
          strong([Component.text(count?.toString() ?? '—')]),
          span([Component.text(label)], classes: 'sra-muted'),
        ]),
      ], classes: 'sra-stat', attributes: {
        'title': count == null
            ? '$label: not recorded by this source'
            : '$label: $count',
      });

  Component _rentalRow(AssessmentListItem a, RentalSelectionSummary r) {
    final enabled = component.onViewRental != null;
    return button([
      if (r.thumbnailUrl != null && r.thumbnailUrl!.isNotEmpty)
        img(
          src: r.thumbnailUrl!,
          alt: 'Rental property thumbnail for ${r.title}',
          classes: 'sra-rental-photo',
        )
      else
        div([Icon('storefront')], classes: 'sra-rental-photo placeholder'),
      div([
        strong([Component.text(r.title)]),
        span([Component.text(r.locality)], classes: 'sra-muted'),
      ], classes: 'sra-rental-name'),
      div([
        span([Component.text('Size')], classes: 'sra-muted'),
        strong([Component.text(r.areaLabel)]),
      ], classes: 'sra-rental-meta'),
      div([
        span([Component.text('Monthly rent')], classes: 'sra-muted'),
        strong([Component.text(r.monthlyRentLabel)]),
      ], classes: 'sra-rental-meta'),
      div([
        span([Component.text('Listing status')], classes: 'sra-muted'),
        strong([Component.text(r.availabilityLabel)]),
      ], classes: 'sra-rental-meta'),
      Icon('chevron_right', label: 'Open rental details'),
    ],
        classes: 'sra-rental-row',
        disabled: !enabled,
        onClick: enabled ? () => component.onViewRental!(a.id, r.id) : null);
  }

  Component _details(AssessmentListItem? a) {
    if (a == null) {
      return section([
        div([Icon('description')], classes: 'sra-icon large'),
        h2([Component.text('Assessment Details')]),
        p([Component.text('No assessment has been loaded.')], classes: 'sra-muted'),
      ], classes: 'sra-card sra-details sra-details--empty');
    }
    final reportAction = a.reportAccess == ReportAccess.unavailable ||
            component.onViewReport == null
        ? null
        : () => component.onViewReport!(a.id);
    final reportLabel = a.reportAccess == ReportAccess.admitted
        ? 'View Report'
        : a.reportAccess == ReportAccess.draftPreview
            ? 'Preview Report'
            : 'Report unavailable';

    return section([
      div([
        h2([Component.text('Assessment Details')]),
        _button(reportLabel, reportAction,
            primary: a.reportAccess != ReportAccess.unavailable),
      ], classes: 'sra-panel-header'),
      div([
        div([Icon('description')], classes: 'sra-icon large'),
        div([
          h3([Component.text(a.businessName)]),
          p([
            Component.text('Location assessment · Café demand report · ${a.id}'),
          ], classes: 'sra-muted'),
        ], classes: 'sra-assessment-title'),
        _statusBadge(a.status),
      ], classes: 'sra-detail-heading'),
      div([
        _info('Assessment ID', a.id),
        _info('Created by', a.createdByLabel),
        _info('Created on', a.createdAtLabel),
        _info('Last updated', a.updatedAtLabel),
      ], classes: 'sra-metadata'),
      section([
        div([
          h3([Component.text('Progress & Inputs')]),
          span([
            Component.text('${a.completedStages} of ${a.totalStages} stages completed'),
          ], classes: 'sra-muted'),
        ], classes: 'sra-panel-header'),
        _progress(a.progressPercent),
        p([Component.text('Current stage: ${a.currentStageLabel}')],
            classes: 'sra-muted'),
        div([
          _stat('Business profiles', a.businessProfileCount, 'business_center'),
          _stat('Selected rentals', a.selectedRentals.length, 'home_work'),
          _stat('Respondents', a.respondentCount, 'group'),
          _stat('Survey responses', a.responseCount, 'forum'),
          _stat('External sources', a.externalSourceCount, 'public'),
        ], classes: 'sra-stats'),
      ], classes: 'sra-inner'),
      section([
        div([
          h3([
            Component.text('Selected Rentals (${a.selectedRentals.length})'),
          ]),
          _button('View all rental details',
              component.onViewRentals == null
                  ? null
                  : () => component.onViewRentals!(a.id)),
        ], classes: 'sra-panel-header'),
        if (a.selectedRentals.isEmpty)
          p([Component.text('No rentals are selected for this assessment.')],
              classes: 'sra-muted')
        else
          for (final rental in a.selectedRentals) _rentalRow(a, rental),
      ], classes: 'sra-inner'),
      if (a.reportAccess != ReportAccess.admitted)        p([
          Icon(
            a.reportAccess == ReportAccess.draftPreview ? 'info' : 'lock',
            size: 'sm',
          ),
          Component.text(
            a.reportAccess == ReportAccess.draftPreview
                ? 'Report preview only. Claim admission and PDF release are separately governed.'
                : 'No report viewing permission is available for this assessment.',
          ),
        ], classes: 'sra-report-note'),
    ], classes: 'sra-card sra-details');
  }

  Component _info(String label, String value) => div([
        span([Component.text(label)], classes: 'sra-muted'),
        strong([Component.text(value)]),
      ], classes: 'sra-info');

  /// Header summary chips. Derived only from the records already in the read
  /// model — no extra requests, no invented figures.
  Component _summaryChips() {
    final total = component.assessments.length;
    if (total == 0) return const Component.empty();
    final ready = component.assessments
        .where((item) => item.reportAccess == ReportAccess.admitted)
        .length;
    final active = component.assessments
        .where((item) =>
            item.status == AssessmentStatus.inProgress ||
            item.status == AssessmentStatus.draft)
        .length;
    Component chip(String glyph, String text, String tone) => span(
          [Icon(glyph, size: 'sm'), Component.text(text)],
          classes: 'sra-summary-chip $tone',
        );
    return div([
      chip('fact_check', '$total assessments', 'total'),
      if (ready > 0) chip('task_alt', '$ready report${ready == 1 ? '' : 's'} ready', 'ready'),
      if (active > 0) chip('pending', '$active in progress', 'active'),
    ], classes: 'sra-summary');
  }

  @override
  Component build(BuildContext context) {
    final items = filtered;
    final totalPages = items.isEmpty ? 1 : (items.length + pageSize - 1) ~/ pageSize;
    final safePage = page >= totalPages ? totalPages - 1 : page;
    final pageItems = items.skip(safePage * pageSize).take(pageSize).toList();

    return main_([
      p([Component.text('Project1  ›  Assessment Workspace  ›  Select Assessment')],
          classes: 'sra-breadcrumb'),
      h1([Component.text('Select Assessment to View Report')]),
      p([
        Component.text('Choose an assessment to inspect its inputs, selected rentals '
            'and available report view.'),
      ], classes: 'sra-subtitle'),
      _summaryChips(),
      div([
        section([
          div([
            h2([Component.text('Assessments (${component.assessments.length})')]),
            // No "New Assessment" action: this page is a report selector only.
            // Assessment creation stays on the workspace routes.
          ], classes: 'sra-panel-header'),
          div([
            input<String>(
              type: InputType.text,
              value: search,
              classes: 'sra-search',
              attributes: {
                'placeholder': 'Search name, ID, area or rental',
                'aria-label': 'Search assessments',
              },
              onInput: (value) => setState(() {
                search = value;
                page = 0;
              }),
            ),
            select([
              option([Component.text('All statuses')], value: 'all'),
              option([Component.text('Draft')], value: AssessmentStatus.draft.name),
              option([Component.text('In progress')], value: AssessmentStatus.inProgress.name),
              option([Component.text('Completed')], value: AssessmentStatus.completed.name),
              option([Component.text('On hold')], value: AssessmentStatus.onHold.name),
            ],
                value: statusFilter,
                classes: 'sra-select',
                onChange: (values) => setState(() {
                      statusFilter = values.isEmpty ? 'all' : values.first;
                      page = 0;
                    })),
            select([
              option([Component.text('Most recent')], value: 'recent'),
              option([Component.text('Oldest first')], value: 'oldest'),
            ],
                value: sortOrder,
                classes: 'sra-select',
                onChange: (values) => setState(() {
                      sortOrder = values.isEmpty ? 'recent' : values.first;
                      page = 0;
                    })),
          ], classes: 'sra-filters'),
          div([
            if (pageItems.isEmpty)
              p([Component.text('No assessments match the selected filters.')],
                  classes: 'sra-muted')
            else
              for (final row in pageItems) _assessmentRow(row),
          ], classes: 'sra-list'),
          div([
            _button('← Previous', safePage > 0
                ? () => setState(() => page = safePage - 1)
                : null),
            span([Component.text('Page ${safePage + 1} of $totalPages '
                '(${items.length} assessments)')]),
            _button('Next →', safePage < totalPages - 1
                ? () => setState(() => page = safePage + 1)
                : null),
          ], classes: 'sra-pagination'),
        ], classes: 'sra-card sra-list-panel'),
        _details(selected),
      ], classes: 'sra-grid'),
    ], classes: 'sra-workspace');
  }
}
