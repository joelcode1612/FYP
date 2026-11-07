import 'package:shared_logic/shared_logic.dart';

/// One in-session business assessment draft.
///
/// The app has **no persisted assessment entity** (no backend contract and no
/// storage dependency in `shared_logic`), so a draft lives only as long as the
/// process. Every screen that renders it must label it session-only — never
/// present it as saved history.
class AssessmentDraft {
  final CommercialProperty property;
  final String concept;
  final String audience;
  final double? budgetRm;
  final bool saved;

  const AssessmentDraft({
    required this.property,
    this.concept = '',
    this.audience = '',
    this.budgetRm,
    this.saved = false,
  });

  bool get hasInputs => concept.isNotEmpty && audience.isNotEmpty && budgetRm != null;

  /// 0-based flow position: 0 = business details pending, 1 = inputs entered,
  /// 2 = summary reached (same step the draft was saved from).
  int get step {
    if (saved) return 2;
    return hasInputs ? 1 : 0;
  }

  AssessmentDraft copyWith({String? concept, String? audience, double? budgetRm, bool? saved}) =>
      AssessmentDraft(
        property: property,
        concept: concept ?? this.concept,
        audience: audience ?? this.audience,
        budgetRm: budgetRm ?? this.budgetRm,
        saved: saved ?? this.saved,
      );
}

/// Holds the single active assessment draft for this app session.
///
/// A plain mutable holder (same pattern as `ServiceLocator.preferences`)
/// rather than a Cubit: the draft is written by the flow screens and read on
/// navigation, and every route push rebuilds its page, so no stream is needed.
class AssessmentSessionStore {
  AssessmentDraft? _draft;

  AssessmentDraft? get draft => _draft;

  bool get hasDraft => _draft != null;

  /// Opens the flow for [property], or resumes it when the draft already
  /// points at the same listing — reopening an existing record must never
  /// create a duplicate assessment. Choosing a different property replaces
  /// the draft so a stale concept is never shown against a new listing.
  void start(CommercialProperty property) {
    final d = _draft;
    if (d != null && d.property.id == property.id) return;
    _draft = AssessmentDraft(property: property);
  }

  void updateInputs({
    required String concept,
    required String audience,
    required double budgetRm,
  }) {
    final d = _draft;
    if (d == null) return;
    _draft = d.copyWith(
      concept: concept,
      audience: audience,
      budgetRm: budgetRm,
    );
  }

  /// Marks the draft saved **for this session only**. There is no persistence
  /// layer behind this; screens must keep saying so.
  void markSaved() {
    final d = _draft;
    if (d == null) return;
    _draft = d.copyWith(saved: true);
  }

  void discard() => _draft = null;
}
