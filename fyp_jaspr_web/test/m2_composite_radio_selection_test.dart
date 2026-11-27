import 'package:jaspr/jaspr.dart';
import 'package:jaspr_test/jaspr_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/m2_workflow_panel.dart';
import 'package:sitewise_jaspr_web/core/di/app_locator.dart';

const mid = '00000000-0000-4000-8000-000000000001';
const iid = '00000000-0000-4000-8000-000000000002';
const qid = '00000000-0000-4000-8000-000000000003';

/// A composite item whose first field is a single-choice decision and whose
/// second is a multi-choice list.
///
/// The defect this guards against: a single-choice composite field stores one
/// **String**, and the editor used to read only the List form when deciding
/// which option was selected. Every radio group therefore rendered unselected
/// on reopen, so a saved `PRICED` decision looked unanswered — and the sample
/// guidance keyed to that decision contradicted the control beside it.
class CompositeClient extends ApiClient {
  CompositeClient({this.saved = const {'decision': 'PRICED', 'tags': ['A']}});

  final Map<String, dynamic> saved;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v1/m2/assessments') {
      return {
        'contract_version': 'm2-assessment-list/1',
        'items': [
          {'id': mid},
        ],
      };
    }
    if (path.endsWith('/$mid')) {
      return {
        'assessment': {
          'id': mid,
          'instrument_id': iid,
          'revision': 3,
          'confirmed_revision': null,
        },
        'instrument': {'id': iid, 'version_tag': 'TEST_ONLY'},
        'items': [
          {
            'id': qid,
            'instrument_id': iid,
            'item_key': 'TEST-C1',
            'question_text': 'Synthetic composite',
            'answer_kind': 'COMPOSITE',
            'requiredness': 'REQUIRED',
            'effective_required': true,
            'applicable': true,
            'allowed_states': ['ANSWERED'],
            'option_values': {
              'value_schema': {
                'fields': [
                  {
                    'name': 'decision',
                    'type': 'ENUM',
                    'label': 'Decision',
                    'values': ['PRICED', 'NOT_DECIDED'],
                  },
                  {
                    'name': 'tags',
                    'type': 'MULTI',
                    'label': 'Tags',
                    'values': ['A', 'B'],
                  },
                ],
              },
            },
          },
        ],
        'answers': {
          'TEST-C1': {
            'id': 'test-answer',
            'assessment_id': mid,
            'item_version_id': qid,
            'assessment_revision': 3,
            'answer_state': 'ANSWERED',
            'value_json': saved,
          },
        },
      };
    }
    return {};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected call');
}

Finder withClass(String name) => find.byElementPredicate(
  (element) =>
      element is DomElement &&
      (element.component.classes ?? '').split(' ').contains(name),
  description: 'an element with class $name',
);

/// The inputs the browser would render as selected.
///
/// `input` emits `checked` only when it is true (the entry is null-aware), so a
/// present attribute is exactly the selected state — the same signal the
/// browser uses.
Finder checkedInputs() => find.byElementPredicate(
  (element) =>
      element is DomElement &&
      element.component.attributes?['checked'] != null,
  description: 'a checked input',
);

void main() {
  late ApiM2Repository original;

  setUp(() => original = AppLocator.m2);
  tearDown(() => AppLocator.m2 = original);

  Component panel() => const M2WorkflowPanel(
    assessmentId: mid,
    requireExplicitId: true,
    embedded: true,
  );

  testComponents('a saved single-choice answer renders as selected', (
    tester,
  ) async {
    AppLocator.m2 = ApiM2Repository(CompositeClient());
    tester.pumpComponent(panel());
    await tester.pump();

    // The saved decision is a String; the row that represents it must be the
    // one highlighted, and exactly one radio must be checked.
    expect(
      find.ancestor(of: find.text('Priced'), matching: withClass('asw-answer')),
      findsOneComponent,
    );
    expect(
      find.ancestor(of: find.text('Priced'), matching: withClass('is-on')),
      findsOneComponent,
    );
    expect(
      find.ancestor(of: find.text('Not decided'), matching: withClass('is-on')),
      findsNothing,
    );
    expect(checkedInputs(), findsNComponents(2)); // one radio + one checkbox
  });

  testComponents('a saved multi-choice answer still renders its selections', (
    tester,
  ) async {
    AppLocator.m2 = ApiM2Repository(
      CompositeClient(saved: const {
        'decision': 'NOT_DECIDED',
        'tags': ['A', 'B'],
      }),
    );
    tester.pumpComponent(panel());
    await tester.pump();

    expect(
      find.ancestor(of: find.text('Not decided'), matching: withClass('is-on')),
      findsOneComponent,
    );
    expect(
      find.ancestor(of: find.text('Priced'), matching: withClass('is-on')),
      findsNothing,
    );
    expect(
      find.ancestor(of: find.text('A'), matching: withClass('is-on')),
      findsOneComponent,
    );
    expect(
      find.ancestor(of: find.text('B'), matching: withClass('is-on')),
      findsOneComponent,
    );
    expect(checkedInputs(), findsNComponents(3)); // one radio + both checkboxes
  });

  testComponents('an empty composite field selects nothing by default', (
    tester,
  ) async {
    AppLocator.m2 = ApiM2Repository(CompositeClient(saved: const {}));
    tester.pumpComponent(panel());
    await tester.pump();

    // The fix must not fall back to marking the first option: a field the owner
    // has not answered stays visibly unanswered.
    expect(withClass('is-on'), findsNothing);
    expect(checkedInputs(), findsNothing);
  });
}
