enum AppLanguage { en, bm }

class LocalText {
  final String en;
  final String bm;
  const LocalText(this.en, this.bm);
  String inLanguage(AppLanguage language) =>
      language == AppLanguage.en ? en : bm;
}

enum QuestionKind { single, multiple, matrix }

class AnswerOption {
  final String code;
  final LocalText label;
  const AnswerOption(this.code, this.label);
}

class Question {
  final String id;
  final LocalText title;
  final LocalText stem;
  final LocalText help;
  final QuestionKind kind;
  final List<AnswerOption> options;
  final Set<String> exclusive;
  final int? maxSelections;
  final bool optional;
  const Question({
    required this.id,
    required this.title,
    required this.stem,
    required this.help,
    required this.options,
    this.kind = QuestionKind.single,
    this.exclusive = const {},
    this.maxSelections,
    this.optional = false,
  });
}

class Feature {
  final String id;
  final LocalText label;
  const Feature(this.id, this.label);
}

/// Immutable UI response. Refusal/uncertainty codes remain answers; an empty
/// optional response is a skip, never an implicit refusal or substantive datum.
class Answer {
  final Set<String> codes;
  final Map<String, String> ratings;
  Answer({Set<String> codes = const {}, Map<String, String> ratings = const {}})
    : codes = Set.unmodifiable(codes),
      ratings = Map.unmodifiable(ratings);
  bool get isEmpty => codes.isEmpty && ratings.isEmpty;
}

/// Synthetic UI switches are availability flags, never scientific approvals.
class DemoConfig {
  static const version = 'MOCK-UI-1';
  final bool concept;
  final bool menu;
  final bool offer;
  final bool occasions;
  final bool features;
  final bool optionalQuestions;
  const DemoConfig({
    this.concept = true,
    this.menu = true,
    this.offer = true,
    this.occasions = true,
    this.features = true,
    this.optionalQuestions = true,
  });
  DemoConfig copyWith({
    bool? concept,
    bool? menu,
    bool? offer,
    bool? occasions,
    bool? features,
    bool? optionalQuestions,
  }) => DemoConfig(
    concept: concept ?? this.concept,
    menu: menu ?? this.menu,
    offer: offer ?? this.offer,
    occasions: occasions ?? this.occasions,
    features: features ?? this.features,
    optionalQuestions: optionalQuestions ?? this.optionalQuestions,
  );
}
