import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/ai_execution_status.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/bdj_objective_proposal.dart'
    show BdjReviewState;
import 'package:sitewise_jaspr_web/features/assessment/data/bdj_objective_proposal_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/qg_generation_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/bdj_objective_proposal_panel.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage4_preview_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage4_preview_questionnaire.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage_four_five_api.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart'
    show Icon;
import 'stage_four_question_review.dart' show StageFourQuestionReview;

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

  /// The QG processing terms for one objective, held only after the server has
  /// refused generation for want of a grant. Populated from the server's own
  /// disclosure so the form cannot describe terms the server would not honour.
  QgConsent? _consent;

  /// Which objective [_consent] belongs to. The terms are per objective, so
  /// they must never be shown under a different one.
  String? _consentProposalId;

  /// True while the owner's grant request is in flight.
  bool _grantingConsent = false;

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

  /// The transport budget the server enforces, mirrored for the display only.
  /// A wrong value here can mislead the reader, never the dispatch.
  static const int _generationTimeoutSeconds = 90;

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
    super.dispose();
  }

  String? _message;
  String _newObjective = '';
  final Map<String, String> _reviewRationales = {};

  /// Presentation-only: whether the secondary Review History card is expanded.
  /// Default collapsed so historical candidate reviews never read as the
  /// current BDJ state.
  bool _historyOpen = false;

  /// Presentation-only: Stage 4 question filter. `all` | `pending` | `approved`
  /// | `rejected`. Filtering happens over rows already fetched — no new request.
  String _candidateFilter = 'all';

  /// Presentation-only: which of the two question sets is on screen.
  ///
  /// `basic` is the default because the governed core is the set the owner can
  /// act on — the Extra set is empty until an objective is approved, so opening
  /// on it would show a blank column to most visitors. Both views render the
  /// same two columns; the modifier class only changes which column is
  /// displayed. Nothing is re-fetched and no recorded decision is dropped when
  /// the view changes.
  String _view = 'basic';

  /// Presentation-only demo of the Stage 4 design. Enabled ONLY by the
  /// `?demo=stage4` query parameter. Every row below is sample data; the demo
  /// never calls, creates or writes any M2/backend record. All interactions
  /// (owner option, Approve, Reject) change local widget state only.
  bool get _demoStage4 =>
      Uri.base.queryParameters['demo'] == 'stage4' &&
      component.stageNumber == 4;
  final Map<String, String> _demoOwnerOptions = {};
  final Map<String, String> _demoDecisions = {};

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
      _historyOpen = false;
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
    unawaited(_loadExecution(m2Id));

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
  AiExecutionReading? _execution;

  /// Reads the execution status for the AI Execution Status card.
  ///
  /// Kept off the page's own future on purpose: a slow or failing status read
  /// must not delay or blank the research workspace. A failed read leaves
  /// [_execution] null, which the card words as "unavailable" — a different
  /// statement from "nothing has run".
  Future<void> _loadExecution(String m2Id) async {
    AiExecutionReading? reading;
    try {
      final result = await component.stageFourFive.executionStatus(
        assessmentId: m2Id,
      );
      if (result.ok) reading = result.value;
    } catch (_) {
      reading = null;
    }
    if (!mounted) return;
    setState(() => _execution = reading);
  }

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
  }) async {
    final proposalId = objective['proposal_id'];
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
  /// Deliberately a *progress* indicator and not a fake percentage of "work
  /// done": the server does not report model progress, and inventing one would
  /// be the same class of lie as presenting a simulated candidate as evidence.
  /// What is shown is elapsed time against the timeout the server actually
  /// enforces, which is a fact the panel knows.
  Component _generationProgress() {
    final elapsed = _generatingSeconds;
    final remaining = _generationTimeoutSeconds - elapsed;
    final overBudget = remaining <= 0;
    final percent = ((elapsed / _generationTimeoutSeconds) * 100).clamp(0, 100);
    return div(classes: 'p1-notice p1-notice--soft', [
      p(classes: 'p1-muted', [
        Component.text(
          overBudget
              ? 'The model call has passed its ${_generationTimeoutSeconds}s '
                    'transport budget. The server will report a timeout rather '
                    'than a candidate; nothing has been approved.'
              : 'Waiting for the model. ${elapsed}s elapsed of a '
                    '${_generationTimeoutSeconds}s transport budget. The attempt '
                    'is already spent, so do not close this page and press '
                    'Generate again — that would be refused, not retried.',
        ),
      ]),
      div(classes: 'p1-progress', [
        div(
          classes: overBudget
              ? 'p1-progress__bar p1-progress__bar--over'
              : 'p1-progress__bar',
          attributes: {'style': 'width: ${percent.toStringAsFixed(1)}%'},
          const [],
        ),
      ]),
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

  /// The count shown beside the Basic column header.
  ///
  /// Read from the same preview payload the column renders, so the header can
  /// never claim thirteen while the list below it holds a different number. A
  /// failed preview reports zero rather than an invented count.
  String _coreCount(Map<String, dynamic> data) {
    final raw = data['preview_questionnaire'];
    return raw is PreviewQuestionnaire ? '${raw.questionCount}' : '0';
  }

  /// The view switcher for the two question sets.
  ///
  /// `Basic` and `Extra` each read one set at full width. There is no combined
  /// view: side by side, the generated column is usually empty (it needs an
  /// approved objective) and its banner competed with the governed list for the
  /// same attention, so the reader got a half-blank row instead of a choice.
  /// The tabs do not fetch or discard anything — they set [_view], which only
  /// changes the grid modifier on the shared panel — so a review decision
  /// already recorded on a card survives a tab switch.
  ///
  /// The counts are the same numbers the column headers report, and `varies`
  /// is not a count: it says the generated set is read by another surface and
  /// this panel never tallied it.
  Component _viewTabs(Map<String, dynamic> data) {
    Component tab(String id, String label, String icon, String? count) {
      final active = _view == id;
      return button(
        attributes: {
          'type': 'button',
          'role': 'tab',
          'aria-selected': active.toString(),
          'aria-controls': 's4-view-panel',
        },
        classes: 'p1-s4tab${active ? ' is-active' : ''}',
        onClick: () => setState(() => _view = id),
        [
          span(classes: 'p1-s4tab__ico', [Icon(icon, size: 'sm')]),
          span(classes: 'p1-s4tab__label', [Component.text(label)]),
          if (count != null)
            span(classes: 'p1-s4tab__n', [Component.text(count)]),
        ],
      );
    }

    return div(
      classes: 'p1-s4tabs',
      attributes: const {'role': 'tablist', 'aria-label': 'Questionnaire view'},
      [
        tab('basic', 'Basic', 'lock', _coreCount(data)),
        tab('extra', 'Extra', 'auto_awesome', 'varies'),
      ],
    );
  }

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

  /// One column header for the Stage 4 two-column layout.
  ///
  /// The two columns hold different kinds of question — a fixed governed set and
  /// a generated set — so each states which it is, how many it holds and what
  /// the reader may do with it. The Basic count is a server-reported number.
  ///
  /// The Extra count is [count] = null when the generated questions are read by
  /// the embedded review surface rather than by this panel: the panel cannot
  /// count rows it never fetched, and printing the *legacy* candidate tally here
  /// would count a different table than the cards below it.
  Component _columnHead({
    required String title,
    String? count,
    required String icon,
    required String sub,
    required String tone,
  }) => div(classes: 'p1-s4head p1-s4head--$tone', [
    div(classes: 'p1-s4head__top', [
      span(classes: 'p1-s4head__icon', [Icon(icon, size: 'sm')]),
      h3(classes: 'p1-s4head__title', [Component.text(title)]),
      if (count != null)
        span(classes: 'p1-s4head__n', [Component.text(count)])
      else
        span(classes: 'p1-s4head__n p1-s4head__n--varies', [
          Component.text('varies'),
        ]),
    ]),
    p(classes: 'p1-s4head__sub', [Component.text(sub)]),
  ]);

  /// Right-hand guidance card.
  Component _sideCard(String title, List<Component> children) =>
      section(classes: 'p1-card', [
        h3(classes: 'p1-card__title', [Component.text(title)]),
        ...children,
      ]);

  Component _row(String label, String value) => div(classes: 'p1-row', [
    span([Component.text(label)]),
    b([Component.text(value)]),
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

  /// One purpose's execution state, worded from what the ledger recorded.
  ///
  /// Every sentence here is a restatement of a stored fact. Nothing is
  /// interpolated between states, and no percentage is shown: the ledger does
  /// not record fractions, so the card does not draw any.
  Component _executionLine(AiExecutionPurpose? execution) {
    if (execution == null) {
      return p(classes: 'p1-muted', [
        Component.text(
          'Execution status is unavailable: the ledger could not be read. '
          'That is not the same as "nothing has run".',
        ),
      ]);
    }
    final text = switch (execution.state) {
      'BLOCKED' =>
        'No attempt has been reserved for this purpose. Prerequisites have not '
            'all been met, or generation has not been started.',
      'PROCESSING' =>
        'Attempt ${execution.attemptNo ?? 1} is reserved and the provider has '
            'not answered yet.',
      'RETURNED' =>
        'The provider returned a result and no governed record has been written '
            'yet. The attempt is already spent.',
      'VALIDATING' =>
        'A record was written and its validation has not finished '
            '(${execution.pendingValidation} pending).',
      'PERSISTED' =>
        'A validated record is persisted (${execution.persisted}).',
      'FAILED' =>
        'The attempt was refused by the provider or the gate: '
            '${execution.receiptOutcome ?? execution.reason}.',
      'UNKNOWN_OUTCOME' =>
        'An attempt was reserved and no receipt was recorded. The outcome is '
            'unknown, the attempt is spent, and it is not retried automatically.',
      _ => 'State "${execution.state}" is not one this interface can describe.',
    };
    return p(classes: 'p1-muted', [
      Component.text('State: ${execution.state}. $text'),
      if (execution.reason.isNotEmpty)
        Component.text(' (ledger reason: ${execution.reason})'),
      if (execution.attemptsReserved > 1)
        Component.text(
          ' ${execution.attemptsReserved} attempt(s) are recorded for this '
          'purpose.',
        ),
    ]);
  }

  /// The five stages one LLM attempt actually passes through, in order.
  ///
  /// These are the ledger's own transitions, not a decorative animation: the
  /// rail is drawn from the persisted attempt state, so a stalled run shows a
  /// stalled rail rather than an encouraging one. "Dispatched" and "Returned"
  /// are separate because a provider that never answered and a provider that
  /// answered are different facts with different consequences — the first may
  /// have completed upstream, the second definitely spent the attempt.
  static const _executionStages = <String>[
    'Reserved',
    'Dispatched',
    'Returned',
    'Validated',
    'Persisted',
  ];

  /// How far along the rail a persisted state has travelled.
  ///
  /// Returned as (reached, current, failed) rather than a percentage: a
  /// percentage would imply progress that the ledger cannot promise, and the
  /// terminal states are not "90% done" — they are finished, one way or the
  /// other. ``current`` is -1 when the run has no stage in progress, which is
  /// the case for a terminal success.
  static (int, int, bool) _railPosition(AiExecutionPurpose execution) {
    switch (execution.state) {
      case 'BLOCKED':
        return (0, 0, false);
      case 'PROCESSING':
        return (2, 1, false);
      case 'RETURNED':
        return (3, 2, false);
      case 'VALIDATING':
        return (3, 3, false);
      case 'PERSISTED':
        // A persisted record is the end of the rail, so there is no *current*
        // stage left to point at: ``current`` is -1 and every step is behind
        // the run. Reporting ``current = 4`` drew the terminal "Persisted"
        // step as the in-progress dot, so a finished execution always looked
        // unfinished — the rail contradicted the state printed directly
        // beneath it ("State: PERSISTED ... 2 record(s) persisted").
        return (5, -1, false);
      case 'FAILED':
        // A refusal after the provider answered still reached "Returned"; a
        // refusal before it did not. The receipt outcome is the only thing that
        // distinguishes them, and the rail must not overstate either.
        return execution.receiptOutcome == 'returned'
            ? (3, 2, true)
            : (2, 1, true);
      case 'UNKNOWN_OUTCOME':
        return (2, 1, true);
      default:
        return (0, 0, false);
    }
  }

  /// One progress rail, shared by BDJ and Direct-QG.
  ///
  /// Reused rather than duplicated so the two purposes cannot drift into
  /// telling the owner different stories about the same ledger.
  Component _executionProgress(
    AiExecutionPurpose? execution, {
    required String label,
  }) {
    if (execution == null) {
      return div(classes: 'p1-ai__progress', [
        strong(classes: 'p1-ai__label', [Component.text(label)]),
        p(classes: 'p1-muted', [
          Component.text(
            'Progress unavailable: the ledger could not be read. Nothing is '
            'shown rather than a plausible-looking bar.',
          ),
        ]),
      ]);
    }
    final (reached, current, failed) = _railPosition(execution);
    final stages = <Component>[];
    for (var i = 0; i < _executionStages.length; i++) {
      final done = i < reached && i != current;
      final isCurrent = i == current;
      final cls = failed && isCurrent
          ? 's4-badge s4-badge--warn'
          : isCurrent
          ? 's4-badge s4-badge--objective'
          : done
          ? 's4-badge s4-badge--pass'
          : 's4-badge s4-badge--muted';
      final mark = failed && isCurrent
          ? '!'
          : done
          ? '✓'
          : isCurrent
          ? '·'
          : '○';
      stages.add(
        span(classes: cls, [Component.text('$mark ${_executionStages[i]}')]),
      );
    }
    return div(classes: 'p1-ai__progress', [
      strong(classes: 'p1-ai__label', [Component.text(label)]),
      div(classes: 's4-row', stages),
      if (failed && execution.receiptOutcome == 'rejected')
        // A rejection can happen after the provider answered (content that
        // fails the schema) or before it ever did. The ledger does not persist
        // the provider's HTTP status, so the rail must not claim either.
        p(classes: 'p1-muted', [
          Component.text(
            'The ledger records this attempt as rejected. It does not record '
            'whether the provider answered, so the rail stops at the last stage '
            'it can prove.',
          ),
        ]),
      p(classes: 'p1-muted', [
        Component.text(
          'Attempt ${execution.attemptNo ?? 1}'
          '${execution.reservedAt == null ? '' : ', reserved ${execution.reservedAt}'}'
          '${execution.receiptAt == null ? '' : ', receipt ${execution.receiptAt}'}'
          '${execution.persisted > 0 ? ', ${execution.persisted} record(s) persisted' : ''}'
          '${execution.pendingValidation > 0 ? ', ${execution.pendingValidation} awaiting validation' : ''}.',
        ),
      ]),
    ]);
  }

  Component _aiStatus(
    AiExecutionStatus status, {
    bool loading = false,
    CurrentBdjResult? current,
    Map<String, dynamic>? domain,
    AiExecutionReading? execution,
  }) {
    final worksheet = switch (status.worksheet) {
      ConfirmedWorksheetStatus.notEvaluated =>
        'No candidate worksheet is recorded in this confirmed review.',
      ConfirmedWorksheetStatus.historicalCandidate =>
        'Historical candidate ruleset ${status.ruleset}: ${status.historicalFindingCount} finding(s). This is not a cloud execution receipt.',
      ConfirmedWorksheetStatus.unavailable => 'Confirmed review unavailable.',
    };
    return section(classes: 'p1-card p1-ai', [
      div([
        h3(classes: 'p1-card__title', [Component.text('AI Execution Status')]),
        if (loading)
          p(classes: 'p1-muted', [Component.text('Loading verified status…')]),
        div(classes: 'p1-ai__block', [
          strong(classes: 'p1-ai__label', [
            Component.text('Business Description Judge (BDJ)'),
          ]),
          if (current != null)
            p(classes: 'p1-muted', [
              Component.text(
                'Current result status: ${current.status}. '
                'This read contract does not record an execution origin, so '
                'none is claimed here.',
              ),
            ]),
          _executionProgress(execution?.forPurpose('BDJ'), label: 'Progress'),
          _executionLine(execution?.forPurpose('BDJ')),
          if (status.m2Revision != null)
            p(classes: 'p1-muted', [
              Component.text('Confirmed M2 revision ${status.m2Revision}.'),
            ]),
          p(classes: 'p1-muted', [Component.text(worksheet)]),
        ]),
        div(classes: 'p1-ai__block', [
          strong(classes: 'p1-ai__label', [
            Component.text('Direct Question Generator (Direct-QG)'),
          ]),
          _executionProgress(execution?.forPurpose('QG'), label: 'Progress'),
          _executionLine(execution?.forPurpose('QG')),
          p(classes: 'p1-muted', [
            Component.text(
              'Eligibility, the owner\'s QG permission and generation are read '
              'separately, from the objective you approved.',
            ),
          ]),
        ]),
        // Domain results, one per execution purpose.
        //
        // These are three different questions and are reported separately on
        // purpose. An empty findings list is *not* evidence that a BDJ
        // objective run failed to persist: that run writes objective proposals,
        // not findings. Collapsing the three into one "persistence" verdict
        // would report a failure that never happened.
        if (domain != null) ...[
          div(classes: 'p1-ai__block', [
            strong(classes: 'p1-ai__label', [
              Component.text('Recorded results by purpose'),
            ]),
            p(classes: 'p1-muted', [
              Component.text(
                'BDJ findings: ${_rows(domain['findings']).length} finding(s) '
                'in the confirmed review.',
              ),
            ]),
            p(classes: 'p1-muted', [Component.text(_bdjObjectiveSummary())]),
            p(classes: 'p1-muted', [
              Component.text(
                'Direct-QG: ${_rows(domain['candidates']).length} question '
                'candidate(s) persisted for this assessment.',
              ),
            ]),
          ]),
        ],
        p(classes: 'p1-muted', [
          Component.text(
            'Source: confirmed review and research workspace. Viewing or refreshing does not invoke an AI model.',
          ),
        ]),
        div(classes: 'p1-toolbar', [
          button(
            attributes: const {'type': 'button'},
            classes: 'p1-btn p1-btn--small',
            onClick: () => setState(() {
              _message = null;
              _future = _fetch();
            }),
            [Component.text('Refresh AI status')],
          ),
        ]),
      ]),
    ]);
  }

  /// Proposal counts for Stage 3, with the owner's approval kept separate from
  /// scientific admission.
  ///
  /// The row this replaces counted `data['objectives']` — the confirmed-review
  /// objective list, which never contains a proposal — so Stage 3 printed
  /// "0 / 0 approved" directly beside a card that said "Approved by you"
  /// (DD-061). The counts now come from the BDJ proposals themselves, and a
  /// count that could not be read says so instead of printing a zero.
  ///
  /// Approval and admission are shown as two rows on purpose: an objective the
  /// owner approved can still be refused as research-unsuitable, and collapsing
  /// them would present one act as the other.
  List<Component> _objectiveCountRows() {
    final counts = _execution?.bdjObjectives;
    if (counts == null || !counts.readable) {
      return [
        _row('Objective proposals', 'Unavailable'),
        _row('Approved by you', 'Unavailable'),
        _row('Scientifically admitted', 'Unavailable'),
      ];
    }
    return [
      _row('Objective proposals', '${counts.proposed}'),
      _row('Approved by you', '${counts.approved} of ${counts.proposed}'),
      _row(
        'Scientifically admitted',
        '${counts.admitted} of ${counts.proposed}',
      ),
    ];
  }

  /// The BDJ objective line in "Recorded results by purpose".
  ///
  /// It previously counted `domain['objectives']` and labelled the result
  /// "approved objective proposal(s)". That list holds confirmed-review
  /// objectives, not proposals, so the line read 0 while two proposals were
  /// persisted and one was approved (DD-061).
  String _bdjObjectiveSummary() {
    final counts = _execution?.bdjObjectives;
    if (counts == null || !counts.readable) {
      return 'BDJ objective generation: unavailable.';
    }
    return 'BDJ objective generation: ${counts.proposed} persisted, '
        '${counts.approved} approved by you, '
        '${counts.admitted} scientifically admitted.';
  }

  Component _step3(Map<String, dynamic> data) {
    final findings = _rows(data['findings']);
    final objectives = _rows(data['objectives']);
    final intention = _rows(data['research_intention']);
    final currentBdj = data['current_bdj'] is CurrentBdjResult
        ? data['current_bdj'] as CurrentBdjResult
        : null;
    final evaluated = data['evaluation_state'] == 'EVALUATED_CANDIDATE';
    // This opens a read-only review view; the workspace callback still checks
    // the server's enterable flag. It does not complete or authorize a stage.
    final canContinue = data['source_current'] == true;

    return div(classes: 'p1-research-stage', [
      _head(
        'Business review and research goals',
        'BDJ identifies possible uncertainties and proposes research objectives. '
            'You approve or clarify them; opening this stage does not run BDJ.',
      ),
      div(classes: 'p1-cols', [
        // ------------------------------------------------ main column
        div(classes: 'p1-col', [
          // Scoped Stage 3 replacement: this slot used to hold the BDJ status
          // card and the "No proposed objective available" notice. The governed
          // proposal panel now owns the whole slot and renders only objectives
          // that pass its persisted-source checks — no placeholder proposals.
          BdjObjectiveProposalPanel(
            marketplaceAssessmentId: component.marketplaceAssessmentId,
            // An admitted objective is the evidence stage 3 waits for.
            onDecisionRecorded: component.onStageProgressChanged,
          ),

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

          // ------------------------------------------------ history
          section(classes: 'p1-card', [
            button(
              attributes: {
                'type': 'button',
                'aria-expanded': _historyOpen ? 'true' : 'false',
              },
              classes: 'p1-history__toggle',
              onClick: () => setState(() => _historyOpen = !_historyOpen),
              [
                h3(classes: 'p1-card__title', [
                  Component.text('Review history'),
                ]),
                _chip(_historyOpen ? 'Hide' : 'Show', tone: 'gray'),
              ],
            ),
            p(classes: 'p1-muted', [
              Component.text(
                'Historical candidate reviews and recorded findings. These are '
                'persisted records, not a live BDJ execution.',
              ),
            ]),
            if (_historyOpen)
              div(classes: 'p1-history__body', [
                for (final finding in findings)
                  div(classes: 'p1-finding', [
                    div(classes: 'p1-card__head', [
                      strong([
                        Component.text(
                          'Candidate business uncertainty · ${_s(finding['finding_id'])}',
                        ),
                      ]),
                      _chip(
                        _statusLabel(_s(finding['review_status'])),
                        tone: _statusTone(_s(finding['review_status'])),
                      ),
                    ]),
                    p([Component.text(_s(finding['uncertainty_text']))]),
                    p(classes: 'p1-finding__source', [
                      Component.text(
                        'Finding review: ${_s(finding['review_status'])}',
                      ),
                    ]),
                  ]),
                if (findings.isEmpty)
                  p(classes: 'p1-notice p1-notice--soft', [
                    Component.text(
                      'No historical findings are recorded for this confirmation.',
                    ),
                  ]),
                p(classes: 'p1-muted', [
                  Component.text(
                    'Source revision ${_v(data['m2_revision'])} · '
                    'ruleset ${_s(data['rule_version'])}',
                  ),
                ]),
              ]),
          ]),
        ]),

        // ------------------------------------------------ side column
        aside(classes: 'p1-col p1-col--side', [
          _sideCard('What happens here?', [
            p(classes: 'p1-muted', [
              Component.text(
                'Stage 3 reviews confirmed M2 intentions and validated BDJ findings. '
                'Entrepreneur-authored objectives are also supported.',
              ),
            ]),
            div(classes: 'p1-divider', []),
            _row('M2 confirmation', 'Current'),
            _row(
              'BDJ review',
              currentBdj != null
                  ? _statusLabel(currentBdj.status)
                  : evaluated
                  ? 'Historical only'
                  : 'Not executed',
            ),
            ..._objectiveCountRows(),
          ]),
          _sideCard('Research safeguard', [
            p(classes: 'p1-muted', [
              Component.text(
                'An objective may only be approved when its version and source '
                'identity are verified. Clarification never rewrites or approves '
                'an objective automatically.',
              ),
            ]),
            div(classes: 'p1-divider', []),
            p(classes: 'p1-muted', [
              Component.text(
                'Owner-approved objectives are research directions, not customer '
                'demand evidence.',
              ),
            ]),
          ]),
          _sideCard('Source', [
            _row('Assessment', _s(data['marketplace_assessment_id'])),
            _row('Revision', _v(data['m2_revision'])),
            _row(
              'Ruleset',
              _s(data['rule_version']).isEmpty
                  ? 'Not recorded'
                  : _s(data['rule_version']),
            ),
          ]),
        ]),
      ]),

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
    final visible = [
      for (final candidate in candidates)
        if (_matchesFilter(candidate)) candidate,
    ];
    final approvedCount = candidates
        .where((c) => _s(c['owner_review_decision']) == 'APPROVE_FOR_REVIEW')
        .length;
    final rejectedCount = candidates
        .where((c) => _s(c['owner_review_decision']) == 'REJECT')
        .length;
    final pendingCount = candidates.length - approvedCount - rejectedCount;

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
        'The questionnaire has two parts, one shown at a time. Basic is the fixed '
            'governed core, populated from your own declarations and identical in '
            'count for every assessment. Extra holds the questions generated for '
            'your approved research objectives.',
      ),
      // The blocked state is a page-level fact, so it sits above the view
      // switcher as one line rather than as a card inside the candidate list.
      if (blocked) _readinessLine(),
      div(classes: 'p1-cols', [
        div(classes: 'p1-col p1-col--main', [
          _viewTabs(data),
          // Two columns in the DOM, one on screen: these are two different kinds
          // of question — a fixed set every assessment receives, and a generated
          // set whose count depends on the objectives the owner approved.
          // `--$_view` only hides the set that is not selected; the columns
          // themselves, and every card in them, stay mounted, so switching tabs
          // fetches nothing and drops no decision.
          div(
            classes: 'p1-s4two p1-s4two--$_view',
            attributes: const {'id': 's4-view-panel'},
            [
              // `--fixed` welds the header to the list below it: the fixed core is the
              // header's content, so the two are one card, not a card plus a heading.
              div(classes: 'p1-s4col p1-s4col--fixed', [
                _columnHead(
                  // The strip already says which set is on screen, so the head
                  // names the set rather than repeating the tab's one word.
                  title: 'Governed core questions',
                  count: _coreCount(data),
                  icon: 'lock',
                  sub:
                      'Fixed for every assessment — the same count and wording each '
                      'time. These governed core questions cannot be edited, reordered '
                      'or approved here.',
                  tone: 'fixed',
                ),
                _sectionA(data),
              ]),
              div(classes: 'p1-s4col p1-s4col--gen', [
                _columnHead(
                  title: 'Generated questions',
                  // No number: these questions are read by the review surface below,
                  // not by this panel. Section B keeps its own count for the legacy
                  // version chain, which is the table this panel does read.
                  icon: 'auto_awesome',
                  sub:
                      'Generated from your approved research objectives. The count '
                      'varies; only these questions carry a review decision.',
                  tone: 'gen',
                ),
                div(classes: 'p1-banner p1-banner--inline', [
                  strong([
                    Component.text('Generated from approved objectives'),
                  ]),
                  p([
                    Component.text(
                      'Direct-QG candidates are grouped under the approved objective '
                      'that produced them. Owner predictions are expectations, not '
                      'customer observations or established demand.',
                    ),
                  ]),
                ]),
                // The approved objective, its eligibility and the questions generated
                // from it are read here, from the same component the M2 panel uses. It
                // was previously mounted only inside that panel, so the normal Stage 4
                // route never asked for them (DD-043).
                if (data['context_id'] is String &&
                    (data['context_id'] as String).isNotEmpty)
                  StageFourQuestionReview(
                    key: ValueKey(
                      's4-${data['m2_assessment_id']}-${data['m2_revision']}',
                    ),
                    m2AssessmentId: data['m2_assessment_id'] as String,
                    expectedRevision: data['m2_revision'] as int,
                    contextId: data['context_id'] as String,
                    // The panel's own transports are passed down, so this page and a
                    // component test read the same two sources through the same
                    // objects. A default here would silently reach the network from a
                    // test that believed it had replaced every read.
                    api: component.stageFourFive,
                    proposalApi: component.proposalApi,
                    // Mounted inside the Extra column, whose own header and banner
                    // already introduce this list. The surface keeps every per-card
                    // statement and drops only its page-level headings.
                    embedded: true,
                    // An approved question per verified objective is the evidence
                    // stage 4 waits for, so a stored decision may complete it.
                    onStageProgressChanged: component.onStageProgressChanged,
                  ),
                // The generation control and the candidate list for the approved
                // objective. Extra view only: in Combined the column is already dense,
                // and this card's own head would compete with the review cards above
                // it. It reads a different record set from those cards, so it stays a
                // separately titled card instead of being folded into their list.
                div(classes: 'p1-s4secb', [
                  section(classes: 'p1-card', [
                    div(classes: 'p1-filterbar', [
                      div(classes: 'p1-filterbar__left', [
                        h3(classes: 'p1-card__title', [
                          // "Section B" no longer names anything the reader can see:
                          // the page is Basic / Extra, and there is no Section A to be
                          // the first of. The head says what the card holds.
                          Component.text('Additional question candidates'),
                        ]),
                        span(classes: 'p1-filterbar__count', [
                          Component.text('(${visible.length})'),
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
                    p(classes: 'p1-muted', [
                      Component.text(
                        'Approve, Reject and Request revision apply to these additional '
                        'candidates only. They never approve a Section A core question.',
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
                          div([
                            span(classes: 'p1-group__mark', [
                              Component.text('◎'),
                            ]),
                            Component.text(
                              '${_s(objective['objective_id'])} · '
                              '${_s(objective['exact_text'])}',
                            ),
                          ]),
                          span(classes: 'p1-group__count', [
                            Component.text(
                              '${candidates.where((c) => c['source_objective_id'] == objective['objective_id'] && c['source_objective_version'] == objective['objective_version']).length} questions',
                            ),
                          ]),
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
                        // The objective the owner approved at Stage 3 carries a
                        // contract-2.1 identity (``proposal:<uuid>``), not a registry
                        // code, so it can never satisfy the context-objective test
                        // above. Without this branch the approved objective was shown
                        // with no action bound to it at all (DD-043).
                        if (objective['proposal_id'] is String &&
                            data['context_id'] is String &&
                            data['confirmation_id'] is String)
                          button(
                            attributes: const {'type': 'button'},
                            classes: 'p1-btn p1-btn--primary',
                            onClick: _generatingProposalId != null
                                ? null
                                : () => _generateForProposal(data, objective),
                            [
                              Component.text(
                                _generatingProposalId ==
                                        objective['proposal_id']
                                    ? 'Generating… ${_generatingSeconds}s'
                                    : 'Generate questions for this objective',
                              ),
                            ],
                          ),
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
                    if (candidates.isEmpty &&
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
                    if (candidates.isNotEmpty && visible.isEmpty)
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

        aside(classes: 'p1-col p1-col--side', [
          _sideCard('Research objective sources', [
            if (approvedObjectives.isEmpty)
              p(classes: 'p1-muted', [
                Component.text(
                  objectiveReadUnavailable
                      ? 'Approved objective could not be read; refresh to retry.'
                      : 'No approved objective yet.',
                ),
              ]),
            for (final objective in approvedObjectives) ...[
              div(classes: 'p1-objitem', [
                p(classes: 'p1-objitem__text', [
                  Component.text(
                    '${_s(objective['objective_id'])} · '
                    '${_s(objective['exact_text'])}',
                  ),
                ]),
                _chip('Approved', tone: 'green'),
              ]),
            ],
          ]),
          _sideCard('Review summary', [
            _row('Approved', '$approvedCount'),
            _row('Rejected', '$rejectedCount'),
            _row('Pending', '$pendingCount'),
          ]),
          _sideCard('Required checks', [
            p(classes: 'p1-muted', [
              Component.text(
                'Before any real questionnaire release: scientific review, '
                'wording and options validation, adaptive routing validation '
                'and authorized fielding.',
              ),
            ]),
            div(classes: 'p1-divider', []),
            p(classes: 'p1-muted', [
              Component.text(
                'Owner expected answers are entrepreneur predictions only and '
                'are never counted as customer responses.',
              ),
            ]),
          ]),
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
        if (ready['stage4_ready'] == true && candidates.isNotEmpty)
          button(
            attributes: const {'type': 'button'},
            classes: 'p1-btn p1-btn--primary',
            onClick: component.onOpenStage == null
                ? null
                : () => component.onOpenStage!('assessment_report'),
            [Component.text('Continue to Stage 5')],
          )
        else
          p(classes: 'p1-foot__hint', [
            Component.text(
              'Stage 5 requires saved decisions and server readiness.',
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
  /// recorded elsewhere, not an owner toggle. Every row therefore reports the
  /// approval it does *not* have, and the wording is rendered exactly as the
  /// server populated it.
  Component _sectionA(Map<String, dynamic> data) {
    final raw = data['preview_questionnaire'];
    final error = data['preview_error'];
    final preview = raw is PreviewQuestionnaire ? raw : null;

    return section(classes: 'p1-card p1-s4card', [
      p(classes: 'p1-muted', [
        Component.text(
          'The governed core questions, with your own declared business details '
          'substituted in. This is a preview of wording only.',
        ),
      ]),
      if (preview == null)
        p(classes: 'p1-notice p1-notice--warn', [
          strong(classes: 'p1-notice__title', [
            Component.text('Core questionnaire unavailable'),
          ]),
          Component.text(
            error is String && error.isNotEmpty
                ? 'The governed wording could not be loaded ($error). The Extra '
                      'tab is unaffected.'
                : 'The governed wording could not be loaded. The Extra tab is '
                      'unaffected.',
          ),
        ])
      else ...[
        p(classes: 'p1-s4meta', [
          Component.text(
            '${preview.questionCount} questions · '
            '${preview.approvedQuestionCount} scientifically approved · '
            '${preview.unresolvedRequiredSlotCount} placeholder(s) awaiting your input',
          ),
        ]),
        for (final question in preview.questions) _coreQuestion(question),
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

  /// One fixed core question: id, populated wording, response format, then the
  /// codes and the contract metadata it carries.
  ///
  /// No buttons — the fixed core carries no per-question review control by
  /// contract. Every field the previous card showed is still here; what changed
  /// is the weight: the wording leads, and the metadata sits in one muted line
  /// instead of a row of chips above it.
  Component _coreQuestion(PreviewQuestion question) {
    final unresolved = [
      for (final slot in question.unresolvedSlots)
        if (slot.required) slot,
    ];
    final meta = <String>[
      if (question.construct.trim().isNotEmpty)
        'Construct ${question.construct}',
      if (question.measurementStatus.trim().isNotEmpty)
        'Measurement: ${_measurementLabel(question.measurementStatus)}',
    ];
    return div(classes: 'p1-corerow', [
      div(classes: 'p1-corerow__top', [
        span(classes: 'p1-qid', [Component.text(question.questionId)]),
        span(classes: 'p1-corerow__q', [
          Component.text(question.populatedStem),
        ]),
        span(classes: 'p1-corerow__f', [
          Component.text(_shortType(question.responseType)),
        ]),
      ]),
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
      if (snapshot.connectionState != ConnectionState.done) {
        return div(classes: 'stack stack--md', [
          section(classes: 'p1-card', [
            div([Component.text('Loading verified research records…')]),
          ]),
          _aiStatus(AiExecutionStatus.unavailable, loading: true),
        ]);
      }
      if (snapshot.hasError || snapshot.data == null) {
        return div(classes: 'stack stack--md', [
          _notice(
            'Research integration is not ready',
            'A current authenticated research workspace could not be verified. '
                'Check the assessment, sign-in and service availability, then retry.',
          ),
          _aiStatus(AiExecutionStatus.unavailable),
        ]);
      }
      return div(classes: 'stack stack--md', [
        component.stageNumber == 3
            ? _step3(snapshot.data!)
            : _step4(snapshot.data!),
        _aiStatus(
          snapshot.data!['ai_status'] as AiExecutionStatus,
          current: snapshot.data!['current_bdj'] as CurrentBdjResult?,
          domain: snapshot.data!,
          execution: _execution,
        ),
      ]);
    },
  );
}
