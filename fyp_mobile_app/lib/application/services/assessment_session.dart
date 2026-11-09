import 'package:shared_logic/shared_logic.dart';

/// One active business assessment draft.
///
/// There is **no persisted assessment entity on the backend** (no backend
/// contract for it), so a draft is never sent anywhere — but it IS written
/// through to device storage (user-scoped, via `ApplicationDraftRepository`)
/// so an interrupted app resumes instead of discarding typed work. Screens
/// must present it as a device draft, never as saved history.
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
  /// Called after every draft mutation so the caller can write the draft
  /// through to [ApplicationDraftRepository]. Best-effort: the hook receives
  /// the draft, or an [_EmptyDraft] sentinel (empty property id) meaning
  /// "clear the persisted copy".
  AssessmentSessionStore({this.onPersist});

  final void Function(AssessmentDraft draft)? onPersist;

  AssessmentDraft? _draft;

  AssessmentDraft? get draft => _draft;

  bool get hasDraft => _draft != null;

  /// Re-attaches a draft restored from disk at boot. Never persists — the
  /// copy on disk is already authoritative for this data.
  void restore(AssessmentDraft draft) {
    _draft = draft;
  }

  /// Opens the flow for [property], or resumes it when the draft already
  /// points at the same listing — reopening an existing record must never
  /// create a duplicate assessment. Choosing a different property replaces
  /// the draft so a stale concept is never shown against a new listing.
  void start(CommercialProperty property) {
    final d = _draft;
    if (d != null && d.property.id == property.id) return;
    _draft = AssessmentDraft(property: property);
    _persist();
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
    _persist();
  }

  /// Marks the draft saved and writes that step through to disk, so a
  /// restart resumes at the summary instead of the first input screen.
  void markSaved() {
    final d = _draft;
    if (d == null) return;
    _draft = d.copyWith(saved: true);
    _persist();
  }

  /// Explicit user discard. Clears the in-session copy AND the persisted
  /// one (via the sentinel). A failed network request must never route
  /// here — clearing on failure is exactly the bug this store prevents.
  void discard() {
    _draft = null;
    try {
      onPersist?.call(const _EmptyDraft());
    } catch (_) {
      // Persisting the clear is best-effort; the in-session discard is done.
    }
  }

  void _persist() {
    final d = _draft;
    if (d == null) return;
    try {
      onPersist?.call(d);
    } catch (_) {
      // Write-through is best-effort: losing the disk copy degrades to the
      // old session-only behaviour, it must never crash the flow.
    }
  }
}

/// Sentinel passed to [AssessmentSessionStore]'s `onPersist` hook when the
/// draft is discarded: an empty property id tells the repository to clear
/// the stored copy instead of writing one.
class _EmptyDraft implements AssessmentDraft {
  const _EmptyDraft();

  @override
  CommercialProperty get property => CommercialProperty(
        id: '',
        title: '',
        address: '',
        city: '',
        state: '',
        postcode: '',
        rentalRm: 0,
        sizeSqft: 0,
        latitude: 0,
        longitude: 0,
        propertyType: '',
        verification: VerificationStatus.draft,
        suitabilityScore: 0,
        ownerId: '',
        hasTour: false,
      );

  @override
  String get concept => '';

  @override
  String get audience => '';

  @override
  double? get budgetRm => null;

  @override
  bool get saved => false;

  @override
  bool get hasInputs => false;

  @override
  int get step => 0;

  @override
  AssessmentDraft copyWith({String? concept, String? audience, double? budgetRm, bool? saved}) =>
      const _EmptyDraft();
}
