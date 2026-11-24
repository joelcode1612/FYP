/// Typed view of one `ee01-explanation-candidate/3` response.
///
/// This is a **data adapter**, not a renderer: it parses the envelope the
/// backend already returns so the existing report can read it without embedding
/// JSON handling in the page. Rendering is the report's own card styles.
///
/// Three gates, deliberately separate — the same discipline the report already
/// applies to [ChartSpecModel], the Q01 preview and the measurement readback, so
/// none can satisfy another's check:
///
/// * [isReportAdmissible] requires the backend's own admission marker. It is
///   **always false in V1**, because no adopted ReportAdmission adapter exists.
/// * [isHeldExplanation] is a *withheld* explanation: the registry decided the
///   item cannot be explained and produced no figure. It is safe to show in a
///   production report precisely because it discloses nothing.
/// * [isRenderable] is the only question the report asks. A substantive but
///   unadmitted explanation renders nothing at all — not a warning, because a
///   warning would still confirm that a measurement exists.
///
/// Nothing here can turn a held explanation into a result: [state] and [gate]
/// come from the registry, and a candidate claiming authority is refused at
/// parse time rather than being rendered with a caveat.
library;

/// A withheld or admitted explanation, ready for the report to render.
class ExplanationPanel {
  const ExplanationPanel({
    required this.contractVersion,
    required this.producer,
    required this.authority,
    required this.headline,
    required this.observation,
    required this.research,
    required this.planning,
    required this.limitations,
    required this.summary,
    required this.insufficientEvidence,
    required this.missingEvidenceReferences,
    required this.reportAdmissionAuthorized,
    required this.state,
    required this.gate,
    required this.questionId,
    required this.registryVersion,
    required this.registrySha256,
    this.snapshotId,
    this.assessmentId,
    this.campaignId,
    this.resultId,
    this.sourceFingerprint,
    this.rulesetVersion,
    this.validationStatus,
    this.admissionState,
    this.syntheticPreview = false,
    this.moduleHeld = false,
  });

  /// The only contracts this adapter understands.
  static const expectedContractVersion = 'ee01-explanation-candidate/3';
  static const expectedReadbackContractVersion = 'ee01-explanation-readback/1';
  static const withheldAdmissionState =
      'REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE';

  final String contractVersion;
  final String producer;

  /// Always `CANDIDATE_UNVERIFIED`. Kept so a caller can assert it.
  final String authority;

  final String headline;
  final String observation;
  final String research;
  final String planning;
  final String limitations;
  final String summary;

  /// True when the registry decided this item cannot be explained.
  final bool insufficientEvidence;
  final List<String> missingEvidenceReferences;

  /// The backend's admission marker. False in every V1 response.
  final bool reportAdmissionAuthorized;

  /// Registry evidence state (for example `NOT_AUTHORIZED`) and instrument gate.
  final String? state;
  final String? gate;
  final String? questionId;
  final String? registryVersion;
  final String? registrySha256;

  /// True when the backend refused at the *module* level rather than for this
  /// item. Distinct from a withheld item, which the registry considered and
  /// found unexplainable; the two must not read alike, because this one says
  /// nothing was ever measured.
  final bool moduleHeld;

  /// Identity fields from the store-backed readback envelope. They let the
  /// report verify that a result belongs to the assessment and snapshot it is
  /// about instead of trusting a client-supplied binding.
  final String? assessmentId;
  final String? campaignId;
  final String? resultId;
  final String? sourceFingerprint;
  final String? rulesetVersion;
  final String? validationStatus;
  final String? admissionState;

  /// True only for a fixture rendered by the explicitly dev-gated preview.
  /// It never changes publication authority; it only permits a visual
  /// demonstration of prose the normal report must withhold.
  final bool syntheticPreview;

  /// A module-level refusal, built from `GET /cq/explanations/availability`.
  ///
  /// It is deliberately not a `fromJson`: that factory refuses anything that is
  /// not a candidate envelope, and this is a different contract. Constructing it
  /// here keeps the authority marker and the disclosure rules in one file.
  factory ExplanationPanel.unavailable({String? reason}) => ExplanationPanel(
    contractVersion: expectedContractVersion,
    producer: 'EXPLANATION_MODULE_HOLD',
    authority: 'CANDIDATE_UNVERIFIED',
    headline: 'Explanations are not available for this assessment',
    observation:
        reason ??
        'The explanation module is held, so no questionnaire item can be '
            'explained. Nothing has been measured and nothing is withheld.',
    research: '',
    planning: '',
    limitations: '',
    summary: '',
    insufficientEvidence: true,
    missingEvidenceReferences: const [],
    reportAdmissionAuthorized: false,
    state: null,
    gate: null,
    questionId: null,
    registryVersion: null,
    registrySha256: null,
    moduleHeld: true,
  );

  /// The measurement this panel was rendered over, when it names one.
  ///
  /// The envelope carries no assessment id, so the snapshot is the only binding
  /// a client can check. A held explanation needs no binding because it
  /// discloses nothing; a substantive one must be bound before it is drawn.
  final String? snapshotId;

  /// A result the report may treat as admitted evidence. Unreachable in V1.
  bool get isReportAdmissible =>
      reportAdmissionAuthorized && !insufficientEvidence;

  /// A withheld explanation: no figure is disclosed, so it is safe to show.
  bool get isHeldExplanation => insufficientEvidence;

  /// What the report actually asks. A substantive, unadmitted explanation is
  /// not renderable — showing it would publish an unadmitted finding.
  bool get isRenderable => isReportAdmissible || isHeldExplanation;

  /// A dev-gated preview may display substantive candidate prose so the report
  /// components can be verified. This never sets [isReportAdmissible], so the
  /// card must still be labelled as synthetic and not as a finding.
  bool get isSyntheticPreviewRenderable => syntheticPreview && !moduleHeld;

  /// The registry state, said in the report's own words. Unknown states are
  /// passed through verbatim rather than guessed.
  String get stateLabel {
    if (moduleHeld) return 'Explanations unavailable';
    if (isReportAdmissible) return 'Substantive result';
    final s = state;
    if (s == null || s.isEmpty) return 'Withheld';
    return switch (s) {
      'NOT_AUTHORIZED' => 'Withheld — instrument not authorised',
      'BLOCKED_SOURCE' => 'Withheld — source unresolved',
      'MISSING_APPROVED_STIMULUS' => 'Withheld — approved stimulus absent',
      'MISSING_APPROVED_BANK' => 'Withheld — approved bank absent',
      'UNKNOWN_ROUTE' => 'Withheld — applicability unverified',
      'LOW_VALID_BASE' => 'Estimated on a small valid base',
      'VALID_APPROVED' => 'Substantive result',
      _ => s,
    };
  }

  /// Parse the backend envelope.
  ///
  /// Throws [FormatException] when the payload is not the contract this adapter
  /// understands, or when it claims an authority the explanation layer cannot
  /// hold. Failing at parse time means no renderer ever sees a candidate that
  /// asserts admission it does not have.
  factory ExplanationPanel.fromJson(Map<String, dynamic> json) {
    if (json['contract_version'] != expectedContractVersion) {
      throw const FormatException('Unsupported explanation contract version.');
    }
    final candidate = json['candidate'];
    if (candidate is! Map) {
      throw const FormatException('Explanation candidate is missing.');
    }
    final authority = json['authority'] as String? ?? '';
    if (authority != 'CANDIDATE_UNVERIFIED') {
      throw const FormatException('Explanation candidate claims authority.');
    }
    // The five authority markers must all be false. A backend that ever sets one
    // has changed the governance position, and this adapter refuses rather than
    // rendering a result it was never built to gate.
    for (final marker in const [
      'scientific_acceptance',
      'owner_authorization',
      'publication_authorized',
      'fielding_authorized',
      'report_release_authorized',
    ]) {
      if (json[marker] == true) {
        throw const FormatException('Explanation candidate asserts authority.');
      }
    }
    final question = json['question'];
    return ExplanationPanel(
      contractVersion: expectedContractVersion,
      producer: json['producer'] as String? ?? '',
      authority: authority,
      headline: candidate['headline'] as String? ?? '',
      observation: candidate['observation_interpretation'] as String? ?? '',
      research: candidate['research_interpretation'] as String? ?? '',
      planning: candidate['planning_implication'] as String? ?? '',
      limitations: candidate['limitations'] as String? ?? '',
      summary: candidate['summary'] as String? ?? '',
      insufficientEvidence: candidate['insufficient_evidence'] == true,
      missingEvidenceReferences:
          (candidate['missing_evidence_references'] as List? ?? const [])
              .whereType<String>()
              .toList(growable: false),
      reportAdmissionAuthorized: false,
      state: question is Map ? question['effective_state'] as String? : null,
      gate: question is Map ? question['instrument_gate'] as String? : null,
      questionId: question is Map ? question['question_id'] as String? : null,
      registryVersion: question is Map ? question['registry_version'] as String? : null,
      registrySha256: question is Map ? question['registry_sha256'] as String? : null,
      snapshotId: candidate['snapshot_id'] as String?,
    );
  }

  /// Parse the store-backed `ee01-explanation-readback/1` envelope.
  ///
  /// This is the authenticated read API used by the normal report. It refuses a
  /// stale, admitted, authority-asserting or invalid result before the renderer
  /// ever sees it. The report still decides disclosure separately: a withheld
  /// candidate can be shown, a substantive candidate cannot.
  factory ExplanationPanel.fromReadback(Map<String, dynamic> json,
      {bool syntheticPreview = false}) {
    if (json['contract_version'] != expectedReadbackContractVersion) {
      throw const FormatException('Unsupported explanation readback contract.');
    }
    final authority = json['authority'] as String? ?? '';
    if (authority != 'CANDIDATE_UNVERIFIED') {
      throw const FormatException('Explanation result claims authority.');
    }
    for (final marker in const [
      'scientific_acceptance',
      'report_release_authorized',
    ]) {
      if (json[marker] == true) {
        throw const FormatException('Explanation result claims authority.');
      }
    }
    if (json['admitted'] == true) {
      throw const FormatException('Admitted explanation is not a candidate.');
    }
    if (json['stale_reason'] != null || json['validation_status'] != 'valid') {
      throw const FormatException('Explanation result is not current.');
    }
    if (json['admission_state'] != withheldAdmissionState) {
      throw const FormatException('Explanation admission state changed.');
    }
    final candidate = json['candidate'];
    if (candidate is! Map) {
      throw const FormatException('Explanation candidate is missing.');
    }
    final snapshotId = json['snapshot_id']?.toString();
    final candidateSnapshotId = candidate['snapshot_id']?.toString();
    if (candidateSnapshotId != null &&
        snapshotId != null &&
        candidateSnapshotId != snapshotId) {
      throw const FormatException('Explanation snapshot binding mismatch.');
    }
    return ExplanationPanel(
      contractVersion: expectedContractVersion,
      producer: json['execution_kind']?.toString() ?? '',
      authority: authority,
      headline: candidate['headline'] as String? ?? '',
      observation: candidate['observation_interpretation'] as String? ?? '',
      research: candidate['research_interpretation'] as String? ?? '',
      planning: candidate['planning_implication'] as String? ?? '',
      limitations: candidate['limitations'] as String? ?? '',
      summary: candidate['summary'] as String? ?? '',
      insufficientEvidence: candidate['insufficient_evidence'] == true,
      missingEvidenceReferences:
          (candidate['missing_evidence_references'] as List? ?? const [])
              .whereType<String>()
              .toList(growable: false),
      reportAdmissionAuthorized: false,
      state: null,
      gate: null,
      questionId: json['question_id']?.toString(),
      registryVersion: json['registry_version']?.toString(),
      registrySha256: json['registry_sha256']?.toString(),
      snapshotId: snapshotId,
      assessmentId: json['assessment_id']?.toString(),
      campaignId: json['campaign_id']?.toString(),
      resultId: json['result_id']?.toString(),
      sourceFingerprint: json['source_fingerprint']?.toString(),
      rulesetVersion: json['ruleset_version']?.toString(),
      validationStatus: json['validation_status']?.toString(),
      admissionState: json['admission_state']?.toString(),
      syntheticPreview: syntheticPreview,
    );
  }

  /// Whether this panel may be drawn for the measurement the report is showing.
  ///
  /// A held explanation discloses nothing, so it needs no binding. A substantive
  /// one does: drawing an unbound explanation would attribute one assessment's
  /// measurement to another, which is the join the directive forbids.
  ///
  /// **Unreachable in V1, by design.** No substantive panel can be renderable
  /// while [isReportAdmissible] is always false, so this returns `true` for
  /// every panel the report actually draws. It is kept, and tested directly, so
  /// that the rule exists before the first admitted explanation does — the same
  /// way `render_state == RENDERABLE` is kept in the chart contract.
  bool boundToSnapshot(String? expected) {
    if (insufficientEvidence) return true;
    if (expected == null || snapshotId == null) return false;
    return snapshotId == expected;
  }
}
