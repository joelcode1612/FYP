import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/assessment_api.dart';
import '../../data/assessment_format.dart';
import '../../layouts/app_layout.dart';

/// Every assessment this entrepreneur has started, newest first.
///
/// ```text
/// .page-head     "Assessment history" · count
/// SectionCard    .table-scroll > table.audit-table
///                property · status · progress · last updated · report · reopen
/// ```
///
/// The rows come from `GET /api/v1/assessments/me` and nothing else. A record
/// only appears here once it has been persisted, so the list can never be
/// seeded from demonstration data or from what the browser happens to have
/// visited this session.
///
/// "Reopen" is a link into the workspace, not a mutation: opening a row resumes
/// the stored record at whatever stage it actually reached.
@client
class AssessmentHistoryPage extends StatefulComponent {
  const AssessmentHistoryPage({super.key});

  @override
  State<AssessmentHistoryPage> createState() => _AssessmentHistoryPageState();
}

class _AssessmentHistoryPageState extends State<AssessmentHistoryPage> {
  static const _api = AssessmentApi();
  static const _pageSize = 50;

  late Future<ApiResult<AssessmentHistory>> _future = _load(0);
  int _offset = 0;

  static Future<ApiResult<AssessmentHistory>> _load(int offset) =>
      _api.history(limit: _pageSize, offset: offset);

  void _reload(int offset) {
    setState(() {
      _offset = offset;
      _future = _load(offset);
    });
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/assessments',
      title: 'Assessment history',
      eyebrow: 'Assessments',
      subtitle:
          'Every location assessment saved to your account. Reopen one to '
          'continue from the stage it reached.',
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
          if (result == null) {
            return EmptyState(
              title: 'The history did not load',
              body: 'No response came back from the assessment service.',
              action: ActionButton(
                'Try again',
                onClick: () => _reload(_offset),
              ),
            );
          }
          if (!result.ok) return _failure(result.failure!);

          final history = result.value!;
          if (history.items.isEmpty) {
            return const EmptyState(
              title: 'No assessments yet',
              body:
                  'Assessments you start are saved here, so you can leave one '
                  'part-finished and pick it up later. Choose a property to '
                  'begin.',
              action: ActionLink(
                'Browse commercial properties',
                href: '/entrepreneur/explore',
                variant: 'primary',
              ),
            );
          }
          return _list(history);
        },
      ),
    );
  }

  /// The four failure kinds the workspace distinguishes, mapped the same way so
  /// the two pages never disagree about what a status code means.
  Component _failure(AssessmentFailure failure) {
    return switch (failure.kind) {
      AssessmentFailureKind.unauthorized => const EmptyState(
        title: 'You are not signed in to this workspace',
        body:
            'Assessment history belongs to your account, so the service will '
            'only return it to a signed-in entrepreneur.',
        action: ActionLink('Go to sign in', href: '/login', variant: 'primary'),
      ),
      AssessmentFailureKind.notFound => EmptyState(
        title: 'No history endpoint response',
        body: failure.message,
        action: ActionButton('Try again', onClick: () => _reload(_offset)),
      ),
      AssessmentFailureKind.refused => EmptyState(
        title: 'The request was refused',
        body: failure.message,
      ),
      AssessmentFailureKind.serviceFailure => EmptyState(
        title: 'The assessment service did not respond',
        body:
            '${failure.message} Nothing was lost: your saved assessments are '
            'still on the server.',
        action: ActionButton('Try again', onClick: () => _reload(_offset)),
      ),
    };
  }

  Component _list(AssessmentHistory history) {
    final shown = history.items.length;
    final remaining = history.total - _offset - shown;
    return div(classes: 'stack stack--md', [
      SectionCard(
        title:
            '${history.total} '
            '${history.total == 1 ? 'assessment' : 'assessments'}',
        flush: true,
        child: div(classes: 'table-scroll', [
          table(classes: 'audit-table', [
            thead([
              tr([
                th([Component.text('Property')]),
                th([Component.text('Status')]),
                th([Component.text('Progress')]),
                th([Component.text('Last updated')]),
                th([Component.text('Report')]),
                th([Component.text('')]),
              ]),
            ]),
            tbody([for (final record in history.items) _row(record)]),
          ]),
        ]),
      ),
      if (remaining > 0)
        div(classes: 'actions-row', [
          ActionButton(
            'Load ${remaining > _pageSize ? _pageSize : remaining} more',
            variant: 'secondary',
            onClick: () => _reload(_offset + _pageSize),
          ),
        ]),
      p(classes: 'disclaimer', [
        Component.text(
          'This list is read from the server on every visit. An assessment '
          'appears here only after it has been saved, and reopening one '
          'continues the stored record rather than starting a new one.',
        ),
      ]),
    ]);
  }

  Component _row(AssessmentRecord record) {
    final property = record.property;
    final bucket = (record.progressPercent / 5).round() * 5;
    return tr([
      // Property. A listing that has since left the catalogue is named as
      // unavailable rather than blanked or given an invented title.
      td([
        if (property != null)
          AppLink(
            to: '/entrepreneur/assessment?id=${record.propertyId}',
            classes: 'who text-action',
            children: [Component.text(property.title)],
          )
        else
          span(classes: 'who', [
            Component.text('Listing no longer in the catalogue'),
          ]),
        span(classes: 'sub', [
          Component.text(
            property == null
                ? 'Property ${record.propertyId}'
                : '${property.address}, ${property.city}',
          ),
        ]),
      ]),
      td([
        StatusBadge(
          record.isCompleted ? 'Completed' : 'In progress',
          tone: record.isCompleted ? 'success' : 'action',
        ),
      ]),
      td([
        div(classes: 'stack stack--xs', [
          span(classes: 'small', [
            Component.text(
              '${record.completedStages} of ${record.totalStages} stages',
            ),
          ]),
          div(classes: 'progress-track', [i(classes: 'w-$bucket', [])]),
          span(classes: 'small asw-muted', [
            Component.text(
              record.isCompleted
                  ? 'All stages recorded'
                  : 'Current: ${record.currentStage} — '
                        '${record.stageByKey(record.currentStageKey)?.title ?? record.currentStageKey}',
            ),
          ]),
        ]),
      ]),
      td([
        Component.text(
          assessmentStampOrNull(record.updatedAt) ?? 'Not recorded',
        ),
      ]),
      // Report availability is the persisted flag, not a guess from progress:
      // a completed assessment whose report generator is unavailable still
      // reads as unavailable here.
      td([
        if (record.reportAvailable)
          AppLink(
            to: '/entrepreneur/report?id=${record.propertyId}',
            classes: 'text-action',
            children: [Component.text('Open report')],
          )
        else
          span(classes: 'small asw-muted', [
            Component.text(
              record.capabilities.report.reason ?? 'Not available',
            ),
          ]),
      ]),
      td([
        AppLink(
          to: '/entrepreneur/assessment?id=${record.propertyId}',
          classes: 'text-action',
          children: [Component.text(record.isCompleted ? 'Review' : 'Reopen')],
        ),
      ]),
    ]);
  }
}
