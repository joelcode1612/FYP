/// M2 entrepreneur questionnaire — shared domain model.
///
/// Framework-free (pure Dart) so the Flutter app and the Jaspr web app can both
/// consume it. The ViewModel lives in `application/notifiers/`, the fixtures in
/// `data/datasources/local/`.
///
/// **Provenance.** Ported from the Jaspr prototype's `lib/prototype/
/// prototype_data.dart` (version `PROTO-V4-2026-10-28`). That source states
/// plainly that it is *illustrative*: not a scientific instrument, not fielded
/// research, not approved benchmark data, and its item IDs are **local to the
/// prototype**, not the frozen B03 register IDs. Those caveats travel with the
/// data — see `m2_prototype_data.dart`.
library;

/// How an M2 item is answered.
///
/// The web prototype encoded this as a bare string (`'choice' | 'multi' |
/// 'text' | 'action'`). A typed enum is used here so an unknown value is a
/// compile error rather than a silent fall-through to "text".
enum M2ItemType {
  /// Single selection from [M2Item.options].
  choice,

  /// Multiple selections from [M2Item.options].
  multi,

  /// Free-text answer.
  text,

  /// A governance/review action rather than an answer field. Actions are not
  /// counted toward progress and cannot be "answered".
  action,
}

/// One M2 questionnaire item.
class M2Item {
  /// Prototype-local identifier (`M2-01` …). Not a frozen B03 register ID.
  final String id;

  /// Display section, e.g. `A · Entrepreneur & experience`.
  final String section;

  final M2ItemType type;

  final String prompt;

  final bool required;

  /// Selectable options for [M2ItemType.choice] and [M2ItemType.multi].
  final List<String> options;

  /// Pre-filled illustrative answer. Empty for actions.
  ///
  /// For [M2ItemType.multi] this is a comma-separated list.
  final String sample;

  const M2Item({
    required this.id,
    required this.section,
    required this.type,
    required this.prompt,
    required this.required,
    this.options = const [],
    this.sample = '',
  });

  /// Whether this item contributes to progress and validation.
  bool get isAnswerField => type != M2ItemType.action;

  /// The [sample] parsed into a set for [M2ItemType.multi].
  Set<String> get sampleMulti => sample
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toSet();
}

/// Immutable state of an in-progress M2 assessment.
///
/// Two answer maps are kept rather than one `Object` map: the web prototype did
/// the same (`Map<String, String> _answers` + `Map<String, Set<String>> _multi`)
/// and the split keeps the mobile form typed.
class M2AssessmentState {
  /// Single-value answers, keyed by item id. Covers [M2ItemType.choice] and
  /// [M2ItemType.text].
  final Map<String, String> answers;

  /// Multi-select answers, keyed by item id.
  final Map<String, Set<String>> multi;

  /// Whether validation messages should be shown. Set by a failed submit.
  final bool showErrors;

  /// Whether the questionnaire has been submitted.
  final bool submitted;

  const M2AssessmentState({
    this.answers = const {},
    this.multi = const {},
    this.showErrors = false,
    this.submitted = false,
  });

  /// Seed every field from its illustrative [M2Item.sample].
  ///
  /// Matches the web prototype's `_resetToSamples()`.
  factory M2AssessmentState.seeded(Iterable<M2Item> items) {
    final answers = <String, String>{};
    final multi = <String, Set<String>>{};
    for (final item in items) {
      if (item.type == M2ItemType.multi) {
        multi[item.id] = item.sampleMulti;
      } else if (item.type != M2ItemType.action) {
        answers[item.id] = item.sample;
      }
    }
    return M2AssessmentState(answers: answers, multi: multi);
  }

  M2AssessmentState copyWith({
    Map<String, String>? answers,
    Map<String, Set<String>>? multi,
    bool? showErrors,
    bool? submitted,
  }) {
    return M2AssessmentState(
      answers: answers ?? this.answers,
      multi: multi ?? this.multi,
      showErrors: showErrors ?? this.showErrors,
      submitted: submitted ?? this.submitted,
    );
  }

  /// Whether [item] currently has a non-empty answer.
  bool isAnswered(M2Item item) {
    if (item.type == M2ItemType.action) return false;
    if (item.type == M2ItemType.multi) {
      return (multi[item.id] ?? const <String>{}).isNotEmpty;
    }
    return (answers[item.id] ?? '').trim().isNotEmpty;
  }

  /// Answer fields that have a value.
  int answeredCount(Iterable<M2Item> items) =>
      items.where((i) => i.isAnswerField && isAnswered(i)).length;

  /// Total answer fields (actions excluded).
  int fieldCount(Iterable<M2Item> items) =>
      items.where((i) => i.isAnswerField).length;

  /// Required fields still empty.
  List<M2Item> missingRequired(Iterable<M2Item> items) => items
      .where((i) => i.isAnswerField && i.required && !isAnswered(i))
      .toList();

  /// Completion in the range 0.0–1.0.
  double progress(Iterable<M2Item> items) {
    final total = fieldCount(items);
    if (total == 0) return 0;
    return answeredCount(items) / total;
  }

  /// Section headings in first-seen order.
  static List<String> sectionsOf(Iterable<M2Item> items) {
    final seen = <String>[];
    for (final item in items) {
      if (!seen.contains(item.section)) seen.add(item.section);
    }
    return seen;
  }

  /// Items belonging to [section], in declaration order.
  static List<M2Item> itemsInSection(Iterable<M2Item> items, String section) =>
      items.where((i) => i.section == section).toList();
}
