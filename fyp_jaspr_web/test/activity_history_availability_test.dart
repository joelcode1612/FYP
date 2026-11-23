import 'package:jaspr/dom.dart';
import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/pages/activity_history_page.dart';

/// These tests cover the read-only projection surface only: chronology,
/// de-duplication, failed-outcome retention, pagination and the difference
/// between "no records" and "records unavailable".
///
/// They were rewritten after an audit found the previous version asserting
/// headings this page has never rendered ('Activity Timeline (3)', 'Filters',
/// 'Activity Details'). Those assertions could not pass against the committed
/// page, so the file was not evidence of anything. The intent is preserved;
/// the selectors now match real rendered text.
void main() {
  AssessmentActivity event(String id, String at, String status) =>
      AssessmentActivity(
        eventId: id,
        occurredAtIso: at,
        engine: 'BDJ',
        activityType: 'TEST_RECEIPT',
        status: status,
        title: id,
        summary: 'Metadata only',
        actor: 'Actor not recorded',
        revision: 2,
        version: '2',
        reason: 'TEST_REASON',
        sourceIsCurrent: false,
      );

  testComponents(
    'UTC chronology, deduplication and failed outcomes survive later recovery',
    (tester) async {
      final failure = event('failed-receipt', '2026-11-13T10:30:00Z', 'FAILED');
      // Local-looking 11:00+02 is 09:00Z, earlier than the failure.
      final earlier = event(
        'earlier-receipt',
        '2026-11-13T11:00:00+02:00',
        'PROCESSING',
      );
      tester.pumpComponent(
        ActivityHistoryPage(
          businessName: 'Test source',
          assessmentId: 'test',
          activities: [
            earlier,
            failure,
            failure,
            event('recovered-receipt', '2026-11-13T12:00:00Z', 'COMPLETED'),
          ],
          workflowHistory: true,
          sourceCoverage: const ['QJ: NOT_VERIFIED — missing source.'],
        ),
      );
      await tester.pump();
      // Four inputs, one duplicate → three distinct records.
      expect(
        find.text('3 matching activities · Newest first'),
        findsOneComponent,
      );
      expect(find.text('failed-receipt').evaluate().length, greaterThan(0));
      expect(
        find.text('QJ: NOT_VERIFIED — missing source.'),
        findsOneComponent,
      );
      expect(
        find
            .text(
              'Historical source revision — original outcome retained; not a current handoff.',
            )
            .evaluate()
            .length,
        greaterThan(0),
      );
      // Backend-supplied status filtering must retain the distinct failed receipt.
      final filters = find.byType(select).evaluate().toList();
      (filters.last.component as select).onChange!(['FAILED']);
      await tester.pump();
      expect(
        find.text('1 matching activity · Newest first'),
        findsOneComponent,
      );
      expect(find.text('recovered-receipt'), findsNothing);
    },
  );

  testComponents(
    'loaded-window pagination preserves events and authorization boundary',
    (tester) async {
      tester.pumpComponent(
        ActivityHistoryPage(
          businessName: 'Test source',
          assessmentId: 'test',
          activities: [
            for (var i = 0; i < 8; i++)
              event('receipt-$i', '2026-11-13T12:00:0${i}Z', 'PERSISTED'),
          ],
          workflowHistory: true,
          currentSnapshots: const [
            'Confirmation test · FAILED · historical source',
          ],
          sourceCoverage: const [
            'Scientific / Owner / Fielding: NOT_VERIFIED — no decisions.',
          ],
        ),
      );
      await tester.pump();
      expect(find.text('Page 1 of 2'), findsOneComponent);
      expect(find.text('receipt-0'), findsNothing);
      await tester.click(
        find.ancestor(of: find.text('Next ›'), matching: find.tag('button')),
      );
      await tester.pump();
      expect(find.text('Page 2 of 2'), findsOneComponent);
      expect(find.text('receipt-0').evaluate().length, greaterThan(0));
      expect(
        find.text('Latest BCB status snapshots — not attempt history'),
        findsOneComponent,
      );
      expect(
        find.text(
          'Scientific / Owner / Fielding: NOT_VERIFIED — no decisions.',
        ),
        findsOneComponent,
      );
    },
  );

  testComponents(
    'existing Activity History layout stays visible without loaded records',
    (tester) async {
      tester.pumpComponent(
        const ActivityHistoryPage(
          businessName: 'Saved M2 assessment',
          assessmentId: '',
          activities: [],
          activitiesAvailable: false,
          availabilityMessage: 'Saved activity could not be loaded.',
        ),
      );
      await tester.pump();
      for (final text in [
        'Activity history',
        'Engine / module',
        'Filter activities',
        'Activity details',
        'Timeline unavailable',
        'Pagination unavailable',
      ]) {
        expect(find.text(text), findsOneComponent);
      }
      // Unavailable must not render as a known-empty list.
      expect(find.text('No activities recorded yet'), findsNothing);
      expect(find.text('No matching activities'), findsNothing);
      // One assessment picker plus the three filter selects.
      expect(find.tag('select'), findsNComponents(4));
    },
  );

  testComponents('known empty activity is distinct from unavailable data', (
    tester,
  ) async {
    tester.pumpComponent(
      const ActivityHistoryPage(
        businessName: 'Saved M2 assessment',
        assessmentId: 'saved-assessment',
        activities: [],
      ),
    );
    await tester.pump();
    expect(
      find.text('0 matching activities · Newest first'),
      findsOneComponent,
    );
    expect(find.text('No activities recorded yet'), findsOneComponent);
    expect(find.text('Pagination unavailable'), findsNothing);
    expect(find.text('Timeline unavailable'), findsNothing);
  });
}
