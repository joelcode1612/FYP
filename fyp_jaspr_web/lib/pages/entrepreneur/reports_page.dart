import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/assessment_api.dart';
import '../../layouts/app_layout.dart';

/// Read-only report directory for the signed-in entrepreneur.
///
/// The existing `/entrepreneur/report?id=...` is a property-specific report;
/// a top-level navbar link cannot use that route without a property id.
/// This page lists only real persisted assessments, and enables the report
/// link only when the backend says `report_available == true`.
@client
class ReportsPage extends StatefulComponent {
  const ReportsPage({super.key});

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  static const _api = AssessmentApi();
  static const _pageSize = 50;

  int _offset = 0;
  late Future<ApiResult<AssessmentHistory>> _future = _load(0);

  static Future<ApiResult<AssessmentHistory>> _load(int offset) =>
      _api.history(limit: _pageSize, offset: offset);

  void _reload([int? offset]) {
    final target = offset ?? _offset;
    setState(() {
      _offset = target;
      _future = _load(target);
    });
  }

  @override
  Component build(BuildContext context) => AppLayout(
    role: AppRole.entrepreneur,
    currentRoute: '/entrepreneur/reports',
    title: 'Reports',
    eyebrow: 'Location intelligence',
    subtitle:
        'Review reports from your saved property assessments, or continue an assessment to generate one.',
    actions: const [
      ActionLink(
        'Assessment history',
        href: '/entrepreneur/assessments/history',
        variant: 'secondary',
      ),
    ],
    child: FutureBuilder<ApiResult<AssessmentHistory>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SectionCard(
            title: 'Loading assessment reports',
            child: Skeleton(variant: 'row', count: 5),
          );
        }
        final result = snapshot.data;
        if (result == null || !result.ok) {
          final failure = result?.failure;
          if (failure?.kind == AssessmentFailureKind.unauthorized) {
            return const EmptyState(
              title: 'Sign in to view reports',
              body: 'Only your own saved assessment reports are shown here.',
              action: ActionLink(
                'Go to sign in',
                href: '/login',
                variant: 'primary',
              ),
            );
          }
          return EmptyState(
            title: 'Reports could not be loaded',
            body: failure?.message ?? 'The assessment service did not respond.',
            action: ActionButton('Try again', onClick: _reload),
          );
        }

        final history = result.value;
        if (history == null || history.items.isEmpty) {
          if (_offset > 0) {
            return EmptyState(
              title: 'No further assessments',
              body: 'This page of the report directory is empty.',
              action: ActionButton('Back to first page', onClick: () => _reload(0)),
            );
          }
          return const EmptyState(
            title: 'No assessments or reports yet',
            body: 'Start a property assessment. When its report has been saved, you can open it here.',
            action: ActionLink(
              'Start an assessment',
              href: '/entrepreneur/assessments',
              variant: 'primary',
            ),
          );
        }
        return _table(history);
      },
    ),
  );

  Component _table(AssessmentHistory history) {
    final availableOnPage = history.items.where((x) => x.reportAvailable).length;
    final remaining = history.total - _offset - history.items.length;
    return div(classes: 'stack stack--md', [
      SectionCard(
        title: '$availableOnPage ready on this page · ${history.total} saved assessments',
        flush: true,
        child: div(classes: 'table-scroll', [
          table(classes: 'audit-table', [
            thead([
              tr([
                th([Component.text('Property')]),
                th([Component.text('Assessment')]),
                th([Component.text('Report')]),
                th([Component.text('Action')]),
              ]),
            ]),
            tbody([for (final assessment in history.items) _row(assessment)]),
          ]),
        ]),
      ),
      if (remaining > 0)
        div(classes: 'actions-row', [
          ActionButton(
            'Next ${remaining > _pageSize ? _pageSize : remaining} assessments',
            variant: 'secondary',
            onClick: () => _reload(_offset + _pageSize),
          ),
        ]),
      p(classes: 'disclaimer', [
        Component.text(
          'Reports are not created by opening this page. Availability is read from the saved assessment record. '
          'If the backend has not generated a report, continue the assessment instead.',
        ),
      ]),
    ]);
  }

  Component _row(AssessmentRecord record) {
    final property = record.property;
    final encodedId = Uri.encodeComponent(record.propertyId);
    return tr([
      td([
        span(classes: 'who', [
          Component.text(property?.title ?? 'Property ${record.propertyId}'),
        ]),
        span(classes: 'sub', [
          Component.text(property == null
              ? 'Catalogue property unavailable'
              : '${property.city}, ${property.state}'),
        ]),
      ]),
      td([
        StatusBadge(
          record.isCompleted ? 'Completed' : 'In progress',
          tone: record.isCompleted ? 'success' : 'action',
        ),
      ]),
      td([
        if (record.reportAvailable)
          const StatusBadge('Ready', tone: 'success')
        else
          span(classes: 'small asw-muted', [
            Component.text(
              record.capabilities.report.reason ?? 'Not generated yet',
            ),
          ]),
      ]),
      td([
        if (record.reportAvailable)
          AppLink(
            to: '/entrepreneur/report?id=$encodedId',
            classes: 'text-action',
            children: [Component.text('View report')],
          )
        else
          AppLink(
            to: '/entrepreneur/assessments?id=$encodedId',
            classes: 'text-action',
            children: [Component.text('Continue assessment')],
          ),
      ]),
    ]);
  }
}
