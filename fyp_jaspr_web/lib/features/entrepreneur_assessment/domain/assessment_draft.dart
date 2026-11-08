/// Immutable browser-only draft. Does not persist or submit any user information.
class AssessmentDraft {
  AssessmentDraft({
    this.page = 0,
    Map<String, String> singleAnswers = const {},
    Map<String, List<String>> multiAnswers = const {},
    Map<String, String> otherDetails = const {},
    this.entrepreneurConcern = '',
    this.description = '',
    this.primaryCustomer = '',
    this.reviewed = false,
    this.confirmedInDemo = false,
    this.answerRevision = 0,
  })  : singleAnswers = Map.unmodifiable(singleAnswers),
        otherDetails = Map.unmodifiable(otherDetails),
        multiAnswers = Map.unmodifiable(
          multiAnswers.map((key, value) => MapEntry(key, List<String>.unmodifiable(value))),
        );

  final int page;
  final Map<String, String> singleAnswers;
  final Map<String, List<String>> multiAnswers;
  final String description;
  final String entrepreneurConcern;
  final Map<String, String> otherDetails;
  final String primaryCustomer;
  final bool reviewed;
  final bool confirmedInDemo;
  final int answerRevision;

  String single(String id) => singleAnswers[id] ?? '';
  List<String> multi(String id) => multiAnswers[id] ?? const [];

  AssessmentDraft copyWith({
    int? page,
    Map<String, String>? singleAnswers,
    Map<String, List<String>>? multiAnswers,
    Map<String, String>? otherDetails,
    String? entrepreneurConcern,
    String? description,
    String? primaryCustomer,
    bool? reviewed,
    bool? confirmedInDemo,
    int? answerRevision,
  }) => AssessmentDraft(
        page: page ?? this.page,
        singleAnswers: singleAnswers ?? this.singleAnswers,
        multiAnswers: multiAnswers ?? this.multiAnswers,
        otherDetails: otherDetails ?? this.otherDetails,
        entrepreneurConcern: entrepreneurConcern ?? this.entrepreneurConcern,
        description: description ?? this.description,
        primaryCustomer: primaryCustomer ?? this.primaryCustomer,
        reviewed: reviewed ?? this.reviewed,
        confirmedInDemo: confirmedInDemo ?? this.confirmedInDemo,
        answerRevision: answerRevision ?? this.answerRevision,
      );
}
