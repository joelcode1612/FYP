import 'package:jaspr_test/jaspr_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:sitewise_jaspr_web/data/app_locator.dart';
import 'package:sitewise_jaspr_web/pages/entrepreneur/confirmed_business_review_page.dart';
import '../../shared_logic/test/confirmed_review_contract_test.dart'
    show reviewFixture, aid, cid;
import 'package:sitewise_jaspr_web/pages/entrepreneur/review_portal_page.dart';
import 'fixtures/review_demo_data.dart';

class Client extends ApiClient {
  Object? failure;
  int reads = 0;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    reads++;
    if (failure != null) throw failure!;
    return reviewFixture();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No mutations allowed.');
}

void main() {
  late ApiConfirmedReviewRepository original;
  late Client client;
  setUp(() {
    original = AppLocator.confirmedReview;
    client = Client();
    AppLocator.confirmedReview = ApiConfirmedReviewRepository(client);
  });
  tearDown(() => AppLocator.confirmedReview = original);
  testComponents('unconnected candidate actions cannot manufacture decisions or notes', (tester) async {
    tester.pumpComponent(ReviewPortalPage(assessmentTitle: demoAssessmentTitle,
      assessmentId: demoAssessmentId, batchId: demoBatchId, findings: [],
      descriptionSections: [], candidates: demoCandidates));
    await tester.pump();
    final approve = find.ancestor(of: find.text('Approve'), matching: find.tag('button'));
    final note = find.ancestor(of: find.text('Add note'), matching: find.tag('button'));
    expect(approve, findsOneComponent);
    await tester.click(approve);
    await tester.click(note);
    await tester.pump();
    expect(find.text('Candidate accepted for scientific review'), findsNothing);
    expect(find.text('Note added'), findsNothing);
  });
  testComponents(
    'requires explicit source refs without guessing a workspace binding',
    (tester) async {
      tester.pumpComponent(
        const ConfirmedBusinessReviewPage(
          assessmentId: '',
          confirmationId: '',
          revision: -1,
        ),
      );
      await tester.pump();
      expect(find.text('Business review source required'), findsOneComponent);
      expect(client.reads, 0);
    },
  );
  testComponents(
    'renders saved declaration without fake decisions, counts or notes',
    (tester) async {
      tester.pumpComponent(
        const ConfirmedBusinessReviewPage(
          assessmentId: aid,
          confirmationId: cid,
          revision: 1,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Confirmed business review'), findsOneComponent);
      expect(find.text('Synthetic declaration'), findsComponents);
      expect(find.text('Approve'), findsNothing);
      expect(find.text('Add note'), findsNothing);
      expect(find.text('QJ Questions'), findsNothing);
      await tester.click(
        find.ancestor(
          of: find.text('Show saved M2 activity'),
          matching: find.tag('button'),
        ),
      );
      await tester.pump();
      expect(find.text('Answer revision saved'), findsComponents);
    },
  );
  testComponents(
    'failed source read supports retry without a successful empty history',
    (tester) async {
      client.failure = StateError('Source unavailable');
      tester.pumpComponent(
        const ConfirmedBusinessReviewPage(
          assessmentId: aid,
          confirmationId: cid,
          revision: 1,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Business review unavailable'), findsOneComponent);
      expect(find.text('Confirmed business review'), findsNothing);
      client.failure = null;
      await tester.click(
        find.ancestor(of: find.text('Retry'), matching: find.tag('button')),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Confirmed business review'), findsOneComponent);
    },
  );
}
