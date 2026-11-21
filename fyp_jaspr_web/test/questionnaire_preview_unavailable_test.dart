import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/components/customer_questionnaire_step5.dart';

void main() {
  testComponents('missing assessment data never loads sample or publish controls', (tester) async {
    tester.pumpComponent(const CustomerQuestionnaireStep5(assessmentId: 'synthetic'));
    await tester.pump();
    expect(find.textContaining('Questionnaire records are unavailable'), findsOneComponent);
    expect(find.text('How often do you visit a café?'), findsNothing);
    expect(find.text('Publish Questionnaire'), findsNothing);
    expect(find.text('Mark this step complete'), findsNothing);
  });

  testComponents('preview renders only supplied test rows without publication', (tester) async {
    tester.pumpComponent(const CustomerQuestionnaireStep5(
      assessmentId: 'synthetic-A', rows: [CqRow(id: 'TEST-A',
        question: 'Synthetic assessment A question?', options: ['Yes', 'No'],
        type: 'Single choice', applicability: 'Test fixture only')],
    ));
    await tester.pump();
    expect(find.text('Synthetic assessment A question?'), findsOneComponent);
    expect(find.text('How often do you visit a café?'), findsNothing);
    expect(find.text('Publish Questionnaire'), findsNothing);
    expect(find.text('Mark this step complete'), findsNothing);
  });
}
