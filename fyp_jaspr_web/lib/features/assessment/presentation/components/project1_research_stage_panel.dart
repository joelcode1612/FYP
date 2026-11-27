import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/features/assessment/application/execution_status_poller.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/confirmed_worksheet_status.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/ai_execution_progress.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/bdj_objective_proposal.dart'
    show BdjReviewState;
import 'package:sitewise_jaspr_web/features/assessment/data/bdj_objective_proposal_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/qg_generation_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/bdj_objective_proposal_panel.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/fixed_objectives.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage4_preview_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage4_preview_questionnaire.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage_four_five_api.dart';

/// Stage 3 and 4 research presentation for the existing five-stage SiteWise
/// assessment. No synthetic findings, objective text or generated candidates
/// are embedded in this production component.
///
/// IMPORTANT ADAPTER CONTRACT (NOT IMPLEMENTED IN THE UPLOADED REPOSITORY):
/// AppLocator.m2.researchWorkspaceSnapshot(m2Id, confirmationId) -> Map
/// AppLocator.m2.approveResearchObjective(objectiveId, version)
/// AppLocator.m2.clarifyResearchObjective(objectiveId, version, category, text)
/// AppLocator.m2.saveOwnerExpectedAnswer(candidateId, version, optionId)
/// AppLocator.m2.reviewResearchQuestion(candidateId, version, decision)
/// AppLocator.m2.reviseResearchQuestion(candidateId, version, newQuestionText)
///
/// Implement these as typed methods on the existing authenticated M2
/// repository using *verified* existing FastAPI routes. These names are adapter
/// method proposals, NOT claims that server routes already have these names.
/// Missing methods must fail closed and be visible in the page, never be
/// interpreted as a save/approval. No new BDJ role or automatic LLM execution.
class Project1ResearchStagePanel extends StatefulComponent {
  final String marketplaceAssessmentId;
  final String propertyId;
  final int stageNumber;
  final void Function(String stageKey)? onOpenStage;

  /// Called after a governed write in this panel succeeded.
  ///
  /// Stages 3 and 4 never complete through a stage-write endpoint — they
  /// complete when their own evidence exists. That evidence is produced by the
  /// panels nested below (an admitted objective, an approved question), so this
  /// component cannot know on its own that the *assessment* changed. It reports
  /// the save and lets the owning page re-read the authoritative record, which
  /// is what moves the count from 2/5 to 3/5 (60%) and then 4/5 (80%).
  ///
  /// Deliberately a notification, not a completion claim: nothing here can mark
  /// a stage complete, and the caller re-reads rather than incrementing.
  final VoidCallback? onStageProgressChanged;

  /// Transport for Stage 4 Section A (the fixed governed Q01–Q13 preview).
  /// Defaulted like `BdjObjectiveProposalPanel.api` so a component test can
  /// render a recorded payload without reaching the network.
  final Stage4PreviewPort previewApi;

  /// Transport for the governed Direct-QG generation step on an objective the
  /// owner approved at Stage 3. Defaulted like [previewApi] so a component test
  /// can render a recorded response without reaching the network.
  final QgGenerationPort qgGeneration;

  /// Transport for the Stage 4/5 reads, including the AI execution status the
  /// ledger already records. Defaulted like [previewApi] so a component test can
  /// render a recorded reading without reaching the network.
  final StageFourFivePort stageFourFive;

  /// Transport for the objective proposals Stage 4's Extra column groups its
  /// generated questions under. Defaulted like [previewApi] so a component test
  /// can render a recorded proposal list without reaching the network; without
  /// it the embedded review surface cannot render at all, because its first
  /// read is the proposal list.
  final BdjObjectiveProposalPort proposalApi;

  const Project1ResearchStagePanel({
    super.key,
    required this.marketplaceAssessmentId,
    required this.propertyId,
    required this.stageNumber,
    this.onOpenStage,
    this.onStageProgressChanged,
    this.previewApi = const Stage4PreviewApi(),
    this.qgGeneration = const QgGenerationApi(),
    this.stageFourFive = const StageFourFiveApi(),
    this.proposalApi = const BdjObjectiveProposalApi(),
  }) : assert(stageNumber == 3 || stageNumber == 4);

  @override
  State<Project1ResearchStagePanel> createState() =>
      _Project1ResearchStageState();
}

class _Project1ResearchStageState extends State<Project1ResearchStagePanel> {
  late Future<Map<String, dynamic>> _future = _fetch();
  bool _saving = false;

  /// The proposal whose governed generation attempt is in flight, if any.
  /// Separate from [_saving] so one objective's attempt does not disable the
  /// whole stage.
  String? _generatingProposalId;

  /// Which approved objectives the one batch action will include.
  ///
  /// A selection, not a permission. The server re-derives every objective's
  /// eligibility and authorization on the request and refuses per objective, so
  /// ticking an ineligible objective cannot make it eligible — it only asks the
  /// server to say so.
  final Set<String> _batchSelection = {};

  /// The assessment the selection was seeded for, so re-reading the page does
  /// not silently re-tick objectives the owner deliberately unticked.
  String? _batchSeededFor;
  bool _batchRunning = false;
  QgBatchResult? _batchResult;

  /// The QG processing terms for one objective, held only after the server has
  /// refused generation for want of a grant. Populated from the server's own
  /// disclosure so the form cannot describe terms the server would not honour.
  QgConsent? _consent;

  /// Which objective [_consent] belongs to. The terms are per objective, so
  /// they must never be shown under a different one.
  String? _consentProposalId;

  /// True while the owner's grant request is in flight.
  bool _grantingConsent = false;

  // -- Section B: the generated questions themselves -------------------------
  //
  // `m2_qg_candidates` is a different record set from the legacy per-objective
  // version chain that `data['candidates']` holds, and only this read returns
  // it. It is loaded here rather than by a child component so that one
  // objective is one card on this page: the objective's wording, its question
  // count, its selection tick and its questions are all rendered from the same
  // list, and a question can never be listed under an objective other than the
  // one it was generated for.
  List<QgCandidate> _qgCandidates = const [];

  /// `false` until the first read returns. A failed read is reported as
  /// unavailable, never as "no questions were generated".
  bool _qgLoaded = false;
  String? _qgError;

  /// The candidate whose decision or intention is being written.
  String? _qgBusyId;
  final Map<String, String> _qgWriteError = {};

  /// The assessment revision the questions were read against. A write is
  /// refused by the server when it disagrees, so the value sent is the one the
  /// reader is actually looking at.
  int? _qgRevision;

  /// Why an objective with no question yet cannot generate, per objective.
  ///
  /// Read on demand for exactly those objectives, because the report answers a
  /// question only they raise. A PASS here is not an authorisation.
  final Map<String, QgEligibility> _qgEligibility = {};

  /// Objectives whose eligibility has been *asked for*, whether or not the
  /// answer arrived.
  ///
  /// Separate from [_qgEligibility] on purpose: the read is started from build,
  /// so a failed read that left no map entry would be retried on every rebuild —
  /// a request loop against a server that has already said no.
  final Set<String> _eligibilityAsked = <String>{};

  /// Objectives whose eligibility report the reader has opened. Owned here for
  /// the same reason as [_openCoreQuestions]: a rebuild would otherwise close it.
  final Set<String> _openEligibility = <String>{};

  /// What a separately authorised recovery of this objective would require.
  ///
  /// Read from the server rather than inferred from a refusal code: only the
  /// server can say whether a spent attempt can still be recovered, because only
  /// it knows whether an unspent grant remains. Null means "not asked", which is
  /// different from "not possible" — [_recoveryProposalId] tells them apart.
  QgRecoveryState? _recovery;
  String? _recoveryProposalId;

  /// True while the recovery authorization request is in flight.
  bool _authorisingRecovery = false;

  /// Seconds elapsed in the provider call that is currently running.
  ///
  /// A live generation is a real cloud call bounded by a 90-second transport
  /// timeout, and the panel previously showed a static "Generating…" for the
  /// whole of it. That reads as a hung page. This ticks once a second so the
  /// owner can see the call is still running and how much of the budget is
  /// left — it is a *transport* indicator, not a claim that the model has
  /// produced anything, and it stops the moment the request returns.
  int _generatingSeconds = 0;
  Timer? _generatingTicker;

  /// The transport budget the server enforces, taken from the status contract.
  ///
  /// It is **not** hardcoded: the server reports `timing.provider_timeout_seconds`
  /// in every status reading, and the deployed value is configurable (and
  /// clamped to 180 s). The fallback below only covers the window before the
  /// first reading arrives, where the panel has no fact to show; it is labelled
  /// as an assumption, never presented as the server's policy.
  static const int _fallbackTimeoutSeconds = 90;
  int get _generationTimeoutSeconds =>
      _execution?.providerTimeoutSeconds ?? _fallbackTimeoutSeconds;

  void _startGenerationClock() {
    _generatingTicker?.cancel();
    _generatingSeconds = 0;
    _generatingTicker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _generatingSeconds += 1);
    });
  }

  void _stopGenerationClock() {
    _generatingTicker?.cancel();
    _generatingTicker = null;
  }

  @override
  void dispose() {
    // A timer that outlives the component would call setState on a disposed
    // State, which is a crash rather than a leak.
    _stopGenerationClock();
    // Polling must stop with the component, or navigating away leaves a request
    // every two seconds against an assessment nobody is looking at. The poller
    // also makes any in-flight response a no-op, so a late answer cannot call
    // setState on this disposed State.
    _poller.dispose();
    super.dispose();
  }

  String? _message;
  String _newObjective = '';
  final Map<String, String> _reviewRationales = {};

  /// Presentation-only: Stage 4 question filter. `all` | `pending` | `approved`
  /// | `rejected`. Filtering happens over rows already fetched — no new request.
  String _candidateFilter = 'all';

  /// Which fixed-core questions the reader has opened, keyed by question id.
  ///
  /// A `<details>` element keeps its open state in the DOM, and this panel
  /// rebuilds on every status poll. So the state is owned here and written back
  /// on each render — otherwise a rebuild would close a row the reader had just
  /// opened, which is the same defect the execution card's "More details" had.
  final Set<String> _openCoreQuestions = <String>{};

  /// How many fixed questions are shown before `Show all questions`.
  ///
  /// Five, not thirteen: the reference shows a few rows plus a count of the
  /// rest, and thirteen rows of read-only wording push Section B — the part the
  /// owner can actually act on — off the first screen.
  static const int _corePageSize = 5;
  bool _showAllCore = false;

  /// Presentation-only demo of the Stage 4 design. Enabled ONLY by the
  /// `?demo=stage4` query parameter. Every row below is sample data; the demo
  /// never calls, creates or writes any M2/backend record. All interactions
  /// (owner option, Approve, Reject) change local widget state only.
  bool get _demoStage4 =>
      Uri.base.queryParameters['demo'] == 'stage4' &&
      component.stageNumber == 4;
  final Map<String, String> _demoOwnerOptions = {};
  final Map<String, String> _demoDecisions = {};

  /// Generated questions for the design demo.
  ///
  /// Two formats on purpose: the single-answer control and the multi-answer
  /// control are different controls, and a demo that showed only one of them
  /// could not be used to review the other. Nothing here is read from or
  /// written to a database.
  List<QgCandidate> get _demoQgCandidates => [
    QgCandidate(
      candidateId: 'DEMO-QG-1',
      assessmentId: 'DEMO-ONLY',
      objectiveId: 'RO-01',
      objectiveClassification: 'ADDITIONAL_ASSESSMENT_OBJECTIVE',
      question:
          'How would you prefer to buy coffee during weekday mornings?',
      responseFormat: 'SINGLE_CHOICE',
      options: const [
        CandidateOption(
          code: 'TAKEAWAY',
          label: 'Takeaway',
          order: 0,
          orderSource: 'DEMO',
        ),
        CandidateOption(
          code: 'DINE_IN',
          label: 'Dine-in',
          order: 1,
          orderSource: 'DEMO',
        ),
        CandidateOption(
          code: 'BOTH',
          label: 'Both, depending on the situation',
          order: 2,
          orderSource: 'DEMO',
        ),
      ],
      routing: const {},
      review: CandidateReview(
        decision: _demoDecisions['DEMO-QG-1'],
        expectedOptionCodes: _demoOwnerOptions['DEMO-QG-1'] == null
            ? const []
            : [_demoOwnerOptions['DEMO-QG-1']!],
      ),
      candidateState: 'VALIDATED',
      executionMode: 'SIMULATED',
      modelProvider: 'simulated-qg-v1',
      dispatched: false,
      fieldingAuthorized: false,
      scientificallyAccepted: false,
    ),
    QgCandidate(
      candidateId: 'DEMO-QG-2',
      assessmentId: 'DEMO-ONLY',
      objectiveId: 'RO-01',
      objectiveClassification: 'ADDITIONAL_ASSESSMENT_OBJECTIVE',
      question:
          'Which of these would you consider buying on a weekday morning?',
      responseFormat: 'MULTIPLE_CHOICE',
      options: const [
        CandidateOption(
          code: 'COFFEE',
          label: 'Coffee',
          order: 0,
          orderSource: 'DEMO',
        ),
        CandidateOption(
          code: 'PASTRY',
          label: 'A pastry',
          order: 1,
          orderSource: 'DEMO',
        ),
        CandidateOption(
          code: 'BREAKFAST_SET',
          label: 'A breakfast set',
          order: 2,
          orderSource: 'DEMO',
        ),
      ],
      routing: const {},
      review: const CandidateReview(),
      candidateState: 'VALIDATED',
      executionMode: 'SIMULATED',
      modelProvider: 'simulated-qg-v1',
      dispatched: false,
      fieldingAuthorized: false,
      scientificallyAccepted: false,
    ),
  ];

  Map<String, dynamic> _demoStage4Snapshot() {
    const objId = 'RO-01';
    final objectives = [
      {
        'objective_id': objId,
        'objective_version': objId,
        'exact_text':
            'Investigate takeaway versus dine-in preferences among nearby '
            'office workers during weekday mornings.',
        'source_finding_ids': ['F-001'],
        'approval_status': 'CONFIRMED_BY_OWNER',
      },
    ];
    Map<String, dynamic> candidate(
      String id,
      String question,
      List<String> options,
    ) => {
      'candidate_id': id,
      'candidate_version': id,
      'source_objective_id': objId,
      'source_objective_version': objId,
      'question_text': question,
      'response_kind': 'SINGLE_CHOICE',
      'owner_review_decision': _demoDecisions[id] ?? 'PENDING',
      'owner_expected_option_id': _demoOwnerOptions[id] ?? '',
      'options': [
        for (var i = 0; i < options.length; i++)
          {'option_id': 'opt-$i', 'label': options[i]},
      ],
    };
    final candidates = [
      candidate(
        'Q1',
        'How would you prefer to buy coffee during weekday mornings?',
        [
          'Takeaway',
          'Dine-in',
          'Both, depending on the situation',
          'No clear preference',
        ],
      ),
      candidate(
        'Q2',
        'How often would you consider buying takeaway coffee on a weekday morning?',
        [
          'Daily',
          '2–4 times per week',
          'Once per week',
          'Less than once per week',
          'Never',
        ],
      ),
    ];
    return {
      'marketplace_assessment_id': component.marketplaceAssessmentId,
      'm2_assessment_id': 'DEMO-ONLY',
      'confirmation_id': 'DEMO-ONLY',
      'm2_revision': 1,
      'source_current': true,
      'evaluation_state': 'DEMO',
      'rule_version': 'DEMO',
      'current_bdj': null,
      'research_intention': [],
      'ai_status': AiExecutionStatus.unavailable,
      'findings': [],
      'objectives': objectives,
      'candidates': candidates,
      'context_id': null,
      'context_objective_id': null,
      'candidate_read_unavailable': false,
      'unmapped_candidate_count': 0,
      'readiness': {'stage3_ready': true, 'stage4_ready': true},
      'demo': true,
    };
  }

  @override
  void didUpdateComponent(covariant Project1ResearchStagePanel oldComponent) {
    super.didUpdateComponent(oldComponent);
    if (oldComponent.marketplaceAssessmentId !=
            component.marketplaceAssessmentId ||
        oldComponent.stageNumber != component.stageNumber) {
      _newObjective = '';
      _reviewRationales.clear();
      _message = null;
      _candidateFilter = 'all';
      // Terms belong to one objective on one assessment; carrying them across a
      // switch would show a permission for the wrong research objective.
      _consent = null;
      _consentProposalId = null;
      _grantingConsent = false;
      // A recovery names one spent attempt on one objective; showing it under
      // another objective would misdescribe which act is being authorised.
      _recovery = null;
      _recoveryProposalId = null;
      _authorisingRecovery = false;
      _future = _fetch();
    }
  }

  // Only reads the M2 explicitly linked to this marketplace assessment.
  // Never infer an M2 id from its owner, creation time or list ordering.
  Future<Map<String, dynamic>> _fetch() async {
    if (_demoStage4) return _demoStage4Snapshot();
    final linked = await AppLocator.m2.linkForMarketplace(
      component.marketplaceAssessmentId,
    );
    final m2Id = linked?['m2_assessment_id'];
    if (m2Id is! String || m2Id.isEmpty) {
      throw StateError('A verified linked M2 assessment is required.');
    }
    final draft = await AppLocator.m2.read(m2Id);
    final conf = await AppLocator.m2.currentConfirmation(m2Id);
    if (conf == null || conf['assessment_revision'] != draft.revision) {
      throw StateError(
        'Current M2 confirmation is missing or stale. Return to Stage 2.',
      );
    }
    final confId = conf['id'];
    if (confId is! String || confId.isEmpty) {
      throw StateError('The M2 confirmation has no persisted identifier.');
    }

    final review = await AppLocator.confirmedReview.read(
      assessmentId: m2Id,
      confirmationId: confId,
      revision: draft.revision,
    );
    final workspace = await AppLocator.m2.readResearchWorkspace(
      m2Id,
      confId,
      draft.revision,
    );
    CurrentBdjResult? currentBdj;
    try {
      currentBdj = await AppLocator.m2.readCurrentBdj(
        m2Id,
        confId,
        draft.revision,
      );
    } catch (_) {
      // The optional result feed may be unprovisioned or held. Never turn
      // failure into a successful zero-finding execution.
      currentBdj = null;
    }
    // A second read prevents a revision change during the two source reads
    // from being presented as a current workspace.
    final current = await AppLocator.m2.currentConfirmation(m2Id);
    if (current == null ||
        current['id'] != confId ||
        current['assessment_revision'] != draft.revision) {
      throw StateError('The M2 confirmation changed during the read.');
    }
    final currentLink = await AppLocator.m2.linkForMarketplace(
      component.marketplaceAssessmentId,
    );
    if (currentLink?['m2_assessment_id'] != m2Id) {
      throw StateError('The assessment link changed during the read.');
    }
    final unique = <String, Map<String, dynamic>>{};
    for (final row in workspace.rows) {
      final id = row['id'] as String;
      final source = Map<String, dynamic>.from(row['provenance'] as Map);
      final findingId = source['finding_id'];
      unique[id] = {
        'objective_id': id,
        'objective_version': row['objective_version_id'],
        'exact_text': row['exact_text'],
        'source_finding_ids': findingId is String ? [findingId] : <String>[],
        'approval_status': row['approval_status'] ?? 'AUTHORITY_UNVERIFIED',
      };
    }
    final candidates = <Map<String, dynamic>>[];
    String? contextId;
    String? contextObjectiveId;
    var candidateReadUnavailable = false;
    var candidateHistoryLoaded = false;
    if (component.stageNumber == 4) {
      try {
        final status = await AppLocator.m2.contextStatus(
          m2Id,
          confId,
          draft.revision,
        );
        final id = status['context_id'];
        if (status['status'] == 'PERSISTED' &&
            status['source_is_current'] == true &&
            id is String) {
          // Set before the packet is inspected: a BCB 1.2.1 packet has
          // ``confirmed_uncertainty = null``, so requiring one to identify the
          // context left Stage 4 with no context id and therefore no way to
          // read the objective the owner approved (DD-043).
          contextId = id;
          final context = await AppLocator.m2.readContext(
            m2Id,
            confId,
            draft.revision,
            id,
          );
          final packet = Map<String, dynamic>.from(
            context.data['packet'] as Map,
          );
          final uncertainty = packet['confirmed_uncertainty'];
          final objectiveId = uncertainty is Map ? uncertainty['id'] : null;
          final objective = unique[objectiveId];
          if (objectiveId is String &&
              objective != null &&
              objective['approval_status'] == 'CONFIRMED_BY_OWNER' &&
              objective['objective_version'] == objectiveId) {
            contextId = id;
            contextObjectiveId = objectiveId;
            final history = await AppLocator.m2.candidateHistory(
              objectiveId,
              draft.revision,
            );
            candidateHistoryLoaded = true;
            for (final entry in history.versions) {
              final candidate = await AppLocator.m2.readCandidate(
                entry.version,
              );
              final fixed = candidate.fields['fixed_measurement'];
              if (candidate.objectiveId != objectiveId ||
                  candidate.fields['source_fingerprint'] !=
                      packet['packet_hash'] ||
                  candidate.fields['contract_version'] !=
                      'P1-QG-FIXED-OPTION-1.0' ||
                  fixed is! Map ||
                  fixed['response_format'] is! String) {
                candidateReadUnavailable = true;
                continue;
              }
              String? expectedOption;
              var predictionAvailable = false;
              try {
                final reviewQuestion = await AppLocator.m2
                    .readEntrepreneurQuestion(
                      candidate.version,
                      draft.revision,
                    );
                final reviewOptions = reviewQuestion['options'] as List;
                final matchingOptions =
                    reviewOptions.length == candidate.options.length &&
                    candidate.options.every(
                      (choice) => reviewOptions.whereType<Map>().any(
                        (row) =>
                            row['code'] == choice.code &&
                            row['label'] == choice.label &&
                            row['eligible'] == true,
                      ),
                    );
                if (reviewQuestion['objective_id'] == objectiveId &&
                    reviewQuestion['question'] == candidate.question &&
                    matchingOptions) {
                  final saved = reviewQuestion['option_code'];
                  if (saved == null ||
                      candidate.options.any((choice) => choice.code == saved)) {
                    expectedOption = saved as String?;
                    predictionAvailable = true;
                  }
                }
              } catch (_) {
                // Prediction is a separate owner-scoped capability. A held or
                // historical version must not hide an otherwise valid candidate.
              }
              candidates.add({
                'candidate_id': candidate.version,
                'candidate_version': candidate.version,
                'source_objective_id': objectiveId,
                'source_objective_version': objectiveId,
                'question_text': candidate.question,
                'response_kind': fixed['response_format'],
                'owner_review_decision': candidate.decision.wireCode,
                'review_rationale': candidate.rationale,
                'supersedes': candidate.supersedes,
                'owner_expected_option_id': expectedOption ?? '',
                'prediction_available': predictionAvailable,
                'source_revision': draft.revision,
                'context_id': id,
                'options': [
                  for (final option in candidate.options)
                    {'option_id': option.code, 'label': option.label},
                ],
              });
            }
          }
        }
      } catch (_) {
        candidateReadUnavailable = true;
      }
      final after = await AppLocator.m2.currentConfirmation(m2Id);
      final linkAfter = await AppLocator.m2.linkForMarketplace(
        component.marketplaceAssessmentId,
      );
      if (after == null ||
          after['id'] != confId ||
          after['assessment_revision'] != draft.revision ||
          linkAfter?['m2_assessment_id'] != m2Id) {
        throw StateError(
          'The confirmed source changed while loading questions.',
        );
      }
    }
    // Stage 4 Section A: the fixed governed Q01-Q13 core questionnaire.
    //
    // Independent of objective approval, QJ and cloud QG on purpose: the core
    // preview must render even when no additional candidate exists, and a
    // failure here degrades Section A only — it never breaks Section B.
    PreviewQuestionnaire? preview;
    String? previewError;
    if (component.stageNumber == 4) {
      final result = await component.previewApi.read(
        assessmentId: m2Id,
        expectedRevision: draft.revision,
        confirmationId: confId,
      );
      if (result.ok) {
        preview = result.value;
      } else {
        previewError = result.failure?.code ?? 'PREVIEW_UNAVAILABLE';
      }
    }

    // DD-043 / DD-047. The owner's approval is recorded against an *objective
    // proposal* (``m2_bdj_objective_proposals`` plus ``m2_bdj_objective_decisions``),
    // not against the research-workspace objective rows read above. Section B
    // therefore rendered "No approved objective" while the database held an
    // APPROVED decision, and told the owner to repeat an action already done.
    //
    // The proposal collection is read here through the same endpoint Stage 3
    // uses, and merged under its contract-2.1 identity ``proposal:<uuid>`` so
    // the two stages finally name the same thing the same way. A failed read is
    // recorded as *unavailable*, never as "nothing approved" (DD-047).
    var objectiveReadUnavailable = false;
    if (component.stageNumber == 4) {
      final proposalContextId = contextId;
      if (proposalContextId == null) {
        // Without a current business context the proposal read is bound to
        // nothing, so it is reported as unavailable rather than as empty.
        objectiveReadUnavailable = true;
      } else {
        try {
          // The port, not the default implementation: [proposalApi] exists so a
          // component test can render a recorded proposal list without reaching
          // the network. Calling the concrete client here bypassed the seam and
          // made the "no approved objective" branch unreachable under test.
          final listed = await component.proposalApi.list(
            assessmentId: m2Id,
            expectedRevision: draft.revision,
            contextId: proposalContextId,
          );
          if (listed.ok && listed.value != null) {
            for (final proposal in listed.value!.proposals) {
              if (proposal.reviewState != BdjReviewState.approved) continue;
              final identity = 'proposal:${proposal.proposalId}';
              unique[identity] = {
                'objective_id': identity,
                'objective_version': identity,
                'exact_text': proposal.recommendation.researchObjective,
                'source_finding_ids': <String>[],
                'approval_status': 'APPROVED',
                // Contract 2.1 identity carried to the generation action: the
                // route needs the proposal id, not the registry code.
                'proposal_id': proposal.proposalId,
                'objective_kind': 'ADDITIONAL_ASSESSMENT_OBJECTIVE',
              };
            }
          } else {
            objectiveReadUnavailable = true;
          }
        } catch (_) {
          // A transport failure is not an absence of approval.
          objectiveReadUnavailable = true;
        }
      }
    }

    // What the AI ledger recorded for BDJ and Direct-QG, started but not
    // awaited. The card has its own loading state, and awaiting a second read
    // here would make the whole page wait on a status panel. Reading it never
    // invokes a model, so starting it eagerly is free of side effects.
    _loadExecution(m2Id);

    // Section B's own record set. Also started, not awaited: the generated
    // questions are one section of the page and must not hold up the fixed
    // core above them. Reading it never invokes a model.
    if (component.stageNumber == 4) {
      unawaited(_loadQg(m2Id, draft.revision));
    }

    final data = <String, dynamic>{
      'marketplace_assessment_id': component.marketplaceAssessmentId,
      'm2_assessment_id': m2Id,
      'confirmation_id': confId,
      'm2_revision': draft.revision,
      'preview_questionnaire': preview,
      'preview_error': previewError,
      'source_current': true,
      'evaluation_state': review.evaluationState,
      'rule_version': review.ruleVersion,
      'current_bdj': currentBdj,
      'research_intention': [
        for (final answer in review.answers)
          if (const {'M2V1-09', 'M2V1-10', 'M2V1-11'}.contains(answer.itemKey))
            {
              'item_key': answer.itemKey,
              'state': answer.state,
              'value': answer.displayValue,
            },
      ],
      'ai_status': AiExecutionStatus.fromConfirmedReview(
        evaluationState: review.evaluationState,
        revision: draft.revision,
        ruleVersion: review.ruleVersion,
        findingCount: review.findings.length,
      ),
      'findings': [
        for (final finding in review.findings)
          {
            'finding_id': finding.id,
            'uncertainty_text': finding.explanation,
            'review_status': finding.reviewState,
            'source_refs': finding.sourceAnswerIds,
          },
      ],
      'objectives': unique.values.toList(),
      // True when the approved-objective read itself failed. Section B must
      // distinguish that from "the owner has approved nothing" (DD-047).
      'objective_read_unavailable': objectiveReadUnavailable,
      // The existing workspace response does not prove objective approval,
      // objective version, candidate currentness or BCB authority.
      'candidates': candidates,
      'context_id': contextId,
      'context_objective_id': contextObjectiveId,
      'candidate_read_unavailable': candidateReadUnavailable,
      'candidate_history_loaded': candidateHistoryLoaded,
      'unmapped_candidate_count': workspace.rows
          .where(
            (row) =>
                row['version'] != null &&
                !candidates.any(
                  (candidate) =>
                      candidate['candidate_id'] == row['version'].toString(),
                ),
          )
          .length,
      'readiness': {'stage3_ready': false, 'stage4_ready': false},
    };
    if (data['marketplace_assessment_id'] !=
            component.marketplaceAssessmentId ||
        data['m2_assessment_id'] != m2Id ||
        data['confirmation_id'] != confId ||
        data['m2_revision'] != draft.revision ||
        data['source_current'] != true) {
      throw StateError(
        'Research workspace source identity is unverified or stale.',
      );
    }
    if (data['findings'] is! List ||
        data['objectives'] is! List ||
        data['candidates'] is! List ||
        data['readiness'] is! Map) {
      throw StateError('Research workspace result is missing required fields.');
    }
    return data;
  }

  /// What the AI ledger recorded, once it has been read.
  ///
  /// Mirrored from [_poller] rather than owned here: the polling lifecycle lives
  /// in `ExecutionStatusPoller` so it can be verified without mounting this page
  /// (CP-P03). This field exists only because the page reads the reading in
  /// three places.
  AiExecutionReading? _execution;

  /// Whether the status read has answered, not answered yet, or failed.
  ///
  /// Kept separate from [_execution] because a null reading means three
  /// different things and the card must not word them the same way: the request
  /// is still in flight, the request failed, or the server answered without
  /// this purpose. Only the middle case may say "could not be read".
  RailReadState _executionRead = RailReadState.pending;

  /// The status reader.
  ///
  /// A *read*: nothing here can dispatch, retry or authorise an execution, which
  /// is what makes polling safe (CP-PROG-04). Kept off the page's own future on
  /// purpose — a slow or failing status read must not delay or blank the
  /// research workspace.
  late final ExecutionStatusPoller _poller = ExecutionStatusPoller(
    read: (assessmentId) async {
      final result = await component.stageFourFive.executionStatus(
        assessmentId: assessmentId,
      );
      // A refused read is a failed read, never a failed execution. The poller
      // keeps the last good reading and backs off.
      if (!result.ok) throw StateError('execution status read failed');
      return result.value;
    },
    onChanged: _onExecutionChanged,
  );

  /// True while a status request is outstanding. Disables the manual refresh so
  /// the button cannot stack requests.
  bool get _executionPollInFlight => _poller.view.inFlight;

  void _onExecutionChanged(ExecutionStatusView view) {
    if (!mounted) return;
    setState(() {
      _execution = view.reading;
      _executionRead = view.readState;
    });
  }

  /// Begins reading the status for [m2Id], and keeps reading it while the
  /// execution is non-terminal.
  void _loadExecution(String m2Id) => _poller.start(m2Id);

  /// Manual refresh, exposed to the "status unavailable" state.
  Future<void> _refreshExecution() => _poller.refresh();

  Future<void> _generateQuestion(
    Map<String, dynamic> data,
    String objectiveId,
  ) async {
    if (_saving ||
        data['context_objective_id'] != objectiveId ||
        data['context_id'] is! String) {
      return;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final outcome = await AppLocator.m2.prepareCandidate(
        objectiveId: objectiveId,
        expectedRevision: data['m2_revision'] as int,
        contextId: data['context_id'] as String,
      );
      final refreshed = await _fetch();
      if (!mounted) return;
      final code = outcome.code;
      final readbackVerified =
          outcome.candidate != null &&
          _rows(refreshed['candidates']).any(
            (row) =>
                row['candidate_id'] == outcome.candidate!.version &&
                row['source_objective_id'] == objectiveId,
          );
      setState(() {
        _saving = false;
        _future = Future.value(refreshed);
        _message = outcome.hasCandidate && readbackVerified
            ? 'Question candidate saved. Review its wording and options below.'
            : outcome.hasCandidate
            ? 'The returned candidate could not be verified in saved history. Refresh before retrying.'
            : outcome.isAbstention
            ? 'The generator needs more information before proposing a question.'
            : code != null && RegExp(r'^[A-Z0-9_]{1,80}$').hasMatch(code)
            ? 'Question generation is unavailable ($code). No approval was recorded.'
            : 'Question generation is unavailable. Check the current research context.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _message =
            'The question request could not be verified. Refresh before retrying.';
      });
    }
  }

  /// One owner action, one governed attempt per selected objective.
  ///
  /// The server walks the selection in order and reports each objective
  /// separately, so a refusal on one does not remove another's candidate. The
  /// page sends identities only: no authorization, no measurement, no owner
  /// answer. Everything that decides whether a question may be generated is
  /// re-derived server-side from the approval it already recorded.
  Future<void> _generateForObjectives(
    Map<String, dynamic> data,
    List<Map<String, dynamic>> approved,
  ) async {
    final assessmentId = data['m2_assessment_id'];
    final contextId = data['context_id'];
    final confirmationId = data['confirmation_id'];
    if (assessmentId is! String ||
        contextId is! String ||
        confirmationId is! String ||
        _batchRunning) {
      return;
    }
    final selected = <String>[
      for (final objective in approved)
        if (objective['proposal_id'] is String &&
            _batchSelection.contains(objective['proposal_id']))
          objective['proposal_id'] as String,
    ];
    if (selected.isEmpty) return;

    setState(() {
      _batchRunning = true;
      _batchResult = null;
      _message = null;
    });
    _startGenerationClock();
    try {
      final result = await component.qgGeneration.generateForObjectives(
        assessmentId: assessmentId,
        confirmationId: confirmationId,
        contextId: contextId,
        proposalIds: selected,
      );
      if (!mounted) return;
      if (!result.ok) {
        final code = result.failure?.code;
        setState(() {
          _batchRunning = false;
          _message =
              'Question generation is unavailable'
              '${code == null ? '' : ' ($code)'}. '
              '${result.failure?.message ?? 'No candidate was produced and no approval was recorded.'}';
        });
        return;
      }
      final value = result.value!;
      // Re-read before reporting. A 200 says the server walked the selection;
      // only the refreshed candidate list says what was actually saved.
      final refreshed = await _fetch();
      if (!mounted) return;
      setState(() {
        _batchRunning = false;
        _future = Future.value(refreshed);
        _batchResult = value;
        _message = _batchSummary(value);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _batchRunning = false;
        _message =
            'The generation request could not be completed. Refresh before '
            'retrying; an objective that already used its attempt will say so.';
      });
    }
  }

  /// The objective's own label for a result row.
  ///
  /// Falls back to a short proposal id when the objective is no longer in the
  /// approved list — a result must still be attributable to the thing that
  /// produced it after the list changes.
  String _objectiveLabel(
    List<Map<String, dynamic>> approved,
    String proposalId,
  ) {
    for (final objective in approved) {
      if (objective['proposal_id'] == proposalId) {
        return _s(objective['objective_id']);
      }
    }
    return proposalId.length > 8 ? proposalId.substring(0, 8) : proposalId;
  }

  /// One sentence about the batch, in the server's own counts.
  ///
  /// Deliberately does not say "generated N questions": the response reports
  /// attempts and candidate ids, and the wording must not claim more than that.
  String _batchSummary(QgBatchResult value) {
    if (value.requested == 0) return 'No objective was selected.';
    final parts = <String>[
      value.persisted == 0
          ? 'No question candidate was saved'
          : '${value.persisted} question '
                '${value.persisted == 1 ? 'candidate' : 'candidates'} saved',
      if (value.refused > 0)
        '${value.refused} objective${value.refused == 1 ? '' : 's'} refused',
    ];
    return '${parts.join(' · ')}. Each objective below carries its own outcome.';
  }

  /// Seed the selection once per assessment revision.
  ///
  /// Defaults are a convenience, not a verdict: an objective that already has a
  /// candidate is not re-ticked, because regenerating it would spend an attempt
  /// the ledger has already recorded. Whether the rest may generate is still
  /// the server's answer, given per objective when the action is taken.
  ///
  /// Both record sets are consulted. A question generated by Direct-QG lives in
  /// `m2_qg_candidates`, not in the legacy version chain, so a seed that read
  /// only the chain would tick every objective that already had a generated
  /// question and invite the owner to spend a second attempt on it.
  void _seedBatchSelection(
    Map<String, dynamic> data,
    List<Map<String, dynamic>> approved,
  ) {
    final key = '${data['m2_assessment_id']}:${data['m2_revision']}';
    if (_batchSeededFor == key) return;
    _batchSeededFor = key;
    final candidates = _rows(data['candidates']);
    _batchSelection
      ..clear()
      ..addAll([
        for (final objective in approved)
          if (objective['proposal_id'] is String &&
              _qgFor(objective).isEmpty &&
              candidates
                  .where(
                    (c) =>
                        c['source_objective_id'] == objective['objective_id'] &&
                        c['source_objective_version'] ==
                            objective['objective_version'],
                  )
                  .isEmpty)
            objective['proposal_id'] as String,
      ]);
  }

  // -- Section B reads and writes --------------------------------------------

  /// Read the generated questions for this assessment.
  ///
  /// Deliberately independent of the legacy candidate read: a failure here
  /// degrades Section B's question list only, and is reported as *unavailable*
  /// rather than as an empty list, because "nothing was generated" and "the
  /// generated questions could not be read" are different facts about the
  /// assessment and only one of them is the owner's to act on.
  Future<void> _loadQg(String m2Id, int revision) async {
    if (_qgLoaded) return;
    final result = await component.stageFourFive.candidates(assessmentId: m2Id);
    if (!mounted) return;
    setState(() {
      _qgLoaded = true;
      _qgRevision = revision;
      if (result.ok) {
        _qgCandidates = result.value ?? const <QgCandidate>[];
        _qgError = null;
      } else {
        _qgError = result.failure?.code ?? 'QG_CANDIDATES_UNAVAILABLE';
      }
    });
  }

  /// Read why one objective cannot generate a question yet.
  ///
  /// Called for objectives that hold no candidate, which is the only situation
  /// that raises the question. The report is the server's own, check by check;
  /// nothing here decides eligibility locally.
  Future<void> _loadEligibility(String m2Id, String objectiveId) async {
    if (_eligibilityAsked.contains(objectiveId)) return;
    _eligibilityAsked.add(objectiveId);
    final result = await component.stageFourFive.eligibility(
      assessmentId: m2Id,
      objectiveId: objectiveId,
    );
    if (!mounted || !result.ok || result.value == null) return;
    setState(() => _qgEligibility[objectiveId] = result.value!);
  }

  /// Record the owner's judgement about one generated question.
  ///
  /// The receipt is not the record: it echoes the decision and the two
  /// authority flags only, so the list is read back rather than reconstructed.
  Future<void> _decideQg(
    String m2Id,
    QgCandidate candidate,
    String decision,
  ) async {
    if (_qgBusyId != null) return;
    setState(() {
      _qgBusyId = candidate.candidateId;
      _qgWriteError.remove(candidate.candidateId);
    });
    final result = await component.stageFourFive.reviewCandidate(
      assessmentId: m2Id,
      candidateId: candidate.candidateId,
      decision: decision,
      // The decision is the record. The screen collects no prose, so it sends
      // none rather than inventing a reason on the owner's behalf.
      rationale: '',
      expectedRevision: _qgRevision,
    );
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _qgBusyId = null;
        _qgWriteError[candidate.candidateId] =
            result.failure?.message ?? 'The decision could not be recorded.';
      });
      return;
    }
    final receipt = result.value;
    final refreshed = await component.stageFourFive.candidates(
      assessmentId: m2Id,
    );
    if (!mounted) return;
    setState(() {
      _qgBusyId = null;
      if (refreshed.ok) _qgCandidates = refreshed.value ?? _qgCandidates;
      // Approving a question is not fielding it. If the server ever reports
      // otherwise that is a change in authority, and the reader must be told
      // rather than shown a success.
      if (receipt != null &&
          (receipt.fieldingAuthorized || receipt.scientificallyAccepted)) {
        _qgWriteError[candidate.candidateId] =
            'The server reported fielding authorisation or scientific '
            'acceptance on this decision. That is a change in authority — stop '
            'and review it rather than continuing.';
      }
    });
    component.onStageProgressChanged?.call();
  }

  /// Record the owner's intended response to one generated question.
  ///
  /// A prediction about respondents, never a respondent answer. The codes are
  /// sent as the set the server stores, so a multiple-choice intention keeps
  /// every option the owner chose instead of being truncated to its first.
  Future<void> _expectQg(
    String m2Id,
    QgCandidate candidate,
    List<String>? codes,
  ) async {
    if (_qgBusyId != null) return;
    setState(() {
      _qgBusyId = candidate.candidateId;
      _qgWriteError.remove(candidate.candidateId);
    });
    final result = await component.stageFourFive.setExpectedAnswer(
      assessmentId: m2Id,
      candidateId: candidate.candidateId,
      optionCodes: codes,
      expectedRevision: _qgRevision,
    );
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _qgBusyId = null;
        _qgWriteError[candidate.candidateId] =
            result.failure?.message ??
            'The intended response could not be recorded.';
      });
      return;
    }
    final refreshed = await component.stageFourFive.candidates(
      assessmentId: m2Id,
    );
    if (!mounted) return;
    setState(() {
      _qgBusyId = null;
      if (refreshed.ok) _qgCandidates = refreshed.value ?? _qgCandidates;
    });
  }

  /// One governed Direct-QG attempt for an objective the owner approved at
  /// Stage 3, using the contract-2.1 route.
  ///
  /// The route derives the objective authority from the approval, evaluates
  /// eligibility, issues the single-use authorization and runs the existing
  /// adapter. The panel sends the proposal identity and nothing that decides
  /// authority, and it renders the server's own refusal code rather than
  /// inventing a reason.
  Future<void> _generateForProposal(
    Map<String, dynamic> data,
    Map<String, dynamic> objective, {
    String? recoveryOf,
  }) async {    final proposalId = objective['proposal_id'];
    final contextId = data['context_id'];
    final confirmationId = data['confirmation_id'];
    if (proposalId is! String ||
        contextId is! String ||
        confirmationId is! String ||
        _generatingProposalId != null) {
      return;
    }
    setState(() {
      _generatingProposalId = proposalId;
      _message = null;
      // Asking to generate supersedes any recovery offer for this objective: the
      // attempt it described is about to be re-evaluated by the server.
      if (_recoveryProposalId == proposalId) {
        _recovery = null;
        _recoveryProposalId = null;
      }
    });
    _startGenerationClock();
    try {
      final result = await component.qgGeneration.generateForObjective(
        assessmentId: data['m2_assessment_id'] as String,
        confirmationId: confirmationId,
        contextId: contextId,
        proposalId: proposalId,
        recoveryOf: recoveryOf,
      );
      if (!mounted) return;
      if (!result.ok) {
        final code = result.failure?.code;
        final serverMessage = result.failure?.message;
        // A missing processing permission is not a malfunction and not a
        // failure of the objective: the owner simply has not granted it yet.
        // The route refuses with this code before issuing an authorization, so
        // nothing was reserved and nothing was dispatched. Offering the terms
        // here is the whole point of the interaction — it keeps the permission
        // inside the workflow that needs it instead of a separate screen.
        if (code == QgGenerationCodes.consentAbsent) {
          await _loadConsentTerms(
            data['m2_assessment_id'] as String,
            proposalId,
          );
          return;
        }
        // A spent attempt is the one refusal with a lawful next step. Read what
        // that step would be from the server, which is the only party that knows
        // whether an unspent grant remains. Nothing is retried automatically:
        // the offer is shown, and the owner decides.
        if (QgGenerationCodes.isSpent(code)) {
          await _loadRecovery(
            data['m2_assessment_id'] as String,
            contextId,
            proposalId,
          );
          return;
        }
        setState(() {
          _generatingProposalId = null;
          _message =
              'Question generation is unavailable'
              '${code == null ? '' : ' ($code)'}. '
              '${serverMessage ?? 'No candidate was produced and no approval was recorded.'}';
        });
        return;
      }
      final value = result.value!;
      final refreshed = await _fetch();
      if (!mounted) return;
      final verified =
          value.candidateId != null &&
          _rows(
            refreshed['candidates'],
          ).any((row) => row['candidate_id'] == value.candidateId);
      setState(() {
        _generatingProposalId = null;
        _future = Future.value(refreshed);
        _message = value.candidateId == null
            ? 'No candidate was produced (${value.outcome}). '
                  '${value.abstentionReason ?? 'The objective could not be turned into a fixed-option question.'}'
            : verified
            ? 'Question candidate saved. Review its wording and options below.'
            : 'The returned candidate could not be verified in saved history. Refresh before retrying.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _generatingProposalId = null;
        _message =
            'The question request could not be verified. Refresh before retrying.';
      });
    } finally {
      // Every exit path — success, governed refusal, consent branch, recovery
      // branch, transport error — stops the clock. A ticker left running would
      // keep claiming a call is in flight after it returned.
      _stopGenerationClock();
    }
  }

  /// Fetch the processing terms the server would ask the owner to accept.
  ///
  /// The terms are read, never composed here: the same call that reports the
  /// absence of a grant also returns the canonical disclosure, so the form can
  /// only ever show what the server will actually honour. If the read fails the
  /// form is not shown at all, because a permission screen with invented terms
  /// would be worse than no permission screen.
  Future<void> _loadConsentTerms(String assessmentId, String proposalId) async {
    final result = await component.stageFourFive.qgConsent(
      assessmentId: assessmentId,
      proposalId: proposalId,
    );
    if (!mounted) return;
    if (!result.ok || result.value == null) {
      setState(() {
        _generatingProposalId = null;
        _consent = null;
        _consentProposalId = null;
        _message =
            'Question generation needs a processing permission, and the terms '
            'could not be read. Nothing was sent to any model. '
            '${result.failure?.code == null ? '' : '(${result.failure!.code})'}';
      });
      return;
    }
    final consent = result.value!;
    setState(() {
      _generatingProposalId = null;
      if (consent.isGranted) {
        // The permission already exists: generation refused for some other
        // reason, so offering the form again would be misleading.
        _consent = null;
        _consentProposalId = null;
        _message =
            'A processing permission is already recorded for this objective, '
            'so generation was refused for a different reason. Reload before '
            'retrying.';
      } else {
        _consent = consent;
        _consentProposalId = proposalId;
        _message = null;
      }
    });
  }

  /// Ask the server what a separate recovery of this objective would require.
  ///
  /// The refusal code alone cannot answer that: whether a recovery is possible
  /// depends on whether an unspent grant remains, which only the server knows.
  /// This reads; it authorises nothing and dispatches nothing.
  Future<void> _loadRecovery(
    String assessmentId,
    String contextId,
    String proposalId,
  ) async {
    final result = await component.qgGeneration.readRecovery(
      assessmentId: assessmentId,
      contextId: contextId,
      proposalId: proposalId,
    );
    if (!mounted) return;
    setState(() {
      _generatingProposalId = null;
      if (!result.ok || result.value == null) {
        _recovery = null;
        _recoveryProposalId = null;
        _message =
            'This objective has already used its one attempt, and the recovery '
            'state could not be read. Nothing was sent to any model. '
            '${result.failure?.code == null ? '' : '(${result.failure!.code})'}';
        return;
      }
      _recovery = result.value;
      _recoveryProposalId = proposalId;
      _message = null;
    });
  }

  /// Authorise exactly one recovery of the attempt the server named.
  ///
  /// This is a separate act from Generate on purpose. The owner is told which
  /// attempt failed, what will be spent and what the ceiling is, and only then
  /// does the request carry `recovery_of`. Nothing here can retry twice: the
  /// server derives the recovery's identity from the spent attempt, so the same
  /// objective can be recovered at most once.
  Future<void> _authoriseRecovery(
    Map<String, dynamic> data,
    Map<String, dynamic> objective,
  ) async {
    final recovery = _recovery;
    final proposalId = objective['proposal_id'];
    if (recovery == null ||
        _authorisingRecovery ||
        _recoveryProposalId != proposalId) {
      return;
    }
    final prior = recovery.request?['recovery_of'] as String?;
    if (prior == null) return;
    setState(() => _authorisingRecovery = true);
    try {
      await _generateForProposal(data, objective, recoveryOf: prior);
    } finally {
      if (mounted) setState(() => _authorisingRecovery = false);
    }
  }

  /// Record the owner's permission, echoing exactly the terms on screen.
  ///
  /// No generation follows. The permission authorises one attempt, so the
  /// owner presses Generate themselves — a hidden second dispatch after a
  /// permission click is not a decision they made.
  Future<void> _grantConsentFor(String assessmentId, String proposalId) async {
    final consent = _consent;
    if (consent == null ||
        _grantingConsent ||
        _consentProposalId != proposalId) {
      return;
    }
    final disclosure = consent.disclosure;
    final echo = <String, dynamic>{
      'granted': true,
      'disclosure_version': disclosure['contract_version'],
      'provider': disclosure['provider'],
      'purpose': disclosure['purpose'],
      'endpoint': disclosure['endpoint'],
      'model': disclosure['model'],
    };
    final missing = echo.entries
        .where((e) => e.key != 'granted' && e.value is! String)
        .map((e) => e.key)
        .toList();
    if (missing.isNotEmpty) {
      setState(() {
        _message =
            'The permission cannot be recorded because the disclosed terms are '
            'incomplete (${missing.join(', ')}). Nothing was sent to any model.';
      });
      return;
    }
    setState(() {
      _grantingConsent = true;
      _message = null;
    });
    try {
      final result = await component.stageFourFive.grantQgConsent(
        assessmentId: assessmentId,
        proposalId: proposalId,
        echo: echo,
      );
      if (!mounted) return;
      if (!result.ok) {
        setState(() {
          _grantingConsent = false;
          _message =
              'The permission was not recorded'
              '${result.failure?.code == null ? '' : ' (${result.failure!.code})'}. '
              '${result.failure?.message ?? 'No permission exists, so nothing can be generated.'}';
        });
        return;
      }
      final granted = result.value?.isGranted == true;
      setState(() {
        _grantingConsent = false;
        _consent = null;
        _consentProposalId = null;
        _message = granted
            ? 'Processing permission recorded for this objective. It authorises '
                  'one generation attempt. Press Generate questions for this '
                  'objective to use it.'
            : 'No permission was recorded, so no generation attempt is '
                  'authorised. Nothing was sent to any model.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _grantingConsent = false;
        _message =
            'The permission request could not be completed. Nothing was sent to '
            'any model.';
      });
    }
  }

  /// The permission form shown inside the Generate Questions workflow.
  ///
  /// Every line is a term the server disclosed, not a phrase this component
  /// invented. Declining is presented as an ordinary choice because it is one:
  /// it leaves the approved objective, the confirmation and the revision
  /// untouched.
  Component _consentForm(
    Map<String, dynamic> data,
    Map<String, dynamic> objective,
  ) {
    final consent = _consent!;
    final disclosure = consent.disclosure;
    // ``data_shared`` is a list of field names, not a list of records, so it is
    // read directly rather than through the row helper.
    final sharedRaw = disclosure['data_shared'];
    final shared = sharedRaw is List
        ? sharedRaw.whereType<String>().join(', ')
        : '';
    final attempts = disclosure['max_attempts'];
    final note = disclosure['note'];
    return div(classes: 'p1-notice p1-notice--soft', [
      strong(classes: 'p1-notice__title', [
        Component.text(
          'Processing permission required before questions can be generated',
        ),
      ]),
      p(classes: 'p1-muted', [
        Component.text(
          'Generating questions for this objective sends part of your confirmed '
          'business context to an external AI model. Nothing has been sent yet. '
          'This permission is separate from confirming your declarations and from '
          'deriving your research objectives, and declining it changes neither.',
        ),
      ]),
      ul(classes: 'p1-muted', [
        if (disclosure['purpose'] is String)
          li([Component.text('Purpose: ${disclosure['purpose']}')]),
        if (shared.isNotEmpty) li([Component.text('Data sent: $shared')]),
        li([
          Component.text(
            'Provider: ${_s(disclosure['provider'])} · '
            'model ${_s(disclosure['model'])} · '
            'endpoint ${_s(disclosure['endpoint'])}',
          ),
        ]),
        if (attempts is num)
          li([
            Component.text(
              'Authorised attempts: $attempts. A granted permission is spent by '
              'the first attempt and is not reused.',
            ),
          ]),
        if (note is String) li([Component.text(note)]),
      ]),
      div(classes: 'p1-group__head', [
        button(
          attributes: const {'type': 'button'},
          classes: 'p1-btn p1-btn--primary',
          onClick: _grantingConsent
              ? null
              : () => _grantConsentFor(
                  data['m2_assessment_id'] as String,
                  _s(objective['proposal_id']),
                ),
          [
            Component.text(
              _grantingConsent
                  ? 'Recording permission…'
                  : 'Grant QG permission',
            ),
          ],
        ),
        button(
          attributes: const {'type': 'button'},
          classes: 'p1-btn',
          onClick: _grantingConsent
              ? null
              : () => setState(() {
                  _consent = null;
                  _consentProposalId = null;
                  _message =
                      'Permission declined. Nothing was sent to any model and no '
                      'generation attempt is authorised.';
                }),
          [Component.text('Not now')],
        ),
      ]),
    ]);
  }

  /// The transport clock for the call currently in flight.
  ///
  /// Deliberately an *elapsed-time* statement, not a percentage of work done.
  /// It used to draw a bar filled by `elapsed / timeout`, which is a determinate
  /// indicator for something the system cannot measure: the provider adapter is
  /// one request/response with streaming disabled, and no progress channel
  /// exists. A bar filling toward 100 % reads as "nearly finished" when it means
  /// "nearly out of time", so it is replaced by an indeterminate marker plus the
  /// elapsed fact, which is true (CP-PROG-03).
  Component _generationProgress() {
    final elapsed = _generatingSeconds;
    final budget = _generationTimeoutSeconds;
    final overBudget = elapsed >= budget;
    return div(classes: 'p1-notice p1-notice--soft', [
      p(classes: 'p1-muted', [
        Component.text(
          overBudget
              ? 'The model call has passed its ${budget}s transport budget. '
                    'The server will report a timeout rather than a candidate; '
                    'nothing has been approved.'
              : 'Waiting for the model. ${elapsed}s elapsed of a '
                    '${budget}s transport budget. The attempt is already spent, '
                    'so do not close this page and press Generate again — that '
                    'would be refused, not retried.',
        ),
      ]),
      div(
        classes: 'aip__indeterminate',
        attributes: const {
          'role': 'progressbar',
          'aria-valuetext': 'Waiting for the model',
        },
        const [],
      ),
    ]);
  }

  /// What a separately authorised recovery would do, stated before it is asked
  /// for.
  ///
  /// The single-use rules mean a technical failure consumes both the attempt and
  /// the permission. Saying so plainly — and naming the attempt — is what makes
  /// the recovery an informed decision rather than a disguised retry. The button
  /// is absent, not merely disabled, when the server reports nothing may be
  /// requested: an action that cannot succeed should not be offered.
  Component _recoveryForm(
    Map<String, dynamic> data,
    Map<String, dynamic> objective,
  ) {
    final recovery = _recovery!;
    final prior = recovery.priorAuthorizationId;
    final request = recovery.request;
    final needsPermission =
        recovery.blockedBy == 'QG_RECOVERY_CONSENT_REQUIRED';
    return div(classes: 'p1-notice p1-notice--soft', [
      strong(classes: 'p1-notice__title', [
        Component.text(
          recovery.alreadyRequested
              ? 'A recovery attempt is already authorised for this objective'
              : 'This objective has already used its one generation attempt',
        ),
      ]),
      p(classes: 'p1-muted', [
        Component.text(
          recovery.alreadyRequested
              ? 'The recovery was issued separately from the original attempt and '
                    'has not been spent. Generating again will use it; no second '
                    'recovery exists for this objective.'
              : 'The attempt was made and consumed both the authorization and the '
                    'processing permission, so no question was produced. The original '
                    'attempt and its receipt are kept as they are. One further attempt '
                    'is permitted, but only as a recovery you authorise separately — '
                    'it is not a retry and does not happen automatically.',
        ),
      ]),
      ul(classes: 'p1-muted', [
        if (prior != null)
          li([
            Component.text(
              'Failed attempt: authorization $prior. It stays on record.',
            ),
          ]),
        li([
          Component.text(
            'This recovery spends one further attempt on the same confirmed '
            'facts, the same research objective and the same permission terms.',
          ),
        ]),
        if (needsPermission)
          li([
            Component.text(
              'The earlier permission was spent by the failed attempt, so a new '
              'processing permission is needed before a recovery can be '
              'authorised.',
            ),
          ]),
        if (recovery.blockedBy == 'QG_RECOVERY_ALREADY_SPENT')
          li([
            Component.text(
              'The recovery attempt has already been spent. This objective '
              'cannot be generated again without a new confirmation.',
            ),
          ]),
      ]),
      div(classes: 'p1-group__head', [
        if (request != null)
          button(
            attributes: const {'type': 'button'},
            classes: 'p1-btn p1-btn--primary',
            onClick: _authorisingRecovery || _generatingProposalId != null
                ? null
                : () => _authoriseRecovery(data, objective),
            [
              Component.text(
                _authorisingRecovery
                    ? 'Authorising recovery…'
                    : 'Authorise one recovery attempt',
              ),
            ],
          ),
        if (needsPermission)
          button(
            attributes: const {'type': 'button'},
            classes: 'p1-btn p1-btn--primary',
            onClick: () => _loadConsentTerms(
              data['m2_assessment_id'] as String,
              _s(objective['proposal_id']),
            ),
            [Component.text('Review the permission terms')],
          ),
        button(
          attributes: const {'type': 'button'},
          classes: 'p1-btn',
          onClick: _authorisingRecovery
              ? null
              : () => setState(() {
                  _recovery = null;
                  _recoveryProposalId = null;
                  _message =
                      'No recovery was authorised. The failed attempt remains on '
                      'record and nothing further was sent to any model.';
                }),
          [Component.text('Not now')],
        ),
      ]),
    ]);
  }

  Future<void> _commit(Future<void> Function() action) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await action();
      // Reload server state before indicating the new decision.
      final refreshed = await _fetch();
      if (!mounted) return;
      setState(() {
        _saving = false;
        _newObjective = '';
        _future = Future.value(refreshed);
        _message = 'Saved and reloaded from the server.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        final code = error is AppFailure ? error.backendCode : null;
        final status = error is AppFailure ? error.statusCode : null;
        _message = status == 401
            ? 'Your session is unavailable. Sign in again and reload the question.'
            : status == 403
            ? 'This account is not permitted to perform that review. No decision was recorded.'
            : status == 409
            ? 'The question or its source changed. Reload before trying again.'
            : code != null && RegExp(r'^[A-Z0-9_]{1,80}$').hasMatch(code)
            ? 'The requested operation is on hold ($code). The confirmed objective is retained.'
            : 'Could not verify the save. Nothing is marked approved; check the current source and try again.';
      });
    }
  }

  Future<void> _reviewCandidate(String id, ResearchReviewAction action) async {
    await AppLocator.m2.recordOwnerReview(
      id,
      action,
      _reviewRationales[id] ?? '',
    );
    final readback = await AppLocator.m2.readCandidate(id);
    if (readback.version != id ||
        readback.decision.wireCode != action.wireCode) {
      throw StateError('Review decision readback mismatch.');
    }
  }

  Future<void> _reviseCandidate(Map<String, dynamic> candidate) async {
    if (_saving ||
        candidate['context_id'] is! String ||
        candidate['source_revision'] is! int) {
      return;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final outcome = await AppLocator.m2.reviseCandidate(
        version: _s(candidate['candidate_id']),
        expectedRevision: candidate['source_revision'] as int,
        contextId: candidate['context_id'] as String,
      );
      final refreshed = await _fetch();
      if (!mounted) return;
      final verified =
          outcome.candidate != null &&
          _rows(refreshed['candidates']).any(
            (row) =>
                row['candidate_id'] == outcome.candidate!.version &&
                row['supersedes'] == candidate['candidate_id'],
          );
      setState(() {
        _saving = false;
        _future = Future.value(refreshed);
        _message = verified
            ? 'Revised question saved and reloaded.'
            : 'A revised question could not be verified. Check the current source before retrying.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _message = 'The revision request could not be verified.';
      });
    }
  }

  String _s(Object? value) => value is String ? value : '';
  String _v(Object? value) => value?.toString() ?? '';
  List<Map<String, dynamic>> _rows(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final element in raw)
        if (element is Map) Map<String, dynamic>.from(element),
    ];
  }

  Component _notice(String title, String message, {String tone = 'warn'}) =>
      section(classes: 'p1-card', [
        p(classes: 'p1-notice p1-notice--$tone', [
          strong(classes: 'p1-notice__title', [Component.text(title)]),
          Component.text(message),
        ]),
        div(classes: 'p1-toolbar', [
          button(
            attributes: const {'type': 'button'},
            classes: 'p1-btn p1-btn--small',
            onClick: () => setState(() {
              _message = null;
              _future = _fetch();
            }),
            [Component.text('Retry verified read')],
          ),
        ]),
      ]);

  /// Prototype heading: glyph tile, title and one explanatory sentence.
  Component _head(String title, String help) => div(classes: 'p1-head', [
    div(classes: 'p1-head__glyph', [Component.text('◎')]),
    div([
      h2(classes: 'p1-head__title', [Component.text(title)]),
      p(classes: 'p1-head__desc', [Component.text(help)]),
    ]),
  ]);

  /// Status badge. Presentation only — the label text always comes from a
  /// server-reported value, never from a client-side guess.
  Component _chip(String text, {String tone = 'neutral'}) => span(
    classes: tone == 'neutral' ? 'p1-chip' : 'p1-chip p1-chip--$tone',
    [Component.text(text)],
  );

  /// The blocked state, stated in one line.
  ///
  /// It used to be a full card stacked above the candidate list, which both
  /// pushed the page's content down and made a page-level fact look like a
  /// section of that list. The statement itself is kept: it is the server's
  /// readiness verdict, and a page that dropped it would be implying Stage 4
  /// can generate and review when the server says otherwise.
  Component _readinessLine() => div(classes: 'p1-s4status', [
    span(classes: 'p1-s4status__dot', []),
    strong(classes: 'p1-s4status__t', [
      Component.text('Stage 4 is not ready yet'),
    ]),
    _chip('Blocked', tone: 'amber'),
    span(classes: 'p1-s4status__d', [
      Component.text(
        'Server-authoritative readiness — stage completion is not yet '
        'available. You can inspect verified candidates; generation and review '
        'remain subject to server checks.',
      ),
    ]),
  ]);

  Component _row(String label, String value, {bool muted = false}) =>
      div(classes: 'p1-row', [
        span([Component.text(label)]),
        b(
          classes: muted ? 'p1-row__value p1-row__value--muted' : null,
          [Component.text(value)],
        ),
      ]);

  /// Human-readable labels for the M2V1 research-intention vocabulary.
  ///
  /// The stored answer is never changed; this only decides how a code is
  /// printed. Unknown codes fall back to a de-underscored title case so no raw
  /// enum is ever shown as-is.
  static const Map<String, String> _intentionLabels = {
    'EXPERIENCE_PREFERENCE': 'Customer experience preference',
    'LOCATION_ACCESS': 'Location and access',
    'PRODUCT_RANGE': 'Product range',
    'PRICE_POINT': 'Price point',
    'SERVICE_FORMAT': 'Service format',
    'DEMAND_LEVEL': 'Demand level',
    'CUSTOMER_SEGMENT': 'Customer segment',
    'OPERATING_HOURS': 'Operating hours',
    'NONE': 'None selected',
    'UNSURE': 'Not decided yet',
    'UNDECIDED': 'Not decided yet',
  };

  String _human(String code) {
    final key = code.trim();
    if (key.isEmpty) return 'Not provided';
    final mapped = _intentionLabels[key.toUpperCase()];
    if (mapped != null) return mapped;
    final words = key.toLowerCase().replaceAll(RegExp(r'[_-]+'), ' ').trim();
    if (words.isEmpty) return 'Not provided';
    return words[0].toUpperCase() + words.substring(1);
  }

  String _statusTone(String status) {
    switch (status.toUpperCase()) {
      case 'APPROVED':
      case 'CONFIRMED_BY_OWNER':
      case 'APPROVE_FOR_REVIEW':
        return 'green';
      case 'REJECTED':
      case 'REJECT':
        return 'red';
      case 'AUTHORITY_UNVERIFIED':
      case 'PENDING':
      case 'NOT_IMPLEMENTED':
        return 'amber';
      default:
        return 'gray';
    }
  }

  String _statusLabel(String status) {
    switch (status.toUpperCase()) {
      case 'AUTHORITY_UNVERIFIED':
        return 'Authority unverified';
      case 'CONFIRMED_BY_OWNER':
        return 'Confirmed by owner';
      case 'APPROVED':
        return 'Approved';
      case 'REJECTED':
        return 'Rejected';
      case 'PENDING':
        return 'Pending review';
      case 'APPROVE_FOR_REVIEW':
        return 'Approved for review';
      case 'REQUEST_REVISION':
        return 'Revision requested';
      case 'NOT_IMPLEMENTED':
        return 'Not implemented';
      case 'NO_CURRENT_RESULT':
        return 'No current result';
      case 'NOT_EVALUATED':
        return 'Not evaluated';
      case 'EVALUATED_CANDIDATE':
        return 'Evaluated (candidate)';
      case 'CURRENT':
        return 'Current';
      case 'HELD':
        return 'Held';
      case 'UNAVAILABLE':
        return 'Unavailable';
      default:
        return status.isEmpty ? 'Unknown' : _human(status);
    }
  }

  /// The milestone names to draw, taken from the server contract.
  ///
  /// The server is authoritative about how many milestones exist and what they
  /// are called: four today, because `DISPATCHED` has no durable evidence. A
  /// client-side list would drift the moment the server changed its mind, and
  /// the previous hardcoded five is exactly how the rail came to imply a
  /// dispatch nobody recorded. The fallback below is the same four, used only
  /// before the first reading arrives.
  static const _defaultMilestones = <String>[
    'RESERVED',
    'RETURNED',
    'VALIDATED',
    'PERSISTED',
  ];

  List<String> _milestoneNames(AiExecutionReading? reading) =>
      (reading != null && reading.milestones.isNotEmpty)
      ? reading.milestones
      : _defaultMilestones;

  List<String> _unprovableMilestones(AiExecutionReading? reading) =>
      reading?.unprovableMilestones ?? const <String>['DISPATCHED'];

  /// The execution rail for **this** stage.
  ///
  /// Stage 3 reads BDJ and Stage 4 reads Direct-QG, and neither mounts the
  /// other's card. One purpose per stage is the only reading that answers the
  /// question the reader is asking: "is the work this page depends on running?"
  /// A card for the *other* stage's generator answers a question that belongs on
  /// a different page, and putting both on both stages made two different
  /// execution states look like one panel that disagreed with itself.
  ///
  /// Two disclosures from the legacy card are kept, because they are
  /// governance statements rather than decoration:
  ///   * the confirmed worksheet state, whose point is that a worksheet is
  ///     *not* an execution receipt (DD-124);
  ///   * the source-evaluation result, which is a different store from the
  ///     proposal table and must not be inferred from it.
  Component _executionRail(
    AiExecutionStatus status, {
    CurrentBdjResult? current,
    AiExecutionReading? execution,
    Map<String, dynamic>? stageData,
  }) => section(
    classes: 'p1-rail',
    _executionRailCards(
      status,
      current: current,
      execution: execution,
      stageData: stageData,
    ),
  );

  /// The rail's cards, without the column wrapper.
  ///
  /// Stage 3 hands these to the proposal panel, which owns the page's single
  /// right-hand rail; Stage 4 renders them in its own rail. Splitting the cards
  /// from the wrapper is what keeps Stage 3 at two columns instead of three.
  List<Component> _executionRailCards(
    AiExecutionStatus status, {
    CurrentBdjResult? current,
    AiExecutionReading? execution,
    Map<String, dynamic>? stageData,
  }) {
    final worksheet = switch (status.worksheet) {
      ConfirmedWorksheetStatus.notEvaluated =>
        'No candidate worksheet is recorded in this confirmed review.',
      ConfirmedWorksheetStatus.historicalCandidate =>
        'Historical candidate ruleset ${status.ruleset}: '
            '${status.historicalFindingCount} finding(s). Not a cloud execution '
            'receipt.',
      ConfirmedWorksheetStatus.unavailable => 'Confirmed review unavailable.',
    };
    final isBusinessReview = component.stageNumber == 3;
    final purposeKey = isBusinessReview ? 'BDJ' : 'QG';
    final purpose = execution?.forPurpose(purposeKey);
    return [
      // Stage 4's rail is the whole right-hand column: summary, execution,
      // readiness. Stage 3's rail is execution plus the confirmed-source
      // context, because the proposal panel already summarises the scope.
      //
      // Putting the Stage 4 cards here rather than in an `aside` inside the
      // main column is what keeps Stage 4 at two columns. The page used to
      // render main + inner aside + this rail, which is three.
      if (!isBusinessReview && stageData != null) _questionnaireSummary(stageData),
      AiExecutionProgressPanel(
        title: isBusinessReview
            ? 'Business review status'
            : 'Question generation status',
        purposeKey: isBusinessReview ? 'bdj' : 'qg',
        execution: purpose,
        readState: _executionRead,
        milestones: _milestoneNames(execution),
        unprovable: _unprovableMilestones(execution),
        detailFacts: _executionDetails(
          status: status,
          current: current,
          purpose: purpose,
          reading: execution,
          sourceStage: isBusinessReview,
        ),
        detailScope: isBusinessReview
            ? 'These are recorded facts: the confirmed source this stage reads, '
                  'and the objective-generation attempt when one exists.'
            : 'These are recorded facts about one attempt.',
        onRefresh: _refreshExecution,
        refreshBusy: _executionPollInFlight,
      ),
      if (!isBusinessReview && stageData != null) _questionnaireReadiness(stageData),
      div(classes: 'p1-rail__context', [
        // The source-evaluation status and the confirmed revision used to be
        // printed here *and* in the "Recorded BDJ status" card in the main
        // column, which is the duplication this pass removed. Both now live in
        // "More details" above, labelled as source facts so they cannot be read
        // as the objective-generation attempt.
        //
        // The worksheet sentence stays visible rather than moving into that
        // disclosure: it is a governance statement, not a detail. A worksheet
        // is not an execution receipt (DD-124), and that must not be one click
        // away.
        p(classes: 'p1-muted', [Component.text(worksheet)]),
      ]),
    ];
  }

  /// What this questionnaire is made of, in the server's own counts.
  ///
  /// Every number is read from the payload. Nothing is derived by counting the
  /// cards that happen to be on screen: a filtered or failed read would then
  /// silently restate itself as a smaller questionnaire.
  ///
  /// The one exception is the fixed-objective count, which is read from
  /// [fixedResearchObjectives] rather than from the payload. The governed
  /// registry is the authority for that set, and the client mirror is the only
  /// copy of it this page can reach, so counting the registry keeps this row and
  /// the grid below it from ever disagreeing. It was briefly a literal, which is
  /// how a wrong number got shipped: a literal cannot notice that the registry
  /// and the row have drifted apart.
  Component _questionnaireSummary(Map<String, dynamic> data) {
    final objectives = _rows(data['objectives']);
    final approvedObjectives = [
      for (final objective in objectives)
        if (objective['approval_status'] == 'APPROVED' ||
            objective['approval_status'] == 'CONFIRMED_BY_OWNER')
          objective,
    ];
    final coreCount = data['preview_questionnaire'] is PreviewQuestionnaire
        ? '${(data['preview_questionnaire'] as PreviewQuestionnaire).questionCount}'
        // Not "0". A preview that could not be read is not a shorter
        // questionnaire, and reporting it as one would understate the fixed
        // core the owner is being asked to accept.
        : '—';
    final readUnavailable = data['candidate_read_unavailable'] == true;
    final candidates = _rows(data['candidates']);

    // The rail counts what the page shows. A generated question lives in
    // `m2_qg_candidates`, and the legacy per-objective chain is a second record
    // set that also holds generated questions; counting only one of them made
    // the rail disagree with the cards beneath it — the rail said 2 while the
    // objective card said 4. Both sets are counted, and a failed read on either
    // marks all four rows `Not verified`.
    final qgUnavailable = _qgError != null;
    String count(int value) =>
        readUnavailable || qgUnavailable ? 'Not verified' : '$value';
    final awaiting =
        candidates.where((candidate) => _isPendingDecision(candidate)).length +
        _qgSource.where(_isPendingQg).length;
    final approved =
        candidates
            .where(
              (candidate) =>
                  _s(candidate['owner_review_decision']).toUpperCase() ==
                  'APPROVE_FOR_REVIEW',
            )
            .length +
        _qgSource
            .where(
              (candidate) =>
                  (candidate.review.decision ?? '').toUpperCase() ==
                  'APPROVE_FOR_REVIEW',
            )
            .length;
    final rejected =
        candidates
            .where(
              (candidate) =>
                  _s(candidate['owner_review_decision']).toUpperCase() ==
                  'REJECT',
            )
            .length +
        _qgSource
            .where(
              (candidate) =>
                  (candidate.review.decision ?? '').toUpperCase() == 'REJECT',
            )
            .length;
    return section(classes: 'p1-railsum', [
      p(classes: 'p1-railsum__label', [
        Component.text('Current research scope'),
      ]),
      h4(classes: 'p1-railsum__title', [
        Component.text('Questionnaire summary'),
      ]),
      // The ids are named as well as counted. "6" alone is a number the reader
      // has to take on trust, and a bare digit is exactly what a wrong count
      // looks like; `6 (O1–O6)` states which six, so a drift in the registry is
      // visible in the row itself rather than only in the grid below.
      _row('Fixed research objectives', _fixedObjectiveRange),
      _row('Fixed catalogue items', coreCount, muted: coreCount == '—'),
      _row('Approved additional objectives', '${approvedObjectives.length}'),
      // "Not verified" is a fact, and it is not the same fact as zero. These
      // four rows all come from the candidate history, so a failed read marks
      // all four rather than letting three of them read as 0.
      _row(
        'Generated additional questions',
        count(candidates.length + _qgSource.length),
        muted: readUnavailable || qgUnavailable,
      ),
      _row(
        'Awaiting owner review',
        count(awaiting),
        muted: readUnavailable || qgUnavailable,
      ),
      _row(
        'Approved additional questions',
        count(approved),
        muted: readUnavailable || qgUnavailable,
      ),
      _row(
        'Rejected additional questions',
        count(rejected),
        muted: readUnavailable || qgUnavailable,
      ),
      p(classes: 'p1-railsum__note', [
        Component.text(
          'The 13 fixed catalogue items are not counted as questions you '
          'approved: they are governed for every assessment.',
        ),
      ]),
    ]);
  }

  /// True when no decision has been recorded for this candidate yet.
  ///
  /// `REQUEST_REVISION` counts as awaiting: the owner asked for a change, which
  /// is not a decision on the question as written.
  bool _isPendingDecision(Map<String, dynamic> candidate) {
    final decision = _s(candidate['owner_review_decision']).toUpperCase();
    return decision.isEmpty ||
        decision == 'PENDING' ||
        decision == 'REQUEST_REVISION';
  }

  /// The same test for a generated question.
  ///
  /// No decision and an explicit `PENDING` are one state for the reader: the
  /// question is waiting for them. `REQUEST_REVISION` belongs there too — the
  /// question was not accepted, and it is still theirs to decide on.
  bool _isPendingQg(QgCandidate candidate) {
    final decision = (candidate.review.decision ?? '').toUpperCase();
    return decision.isEmpty ||
        decision == 'PENDING' ||
        decision == 'REQUEST_REVISION';
  }

  /// `A01`, `A02`, … for an approved additional objective.
  ///
  /// Positional, so it is stable only while the approved list is stable — which
  /// is why the objective's own id is printed beside it. The six fixed
  /// objectives are `O1`–`O6` and never appear here: this list holds only the
  /// additional objectives approved at Stage 3.
  String _objectiveOrdinal(
    List<Map<String, dynamic>> objectives,
    Map<String, dynamic> objective,
  ) {
    final index = objectives.indexWhere(
      (other) => other['proposal_id'] == objective['proposal_id'],
    );
    return 'A${'${(index < 0 ? 0 : index) + 1}'.padLeft(2, '0')}';
  }

  /// Questions generated from this exact objective — from both record sets.
  ///
  /// `m2_qg_candidates` holds the Direct-QG question and the legacy per-objective
  /// version chain holds its earlier revisions; both are questions generated for
  /// this objective, so the count the card prints is their sum. Counting only one
  /// of them is what made the number disagree with the list underneath it.
  int _generatedCount(
    List<Map<String, dynamic>> candidates,
    Map<String, dynamic> objective,
  ) =>
      candidates
          .where(
            (candidate) =>
                candidate['source_objective_id'] == objective['objective_id'] &&
                candidate['source_objective_version'] ==
                    objective['objective_version'],
          )
          .length +
      _qgFor(objective).length;

  /// The generated questions this page renders.
  ///
  /// The demo's own two rows are substituted only under `?demo=stage4`, so a
  /// design review can see both control formats without a database row behind
  /// them.
  List<QgCandidate> get _qgSource =>
      _demoStage4 ? _demoQgCandidates : _qgCandidates;

  /// The Direct-QG candidates generated for one approved objective.
  ///
  /// Matched on the objective identity and, when the candidate carries it, on
  /// the proposal identity too: the two are the same objective under contract
  /// 2.1, and a projection that reports only one of them must still group the
  /// question under its own objective rather than orphan it.
  List<QgCandidate> _qgFor(Map<String, dynamic> objective) {
    final objectiveId = objective['objective_id'];
    final proposalId = objective['proposal_id'];
    return [
      for (final candidate in _qgSource)
        if ((objectiveId is String &&
                objectiveId.isNotEmpty &&
                candidate.objectiveId == objectiveId) ||
            (proposalId is String &&
                proposalId.isNotEmpty &&
                candidate.proposalId == proposalId))
          candidate,
    ];
  }

  /// The decision filter, applied to generated questions.
  ///
  /// The same four values as the legacy list, read from the candidate's own
  /// recorded decision. A filter is a view, never a write: it cannot change
  /// which questions exist or what the server holds about them.
  bool _matchesQgFilter(QgCandidate candidate) {
    final decision = (candidate.review.decision ?? '').toUpperCase();
    switch (_candidateFilter) {
      case 'approved':
        return decision == 'APPROVE_FOR_REVIEW';
      case 'rejected':
        return decision == 'REJECT';
      case 'pending':
        return decision.isEmpty ||
            decision == 'PENDING' ||
            decision == 'REQUEST_REVISION';
      default:
        return true;
    }
  }

  /// `6 (O1–O6)` — the size of the governed registry, with the ids it spans.
  ///
  /// Read from [fixedResearchObjectives] rather than from a literal or from the
  /// cards on screen, so this row cannot disagree with the grid below it.
  String get _fixedObjectiveRange {
    final objectives = fixedResearchObjectives;
    if (objectives.isEmpty) return '0';
    final first = objectives.first.id;
    final last = objectives.last.id;
    return '${objectives.length} ($first–$last)';
  }

  /// The checks that stand between this questionnaire and a real respondent,
  /// plus the one control that leaves the stage.
  ///
  /// The footer used to carry its own Continue button as well. Two controls
  /// that do the same governed thing are two chances to mislead, so the footer
  /// keeps only "Back to Stage 3" and this is the single authority.
  Component _questionnaireReadiness(Map<String, dynamic> data) {
    final ready = data['readiness'] is Map
        ? data['readiness'] as Map
        : const <String, dynamic>{};
    final stageReady = ready['stage4_ready'] == true;
    final candidates = _rows(data['candidates']);
    // Only conditions this payload can actually answer are listed. The spec
    // names six; two of them — generation outcomes resolved, and per-candidate
    // validation — are read by the review surface, not by this payload, and a
    // check row for them would be a box that never moves for any reason the
    // reader could see. They are named in the note below instead of guessed at.
    final previewAvailable = data['preview_questionnaire'] is PreviewQuestionnaire;
    final reviewsComplete =
        candidates.isNotEmpty &&
        !candidates.any((candidate) => _isPendingDecision(candidate));
    return section(classes: 'p1-railready', [
      h4(classes: 'p1-railsum__title', [
        Component.text('Questionnaire readiness'),
      ]),
      _checkRow('Fixed questionnaire available', previewAvailable),
      _checkRow('Required entrepreneur reviews completed', reviewsComplete),
      _checkRow(
        'Scientific admission requirements satisfied',
        _measurementApproved(data),
      ),
      _checkRow('Publication prerequisites satisfied', stageReady),
      div(classes: 'p1-railready__action', [
        if (stageReady && candidates.isNotEmpty)
          button(
            attributes: const {'type': 'button'},
            classes: 'p1-btn p1-btn--primary p1-btn--block',
            onClick: component.onOpenStage == null
                ? null
                : () => component.onOpenStage!('assessment_report'),
            [Component.text('Continue to Stage 5')],
          )
        else
          div(classes: 'p1-railready__blocked', [
            Component.text('Continue to Stage 5 · blocked'),
          ]),
        if (!stageReady)
          p(classes: 'p1-muted', [
            Component.text(
              'Stage 5 requires saved decisions and server readiness.',
            ),
          ]),
        p(classes: 'p1-railsum__note', [
          Component.text(
            'Generation-outcome and per-candidate validation states are read by '
            'the review surface above, not by this summary.',
          ),
        ]),
      ]),
    ]);
  }

  bool _measurementApproved(Map<String, dynamic> data) {
    final ready = data['readiness'] is Map
        ? data['readiness'] as Map
        : const <String, dynamic>{};
    return ready['measurement_approved'] == true;
  }

  Component _checkRow(String label, bool done) => div(
    classes: 'p1-checkrow',
    [
      span(
        classes: done ? 'p1-checkrow__dot p1-checkrow__dot--done'
            : 'p1-checkrow__dot',
        const [],
      ),
      span(classes: 'p1-checkrow__label', [Component.text(label)]),
    ],
  );

  /// Verified technical facts for the collapsed "More details" block.
  ///
  /// Only values the server actually returned are listed. An absent fact is
  /// omitted rather than shown as a dash, so the block never implies that a
  /// missing field was read and found empty.
  ///
  /// Two classes of fact are listed, and the labels keep them apart:
  ///
  ///   * **source facts** ([sourceStage] only) — what the confirmed source this
  ///     stage reads actually records. They are true whether or not anything
  ///     has run, and they come from `project1_ai.bdj_results` (via the
  ///     `sitewise-bdj-current/1` read) plus the confirmed review;
  ///   * **attempt facts** — what the execution ledger recorded for the
  ///     *objective-generation* attempt (`project1_ai.runs` / `attempts` /
  ///     `attempt_receipts`, counted against
  ///     `public.m2_bdj_objective_proposals`).
  ///
  /// They are different pipelines over different stores (DD-124). A persisted
  /// proposal count beside a `NO_CURRENT_RESULT` is not a contradiction — but
  /// only if the page says which store answered which line.
  List<ExecutionDetail> _executionDetails({
    required AiExecutionStatus status,
    required CurrentBdjResult? current,
    required AiExecutionPurpose? purpose,
    required AiExecutionReading? reading,
    required bool sourceStage,
  }) {
    final facts = <ExecutionDetail>[
      // Stage 4 does not read a BDJ source evaluation, so this row would
      // describe another stage's store there.
      if (sourceStage)
        (
          label: 'BDJ source evaluation',
          value: current == null
              ? 'Not recorded for this confirmation'
              : '${_statusLabel(current.status)} (${current.status})',
        ),
      // `status.ruleset` is null unless the confirmed review carries a
      // candidate worksheet. The review's own `rule_version` is the sentinel
      // `NOT_EVALUATED` for a declaration-only confirmation, and printing that
      // as the name of a ruleset is what put the literal on the page.
      if (sourceStage && status.ruleset != null)
        (label: 'Source ruleset', value: status.ruleset!),
      if (sourceStage && status.m2Revision != null)
        (label: 'Confirmed revision', value: '${status.m2Revision}'),
    ];
    if (purpose == null) return facts;
    facts.addAll(<ExecutionDetail>[
      (
        label: 'Execution state',
        value: purpose.reason.isEmpty
            ? purpose.state
            : '${purpose.state} · ${purpose.reason}',
      ),
      if (purpose.assessmentRevision != null)
        (
          label: 'Recorded at revision',
          value: '${purpose.assessmentRevision}',
        ),
      if (purpose.attemptNo != null)
        (
          label: 'Attempt',
          value: purpose.attemptsReserved > 1
              ? '${purpose.attemptNo} · ${purpose.attemptsReserved} recorded'
              : '${purpose.attemptNo}',
        ),
      if (purpose.reservedAt != null)
        (label: 'Reserved', value: purpose.reservedAt!),
      if (purpose.receiptAt != null)
        (label: 'Receipt', value: purpose.receiptAt!),
      if (purpose.receiptOutcome != null)
        (label: 'Provider outcome', value: purpose.receiptOutcome!),
      if (reading?.providerTimeoutSeconds != null)
        (
          label: 'Provider budget',
          value: reading!.graceSeconds == null
              ? '${reading.providerTimeoutSeconds}s'
              : '${reading.providerTimeoutSeconds}s · grace ${reading.graceSeconds}s',
        ),
      (
        label: 'Validation',
        value: purpose.pendingValidation > 0
            ? '${purpose.pendingValidation} awaiting validation'
            : purpose.state == 'PERSISTED'
            ? 'recorded against the stored result'
            : 'not recorded',
      ),
      (
        label: 'Persistence',
        value: purpose.attributable
            ? '${purpose.persisted} record(s) bound to this attempt'
            : purpose.assessmentWidePersisted > 0
            ? '${purpose.assessmentWidePersisted} stored for the assessment; '
                  'none attributable to this attempt'
            : 'no record attributable to this attempt',
      ),
      if (purpose.domainStore.isNotEmpty)
        (label: 'Store', value: purpose.domainStore),
      if (reading != null && reading.contract.isNotEmpty)
        (label: 'Status contract', value: reading.contract),
    ]);
    return facts;
  }

  Component _step3(Map<String, dynamic> data) {
    final findings = _rows(data['findings']);
    final objectives = _rows(data['objectives']);
    final intention = _rows(data['research_intention']);
    final currentBdj = data['current_bdj'] is CurrentBdjResult
        ? data['current_bdj'] as CurrentBdjResult
        : null;
    // This opens a read-only review view; the workspace callback still checks
    // the server's enterable flag. It does not complete or authorize a stage.
    final canContinue = data['source_current'] == true;

    return div(classes: 'p1-research-stage', [
      // The stage title stays here; the panel below carries its own section
      // title ("Research objectives") and eyebrow, the same two levels the
      // reference design uses for a page heading and the section under it.
      _head(
        'Business review and research goals',
        'BDJ identifies possible uncertainties and proposes research objectives. '
            'You approve or clarify them; opening this stage does not run BDJ.',
      ),
      // The panel owns the objectives themselves: it renders the section
      // heading, the scope rail and the cards as one block.
      BdjObjectiveProposalPanel(
        marketplaceAssessmentId: component.marketplaceAssessmentId,
        // An admitted objective is the evidence stage 3 waits for.
        onDecisionRecorded: component.onStageProgressChanged,
        // Stage 3's only execution card, handed to the rail the panel owns.
        // Mounting the page rail here as well produced three columns and two
        // cards both claiming to be the business review status (D-H01 / D-M07).
        railLead: _executionRailCards(
          data['ai_status'] as AiExecutionStatus,
          current: currentBdj,
          execution: _execution,
        ),
        // Page-owned cards. Rendered inside the panel's reading column so the
        // scope rail stays beside them; appending them after the panel instead
        // would end the rail and start a second full-width block underneath it.
        trailingSections: [

          if (intention.isNotEmpty)
            section(classes: 'p1-card', [
              div(classes: 'p1-card__head', [
                h3(classes: 'p1-card__title', [
                  Component.text('Your research intention'),
                ]),
                _chip('From confirmed M2'),
              ]),
              div(classes: 'p1-chips', [
                for (final answer in intention)
                  _chip(
                    // The item key is a stable identifier and stays verbatim;
                    // only the recorded answer value is humanised.
                    '${_s(answer['item_key'])}: '
                    '${_human(_s(answer['value']))}',
                    tone: 'gray',
                  ),
              ]),
              p(classes: 'p1-muted', [
                Component.text(
                  'Write your own research objective and explicitly confirm it. '
                  'The server checks that it is linked to your current M2 intention.',
                ),
              ]),
              label(classes: 'p1-fieldlabel', [
                Component.text('Your research objective'),
              ]),
              textarea(
                rows: 3,
                classes: 'm1-textarea',
                attributes: const {
                  'maxlength': '1000',
                  'aria-label': 'Your research objective',
                },
                onInput: (value) => setState(() => _newObjective = value),
                [Component.text(_newObjective)],
              ),
              div(classes: 'p1-toolbar', [
                button(
                  attributes: const {'type': 'button'},
                  classes: 'p1-btn p1-btn--primary',
                  onClick: _saving || _newObjective.trim().isEmpty
                      ? null
                      : () => _commit(() async {
                          final text = _newObjective;
                          final saved = await AppLocator.m2.createObjective(
                            _s(data['confirmation_id']),
                            data['m2_revision'] as int,
                            text,
                            origin: 'ENTREPRENEUR',
                          );
                          final reloaded = await AppLocator.m2
                              .readResearchWorkspace(
                                _s(data['m2_assessment_id']),
                                _s(data['confirmation_id']),
                                data['m2_revision'] as int,
                              );
                          if (!reloaded.rows.any(
                            (row) =>
                                row['id'] == saved['id'] &&
                                row['exact_text'] == text,
                          )) {
                            throw StateError(
                              'Saved objective could not be verified.',
                            );
                          }
                        }),
                  [Component.text('Confirm my research objective')],
                ),
              ]),
            ]),

          for (final objective in objectives)
            _objectiveCard(objective, findings, data),

          // The former "No proposed objective available" notice lives in the
          // governed proposal panel above. It has its own empty state, which
          // deliberately shows nothing instead of a fabricated objective.
          if (objectives.any(
            (o) => o['approval_status'] == 'AUTHORITY_UNVERIFIED',
          ))
            _notice(
              'Objective approval unavailable',
              'The current response does not establish objective version or approval '
                  'authority. Approval and clarification remain held.',
            ),

          if (_message != null)
            p(classes: 'p1-notice p1-notice--warn', [
              Component.text(_message!),
            ]),

          // A "Recorded BDJ status" card used to sit here with five rows. Four
          // of them restated facts already on this screen — the source
          // evaluation and the revision were in the rail's context block, the
          // assessment id and the revision were in the panel's "confirmed
          // business context" disclosure, and "M2 confirmation: Current" only
          // repeated a check the read path already enforces by refusing to
          // return a stale confirmation. The fifth, the ruleset, was the only
          // fact nothing else carried, and it printed the review's
          // `NOT_EVALUATED` sentinel as though it named a ruleset.
          //
          // All of it now lives in the "Business review status" panel's
          // "More details" disclosure, labelled as source facts so the BDJ
          // source evaluation cannot be read as the BDJ objective-generation
          // attempt (DD-124: different pipelines, different stores).
        ],
      ),

      // ------------------------------------------------ footer
      div(classes: 'p1-foot', [
        button(
          attributes: const {'type': 'button'},
          classes: 'p1-btn',
          onClick: component.onOpenStage == null
              ? null
              : () => component.onOpenStage!('business_requirements'),
          [Component.text('Back to Stage 2')],
        ),
        if (canContinue)
          button(
            attributes: const {'type': 'button'},
            classes: 'p1-btn p1-btn--primary',
            onClick: component.onOpenStage == null
                ? null
                : () => component.onOpenStage!('ai_explanation'),
            [Component.text('View Stage 4: Question review')],
          )
        else
          p(classes: 'p1-foot__hint', [
            Component.text(
              'Stage 4 awaits server-authorized research objectives.',
            ),
          ]),
      ]),
    ]);
  }

  Component _objectiveCard(
    Map<String, dynamic> objective,
    List<Map<String, dynamic>> findings,
    Map<String, dynamic> data,
  ) {
    final id = _s(objective['objective_id']);
    final version = objective['objective_version'];
    final status = _s(objective['approval_status']);
    final text = _s(objective['exact_text']).trim();
    final sources = objective['source_finding_ids'];
    final validSource =
        sources is List &&
        sources.isNotEmpty &&
        sources.every(
          (sourceId) => findings.any((f) => f['finding_id'] == sourceId),
        );

    // ONE state model for every objective. `AUTHORITY_UNVERIFIED` and
    // `CONFIRMED_BY_OWNER` used to be handled by two different branches, which
    // is why only one of them ever showed review controls. Both now come from
    // the same computation, so the same buttons render for both.
    final ownerConfirmed = status == 'CONFIRMED_BY_OWNER' && version == id;
    final approved = status == 'APPROVED' || ownerConfirmed;
    final versionKnown = version is int && version > 0;
    final authorityUnverified =
        !ownerConfirmed &&
        (status == 'AUTHORITY_UNVERIFIED' || !versionKnown || !validSource);
    final valid =
        ownerConfirmed ||
        (id.isNotEmpty && text.isNotEmpty && !authorityUnverified);

    return section(classes: 'p1-objective', [
      div(classes: 'p1-objective__body', [
        div(classes: 'p1-card__head', [
          h3(classes: 'p1-card__title', [Component.text('Research objective')]),
          div(classes: 'p1-objective__meta', [
            _chip(
              // An entrepreneur-confirmed objective stores its own id as the
              // version, so printing both would repeat the same UUID.
              id.isEmpty
                  ? 'Unidentified'
                  : version == id
                  ? id
                  : '$id · V${_v(version)}',
              tone: 'gray',
            ),
            _chip(_statusLabel(status), tone: _statusTone(status)),
            if (authorityUnverified)
              _chip('Source not verified', tone: 'amber'),
          ]),
        ]),
        p(classes: 'p1-objective__text', [Component.text(text)]),
        p(classes: 'p1-muted', [
          Component.text(
            ownerConfirmed
                ? 'Source: your confirmed M2 research intention.'
                : 'Linked BDJ finding(s): ${sources is List ? sources.join(', ') : 'None'}',
          ),
        ]),
        if (!valid)
          p(classes: 'p1-notice p1-notice--warn', [
            Component.text(
              'Objective version or approval authority is unverified; approval is blocked.',
            ),
          ]),
        if (ownerConfirmed)
          div(classes: 'p1-toolbar', [
            button(
              attributes: const {'type': 'button'},
              classes: 'p1-btn p1-btn--primary',
              onClick: _saving
                  ? null
                  : () => _commit(() async {
                      await AppLocator.m2.buildContext(
                        _s(data['m2_assessment_id']),
                        _s(data['confirmation_id']),
                        data['m2_revision'] as int,
                        objectiveId: id,
                      );
                    }),
              [Component.text('Build business context')],
            ),
          ]),
        // Approve / Reject used to sit here, permanently disabled with the note
        // "Decision API not connected yet". That is no longer true: the governed
        // decision route exists, is owner-scoped, and is exercised from
        // `BdjObjectiveProposalPanel`, which owns the review state, the stored
        // decision readback and the admission block. A second, dead pair here
        // would duplicate that control and misreport it as unavailable, so the
        // review actions live in exactly one place.
        if (!approved && id.isNotEmpty && text.isNotEmpty)
          p(classes: 'p1-muted', [
            Component.text(
              'Review this objective in the governed research-objectives panel '
              'below: approving or rejecting there records your decision and '
              'keeps approval separate from admission.',
            ),
          ]),
        if (approved)
          p(classes: 'p1-muted', [
            Component.text(
              'Entrepreneur-approved objective. This is a research direction, not customer demand evidence.',
            ),
          ]),
      ]),
    ]);
  }

  /// Presentation-only filter for Stage 4. It never changes which candidates
  /// exist, only which fetched rows are currently visible.
  bool _matchesFilter(Map<String, dynamic> candidate) {
    final decision = _s(candidate['owner_review_decision']).toUpperCase();
    switch (_candidateFilter) {
      case 'approved':
        return decision == 'APPROVE_FOR_REVIEW';
      case 'rejected':
        return decision == 'REJECT';
      case 'pending':
        return decision.isEmpty ||
            decision == 'PENDING' ||
            decision == 'REQUEST_REVISION';
      default:
        return true;
    }
  }

  Component _step4(Map<String, dynamic> data) {
    final objectives = _rows(data['objectives']);
    final candidates = _rows(data['candidates']);
    final ready = data['readiness'] as Map;
    final objectiveReadUnavailable = data['objective_read_unavailable'] == true;
    final approvedObjectives = [
      for (final objective in objectives)
        if (objective['approval_status'] == 'APPROVED' ||
            objective['approval_status'] == 'CONFIRMED_BY_OWNER')
          objective,
    ];
    final blocked = ready['stage4_ready'] != true;
    // Seeded only once the generated questions have been read: the seed asks
    // whether an objective already holds a question, and answering that from an
    // unread list would tick every objective that has one.
    if (_qgLoaded || data['demo'] == true) {
      _seedBatchSelection(data, approvedObjectives);
    }
    final visible = [
      for (final candidate in candidates)
        if (_matchesFilter(candidate)) candidate,
    ];

    return div(classes: 'p1-research-stage', [
      if (data['demo'] == true)
        div(classes: 'p1-notice p1-notice--warn', [
          strong(classes: 'p1-notice__title', [
            Component.text('DEMO MODE · SAMPLE DATA ONLY'),
          ]),
          Component.text(
            'These candidates are illustrative. Approve, Reject and owner '
            'option selection change this screen only — no database record '
            'is read or written. Remove ?demo=stage4 from the URL to return '
            'to the live assessment.',
          ),
        ]),
      _head(
        'Stage 4 · Questionnaire construction',
        'One page, read top to bottom. The governed core is the fixed set every '
            'assessment receives, populated from your own declarations. Below it '
            'are the questions generated for your approved research objectives. '
            'Both are on screen at once, because a reader comparing them should '
            'not have to hold one in memory.',
      ),
      // The blocked state is a page-level fact, so it sits above the question
      // sets as one line rather than as a card inside the candidate list.
      if (blocked) _readinessLine(),
      div(classes: 'p1-cols p1-cols--single', [
        div(classes: 'p1-col p1-col--main', [
          // The two sets used to be two tabs, one visible at a time. They are
          // now stacked: the tabs hid half the questionnaire behind a control
          // that looked like a mode, and the generated set is the whole point of
          // the stage. Nothing is fetched or discarded by the change — every card
          // in both sets was already mounted.
          div(
            classes: 'p1-s4stack',
            attributes: const {'id': 's4-view-panel'},
            [
              // `--fixed` welds the header to the list below it: the fixed core is the
              // header's content, so the two are one card, not a card plus a heading.
              div(classes: 'p1-s4col p1-s4col--fixed', [
                // The section owns its own heading now. A column header above it
                // would be a second title for one section, and the reference has
                // exactly one — "SECTION A · REQUIRED / Fixed core questionnaire".
                _sectionA(data),
              ]),
              div(classes: 'p1-s4col p1-s4col--gen', [
                // The reference's Section B heading, in place of the old
                // column header plus a full-width banner. The banner repeated
                // what the sub-line says and cost a whole card of height; its
                // one substantive caveat is kept as a note rather than deleted.
                div(classes: 'p1-s4sechead', [
                  div(classes: 'p1-s4sechead__text', [
                    p(classes: 'p1-s4eyebrow', [
                      Component.text('Section B · Optional'),
                    ]),
                    h3(classes: 'p1-s4title', [
                      Component.text(
                        'Generated questions by research objective',
                      ),
                    ]),
                    p(classes: 'p1-s4sub', [
                      Component.text(
                        'Review additional questions generated from the research '
                        'objectives you approved in Stage 3. Select your intended '
                        'response and approve or reject each generated question.',
                      ),
                    ]),
                    p(classes: 'p1-s4note', [
                      Component.text(
                        'Owner predictions are expectations, not customer '
                        'observations or established demand.',
                      ),
                    ]),
                  ]),
                ]),
                // One list, grouped by objective. The objective's wording, its
                // generated-question count, its selection tick and the questions
                // themselves are all rendered from this one block, so an
                // objective cannot appear twice on the page and a question
                // cannot be listed under an objective other than the one it was
                // generated for.
                //
                // This replaces a second, independently-mounted review surface
                // that read the same proposals and printed each objective's
                // wording again above a flat list of its own questions. Two
                // components cannot agree on which card owns an objective, so
                // the objective was printed up to three times and the reader
                // could not tell which list was the questionnaire. The
                // governed reads that surface performed — eligibility,
                // permission, decision, intention — are made here, per
                // objective, and rendered in the same card as the questions
                // they apply to.
                div(classes: 'p1-s4secb', [
                  section(classes: 'p1-card p1-s4bcard', [
                    // One statement for the whole list, not one per objective:
                    // a failed read is a fact about the page, and repeating it
                    // under six objectives would read as six separate failures.
                    if (_qgError != null)
                      p(classes: 'p1-notice p1-notice--warn', [
                        strong(classes: 'p1-notice__title', [
                          Component.text('Generated questions could not be read'),
                        ]),
                        Component.text(
                          'The generated questions for this assessment could not '
                          'be verified ($_qgError). This is not a statement that '
                          'none exist — refresh to retry.',
                        ),
                      ]),
                    div(classes: 'p1-filterbar p1-filterbar--flat', [
                      div(classes: 'p1-filterbar__left', [
                        p(classes: 'p1-muted', [
                          Component.text(
                            'Approve and Reject apply to these additional '
                            'questions only. They never approve a Section A core '
                            'question, and approving a question does not '
                            'authorise fielding it.',
                          ),
                        ]),
                      ]),
                      div(classes: 'p1-filterbar__right', [
                        label(classes: 'p1-filterbar__label', [
                          Component.text('Filter'),
                        ]),
                        select(
                          [
                            option([
                              Component.text('All questions'),
                            ], value: 'all'),
                            option([
                              Component.text('Pending'),
                            ], value: 'pending'),
                            option([
                              Component.text('Approved for review'),
                            ], value: 'approved'),
                            option([
                              Component.text('Rejected'),
                            ], value: 'rejected'),
                          ],
                          value: _candidateFilter,
                          classes: 'p1-select',
                          attributes: const {
                            'aria-label': 'Filter question candidates',
                          },
                          onChange: (values) => setState(
                            () => _candidateFilter = values.isEmpty
                                ? 'all'
                                : values.first,
                          ),
                        ),
                      ]),
                    ]),
                    if (approvedObjectives.isNotEmpty &&
                        data['context_id'] is String)
                      div(classes: 'p1-batchbar', [
                        div(classes: 'p1-batchbar__text', [
                          strong([
                            Component.text(
                              '${_batchSelection.where((id) => approvedObjectives.any((o) => o['proposal_id'] == id)).length} '
                              'of ${approvedObjectives.length} approved '
                              'objectives selected',
                            ),
                          ]),
                          p(classes: 'p1-muted', [
                            Component.text(
                              'One action generates for every selected '
                              'objective. Each keeps its own authority, '
                              'eligibility check and single-use attempt, so an '
                              'objective that cannot generate is refused on its '
                              'own line instead of stopping the others.',
                            ),
                          ]),
                        ]),
                        button(
                          attributes: const {'type': 'button'},
                          classes: 'p1-btn p1-btn--primary',
                          onClick:
                              _batchRunning ||
                                  !approvedObjectives.any(
                                    (o) => _batchSelection.contains(
                                      o['proposal_id'],
                                    ),
                                  )
                              ? null
                              : () => _generateForObjectives(
                                  data,
                                  approvedObjectives,
                                ),
                          [
                            Component.text(
                              _batchRunning
                                  ? 'Generating… ${_generatingSeconds}s'
                                  : 'Generate all suggested questions',
                            ),
                          ],
                        ),
                      ]),
                    if (_batchResult != null)
                      div(classes: 'p1-batchresult', [
                        for (final row in _batchResult!.results)
                          div(
                            classes:
                                'p1-batchresult__row p1-batchresult__row--${row.completed ? 'ok' : 'refused'}',
                            [
                              span(classes: 'p1-batchresult__id', [
                                Component.text(
                                  _objectiveLabel(approvedObjectives, row.proposalId),
                                ),
                              ]),
                              span([
                                Component.text(
                                  row.completed
                                      ? (row.candidateId == null
                                            ? 'No candidate produced (${row.outcome ?? 'UNKNOWN'})'
                                            : 'Candidate saved')
                                      : '${row.code ?? 'Refused'}${row.attemptSpent ? ' · attempt spent' : ''}',
                                ),
                              ]),
                            ],
                          ),
                      ]),
                    if (approvedObjectives.isEmpty)
                      p(classes: 'p1-notice p1-notice--soft', [
                        strong(classes: 'p1-notice__title', [
                          Component.text(
                            objectiveReadUnavailable
                                ? 'Approved objective could not be read'
                                : 'No approved objective',
                          ),
                        ]),
                        Component.text(
                          objectiveReadUnavailable
                              // DD-047: a failed read must never be reported as an
                              // absence of approval. The owner is not asked to repeat
                              // an action that may already be complete.
                              ? 'The approved research objective could not be verified '
                                    'from this screen. Refresh to retry. If an objective '
                                    'was already approved at Stage 3, it is still '
                                    'recorded and does not need approving again.'
                              : 'Return to Stage 3 and approve a current, linked research objective.',
                        ),
                      ]),
                    for (final objective in approvedObjectives) ...[
                      div(classes: 'p1-group', [
                        div(classes: 'p1-group__head', [
                          // A display ordinal, derived from position in the
                          // approved list — not an objective id, and not a
                          // mapping to O1–O6. The id itself is printed below,
                          // so the badge can never be mistaken for it.
                          span(classes: 'p1-group__badge', [
                            Component.text(
                              _objectiveOrdinal(approvedObjectives, objective),
                            ),
                          ]),
                          div(classes: 'p1-group__title', [
                            Component.text(_s(objective['exact_text'])),
                          ]),
                          span(classes: 'p1-group__count', [
                            Component.text(
                              '${_generatedCount(candidates, objective)} '
                              'question${_generatedCount(candidates, objective) == 1 ? '' : 's'}',
                            ),
                          ]),
                          label(classes: 'p1-group__pick', [
                            input(
                              type: InputType.checkbox,
                              checked: objective['proposal_id'] is String &&
                                  _batchSelection.contains(
                                    objective['proposal_id'],
                                  ),
                              attributes: const {
                                'aria-label':
                                    'Include this objective in generation',
                              },
                              events: events(
                                onClick: () => setState(() {
                                  final id = objective['proposal_id'];
                                  if (id is! String) return;
                                  if (!_batchSelection.remove(id)) {
                                    _batchSelection.add(id);
                                  }
                                }),
                              ),
                            ),
                          ]),
                        ]),
                        p(classes: 'p1-group__src', [
                          Component.text(
                            'Approved research objective · '
                            '${_s(objective['objective_id'])}',
                          ),
                        ]),
                        if (data['context_objective_id'] ==
                                objective['objective_id'] &&
                            data['context_id'] is String)
                          button(
                            attributes: const {'type': 'button'},
                            classes: 'p1-btn p1-btn--primary',
                            onClick: _saving
                                ? null
                                : () => _generateQuestion(
                                    data,
                                    _s(objective['objective_id']),
                                  ),
                            [Component.text('Generate question candidate')],
                          ),
                        // There is no per-objective Generate button. One
                        // action covers the selection above, so an owner with
                        // six objectives makes one decision instead of six.
                        // The selection tick on this card is what includes it.
                        // A spent attempt is still offered its own recovery
                        // form below: recovery is a different act from
                        // generation and must not be folded into the batch.
                        // The control is an attempt, not a permission. The two
                        // conditions the acceptance criteria name — eligibility
                        // (G-01…G-05S, reported check by check under the review
                        // surface above) and an unconsumed QG authorization —
                        // are re-derived by the server on this exact request.
                        // Nothing is disabled here on a locally guessed verdict:
                        // a refused attempt is reported with the server's own
                        // code and reserves nothing.
                        if (objective['proposal_id'] is String &&
                            data['context_id'] is String &&
                            data['confirmation_id'] is String)
                          p(classes: 'p1-muted', [
                            Component.text(
                              'The server re-checks the objective\'s eligibility '
                              'and your QG permission before anything is sent. '
                              'This button grants neither: an ineligible or '
                              'unauthorised objective is refused with its own '
                              'reason and no model is called.',
                            ),
                          ]),
                        // A live generation is a cloud call bounded by the transport
                        // timeout, and nothing else on the page moves while it runs. The
                        // bar is measured against that budget so a slow call looks slow
                        // rather than broken. It says nothing about the model's output:
                        // the candidate appears only after the server has validated and
                        // saved it.
                        if (_generatingProposalId == objective['proposal_id'])
                          _generationProgress(),
                        // The permission form lives inside this workflow rather than on
                        // a separate screen, because the refusal it answers is raised
                        // here. It appears only for the objective it was read for.
                        if (_consent != null &&
                            _consentProposalId == objective['proposal_id'])
                          _consentForm(data, objective),
                        // A spent attempt is offered as its own act, beneath the same
                        // objective, and only when the server says one is still
                        // possible. It is never offered as a "try again" beside Generate:
                        // a retry and a separately authorised recovery are different
                        // decisions and must not look alike.
                        if (_recovery != null &&
                            _recoveryProposalId == objective['proposal_id'])
                          _recoveryForm(data, objective),
                        // The generated questions for this objective, read
                        // from `m2_qg_candidates` — the same record set the
                        // count above is derived from, so the number and the
                        // cards can never disagree.
                        for (final candidate in _qgFor(objective))
                          if (_matchesQgFilter(candidate))
                            _qgCard(data, candidate),
                        if (_qgFor(objective).isEmpty && _qgLoaded)
                          _noGeneratedQuestion(data, objective),
                        for (final candidate in visible)
                          if (candidate['source_objective_id'] ==
                                  objective['objective_id'] &&
                              candidate['source_objective_version'] ==
                                  objective['objective_version'])
                            _candidateCard(
                              candidate,
                              demo: data['demo'] == true,
                            ),
                      ]),
                    ],
                    // Both record sets are consulted. A page that reported "no
                    // question candidates" while a generated question was on
                    // screen above it would be contradicting its own cards.
                    if (candidates.isEmpty &&
                        _qgSource.isEmpty &&
                        data['unmapped_candidate_count'] == 0 &&
                        data['candidate_history_loaded'] == true &&
                        data['candidate_read_unavailable'] != true)
                      p(classes: 'p1-notice p1-notice--soft', [
                        strong(classes: 'p1-notice__title', [
                          Component.text('No Direct-QG candidates returned'),
                        ]),
                        Component.text(
                          'No question candidates were provided by the server. '
                          'Opening Stage 4 does not automatically call a cloud model.',
                        ),
                      ]),
                    if (data['demo'] != true &&
                        data['candidate_history_loaded'] != true &&
                        data['candidate_read_unavailable'] != true)
                      p(classes: 'p1-notice p1-notice--soft', [
                        Component.text(
                          'Candidate history has not been loaded for a verified research context.',
                        ),
                      ]),
                    if ((candidates.isNotEmpty || _qgSource.isNotEmpty) &&
                        visible.isEmpty &&
                        !_qgSource.any(_matchesQgFilter))
                      p(classes: 'p1-notice p1-notice--soft', [
                        Component.text('No questions match this filter.'),
                      ]),
                    if ((data['unmapped_candidate_count'] as int? ?? 0) > 0)
                      p(classes: 'p1-notice p1-notice--warn', [
                        strong(classes: 'p1-notice__title', [
                          Component.text('Candidate provenance unavailable'),
                        ]),
                        Component.text(
                          'Stored questions exist, but their objective version and '
                          'context cannot yet be verified for this view.',
                        ),
                      ]),
                    if (data['candidate_read_unavailable'] == true)
                      p(classes: 'p1-notice p1-notice--warn', [
                        Component.text(
                          'Question records or their current business context could not be verified. Refresh or rebuild the context.',
                        ),
                      ]),
                    if (_message != null)
                      p(classes: 'p1-notice p1-notice--warn', [
                        Component.text(_message!),
                      ]),
                  ]),
                ]),
              ]),
            ],
          ),
        ]),

      ]),

      div(classes: 'p1-foot', [
        button(
          attributes: const {'type': 'button'},
          classes: 'p1-btn',
          onClick: component.onOpenStage == null
              ? null
              : () => component.onOpenStage!('location_evidence'),
          [Component.text('Back to Stage 3')],
        ),
        // "Continue to Stage 5" is not repeated here. It lives in the rail's
        // readiness card, which is where the checks that gate it are stated;
        // two controls for one governed transition are two chances to imply it
        // is available when it is not.
        p(classes: 'p1-foot__hint', [
          Component.text(
            ready['stage4_ready'] == true && candidates.isNotEmpty
                ? 'Stage 5 is available from the readiness card.'
                : 'Stage 5 requires saved decisions and server readiness.',
          ),
        ]),
      ]),
    ]);
  }

  /// Human label for the governed measurement-approval state.
  ///
  /// These are the contract's own values, not a client guess. Anything unknown
  /// is humanised rather than dropped, so a new server state is still visible.
  String _measurementLabel(String status) {
    switch (status.toUpperCase()) {
      case 'APPROVED':
        return 'approved';
      case 'BLOCKED_MEASUREMENT':
        return 'blocked';
      case 'BLOCKED_SOURCE':
        return 'source blocked';
      case 'BLOCKED_OWNER':
        return 'awaiting your input';
      case 'SCIENTIFIC_APPROVAL_PENDING':
        return 'scientific review pending';
      case 'G06_APPROVAL_PENDING':
        return 'approval pending';
      default:
        return _human(status);
    }
  }

  /// Section A — the fixed governed Q01–Q13 core questionnaire.
  ///
  /// Deliberately has NO Approve/Reject control. The fixed core is not
  /// individually reviewable here: what it needs is a scientific approval
  /// recorded elsewhere, not an owner toggle. Every card therefore reports the
  /// approval it does *not* have, and the wording is rendered exactly as the
  /// server populated it.
  ///
  /// One card per question rather than a table. The three catalogue facts (id,
  /// wording, options) are not columns a reader scans down — they are one
  /// question a reader judges whole. In a table the wording was squeezed into a
  /// narrow cell and a nine-option question wrapped into an unreadable column.
  ///
  /// The options are still inert. They are laid out as a grid so the set is
  /// legible at a glance, and each carries a list marker rather than a
  /// checkbox: CP-S4-02 forbids anything that suggests the entrepreneur can
  /// answer a governed question, and a checkbox that does nothing is exactly
  /// that suggestion.
  Component _sectionA(Map<String, dynamic> data) {
    final raw = data['preview_questionnaire'];
    final error = data['preview_error'];
    final preview = raw is PreviewQuestionnaire ? raw : null;

    final questions = preview?.questions ?? const <PreviewQuestion>[];
    // The whole governed catalogue, in the order the server returned it. There
    // is no filter above it: the fixed core is one instrument with one order,
    // and a filter over it made a read-only list look like something the reader
    // was expected to narrow down.
    final visible = _showAllCore
        ? questions
        : questions.take(_corePageSize).toList(growable: false);
    final hidden = questions.length - visible.length;

    return section(classes: 'p1-card p1-s4card', [
      div(classes: 'p1-s4sechead', [
        div(classes: 'p1-s4sechead__text', [
          p(classes: 'p1-s4eyebrow', [Component.text('Section A · Required')]),
          h3(classes: 'p1-s4title', [
            Component.text('Fixed core questionnaire'),
          ]),
          p(classes: 'p1-s4sub', [
            Component.text(
              'Review the existing questionnaire catalogue and its response '
              'options. Fixed questions are read-only.',
            ),
          ]),
        ]),
        if (preview != null)
          span(classes: 'p1-s4count', [
            Component.text('${preview.questionCount} questions'),
          ]),
      ]),
      if (preview == null)
        p(classes: 'p1-notice p1-notice--warn', [
          strong(classes: 'p1-notice__title', [
            Component.text('Core questionnaire unavailable'),
          ]),
          Component.text(
            error is String && error.isNotEmpty
                ? 'The governed wording could not be loaded ($error). The '
                      'generated questions below are read from a different '
                      'source and are unaffected.'
                : 'The governed wording could not be loaded. The generated '
                      'questions below are read from a different source and are '
                      'unaffected.',
          ),
        ])
      else ...[
        // Says what the section is *not*, in the place a reader looks for
        // instructions. The reference put "select the option(s) you would
        // choose" here; that sentence would invite an answer this screen
        // cannot accept, so the note states the opposite instead.
        div(classes: 'p1-howto', [
          span(
            attributes: const {'aria-hidden': 'true'},
            classes: 'p1-howto__badge',
            [Component.text('i')],
          ),
          div(classes: 'p1-howto__body', [
            strong(classes: 'p1-howto__title', [
              Component.text('How to read this section'),
            ]),
            p(classes: 'p1-howto__text', [
              Component.text(
                'Every question below is a fixed item from the governed '
                'catalogue. Its wording and its options are shown exactly as '
                'recorded, so you can check the set a respondent would be '
                'offered. The options are text, not controls — nothing on this '
                'screen can be answered, edited or approved.',
              ),
            ]),
          ]),
        ]),
        div(classes: 'p1-corelist', [
          for (final question in visible) _coreCard(question),
        ]),
        // The reference shows the first few rows and states the rest are still
        // in the questionnaire. Hiding them without saying so would understate
        // the instrument, so the count is always printed next to the control.
        if (hidden > 0)
          div(classes: 'p1-s4more', [
            p(classes: 'p1-s4more__t', [
              Component.text(
                '$hidden more questions · All ${questions.length} are included in '
                'the questionnaire (read-only).',
              ),
            ]),
            button(
              attributes: const {'type': 'button'},
              classes: 'p1-btn p1-btn--small',
              onClick: () => setState(() => _showAllCore = true),
              [Component.text('Show all questions')],
            ),
          ])
        else if (_showAllCore && questions.length > _corePageSize)
          div(classes: 'p1-s4more', [
            button(
              attributes: const {'type': 'button'},
              classes: 'p1-btn p1-btn--small',
              onClick: () => setState(() => _showAllCore = false),
              [Component.text('Show fewer questions')],
            ),
          ]),
        p(classes: 'p1-s4foot', [
          Component.text(
            'None of these questions is scientifically approved, so none is sent '
            'to a respondent from this screen. Showing a question here does not '
            'mean every respondent would be asked it — routing is decided '
            'separately.',
          ),
        ]),
      ],
    ]);
  }

  /// One fixed core question, as a card.
  ///
  /// The format line sits beside the id, where the reference puts it, because
  /// it qualifies how the options underneath should be read. `Details` is a
  /// disclosure on supporting metadata only; its open state is owned in
  /// [_openCoreQuestions] rather than left to the DOM, because this panel
  /// rebuilds on every status poll.
  Component _coreCard(PreviewQuestion question) {
    final id = question.questionId;
    final open = _openCoreQuestions.contains(id);
    final unresolved = [
      for (final slot in question.unresolvedSlots)
        if (slot.required) slot,
    ];
    final options = question.displayOrder.isNotEmpty
        ? question.displayOrder
        : question.codes;
    final format = _coreFormatLabel(question);
    return article(classes: 'p1-corecard', [
      div(classes: 'p1-corecard__head', [
        span(classes: 'p1-corecard__id', [Component.text(id)]),
        if (format.isNotEmpty)
          span(classes: 'p1-corecard__format', [Component.text(format)]),
        button(
          attributes: {
            'type': 'button',
            'aria-expanded': open ? 'true' : 'false',
            // Three cards on screen give three buttons whose visible text is
            // "Details". Without the id a screen reader announces the same
            // label three times and the reader cannot tell which question it
            // opens.
            'aria-label': open ? 'Hide details for $id' : 'Details for $id',
          },
          classes: 'p1-corecard__more',
          onClick: () => setState(() {
            if (!_openCoreQuestions.remove(id)) _openCoreQuestions.add(id);
          }),
          [Component.text(open ? 'Hide details' : 'Details')],
        ),
      ]),
      p(classes: 'p1-corecard__stem', [
        Component.text(question.populatedStem),
        if (unresolved.isNotEmpty)
          span(classes: 'p1-qrow__flag', [
            Component.text('${unresolved.length} to fill'),
          ]),
      ]),
      if (options.isEmpty)
        // No codes is a fact about the record, not an empty option list, so the
        // response format is named instead of printing nothing.
        p(classes: 'p1-corecard__noopts', [
          Component.text(
            '${_shortType(question.responseType)} · the catalogue records no '
            'fixed options for this question.',
          ),
        ])
      else
        ul(classes: 'p1-corecard__opts', [
          for (final code in options)
            li(classes: 'p1-corecard__opt', [Component.text(_human(code))]),
        ]),
      if (open) _coreDetail(question, unresolved),
    ]);
  }

  /// The supporting catalogue metadata for one fixed question.
  ///
  /// Rendered inside the card rather than as an extra table row, so a reader
  /// opening `Details` keeps the wording it belongs to in view.
  Component _coreDetail(
    PreviewQuestion question,
    List<UnresolvedSlot> unresolved,
  ) {
    final meta = <String>[
      if (question.construct.trim().isNotEmpty)
        'Construct ${question.construct}',
      if (question.questionClass.trim().isNotEmpty)
        'Class ${_human(question.questionClass)}',
      if (question.responseType.trim().isNotEmpty)
        'Format ${question.responseType}',
      if (question.measurementStatus.trim().isNotEmpty)
        'Measurement: ${_measurementLabel(question.measurementStatus)}',
      if (question.approvalState.trim().isNotEmpty)
        'Approval: ${_human(question.approvalState)}',
      if (question.populationStatus.trim().isNotEmpty)
        'Population: ${_human(question.populationStatus)}',
    ];
    return div(classes: 'p1-corecard__detail', [
      if (question.codes.isNotEmpty)
        div(classes: 'p1-corerow__codes', [
          Component.text(question.codes.map(_human).join(' · ')),
        ]),
      if (meta.isNotEmpty)
        div(classes: 'p1-corerow__meta', [Component.text(meta.join(' · '))]),
      if (unresolved.isNotEmpty)
        div(classes: 'p1-corerow__need', [
          for (final slot in unresolved)
            span([
              Component.text(
                'Placeholder ${slot.token} needs ${slot.source}. ${slot.reason}',
              ),
            ]),
        ]),
    ]);
  }

  /// The response format, said the way a reader would say it.
  ///
  /// Derived only from contract fields — `response_type`, `max_selections` and
  /// the exclusive terminals the server lists. Nothing here invents a capability
  /// the catalogue does not record, and an unknown type falls back to its own
  /// token rather than to a guess.
  String _coreFormatLabel(PreviewQuestion question) {
    final type = question.responseType.trim();
    final cap = switch (question.maxSelections) {
      null => '',
      1 => ' (select one)',
      final n => ' (select up to ${_spell(n)})',
    };
    return switch (type) {
      'multi_select_with_exclusive_terminals' => cap.isEmpty
          ? 'Multiple choice (select all that apply)'
          : 'Multiple choice$cap',
      'multi_select' => cap.isEmpty
          ? 'Multiple choice (select one or more)'
          : 'Multiple choice$cap',
      'nominal_single' || 'ordinal_single' => 'Single choice (select one)',
      'ordinal_matrix' => 'Matrix (one answer per row)',
      _ => type.isEmpty ? '' : _human(type),
    };
  }

  /// Small counts read better as words in a parenthetical.
  String _spell(int n) => switch (n) {
    1 => 'one',
    2 => 'two',
    3 => 'three',
    4 => 'four',
    5 => 'five',
    6 => 'six',
    7 => 'seven',
    8 => 'eight',
    9 => 'nine',
    10 => 'ten',
    _ => '$n',
  };

  /// A short response-format label, so the format column cannot squeeze the
  /// wording out of the row. The full server token stays in the details.
  String _shortType(String type) => switch (type) {
    'multi_select_with_exclusive_terminals' => 'Multi + terminals',
    'multi_select' => 'Multi-select',
    'ordinal_single' => 'Ordinal',
    'nominal_single' => 'Single choice',
    'ordinal_matrix' => 'Matrix',
    _ => _human(type),
  };

  /// One generated question, under the objective it was generated for.
  ///
  /// The intended response is a control on the options themselves, matched to
  /// the format the server recorded: a multiple-choice question takes a set, so
  /// it gets checkboxes and every chosen option is stored; every other format
  /// takes one answer, so it gets radios and a second choice replaces the
  /// first. One dropdown for all formats is what the legacy card above uses,
  /// and it can only ever express one answer — which is wrong for exactly the
  /// questions that have several.
  ///
  /// Nothing here approves fielding. The decision recorded is an opinion about
  /// the question, and the server pins `fielding_authorized` false on it.
  Component _qgCard(Map<String, dynamic> data, QgCandidate candidate) {
    final demo = data['demo'] == true;
    final busy = _qgBusyId != null;
    final multi = candidate.responseFormat.toUpperCase() == 'MULTIPLE_CHOICE';
    final selected = candidate.review.selection;
    final decision = candidate.review.decision ?? '';
    final error = _qgWriteError[candidate.candidateId];
    final m2Id = data['m2_assessment_id'];
    VoidCallback? decide(String value) {
      if (demo) {
        return () => setState(() {
          _demoDecisions[candidate.candidateId] = value;
          _future = Future.value(_demoStage4Snapshot());
        });
      }
      if (busy || m2Id is! String) return null;
      return () => _decideQg(m2Id, candidate, value);
    }
    return section(classes: 'p1-qcard p1-qcard--qg', [
      div(classes: 'p1-qhead', [
        // The wording leads. Everything about provenance is below it, because
        // the reader is judging the sentence, not the ledger.
        div(classes: 'p1-qtitle', [Component.text(candidate.question)]),
        div(classes: 'p1-chips', [
          if (candidate.responseFormat.isNotEmpty)
            _chip(candidate.responseFormat, tone: 'gray'),
          _chip(_statusLabel(decision), tone: _statusTone(decision)),
          if (candidate.isSimulated)
            _chip('simulated — not live evidence', tone: 'amber'),
        ]),
      ]),
      if (candidate.options.isEmpty)
        p(classes: 'p1-muted', [
          Component.text(
            'This question records no answer options, so no intended response '
            'can be selected for it.',
          ),
        ])
      else
        div(classes: 'p1-opts p1-opts--pick', [
          for (final option in candidate.options)
            label(
              classes:
                  'p1-optrow${multi ? ' p1-optrow--multi' : ' p1-optrow--single'}'
                  '${selected.contains(option.code) ? ' is-picked' : ''}',
              [
                input(
                  type: multi ? InputType.checkbox : InputType.radio,
                  checked: selected.contains(option.code),
                  attributes: {
                    'name': 'expect-${candidate.candidateId}',
                    'value': option.code,
                    // The option code, addressable. A component test has to be
                    // able to click one option rather than "the first input",
                    // or it cannot tell a set from a single answer.
                    'data-option': option.code,
                    'aria-label':
                        'Intended response: ${option.label} (${option.code})',
                  },
                  events: events(
                    onClick: () {
                      if (demo) {
                        // Local state only. The demo never reaches a route, so a
                        // design review cannot write a record by clicking.
                        return () => setState(() {
                          final next = _nextQgSelection(candidate, option.code);
                          if (next == null || next.isEmpty) {
                            _demoOwnerOptions.remove(candidate.candidateId);
                          } else {
                            _demoOwnerOptions[candidate.candidateId] = next.first;
                          }
                          _future = Future.value(_demoStage4Snapshot());
                        });
                      }
                      if (busy || m2Id is! String) return null;
                      return () => _expectQg(
                        m2Id,
                        candidate,
                        _nextQgSelection(candidate, option.code),
                      );
                    }(),
                  ),
                ),
                span(classes: 'p1-optrow__label', [
                  Component.text(option.label),
                ]),
              ],
            ),
          p(classes: 'p1-muted p1-opts__note', [
            Component.text(
              selected.isEmpty
                  ? 'Select your intended response, or leave it blank. This is '
                        'your prediction of what respondents will choose — not a '
                        'respondent answer, and it is never shown to them.'
                  : 'Your intended response is recorded. It is a prediction about '
                        'respondents, not an observation, and it is never counted '
                        'in a CQ or EE-01 calculation.',
            ),
          ]),
        ]),
      div(classes: 'p1-qbottom', [
        div(classes: 'p1-qactions', [
          button(
            attributes: const {'type': 'button'},
            classes: 'p1-btn p1-btn--small p1-btn--approve',
            onClick: decide('APPROVE_FOR_REVIEW'),
            [Component.text('Approve')],
          ),
          button(
            attributes: const {'type': 'button'},
            classes: 'p1-btn p1-btn--small p1-btn--danger',
            onClick: decide('REJECT'),
            [Component.text('Reject')],
          ),
          if (candidate.review.reviewed)
            span(classes: 'p1-muted', [
              Component.text(
                'Recorded: ${_statusLabel(decision)}'
                '${candidate.review.recordedAt == null ? '' : ' · ${candidate.review.recordedAt}'}',
              ),
            ]),
        ]),
      ]),
      if (error != null)
        p(classes: 'p1-notice p1-notice--warn', [Component.text(error)]),
    ]);
  }

  /// The selection an option click produces, matched to the recorded format.
  ///
  /// A multiple-choice question keeps every chosen option; every other format
  /// replaces the selection, and clicking the only chosen option clears it.
  /// Sending a set to a single-choice question would ask the server to store an
  /// answer the question cannot put to a respondent.
  List<String>? _nextQgSelection(QgCandidate candidate, String code) {
    final selected = candidate.review.selection;
    if (candidate.responseFormat.toUpperCase() == 'MULTIPLE_CHOICE') {
      final next = [
        for (final existing in selected)
          if (existing != code) existing,
      ];
      if (!selected.contains(code)) next.add(code);
      return next.isEmpty ? null : next;
    }
    return selected.length == 1 && selected.first == code ? null : [code];
  }

  /// What stands in place of a question when an objective has none yet.
  ///
  /// An objective with no question is a normal state, not a failure, and the
  /// reader needs the server's own reason rather than a blank. The report is
  /// read for exactly these objectives, so the page does not ask the server to
  /// re-evaluate objectives that already hold a question.
  Component _noGeneratedQuestion(
    Map<String, dynamic> data,
    Map<String, dynamic> objective,
  ) {
    final objectiveId = _s(objective['objective_id']);
    final m2Id = data['m2_assessment_id'];
    final report = _qgEligibility[objectiveId];
    final open = _openEligibility.contains(objectiveId);
    if (report == null &&
        m2Id is String &&
        objectiveId.isNotEmpty &&
        !_eligibilityAsked.contains(objectiveId)) {
      unawaited(_loadEligibility(m2Id, objectiveId));
    }
    final blocking = report == null
        ? const <EligibilityCheck>[]
        : [
            for (final check in report.checks)
              if (check.isBlocking) check,
          ];
    return div(classes: 'p1-empty', [
      p(classes: 'p1-empty__title', [
        Component.text('No question generated for this objective yet'),
      ]),
      if (report == null)
        p(classes: 'p1-muted', [Component.text('Reading generation requirements…')])
      else if (blocking.isEmpty)
        p(classes: 'p1-muted', [
          Component.text(
            'The server reports no blocking requirement. Selecting this '
            'objective and using “Generate all suggested questions” will ask it '
            'to generate.',
          ),
        ])
      else ...[
        // The first blocking requirement, in the server's own words. The rest
        // are one click away rather than stacked in the card.
        p(classes: 'p1-muted', [
          Component.text(
            'Blocked by ${blocking.first.title}'
            '${blocking.first.reasonCode.isEmpty ? '' : ' · ${blocking.first.reasonCode}'}'
            '${blocking.length > 1 ? ' · ${blocking.length - 1} more requirement${blocking.length == 2 ? '' : 's'} outstanding' : ''}',
          ),
        ]),
        button(
          attributes: const {'type': 'button'},
          classes: 'p1-qrow__more',
          onClick: () => setState(() {
            if (!_openEligibility.remove(objectiveId)) {
              _openEligibility.add(objectiveId);
            }
          }),
          [Component.text(open ? 'Hide requirements' : 'Why not?')],
        ),
        if (open)
          div(classes: 'p1-reqlist', [
            for (final check in report.checks)
              div(classes: 'p1-req', [
                span(
                  classes:
                      'p1-req__state p1-req__state--${check.status.toLowerCase()}',
                  [Component.text(check.status)],
                ),
                span(classes: 'p1-req__title', [Component.text(check.title)]),
                span(classes: 'p1-req__code', [
                  Component.text(
                    check.reasonCode.isEmpty ? check.checkId : check.reasonCode,
                  ),
                ]),
              ]),
            p(classes: 'p1-muted', [
              Component.text(
                'This report is diagnostic. A PASS would still not authorise a '
                'provider call — the server re-verifies every condition on the '
                'real request.',
              ),
            ]),
          ]),
      ],
    ]);
  }

  Component _candidateCard(
    Map<String, dynamic> candidate, {
    bool demo = false,
  }) {
    final id = _s(candidate['candidate_id']);
    final version = _v(candidate['candidate_version']);
    final options = _rows(candidate['options']);
    final selected = _s(candidate['owner_expected_option_id']);
    final state = _s(candidate['owner_review_decision']);
    final response = _s(candidate['response_kind']);
    final optionIds = options.map((v) => _s(v['option_id'])).toSet();
    final valid =
        id.isNotEmpty &&
        version.isNotEmpty &&
        _s(candidate['question_text']).trim().isNotEmpty &&
        const {
          'SINGLE_CHOICE',
          'BINARY_CHOICE',
          'ORDERED_SCALE',
          'NUMERIC_RANGE_OPTIONS',
          'MULTIPLE_CHOICE',
          'SINGLE',
          'MULTI',
        }.contains(response) &&
        options.length >= 2 &&
        optionIds.length == options.length &&
        optionIds.every((x) => x.isNotEmpty) &&
        options.every((x) => _s(x['label']).trim().isNotEmpty);
    return section(classes: 'p1-qcard', [
      div([
        div(classes: 'p1-qhead', [
          span(classes: 'p1-qid', [
            Component.text(id.isEmpty ? 'Candidate' : id),
          ]),
          div(classes: 'p1-qtitle', [
            Component.text(_s(candidate['question_text'])),
          ]),
          div(classes: 'p1-chips', [
            if (version.isNotEmpty) _chip('V$version', tone: 'gray'),
            // The response format the server recorded for this candidate. It was
            // read (it gates `valid` below) but never shown, so the reviewer had
            // to infer the answer shape from the option list. Shown verbatim:
            // an unrecognised kind is visible as itself rather than hidden.
            if (response.isNotEmpty) _chip(response, tone: 'gray'),
            _chip(_statusLabel(state), tone: _statusTone(state)),
          ]),
        ]),
        if (options.isNotEmpty)
          div(classes: 'p1-answers', [
            for (final item in options)
              span(classes: 'p1-answer', [Component.text(_s(item['label']))]),
          ]),
        div(classes: 'p1-qbottom', [
          div(classes: 'p1-expected', [
            if (options.isNotEmpty) ...[
              label(classes: 'p1-fieldlabel', [
                Component.text("Owner's expected answer (optional)"),
              ]),
              select(
                [
                  option([Component.text('No prediction')], value: ''),
                  for (final item in options)
                    option([
                      Component.text(_s(item['label'])),
                    ], value: _s(item['option_id'])),
                ],
                value: optionIds.contains(selected) ? selected : '',
                classes: 'p1-select',
                attributes: const {'aria-label': 'Owner expected answer'},
                onChange: demo
                    ? (values) => setState(() {
                        _demoOwnerOptions[id] = values.isEmpty
                            ? ''
                            : values.first;
                        _future = Future.value(_demoStage4Snapshot());
                      })
                    : candidate['prediction_available'] == true && !_saving
                    ? (values) => _commit(() async {
                        final value = values.isEmpty || values.first.isEmpty
                            ? null
                            : values.first;
                        await AppLocator.m2.saveDesiredOption(
                          id,
                          candidate['source_revision'] as int,
                          value,
                        );
                        final readback = await AppLocator.m2
                            .readEntrepreneurQuestion(
                              id,
                              candidate['source_revision'] as int,
                            );
                        if (readback['option_code'] != value) {
                          throw StateError('Prediction readback mismatch.');
                        }
                      })
                    : null,
              ),
              if (!demo && candidate['prediction_available'] != true)
                p(classes: 'p1-muted', [
                  Component.text(
                    'Expected-answer selection is unavailable for this version.',
                  ),
                ]),
            ] else
              p(classes: 'p1-muted', [
                Component.text(
                  'No fixed choices: owner-answer dropdown not applicable.',
                ),
              ]),
          ]),
          if (valid && state == 'PENDING')
            div(classes: 'p1-qactions', [
              button(
                attributes: const {'type': 'button'},
                classes: 'p1-btn p1-btn--small p1-btn--approve',
                onClick: demo
                    ? () => setState(() {
                        _demoDecisions[id] = 'APPROVE_FOR_REVIEW';
                        _future = Future.value(_demoStage4Snapshot());
                      })
                    : _saving
                    ? null
                    : () => _commit(() async {
                        await _reviewCandidate(
                          id,
                          ResearchReviewAction.approveForReview,
                        );
                      }),
                [Component.text('Approve')],
              ),
              button(
                attributes: const {'type': 'button'},
                classes: 'p1-btn p1-btn--small p1-btn--danger',
                onClick: demo
                    ? () => setState(() {
                        _demoDecisions[id] = 'REJECT';
                        _future = Future.value(_demoStage4Snapshot());
                      })
                    : _saving
                    ? null
                    : () => _commit(() async {
                        await _reviewCandidate(id, ResearchReviewAction.reject);
                      }),
                [Component.text('Reject')],
              ),
              if (!demo)
                button(
                  attributes: const {'type': 'button'},
                  classes: 'p1-btn p1-btn--small',
                  onClick: _saving
                      ? null
                      : () => _commit(() async {
                          await _reviewCandidate(
                            id,
                            ResearchReviewAction.requestRevision,
                          );
                        }),
                  [Component.text('Request revision')],
                ),
            ]),
        ]),
        p(classes: 'p1-muted p1-source', [
          Component.text(
            'Source: ${_s(candidate['source_objective_id'])} · Draft question · '
            'Entrepreneur expectation is not evidence',
          ),
        ]),
        if (_s(candidate['supersedes']).isNotEmpty)
          p(classes: 'p1-muted', [
            Component.text('Revises candidate ${_s(candidate['supersedes'])}'),
          ]),
        if (_s(candidate['review_rationale']).trim().isNotEmpty)
          p(classes: 'p1-muted', [
            Component.text(
              'Review reason: ${_s(candidate['review_rationale'])}',
            ),
          ]),
        if (!demo &&
            valid &&
            state == 'REQUEST_REVISION' &&
            candidate['context_id'] is String)
          button(
            attributes: const {'type': 'button'},
            classes: 'p1-btn p1-btn--small',
            onClick: _saving ? null : () => _reviseCandidate(candidate),
            [Component.text('Generate revised candidate')],
          ),
        if (options.isEmpty)
          p(classes: 'p1-muted', [
            Component.text(
              'No fixed choices: owner-answer dropdown not applicable.',
            ),
          ]),
        if (!valid)
          p(classes: 'p1-notice p1-notice--warn', [
            Component.text(
              'Candidate or option identity is incomplete; review is blocked.',
            ),
          ]),
        if (valid && state == 'PENDING' && !demo) ...[
          textarea(
            rows: 1,
            classes: 'm1-textarea p1-note',
            attributes: {
              'maxlength': '1000',
              'placeholder': 'Reason for this decision (optional)',
              'aria-label': 'Reason for question review',
            },
            onInput: (value) => setState(() => _reviewRationales[id] = value),
            [Component.text(_reviewRationales[id] ?? '')],
          ),
        ],
      ]),
    ]);
  }

  @override
  Component build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
    future: _future,
    builder: (context, snapshot) {
      // Stage 3's rail lives inside the proposal panel, so the page draws one
      // column. `.p1-stage` is a two-column grid (`1fr` + a 320px rail); with
      // no rail child the 320px would still be reserved and the objectives
      // would sit in a column 340px narrower than the page for no reason.
      final stageClasses = component.stageNumber == 3
          ? 'p1-stage p1-stage--single'
          : 'p1-stage';
      if (snapshot.connectionState != ConnectionState.done) {
        // Page-loading is its own statement. The rail is deliberately absent
        // here: the execution read is started independently, and it shows its
        // own pending skeleton once there is a page for it to sit beside. Two
        // "loading…" lines side by side read as one stalled page.
        return div(classes: stageClasses, [
          div(classes: 'p1-stage__main', [
            section(classes: 'p1-card', [
              div([Component.text('Loading verified research records…')]),
            ]),
          ]),
        ]);
      }
      if (snapshot.hasError || snapshot.data == null) {
        // No rail here. When the page's own read failed there is nothing
        // trustworthy to say about execution either, and a rail that renders
        // "unknown" beside "workspace could not be verified" reads as two
        // independent failures instead of one.
        return div(classes: stageClasses, [
          div(classes: 'p1-stage__main', [
            _notice(
              'Research integration is not ready',
              'A current authenticated research workspace could not be verified. '
                  'Check the assessment, sign-in and service availability, then retry.',
            ),
          ]),
        ]);
      }
      // Both stages get the same two-column shape: the assessment content keeps
      // the full width of the main column and stays usable while a model call is
      // in flight, and the execution rail sits beside it rather than pushing the
      // content down.
      //
      // Only Stage 4 mounts the rail here. Stage 3's proposal panel already owns
      // a right-hand rail of its own, so the page hands it the execution cards
      // through `railLead` instead of drawing a second column beside it.
      final data = snapshot.data!;
      return div(classes: stageClasses, [
        div(classes: 'p1-stage__main', [
          component.stageNumber == 3 ? _step3(data) : _step4(data),
        ]),
        if (component.stageNumber != 3)
          _executionRail(
            data['ai_status'] as AiExecutionStatus,
            current: data['current_bdj'] as CurrentBdjResult?,
            execution: _execution,
            stageData: data,
          ),
      ]);
    },
  );
}
