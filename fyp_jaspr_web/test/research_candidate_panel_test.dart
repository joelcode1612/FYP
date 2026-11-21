import 'package:jaspr/jaspr.dart';
import 'package:jaspr_test/jaspr_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:sitewise_jaspr_web/components/research_workflow_panel.dart';
import 'package:sitewise_jaspr_web/data/app_locator.dart';

/// The candidate panel's own behaviour, with the transport swapped.
///
/// What is covered: the exact strings a 200/abstention/409/429/503 produce, the
/// proposal marker, the absence of review actions on an abstention, the
/// rationale rule, and the history list. What is NOT covered (and cannot be,
/// today) is a real engine answer — the backend runner is `None`, so the live
/// service returns 503. These tests feed the documented payloads directly.
class PanelClient extends ApiClient {
  /// Answer for `POST .../qg-candidate` / `.../revision`.
  Map<String, dynamic>? prepare;
  Object? prepareFailure;

  /// Answer for `GET .../research-questions` (history).
  Map<String, dynamic>? history;

  /// Answer for `GET .../research-questions/{version}`.
  Map<String, dynamic>? read;

  /// Answer for `POST .../owner-review`.
  Map<String, dynamic>? review;

  final calls = <String>[];

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    calls.add('POST $path');
    if (path.endsWith('/owner-review')) {
      return review ?? {'decision': body['decision']};
    }
    if (prepareFailure != null) throw prepareFailure!;
    return prepare!;
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    calls.add('GET $path');
    if (path.endsWith('/research-questions')) {
      return history ?? {'objective_id': _objective, 'versions': []};
    }
    return read!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected request: ${invocation.memberName}');
}

const _objective = '00000000-0000-4000-8000-0000000000a1';
const _context = '00000000-0000-4000-8000-0000000000a2';
const _version = '00000000-0000-4000-8000-0000000000a3';
const _child = '00000000-0000-4000-8000-0000000000a4';

Map<String, dynamic> validated() => {
  'status': 'VALIDATED_OUTPUT',
  'version': _version,
  'candidate': {
    'question': 'How much monthly rent would you accept for this unit?',
    'response_codes': ['A', 'B'],
    'response_options': ['Below RM 4,000', 'RM 4,000 and above'],
    'reference_period': 'the next 12 months',
    'denominator_specification': 'all customer visits in a month',
    'limitations': ['Does not measure willingness to pay a deposit.'],
    'unresolved_assumptions': ['Assumes a 3-year lease.'],
  },
  'field_authority': {
    'scientifically_adopted': false,
    'fielding_authorized': false,
  },
};

void main() {
  late ApiM2Repository original;
  late PanelClient client;

  setUp(() {
    original = AppLocator.m2;
    client = PanelClient();
    AppLocator.m2 = ApiM2Repository(client);
  });
  tearDown(() => AppLocator.m2 = original);

  Component panel({String? contextId = _context}) => ResearchCandidatePanel(
    objectiveId: _objective,
    expectedRevision: 2,
    contextId: contextId,
    objectiveText: 'Which rent level is acceptable?',
  );

  testComponents('without a persisted context the prepare action is inert', (
    tester,
  ) async {
    tester.pumpComponent(panel(contextId: null));
    await tester.pump();
    expect(
      find.text(
        'A persisted business context is required before a candidate can be '
        'prepared. Read the business-context status for this confirmation '
        'first; this panel will not invent one.',
      ),
      findsOneComponent,
    );
    await tester.click(
      find.ancestor(of: find.text('Prepare question'), matching: find.tag('button')),
    );
    await tester.pump();
    expect(client.calls, isEmpty);
  });

  testComponents('a validated answer renders the candidate as a proposal', (
    tester,
  ) async {
    client.prepare = validated();
    tester.pumpComponent(panel());
    await tester.pump();
    await tester.click(
      find.ancestor(of: find.text('Prepare question'), matching: find.tag('button')),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text('How much monthly rent would you accept for this unit?'),
      findsOneComponent,
    );
    expect(find.text('A — Below RM 4,000'), findsOneComponent);
    expect(find.text('B — RM 4,000 and above'), findsOneComponent);
    expect(find.text('Reference period: the next 12 months'), findsOneComponent);
    expect(
      find.text('Denominator: all customer visits in a month'),
      findsOneComponent,
    );
    expect(
      find.text('• Does not measure willingness to pay a deposit.'),
      findsOneComponent,
    );
    expect(find.text('PROPOSAL — not confirmed'), findsOneComponent);
    // Never an approval label.
    expect(find.text('Approved'), findsNothing);
    expect(find.text('Ready to field'), findsNothing);
    // The three decisions are offered on a pending version.
    expect(find.text('Approve for further review'), findsOneComponent);
    expect(find.text('Reject'), findsOneComponent);
    expect(find.text('Request revision'), findsOneComponent);
    // And the child-version action is NOT offered until a revision is asked for.
    expect(find.text('Generate revision'), findsNothing);
  });

  testComponents('an abstention shows what is still needed, not an error', (
    tester,
  ) async {
    client.prepare = {
      'status': 'VALID_ABSTENTION',
      'version': null,
      'candidate': {
        'decision': 'ABSTAIN_NEEDS_REVIEW',
        'question': '',
        'missing_business_facts': ['PRICE'],
      },
      'missing_business_facts': ['PRICE'],
    };
    tester.pumpComponent(panel());
    await tester.pump();
    await tester.click(
      find.ancestor(of: find.text('Prepare question'), matching: find.tag('button')),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('What we still need to know'), findsOneComponent);
    expect(
      find.text(
        'The price you will actually pay (rent, deposit and lease terms)',
      ),
      findsOneComponent,
    );
    expect(find.text('Fact code: PRICE'), findsOneComponent);
    expect(find.text('Approve for further review'), findsNothing);
    expect(find.text('Request revision'), findsNothing);
  });

  testComponents('a stale revision renders the conflict, not a candidate', (
    tester,
  ) async {
    client.prepareFailure = const ConflictFailure(
      'stale',
      backendCode: 'QG_CONTEXT_REVISION_STALE',
    );
    tester.pumpComponent(panel());
    await tester.pump();
    await tester.click(
      find.ancestor(of: find.text('Prepare question'), matching: find.tag('button')),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Your research state changed'), findsOneComponent);
    expect(find.textContaining('Nothing was stored'), findsOneComponent);
    expect(find.text('Server code: QG_CONTEXT_REVISION_STALE'), findsOneComponent);
  });

  testComponents('an exhausted budget is its own message', (tester) async {
    client.prepareFailure = const ThrottledFailure(
      'budget',
      backendCode: 'MODEL_ATTEMPT_BUDGET_EXHAUSTED',
    );
    tester.pumpComponent(panel());
    await tester.pump();
    await tester.click(
      find.ancestor(of: find.text('Prepare question'), matching: find.tag('button')),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Model attempt budget exhausted'), findsOneComponent);
    expect(
      find.text('Server code: MODEL_ATTEMPT_BUDGET_EXHAUSTED'),
      findsOneComponent,
    );
  });

  testComponents('a 503 says the engine is unavailable, not that none exists', (
    tester,
  ) async {
    client.prepareFailure = const ServiceFailure.response(
      'runner missing',
      statusCode: 503,
    );
    tester.pumpComponent(panel());
    await tester.pump();
    await tester.click(
      find.ancestor(of: find.text('Prepare question'), matching: find.tag('button')),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('No question was produced'), findsOneComponent);
    expect(find.textContaining('service condition'), findsOneComponent);
  });

  testComponents('history lists every version with its recorded decision', (
    tester,
  ) async {
    client.history = {
      'objective_id': _objective,
      'objective': 'Which rent level is acceptable?',
      'version_count': 2,
      'versions': [
        {
          'version': _version,
          'depth': 0,
          'question': 'First wording',
          'options': <Map<String, dynamic>>[],
          'status': 'REQUEST_REVISION',
          'decision': 'REQUEST_REVISION',
          'rationale': 'Name the reference period.',
        },
        {
          'version': _child,
          'depth': 1,
          'question': 'Second wording',
          'options': <Map<String, dynamic>>[],
          'supersedes': _version,
          'status': 'PENDING',
          'decision': null,
        },
      ],
    };
    tester.pumpComponent(panel());
    await tester.pump();
    await tester.click(
      find.ancestor(of: find.text('Show history'), matching: find.tag('button')),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('First wording'), findsOneComponent);
    expect(find.text('Second wording'), findsOneComponent);
    expect(find.text('Revision requested'), findsOneComponent);
    expect(find.text('Awaiting your decision'), findsOneComponent);
    expect(
      find.text('Rationale: Name the reference period.'),
      findsOneComponent,
    );
    // The parent decision is not overwritten by the child.
    expect(find.textContaining('supersedes $_version'), findsOneComponent);
  });

  testComponents('a decision without a rationale never reaches the server', (
    tester,
  ) async {
    client.prepare = validated();
    tester.pumpComponent(panel());
    await tester.pump();
    await tester.click(
      find.ancestor(of: find.text('Prepare question'), matching: find.tag('button')),
    );
    await tester.pump();
    await tester.pump();

    await tester.click(
      find.ancestor(of: find.text('Reject'), matching: find.tag('button')),
    );
    await tester.pump();
    await tester.click(
      find.ancestor(
        of: find.text('Record decision'),
        matching: find.tag('button'),
      ),
    );
    await tester.pump();

    expect(
      find.text(
        'A rationale is required. For a revision it is the reason the next '
        'question must address.',
      ),
      findsOneComponent,
    );
    expect(client.calls.where((c) => c.contains('owner-review')), isEmpty);
  });
}
