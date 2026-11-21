import 'package:jaspr_test/jaspr_test.dart';
import 'package:jaspr/dom.dart';
import 'package:sitewise_jaspr_web/pages/entrepreneur/activity_history_page.dart';

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
      expect(find.text('Activity Timeline (3)'), findsOneComponent);
      expect(find.text('recovered-receipt'), findsNComponents(2));
      expect(find.text('failed-receipt'), findsOneComponent);
      expect(
        find.text('QJ: NOT_VERIFIED — missing source.'),
        findsOneComponent,
      );
      expect(
        find.text(
          'Historical source revision — original outcome retained; not a current handoff.',
        ),
        findsOneComponent,
      );
      // Backend-supplied status filtering must retain the distinct failed receipt.
      final filters = find.byType(select).evaluate().toList();
      (filters[2].component as select).onChange!(['FAILED']);
      await tester.pump();
      expect(find.text('Activity Timeline (1)'), findsOneComponent);
      expect(find.text('failed-receipt'), findsNComponents(2));
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
        find.ancestor(of: find.text('Next'), matching: find.tag('button')),
      );
      await tester.pump();
      expect(find.text('Page 2 of 2'), findsOneComponent);
      expect(find.text('receipt-0'), findsOneComponent);
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
        'Activity History',
        'Engine / Module',
        'Filters',
        'Activity Details',
        'Activity Timeline — unavailable',
        'Pagination unavailable',
      ]) {
        expect(find.text(text), findsOneComponent);
      }
      expect(find.text('Activity Timeline (0)'), findsNothing);
      expect(
        find.text('No recorded activity matches these filters.'),
        findsNothing,
      );
      expect(find.tag('select'), findsNComponents(3));
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
    expect(find.text('Activity Timeline (0)'), findsOneComponent);
    expect(
      find.text('No recorded activity matches these filters.'),
      findsOneComponent,
    );
    expect(find.text('Pagination unavailable'), findsNothing);
  });
}
