import 'package:sitewise_jaspr_web/features/assessment/data/stage_four_five_api.dart';

/// Simulated `sitewise-ai-execution-status/2` responses.
///
/// These are *data*, not a service: every helper below returns a plain map in
/// the exact shape the route emits, and the test parses it with the production
/// parser. Nothing here is imported by the application, and nothing here can
/// reach a provider (CP-P05).
///
/// The per-state milestone table is copied from the contract, not computed from
/// `runs._STATE_MILESTONES`. If the two ever disagree,
/// `backend/tests/test_ai_execution_status_projection.py` fails on the server
/// side and the harness fails here — which is the point of copying rather than
/// sharing.
const Map<String, List<(String, String)>> simulatedMilestones = {
  // (completed_count, active_index) in the contract, spelled out.
  'BLOCKED': [
    ('RESERVED', 'PENDING'),
    ('RETURNED', 'PENDING'),
    ('VALIDATED', 'PENDING'),
    ('PERSISTED', 'PENDING'),
  ],
  'PROCESSING': [
    ('RESERVED', 'COMPLETED'),
    ('RETURNED', 'ACTIVE'),
    ('VALIDATED', 'PENDING'),
    ('PERSISTED', 'PENDING'),
  ],
  'RETURNED': [
    ('RESERVED', 'COMPLETED'),
    ('RETURNED', 'COMPLETED'),
    ('VALIDATED', 'ACTIVE'),
    ('PERSISTED', 'PENDING'),
  ],
  'VALIDATING': [
    ('RESERVED', 'COMPLETED'),
    ('RETURNED', 'COMPLETED'),
    ('VALIDATED', 'ACTIVE'),
    ('PERSISTED', 'PENDING'),
  ],
  'PERSISTED': [
    ('RESERVED', 'COMPLETED'),
    ('RETURNED', 'COMPLETED'),
    ('VALIDATED', 'COMPLETED'),
    ('PERSISTED', 'COMPLETED'),
  ],
  'FAILED': [
    ('RESERVED', 'COMPLETED'),
    ('RETURNED', 'FAILED'),
    ('VALIDATED', 'PENDING'),
    ('PERSISTED', 'PENDING'),
  ],
  'UNKNOWN_OUTCOME': [
    ('RESERVED', 'COMPLETED'),
    ('RETURNED', 'UNKNOWN'),
    ('VALIDATED', 'PENDING'),
    ('PERSISTED', 'PENDING'),
  ],
};

/// One purpose entry, exactly as `read_execution_status` emits it.
Map<String, dynamic> simulatedPurpose({
  String purpose = 'BDJ',
  String state = 'BLOCKED',
  String reason = '',
  int? attemptNo,
  int attemptsReserved = 0,
  String? reservedAt,
  String? receiptOutcome,
  String? receiptAt,
  int persisted = 0,
  int pendingValidation = 0,
  bool attributable = true,
  int assessmentWidePersisted = 0,
  bool stale = false,
  int? assessmentRevision,
  String domainStore = 'public.m2_bdj_objective_proposals',
  List<(String, String)>? milestones,
}) => {
  'purpose': purpose,
  'state': state,
  'reason': reason,
  'attempt_no': attemptNo,
  'attempts_reserved': attemptsReserved,
  'reserved_at': reservedAt,
  'receipt_outcome': receiptOutcome,
  'receipt_at': receiptAt,
  'stale': stale,
  'assessment_revision': assessmentRevision,
  'domain_store': domainStore,
  'domain': {
    'persisted': persisted,
    'pending_validation': pendingValidation,
    'attributable': attributable,
  },
  'domain_assessment_wide': {
    'persisted': assessmentWidePersisted,
    'pending_validation': 0,
    'run_bound': 0,
  },
  'milestones': [
    for (final entry in milestones ?? simulatedMilestones[state]!)
      {'milestone': entry.$1, 'status': entry.$2},
  ],
};

/// A full status response carrying one purpose.
Map<String, dynamic> simulatedStatus({
  Map<String, dynamic>? purpose,
  String contract = 'sitewise-ai-execution-status/2',
  int? currentRevision = 33,
  int? providerTimeoutSeconds = 90,
  int? graceSeconds = 120,
  String? objectiveId,
  bool objectiveScoped = false,
  List<Map<String, dynamic>>? extraPurposes,
}) => {
  'contract': contract,
  'assessment_id': 'aaaaaaaa-0000-0000-0000-000000000001',
  'current_revision': currentRevision,
  'objective_id': objectiveId,
  'objective_scoped': objectiveScoped,
  'ledger': 'project1_ai.runs, project1_ai.attempts, project1_ai.receipts',
  'result_store': 'project1_ai.bdj_results',
  'states': const [
    'BLOCKED',
    'PROCESSING',
    'RETURNED',
    'VALIDATING',
    'PERSISTED',
    'FAILED',
    'UNKNOWN_OUTCOME',
  ],
  'milestones': const ['RESERVED', 'RETURNED', 'VALIDATED', 'PERSISTED'],
  'unprovable_milestones': const ['DISPATCHED'],
  'timing': {
    'provider_timeout_seconds': providerTimeoutSeconds,
    'grace_seconds': graceSeconds,
  },
  'purposes': [purpose ?? simulatedPurpose(), ...?extraPurposes],
  // Present and null on purpose: an omitted key would look like an oversight
  // and a number here would be invented.
  'progress_percent': null,
  'progress_note': 'No percentage is reported.',
  'domain_readable': true,
  'bdj_objectives': const {
    'proposed': 0,
    'approved': 0,
    'admitted': 0,
    'readable': true,
    'persistence_attributable': false,
    'attribution_capability': 'UNAVAILABLE',
  },
  'scientific_approval': false,
  'fielding_authorized': false,
};

/// Parse a simulated response the way the client does.
AiExecutionReading simulatedReading({
  Map<String, dynamic>? purpose,
  String? objectiveId,
  bool objectiveScoped = false,
  List<Map<String, dynamic>>? extraPurposes,
}) => AiExecutionReading.fromJson(
  simulatedStatus(
    purpose: purpose,
    objectiveId: objectiveId,
    objectiveScoped: objectiveScoped,
    extraPurposes: extraPurposes,
  ),
);

/// The purpose a rail renders for one stage.
AiExecutionPurpose? simulatedExecution({
  String purpose = 'BDJ',
  String state = 'BLOCKED',
  String reason = '',
  int? attemptNo,
  int attemptsReserved = 0,
  String? reservedAt,
  String? receiptOutcome,
  String? receiptAt,
  int persisted = 0,
  int pendingValidation = 0,
  bool attributable = true,
  int assessmentWidePersisted = 0,
  bool stale = false,
  int? assessmentRevision,
}) => simulatedReading(
  purpose: simulatedPurpose(
    purpose: purpose,
    state: state,
    reason: reason,
    attemptNo: attemptNo,
    attemptsReserved: attemptsReserved,
    reservedAt: reservedAt,
    receiptOutcome: receiptOutcome,
    receiptAt: receiptAt,
    persisted: persisted,
    pendingValidation: pendingValidation,
    attributable: attributable,
    assessmentWidePersisted: assessmentWidePersisted,
    stale: stale,
    assessmentRevision: assessmentRevision,
  ),
).forPurpose(purpose);
