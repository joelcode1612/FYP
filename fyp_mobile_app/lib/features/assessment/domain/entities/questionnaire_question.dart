class QuestionOption {
  final String code;
  final String en;
  final String bm;
  const QuestionOption(this.code, this.en, this.bm);
  String label(String language) => language == 'bm' ? bm : en;
}

class QuestionnaireQuestion {
  final String id;
  final String category;
  final String promptEn;
  final String promptBm;
  final String helperEn;
  final String helperBm;
  final List<QuestionOption> options;
  const QuestionnaireQuestion({
    required this.id,
    required this.category,
    required this.promptEn,
    required this.promptBm,
    required this.helperEn,
    required this.helperBm,
    required this.options,
  });
  String prompt(String language) => language == 'bm' ? promptBm : promptEn;
  String helper(String language) => language == 'bm' ? helperBm : helperEn;
}

/// UI demonstration of TWO example items from the bank of 13.
/// Demo codes are deliberately prefixed: NOT the approved CUST03 codebook.
const demoQuestionBank = <QuestionnaireQuestion>[
  QuestionnaireQuestion(
    id: 'Q04',
    category: 'Past café purchases',
    promptEn:
        'In the past 30 days, on how many occasions have you bought food or a drink from an existing café?',
    promptBm:
        'Dalam 30 hari lalu, berapa kali anda membeli makanan atau minuman daripada kafe sedia ada?',
    helperEn:
        'Think about past purchases at existing cafés, not the proposed café.',
    helperBm:
        'Fikirkan pembelian di kafe sedia ada, bukan kafe yang dicadangkan.',
    options: [
      QuestionOption('DEMO_Q04_0', '0 occasions', '0 kali'),
      QuestionOption('DEMO_Q04_1', '1 occasion', '1 kali'),
      QuestionOption('DEMO_Q04_2_3', '2–3 occasions', '2–3 kali'),
      QuestionOption('DEMO_Q04_4_7', '4–7 occasions', '4–7 kali'),
      QuestionOption(
        'DEMO_Q04_8_PLUS',
        '8 or more occasions',
        '8 kali atau lebih',
      ),
      QuestionOption('DEMO_Q04_UNKNOWN', 'Cannot remember', 'Tidak ingat'),
      QuestionOption(
        'DEMO_Q04_REFUSE',
        'Prefer not to answer',
        'Tidak mahu menjawab',
      ),
    ],
  ),
  QuestionnaireQuestion(
    id: 'Q05',
    category: 'Proposed café interest',
    promptEn:
        'If the café described above opened in the selected area, how likely would you be to visit it at least once in its first three months?',
    promptBm:
        'Jika kafe yang diterangkan dibuka di kawasan yang dipilih, sejauh mana kemungkinan anda akan mengunjunginya sekurang-kurangnya sekali dalam tiga bulan pertama?',
    helperEn:
        'SIMULATED concept card only — no scientifically approved café stimulus has been supplied.',
    helperBm:
        'Kad konsep simulasi sahaja — belum ada rangsangan kafe yang diluluskan secara saintifik.',
    options: [
      QuestionOption(
        'DEMO_Q05_DEF_NO',
        'Definitely unlikely',
        'Pasti tidak mungkin',
      ),
      QuestionOption('DEMO_Q05_PROB_NO', 'Probably unlikely', 'Mungkin tidak'),
      QuestionOption('DEMO_Q05_UNSURE', 'Unsure', 'Tidak pasti'),
      QuestionOption('DEMO_Q05_PROB_YES', 'Probably likely', 'Mungkin ya'),
      QuestionOption('DEMO_Q05_DEF_YES', 'Definitely likely', 'Pasti ya'),
      QuestionOption(
        'DEMO_Q05_REFUSE',
        'Prefer not to answer',
        'Tidak mahu menjawab',
      ),
    ],
  ),
];
