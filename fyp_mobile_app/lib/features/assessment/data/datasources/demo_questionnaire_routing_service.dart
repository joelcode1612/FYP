import 'package:fyp/features/assessment/domain/entities/assessment_draft.dart';
import 'package:fyp/features/assessment/domain/entities/questionnaire_question.dart';
import 'package:fyp/features/assessment/domain/services/questionnaire_routing_service.dart';

/// Synthetic UI demonstration question bank for the assessment flow.
///
/// Used only in a DEBUG, NON-LIVE build so the questionnaire can be clicked
/// through locally. A live or release build keeps the compliance hold
/// (`HeldQuestionnaireRoutingService`) and never exposes these fixture
/// questions. The switch lives in `questionnaireRoutingServiceProvider` and
/// uses the shared `assessmentDemoAllowed` gate
/// (`kDebugMode && !MobileConfig.usesLiveApi`), NOT `AppConfig.usesDemoData`
/// (a fixed compile-time boolean, not a build switch).
const demoQuestionBank = <QuestionnaireQuestion>[
  QuestionnaireQuestion(
    id: 'Q04',
    category: 'Past café purchases',
    promptEn:
        'In the past 30 days, on how many occasions have you bought food or a '
        'drink from an existing café?',
    promptBm:
        'Dalam 30 hari lalu, berapa kali anda membeli makanan atau minuman '
        'daripada kafe sedia ada?',
    helperEn:
        'Think about past purchases at existing cafés, not the proposed café.',
    helperBm:
        'Fikirkan pembelian di kafe sedia ada, bukan kafe yang dicadangkan.',
    options: [
      QuestionOption('DEMO_Q04_0', '0 occasions', '0 kali'),
      QuestionOption('DEMO_Q04_1', '1 occasion', '1 kali'),
      QuestionOption('DEMO_Q04_2_3', '2–3 occasions', '2–3 kali'),
      QuestionOption('DEMO_Q04_4_7', '4–7 occasions', '4–7 kali'),
      QuestionOption('DEMO_Q04_8_PLUS', '8 or more occasions', '8 kali atau lebih'),
      QuestionOption('DEMO_Q04_UNKNOWN', 'Cannot remember', 'Tidak ingat'),
      QuestionOption('DEMO_Q04_REFUSE', 'Prefer not to answer', 'Tidak mahu menjawab'),
    ],
  ),
  QuestionnaireQuestion(
    id: 'Q05',
    category: 'Proposed café interest',
    promptEn:
        'If the café described above opened in the selected area, how likely '
        'would you be to visit it at least once in its first three months?',
    promptBm:
        'Jika kafe yang diterangkan dibuka di kawasan yang dipilih, sejauh mana '
        'kemungkinan anda akan mengunjunginya sekurang-kurangnya sekali dalam '
        'tiga bulan pertama?',
    helperEn:
        'SIMULATED concept card only — no scientifically approved café '
        'stimulus has been supplied.',
    helperBm:
        'Kad konsep simulasi sahaja — belum ada rangsangan kafe yang '
        'diluluskan secara saintifik.',
    options: [
      QuestionOption('DEMO_Q05_DEF_NO', 'Definitely unlikely', 'Pasti tidak mungkin'),
      QuestionOption('DEMO_Q05_PROB_NO', 'Probably unlikely', 'Mungkin tidak'),
      QuestionOption('DEMO_Q05_UNSURE', 'Unsure', 'Tidak pasti'),
      QuestionOption('DEMO_Q05_PROB_YES', 'Probably likely', 'Mungkin ya'),
      QuestionOption('DEMO_Q05_DEF_YES', 'Definitely likely', 'Pasti ya'),
      QuestionOption('DEMO_Q05_REFUSE', 'Prefer not to answer', 'Tidak mahu menjawab'),
    ],
  ),
];

/// Demo routing service: resolves every draft to [demoQuestionBank] so the
/// full questionnaire flow (consent → questions → review) is exercisable in a
/// local/demo build. Mirrors the fixture copy used by the widget tests.
class DemoQuestionnaireRoutingService implements QuestionnaireRoutingService {
  const DemoQuestionnaireRoutingService();
  @override
  List<QuestionnaireQuestion> resolve(AssessmentDraft draft) => demoQuestionBank;
}
