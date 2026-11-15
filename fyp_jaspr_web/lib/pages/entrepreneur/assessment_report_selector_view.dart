import 'package:jaspr/jaspr.dart';
import 'package:jaspr_router/jaspr_router.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/assessment_api.dart';
import '../../data/full_analysis_format.dart';
import '../../layouts/app_layout.dart';
import 'assessment_report_selector_page.dart';

/// The gate that now opens at `/entrepreneur/cafe-report`.
///
/// It renders the approved "Select Assessment to View Report" screen inside the
/// existing [AppLayout] (which supplies the top navigation and the signed-in
/// shell — this page adds no sidebar, root or auth bootstrap of its own).
///
/// Choosing a row hands off to the existing location ReportPage at
/// `/entrepreneur/report?id=<property_id>`, as assessment history already does.
/// The separate R01–R12 research-report admission route is not this report.
///
/// The list is read from `GET /api/v1/assessments/me` on every visit — the same
/// endpoint the assessment-history page uses — so nothing here is seeded from
/// demonstration data.
@client
class AssessmentReportSelectorView extends StatefulComponent {
  const AssessmentReportSelectorView({super.key});

  @override
  State<AssessmentReportSelectorView> createState() =>
      _AssessmentReportSelectorViewState();
}

class _AssessmentReportSelectorViewState
    extends State<AssessmentReportSelectorView> {
  static const _api = AssessmentApi();

  late Future<ApiResult<AssessmentHistory>> _future = _api.history();

  void _reload() => setState(() => _future = _api.history());

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/cafe-report',
      title: 'Select assessment to view report',
      // The selector supplies its own breadcrumb, heading and subtitle, so the
      // shell must not print a second copy above it.
      showPageHead: false,
      showBreadcrumbs: false,
      child: FutureBuilder<ApiResult<AssessmentHistory>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const SectionCard(
              title: 'Loading your assessments',
              child: Skeleton(variant: 'row', count: 5),
            );
          }

          final result = snapshot.data;
          if (result == null || !result.ok) {
            return EmptyState(
              title: 'The assessment list did not load',
              body:
                  result?.failure?.message ??
                  'No response came back from the assessment service.',
              action: ActionButton('Try again', onClick: _reload),
            );
          }

          final items = selectorItemsFrom(result.value!.items);
          if (items.isEmpty) {
            return const EmptyState(
              title: 'No assessments yet',
              body:
                  'Assessments saved to your account appear here with the '
                  'report that belongs to each one.',
              // No create CTA: this page only selects existing
              // assessments and their reports.
            );
          }

          return AssessmentReportSelectorPage(
            assessments: items,
            // The hand-off the whole gate exists for: back to the original page.
            onViewReport: (assessmentId) {
              final href = assessmentLocationReportHref(
                result.value!.items,
                assessmentId,
              );
              if (href != null) context.push(href);
            },
            // A rental row opens that listing's detail page — the only
            // per-rental screen this app has. `View all rental details` has no
            // aggregate route, so it stays disabled rather than inventing one.
            onViewRental: (assessmentId, rentalId) => context.push(
              '/entrepreneur/property-detail?id=${Uri.encodeQueryComponent(rentalId)}',
            ),
          );
        },
      ),
    );
  }
}

/// Resolve the selected owned record to the property identifier expected by
/// the existing ReportPage. Never substitute an assessment UUID for a property.
String? assessmentLocationReportHref(
  List<AssessmentRecord> records,
  String assessmentId,
) {
  final matches = records.where((r) => r.assessmentId == assessmentId).toList();
  if (matches.length != 1 || matches.single.propertyId.isEmpty) return null;
  return '/entrepreneur/report?id=${Uri.encodeQueryComponent(matches.single.propertyId)}';
}

/// Projects the API's assessment records onto the selector's read model.
///
/// Every value comes from the record the server returned:
///
///   * three of the five counters are simply **not** in this read model
///     (`respondentCount`, `responseCount`, `externalSourceCount`), so they are
///     passed as null and the page renders "—". They are never coerced to 0,
///     which would read as "zero were recorded";
///   * report access is taken from the persisted `report_available` flag plus
///     the stage progress the server computed — never guessed from the client.
List<AssessmentListItem> selectorItemsFrom(List<AssessmentRecord> records) => [
  for (final record in records) _selectorItem(record),
];

AssessmentListItem _selectorItem(AssessmentRecord record) {
  final property = record.property;
  final updated = record.updatedAt;
  final created = record.createdAt;
  final stage = record.stageByKey(record.currentStageKey);
  final requirementsSaved = record.requirementsVersion > 0;

  return AssessmentListItem(
    id: record.assessmentId,
    businessName: property?.title ?? 'Property ${record.propertyId}',
    status: record.isCompleted
        ? AssessmentStatus.completed
        : AssessmentStatus.inProgress,
    updatedAtUtc:
        DateTime.tryParse(updated ?? '')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    updatedAtLabel: _dayLabel(updated),
    createdAtLabel: _dayLabel(created),
    // These rows come from `/assessments/me`, so the reader is the owner.
    createdByLabel: 'Your account',
    currentStageLabel: stage?.title ?? record.currentStageKey,
    completedStages: record.completedStages,
    totalStages: record.totalStages,
    // A saved business-requirements payload is the one profile this workflow
    // stores; nothing else is counted here.
    businessProfileCount: requirementsSaved ? 1 : 0,
    // Not carried by this read model — see the doc comment above.
    respondentCount: null,
    responseCount: null,
    externalSourceCount: null,
    reportAccess: _reportAccess(record),
    selectedRentals: property == null
        ? const []
        : [
            RentalSelectionSummary(
              // The catalogue id, so a rental row can open its detail page.
              id: property.id,
              title: property.title,
              locality: _localityOf(property),
              areaLabel: property.sizeSqft > 0
                  ? '${faNum(property.sizeSqft)} sq ft'
                  : 'Not recorded',
              monthlyRentLabel: property.rentalRm > 0
                  ? property.rentalDisplay
                  : 'Not recorded',
              availabilityLabel: _orNotRecorded(property.availability),
              thumbnailUrl: property.imageUrl,
            ),
          ],
  );
}

/// Access is derived from what the server persisted, not from progress alone.
/// These are location-report flags, not scientific or A10 research admission.
///
///   * `admitted` — the report has actually been generated;
///   * `draftPreview` — no admitted report yet, but the record has advanced, so
///     the read-only report shell can still be opened;
///   * `unavailable` — nothing has been recorded yet, so there is no report to
///     open. The backend independently re-authorizes every report read, so this
///     label only decides which button state the screen shows.
ReportAccess _reportAccess(AssessmentRecord record) {
  if (record.reportAvailable) return ReportAccess.admitted;
  if (record.completedStages > 0) return ReportAccess.draftPreview;
  return ReportAccess.unavailable;
}

String _localityOf(CommercialProperty property) {
  final city = property.city.trim();
  final state = property.state.trim();
  if (city.isEmpty) return state.isEmpty ? 'Not recorded' : state;
  if (state.isEmpty || state == city) return city;
  return '$city, $state';
}

String _orNotRecorded(String? value) {
  final text = value?.trim() ?? '';
  return text.isEmpty ? 'Not recorded' : text;
}

const _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// `12 Nov 2026` in local time, or "Not recorded" — never a wrong date.
String _dayLabel(String? iso) {
  final parsed = iso == null ? null : DateTime.tryParse(iso);
  if (parsed == null) return 'Not recorded';
  final local = parsed.toLocal();
  return '${local.day} ${_monthNames[local.month - 1]} ${local.year}';
}
