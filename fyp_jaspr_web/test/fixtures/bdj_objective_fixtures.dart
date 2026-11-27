/// Recorded governed payloads for the Stage 3 objective-proposal tests.
///
/// These mirror the real responses captured in
/// `deliverables/phase2/BDJ_GATEBC_HTTP_E2E_FRESH_20261122.json` (fresh
/// scenario, run `dab8ec06`): three proposals, two source-confirmed gaps on
/// `M2V1-01` (UNDECIDED) and `M2V1-08` (UNKNOWN), and one exploratory
/// `SUGGESTED` with `problem: null` and no source references.
///
/// Nothing here is invented product copy: the objectives, reasons and source
/// identifiers are copied from the persisted rows so a rendering test can
/// assert that the panel shows the server's own text.
library;

const String m2AssessmentId = 'e0124bfd-e54b-4d57-bc19-2023c8e7a5e6';
const String marketplaceAssessmentId = '11111111-1111-4111-8111-111111111111';
const String confirmationId = 'b73d9297-ac39-42f4-9213-4fdd5254af28';
const String contextId = '0af90393-46b3-56ed-bd76-7776cd5ec1c2';
const int confirmationRevision = 11;

/// The two `MOST_SUGGESTED` proposal ids, in the order the server returns them.
const String sourcedProposalId = '356df73c-a360-5fa4-98c8-65a1df109bbf';
const String approvedProposalId = '7490f03c-c1cf-51d0-9b49-f230703f4bea';
const String exploratoryProposalId = 'd4ae970c-e711-5439-a0c9-5367905b67f2';

/// The `generation` block of the list envelope.
///
/// The server decides whether a governed pass can still run, and the panel draws
/// its generate control from this block alone. The default fixture is "nothing
/// attempted yet", so a test that exercises generation is exercising an eligible
/// context; a test that wants a spent or in-flight one passes the reason
/// explicitly rather than relying on the proposal count.
Map<String, dynamic> generationPayload({
  String reason = 'NOT_STARTED',
  bool eligible = true,
  int attempts = 0,
}) => {
  'contract': 'bdj-objective-generation/1',
  'eligible': eligible,
  'reason': reason,
  'attempts': attempts,
  'run_recorded': attempts > 0,
};

Map<String, dynamic> evaluationPayload() => {
  'contract_version': 'bdj-objective-proposal/1',
  'assessment_id': m2AssessmentId,
  'confirmation_id': confirmationId,
  'confirmation_revision': confirmationRevision,
  'context_id': contextId,
  'context_packet_hash':
      '5724cb01d2c727d78f740b4a1eb0be3a656fab5f65d06b73af79b40108162de8',
  'source_fingerprint':
      'd21320f6c7457468d79d91007ac628922fbef6b2f31cc964112d5b5c0f7ee331',
  'outcome': 'reviewed',
  'proposal_count': 3,
  'proposals': [
    {
      'proposal_id': sourcedProposalId,
      'created': true,
      'recommendation_status': 'MOST_SUGGESTED',
      'problem_type': 'SOURCE_CONFIRMED_INFORMATION_GAP',
      'problem':
          'The trading area for the proposed cafe remains undecided, so the '
          'location context of the concept is not established.',
      'research_objective':
          'To investigate candidate areas for the proposed cafe and the '
          'characteristics of each that matter to the concept.',
      'reason':
          'The area answer is recorded as UNDECIDED, which leaves the '
          'geographic setting of the concept open.',
      'source_refs': [
        {
          'item_key': 'M2V1-01',
          'answer_revision_id': '0f1c2d3e-1111-4222-8333-444455556666',
          'item_version_id': '9a8b7c6d-aaaa-4bbb-8ccc-ddddeeeeffff',
        },
      ],
      'review_state': 'PENDING',
    },
    {
      'proposal_id': approvedProposalId,
      'created': true,
      'recommendation_status': 'MOST_SUGGESTED',
      'problem_type': 'SOURCE_CONFIRMED_INFORMATION_GAP',
      'problem':
          'The sources of information used to form current expectations are '
          'recorded as unknown.',
      'research_objective':
          'To investigate what evidence base currently underpins the '
          "entrepreneur's expectations.",
      'reason': 'The information-sources answer is UNKNOWN.',
      'source_refs': [
        {
          'item_key': 'M2V1-08',
          'answer_revision_id': '262fe6ea-8f6e-49b9-a41e-e824acdd113c',
          'item_version_id': 'a5e43b4f-8326-43fc-a2b5-e425b0f32621',
        },
      ],
      'review_state': 'APPROVED',
    },
    {
      'proposal_id': exploratoryProposalId,
      'created': true,
      'recommendation_status': 'SUGGESTED',
      'problem_type': 'EXPLORATORY_RESEARCH_NEED',
      'problem': null,
      'research_objective':
          'To explore how the intended student and office-worker groups '
          'interpret a convenience-led, dine-in study-and-work cafe.',
      'reason':
          'The declared answers are definite selections rather than gaps.',
      'source_refs': <Map<String, dynamic>>[],
      'review_state': 'PENDING',
    },
  ],
  'execution': {
    'execution_mode': 'SIMULATED',
    'model_provider': 'simulated-objective-v1',
    'dispatched': false,
    'run_id': 'dab8ec06-2004-4b8e-af57-11a8d45d3bf0',
    'attempt_no': 1,
    'prompt_version': 'BDJ-OBJECTIVE-3-CAND',
    'prompt_sha256': '76027bfffbce17711fe2c9190bc610eb8e8bfaf8a57cf4a16913b87cddd7b8ab',
    'request_sha256': 'af137f622623684e161d6c89d28c5496a0936b34eaa9ddf054286cd358b70326',
    'output_sha256': 'fe6a5a0e78c86927c9966e1d2b2b294819dee9301387f9da46101737a2e3395c',
    'receipt_outcome': 'returned',
    'reused': false,
    'context_packet_hash':
        '5724cb01d2c727d78f740b4a1eb0be3a656fab5f65d06b73af79b40108162de8',
  },
  'finding_authority': 'CANDIDATE_ONLY',
  'status_contract': 'UNRECONCILED_PROPOSAL',
  'qj_execution': false,
  'qg_execution': false,
  'scientific_acceptance': false,
  'owner_authorization': false,
  'publication_authorized': false,
  'fielding_authorized': false,
  'report_release_authorized': false,
};

Map<String, dynamic> decisionPayload({
  required String decision,
  required String admissionState,
  required String admissionReason,
  String? pendingRequirement,
  bool decisionCreated = true,
}) => {
  'contract_version': 'bdj-objective-proposal/1',
  'proposal_id': approvedProposalId,
  'assessment_id': m2AssessmentId,
  'confirmation_id': confirmationId,
  'confirmation_revision': confirmationRevision,
  'context_id': contextId,
  'context_packet_hash':
      '5724cb01d2c727d78f740b4a1eb0be3a656fab5f65d06b73af79b40108162de8',
  'source_fingerprint':
      'd21320f6c7457468d79d91007ac628922fbef6b2f31cc964112d5b5c0f7ee331',
  'decision': decision,
  'decision_id': 'f278f914-4e31-4e4d-965b-3cb11fe16759',
  'decided_at': '2026-11-22T01:48:40.426834+08:00',
  'note': null,
  'decision_created': decisionCreated,
  'review_state': decision == 'APPROVED' ? 'APPROVED' : 'REJECTED',
  'admission': {
    'admission_state': admissionState,
    'admission_reason': admissionReason,
    'pending_requirement': pendingRequirement,
    'uncertainty_link': null,
    'qj_execution': false,
    'qg_execution': false,
    'fielding_authorized': false,
  },
  'finding_authority': 'CANDIDATE_ONLY',
  'status_contract': 'UNRECONCILED_PROPOSAL',
  'qj_execution': false,
  'qg_execution': false,
};

/// The approved-but-held decision the backend returns for an `APPROVED`
/// proposal: the entrepreneur's record stands, and admission is still held.
Map<String, dynamic> heldDecisionPayload({String? proposalId}) {
  final payload = decisionPayload(
    decision: 'APPROVED',
    admissionState: 'HELD',
    admissionReason: 'M2_UNCERTAINTY_LINK_REQUIRED',
    pendingRequirement:
        'A source-linked BDJ finding review is not adopted; the objective '
        'cannot be linked to a confirmed uncertainty yet.',
  );
  if (proposalId != null) payload['proposal_id'] = proposalId;
  return payload;
}

/// The M2 draft the panel resolves before it can read any proposal. The shape
/// is what `M2Draft.fromJson` validates, so it must stay internally consistent.
Map<String, dynamic> m2DraftPayload({int revision = confirmationRevision}) => {
  'assessment': {
    'id': m2AssessmentId,
    'revision': revision,
    'instrument_id': 'instrument-version-1',
  },
  'instrument': {'id': 'instrument-version-1'},
  'items': [
    {
      'id': '9a8b7c6d-aaaa-4bbb-8ccc-ddddeeeeffff',
      'item_key': 'M2V1-01',
      'instrument_id': 'instrument-version-1',
    },
  ],
  'answers': <String, dynamic>{},
};

Map<String, dynamic> linkPayload() => {
  'm2_assessment_id': m2AssessmentId,
  'marketplace_assessment_id': marketplaceAssessmentId,
};

Map<String, dynamic> confirmationPayload({
  int revision = confirmationRevision,
}) => {
  'id': confirmationId,
  'assessment_id': m2AssessmentId,
  'assessment_revision': revision,
  'is_current': true,
};

Map<String, dynamic> contextStatusPayload({
  String status = 'PERSISTED',
  bool sourceIsCurrent = true,
}) => {
  'assessment_id': m2AssessmentId,
  'confirmation_id': confirmationId,
  'assessment_revision': confirmationRevision,
  'source_is_current': sourceIsCurrent,
  'status': status,
  'attempt_count': 1,
  'context_id': contextId,
};
