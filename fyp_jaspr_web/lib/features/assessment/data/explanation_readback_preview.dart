/// Dev-only fixtures for the EX-05 synthetic explanation preview.
///
/// These envelopes are shaped exactly like `ee01-explanation-readback/1`, but
/// their identifiers and wording are synthetic. They are imported only by the
/// `/dev/report` harness, which is compiled out of production builds by the
/// synthetic-preview gate. Nothing here sets report admission or authority.
library;

import 'package:sitewise_jaspr_web/features/assessment/data/explanation_candidate.dart';

class ExplanationReadbackPreview {
  static const String assessmentId = '77a4faef-0213-48cf-a8ed-f6d10ba926da';
  static const String campaignId = 'c79e88a6-8bf4-472f-b044-ffff81bb26db';
  static const String snapshotId = '3b33bcb0-1731-4d93-8239-41d99fa5cfc7';
  static const String fingerprint =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  static const String registrySha =
      '64d0d074899e18959c66e450af34ee223d431962c492e026cd7add04cea84144';
  static const String contextHash =
      '1e26a70bdd6f8bbf5d8c96c7d22a4c7fbf31e669b28b20ebebd21b2d65d94324';

  static Map<String, dynamic> envelope({
    required String headlinePrefix,
    required String producer,
    required String resultId,
    required String executionKind,
    required String outcome,
    required String llmExecution,
    String? runId,
    int? attemptNo,
    String? promptVersion,
    String origin = 'DETERMINISTIC_TEMPLATE',
  }) {
    return {
      'contract_version': ExplanationPanel.expectedReadbackContractVersion,
      'assessment_id': assessmentId,
      'campaign_id': campaignId,
      'snapshot_id': snapshotId,
      'question_id': 'Q05',
      'result_id': resultId,
      'source_fingerprint': fingerprint,
      'context_id': contextHash,
      'registry_version': 'q01-q13-explanation/1',
      'registry_sha256': registrySha,
      'ruleset_version': 'Q05@1',
      'validation_status': 'valid',
      'validation_failures': const [],
      'stale_reason': null,
      'admission_state': ExplanationPanel.withheldAdmissionState,
      'admitted': false,
      'authority': 'CANDIDATE_UNVERIFIED',
      'execution_kind': executionKind,
      'outcome': outcome,
      'retry_authorized': false,
      'run_id': runId,
      'attempt_no': attemptNo,
      'prompt_version': promptVersion,
      'producer': producer,
      'llm_execution': llmExecution,
      'scientific_acceptance': false,
      'report_release_authorized': false,
      'candidate': {
        'schema_version': 'ee01-explanation/1',
        'task_mode': 'CLAIM_EXPLANATION',
        'context_id': contextHash,
        'snapshot_id': snapshotId,
        'used_claim_ids': const [],
        'headline':
            '$headlinePrefix Q05 — withheld, approved stimulus absent',
        'observation_interpretation':
            'Findings for Q05 are withheld because the instrument, source or '
            'required stimulus has not been approved. No quantitative '
            'conclusion is issued. Concept-interest results cannot be '
            'estimated because the specific concept stimulus, item '
            'validation, or admissible answers are unavailable; the system '
            'does not infer customer demand.',
        'research_interpretation':
            'No claim from Q05 can be made in this state, so no research '
            'conclusion is offered.',
        'planning_implication':
            'No planning implication follows from a measurement that is not '
            'available.',
        'limitations':
            'Item limitation: Not actual purchasing, visits, market share, '
            'revenue or calibrated conversion probability. Coverage '
            'limitation: The stem compounds a time horizon with an '
            'at-least-once event; which clause drives the answer is untested. '
            'UNSURE is substantive per the applicable A10 worked example and '
            'is counted in V; CANNOT_JUDGE is not. Horizon and event '
            'interpretation are referred to WS2.',
        'summary':
            'The measurement for Q05 is not reportable in this state, so no '
            'interpretation is offered.',
        'insufficient_evidence': true,
        'missing_evidence_references': const [
          'EXPLANATION_TEMPLATE_AUTHORITY_UNVERIFIED',
          'A10_ADAPTER_UNVERIFIED',
          'REPORT_ADMISSION_REQUIRED',
          'Q05',
          'MISSING_APPROVED_STIMULUS',
        ],
        'origin': origin,
      },
    };
  }

  /// Three preview states rendered through the same report card.
  static List<ExplanationPanel> panels() => [
    ExplanationPanel.fromReadback(
      envelope(
        headlinePrefix: 'Synthetic deterministic —',
        producer: 'EE01-EXPLANATION-QUESTION-REGISTRY-1',
        resultId: '969ca99a-4cd8-5b74-ba28-8dab5ee51872',
        executionKind: 'DETERMINISTIC_ONLY',
        outcome: 'DETERMINISTIC_ONLY',
        llmExecution: 'NOT_ATTEMPTED',
      ),
      syntheticPreview: true,
    ),
    ExplanationPanel.fromReadback(
      envelope(
        headlinePrefix: 'Synthetic mocked AI —',
        producer: 'EXTERNAL_EXPLANATION_CANDIDATE',
        resultId: 'd20fcc7d-8fa2-5995-b12e-0373e18b4646',
        executionKind: 'AI_ATTEMPTED',
        outcome: 'AI_VALIDATED',
        llmExecution: 'RETURNED',
        runId: 'c64c2957-ff54-489b-b4ad-cf946df65f86',
        attemptNo: 1,
        promptVersion: 'EE01-EXPLANATION-2-CAND',
        origin: 'LLM',
      ),
      syntheticPreview: true,
    ),
    ExplanationPanel.fromReadback(
      envelope(
        headlinePrefix: 'Synthetic fallback —',
        producer: 'EE01-EXPLANATION-QUESTION-REGISTRY-1',
        resultId: 'f3a6b1d0-7b0b-5b2f-9b0e-2c2c2f8e0f11',
        executionKind: 'AI_ATTEMPTED',
        outcome: 'AI_REJECTED_FELL_BACK',
        llmExecution: 'REJECTED_FELL_BACK',
        runId: 'd6a0d8f3-3f4f-4a0c-9b3d-91c5c4f2f6a7',
        attemptNo: 1,
        promptVersion: 'EE01-EXPLANATION-2-CAND',
      ),
      syntheticPreview: true,
    ),
  ];

  /// The stale/unavailable state is a distinct module-level notice.
  static ExplanationPanel unavailable() => ExplanationPanel.unavailable(
    reason:
        'Synthetic preview: a stale or unavailable explanation is withheld; '
        'no candidate prose is displayed.',
  );
}
