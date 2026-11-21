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
