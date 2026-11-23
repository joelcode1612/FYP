import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/ai_execution_status.dart';

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

  const Project1ResearchStagePanel({
    super.key,
    required this.marketplaceAssessmentId,
    required this.propertyId,
    required this.stageNumber,
    this.onOpenStage,
  }) : assert(stageNumber == 3 || stageNumber == 4);

  @override
  State<Project1ResearchStagePanel> createState() =>
      _Project1ResearchStageState();
}

class _Project1ResearchStageState extends State<Project1ResearchStagePanel> {
  late Future<Map<String, dynamic>> _future = _fetch();
  bool _saving = false;
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
    ) =>
        {
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
      candidate('Q1', 'How would you prefer to buy coffee during weekday mornings?', [
        'Takeaway',
        'Dine-in',
        'Both, depending on the situation',
        'No clear preference',
      ]),
      candidate(
        'Q2',
        'How often would you consider buying takeaway coffee on a weekday morning?',
        ['Daily', '2–4 times per week', 'Once per week', 'Less than once per week', 'Never'],
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
                final reviewQuestion = await AppLocator.m2.readEntrepreneurQuestion(
                  candidate.version, draft.revision,
                );
                final reviewOptions = reviewQuestion['options'] as List;
                final matchingOptions = reviewOptions.length == candidate.options.length &&
                    candidate.options.every((choice) => reviewOptions.whereType<Map>().any(
                      (row) => row['code'] == choice.code && row['label'] == choice.label && row['eligible'] == true,
                    ));
                if (reviewQuestion['objective_id'] == objectiveId &&
                    reviewQuestion['question'] == candidate.question && matchingOptions) {
                  final saved = reviewQuestion['option_code'];
                  if (saved == null || candidate.options.any((choice) => choice.code == saved)) {
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
    final data = <String, dynamic>{
      'marketplace_assessment_id': component.marketplaceAssessmentId,
      'm2_assessment_id': m2Id,
      'confirmation_id': confId,
      'm2_revision': draft.revision,
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
      final readbackVerified = outcome.candidate != null &&
          _rows(refreshed['candidates']).any((row) => row['candidate_id'] == outcome.candidate!.version &&
              row['source_objective_id'] == objectiveId);
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
    await AppLocator.m2.recordOwnerReview(id, action, _reviewRationales[id] ?? '');
    final readback = await AppLocator.m2.readCandidate(id);
    if (readback.version != id || readback.decision.wireCode != action.wireCode) {
      throw StateError('Review decision readback mismatch.');
    }
  }

  Future<void> _reviseCandidate(Map<String, dynamic> candidate) async {
    if (_saving || candidate['context_id'] is! String || candidate['source_revision'] is! int) return;
    setState(() { _saving = true; _message = null; });
    try {
      final outcome = await AppLocator.m2.reviseCandidate(
        version: _s(candidate['candidate_id']), expectedRevision: candidate['source_revision'] as int,
        contextId: candidate['context_id'] as String,
      );
      final refreshed = await _fetch();
      if (!mounted) return;
      final verified = outcome.candidate != null && _rows(refreshed['candidates']).any(
        (row) => row['candidate_id'] == outcome.candidate!.version &&
          row['supersedes'] == candidate['candidate_id']);
      setState(() {
        _saving = false;
        _future = Future.value(refreshed);
        _message = verified ? 'Revised question saved and reloaded.' :
          'A revised question could not be verified. Check the current source before retrying.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() { _saving = false; _message = 'The revision request could not be verified.'; });
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

  Component _aiStatus(
    AiExecutionStatus status, {
    bool loading = false,
    CurrentBdjResult? current,
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
                'Current result status: ${current.status}. Execution origin is not verified.',
              ),
            ]),
          p(classes: 'p1-muted', [
            Component.text(
              'Cloud execution and authorization status: unavailable from the current read response.',
            ),
          ]),
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
          p(classes: 'p1-muted', [
            Component.text(
              'Execution, authorization and current candidate status: unavailable from the current read response.',
            ),
          ]),
        ]),
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

  Component _step3(Map<String, dynamic> data) {
    final findings = _rows(data['findings']);
    final objectives = _rows(data['objectives']);
    final intention = _rows(data['research_intention']);
    final currentBdj = data['current_bdj'] is CurrentBdjResult
        ? data['current_bdj'] as CurrentBdjResult
        : null;
    final evaluated = data['evaluation_state'] == 'EVALUATED_CANDIDATE';
    final approvedCount = objectives
        .where(
          (o) =>
              o['approval_status'] == 'APPROVED' ||
              o['approval_status'] == 'CONFIRMED_BY_OWNER',
        )
        .length;
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
          section(classes: 'p1-card', [
            div(classes: 'p1-card__head', [
              h3(classes: 'p1-card__title', [
                Component.text('Business uncertainty (BDJ)'),
              ]),
              _chip(
                currentBdj != null
                    ? 'Current result · ${_statusLabel(currentBdj.status)}'
                    : evaluated
                    ? 'Historical candidate review'
                    : 'Not executed',
                tone: currentBdj != null || evaluated ? 'amber' : 'gray',
              ),
            ]),
            p(classes: 'p1-muted', [
              Component.text(
                data['evaluation_state'] == 'NOT_EVALUATED'
                    ? 'BDJ cloud evaluation has not been verified for this confirmation.'
                    : 'Persisted review source: ${_s(data['rule_version'])}. '
                          'Cloud execution is not established by this record alone.',
              ),
            ]),
            // At-a-glance counts. Findings come from the current BDJ result when
            // one exists, otherwise from the persisted review rows. Objectives
            // are owner-authored, so this is a count of what the owner wrote —
            // not of anything the system generated.
            p(classes: 'p1-muted', [
              Component.text(
                '${currentBdj?.findings.length ?? findings.length} validated '
                'finding(s) · ${objectives.length} objective(s) · '
                '$approvedCount approved',
              ),
            ]),
            if (currentBdj != null)
              for (final finding in currentBdj.findings)
                div(classes: 'p1-finding', [
                  div(classes: 'p1-card__head', [
                    strong([
                      Component.text(
                        'Validated candidate · ${_s(finding['rule_id'])}',
                      ),
                    ]),
                    _chip('Validated candidate', tone: 'amber'),
                  ]),
                  p([Component.text(_s(finding['observed_condition']))]),
                  p(classes: 'p1-finding__source', [
                    Component.text(
                      finding['source_refs'] is List &&
                              (finding['source_refs'] as List).isNotEmpty
                          ? 'M2 sources: ${_rows(finding['source_refs']).map((ref) => _s(ref['item_key'])).join(', ')}'
                          : 'Finding source references unavailable.',
                    ),
                  ]),
                ]),
            if (findings.isEmpty && data['evaluation_state'] == 'NOT_EVALUATED')
              p(classes: 'p1-notice p1-notice--warn', [
                strong(classes: 'p1-notice__title', [
                  Component.text('BDJ evaluation pending'),
                ]),
                Component.text(
                  'This confirmation has no verified BDJ evaluation in this view. '
                  'Cloud review requires authorization and a verified result connection.',
                ),
              ]),
            if (findings.isEmpty && evaluated)
              p(classes: 'p1-notice p1-notice--soft', [
                strong(classes: 'p1-notice__title', [
                  Component.text('Historical candidate review: no findings'),
                ]),
                Component.text(
                  'The confirmed worksheet records no findings for its pinned ruleset. '
                  'This is not evidence of a cloud BDJ execution.',
                ),
              ]),
          ]),

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

          if (objectives.isEmpty)
            _notice(
              'No proposed objective available',
              'The server has not supplied a source-linked objective. You can confirm '
                  'your own objective when a valid M2 research intention is available.',
              tone: 'soft',
            ),
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
            _row(
              'Objectives approved',
              '$approvedCount / ${objectives.length}',
            ),
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

    // Review controls appear for any objective that is not already approved and
    // carries an identity — including the authority-unverified case. The
    // warning above states the hold; the write path reports it honestly.
    final reviewable = !approved && id.isNotEmpty && text.isNotEmpty;
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
        if (reviewable) ...[
          // Approve / Reject are the mandatory entrepreneur decisions for every
          // proposal, but the decision API is not connected yet. They are shown
          // unavailable on purpose: a button that throws is worse than one that
          // is visibly disabled, and Phase 3 is not complete until both work
          // end-to-end through the authenticated route.
          div(classes: 'p1-toolbar', [
            button(
              attributes: const {
                'type': 'button',
                'title': 'Decision API not connected yet',
                'aria-disabled': 'true',
              },
              classes: 'p1-btn p1-btn--approve',
              onClick: null,
              [Component.text('Approve objective')],
            ),
            button(
              attributes: const {
                'type': 'button',
                'title': 'Decision API not connected yet',
                'aria-disabled': 'true',
              },
              classes: 'p1-btn p1-btn--danger',
              onClick: null,
              [Component.text('Reject objective')],
            ),
          ]),
          p(classes: 'p1-muted', [
            Component.text(
              'Approve and Reject are unavailable until the decision API is connected. '
              'No proposal can be admitted as a research objective before then.',
            ),
          ]),
        ],
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
        'Stage 4 · Review question candidates',
        'Questions are organised by the approved research objective that generated '
            'them. Direct-QG runs separately and is not shown as another stage.',
      ),
      div(classes: 'p1-banner', [
        strong([Component.text('Generated from approved objectives')]),
        p([
          Component.text(
            'Direct-QG candidates are grouped under the approved objective that '
            'produced them. Owner predictions are expectations, not customer '
            'observations or established demand.',
          ),
        ]),
      ]),
      div(classes: 'p1-cols', [
        div(classes: 'p1-col', [
          if (blocked)
            section(classes: 'p1-card', [
              div(classes: 'p1-card__head', [
                h3(classes: 'p1-card__title', [
                  Component.text('Stage 4 is not ready yet'),
                ]),
                _chip('Blocked', tone: 'amber'),
              ]),
              p(classes: 'p1-notice p1-notice--warn', [
                strong(classes: 'p1-notice__title', [
                  Component.text('Server-authoritative readiness'),
                ]),
                Component.text(
                  'Stage completion is not yet available. You can inspect '
                  'verified candidates; generation and review remain subject to server checks.',
                ),
              ]),
            ]),

          section(classes: 'p1-card', [
            div(classes: 'p1-filterbar', [
              div(classes: 'p1-filterbar__left', [
                h3(classes: 'p1-card__title', [
                  Component.text('Question candidates'),
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
                    option([Component.text('All questions')], value: 'all'),
                    option([Component.text('Pending')], value: 'pending'),
                    option([
                      Component.text('Approved for review'),
                    ], value: 'approved'),
                    option([Component.text('Rejected')], value: 'rejected'),
                  ],
                  value: _candidateFilter,
                  classes: 'p1-select',
                  attributes: const {'aria-label': 'Filter question candidates'},
                  onChange: (values) => setState(
                    () => _candidateFilter = values.isEmpty
                        ? 'all'
                        : values.first,
                  ),
                ),
              ]),
            ]),
            if (approvedObjectives.isEmpty)
              p(classes: 'p1-notice p1-notice--soft', [
                strong(classes: 'p1-notice__title', [
                  Component.text('No approved objective'),
                ]),
                Component.text(
                  'Return to Stage 3 and approve a current, linked research objective.',
                ),
              ]),
            for (final objective in approvedObjectives) ...[
              div(classes: 'p1-group', [
                div(classes: 'p1-group__head', [
                  div([
                    span(classes: 'p1-group__mark', [Component.text('◎')]),
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
                if (data['context_objective_id'] == objective['objective_id'] &&
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
                for (final candidate in visible)
                  if (candidate['source_objective_id'] ==
                          objective['objective_id'] &&
                      candidate['source_objective_version'] ==
                          objective['objective_version'])
                    _candidateCard(candidate, demo: data['demo'] == true),
              ]),
            ],
            if (candidates.isEmpty && data['unmapped_candidate_count'] == 0 &&
                data['candidate_history_loaded'] == true && data['candidate_read_unavailable'] != true)
              p(classes: 'p1-notice p1-notice--soft', [
                strong(classes: 'p1-notice__title', [
                  Component.text('No Direct-QG candidates returned'),
                ]),
                Component.text(
                  'No question candidates were provided by the server. '
                  'Opening Stage 4 does not automatically call a cloud model.',
                ),
              ]),
            if (data['demo'] != true && data['candidate_history_loaded'] != true &&
                data['candidate_read_unavailable'] != true)
              p(classes: 'p1-notice p1-notice--soft', [Component.text(
                'Candidate history has not been loaded for a verified research context.',
              )]),
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

        aside(classes: 'p1-col p1-col--side', [
          _sideCard('Research objective sources', [
            if (approvedObjectives.isEmpty)
              p(classes: 'p1-muted', [
                Component.text('No approved objective yet.'),
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

  Component _candidateCard(Map<String, dynamic> candidate, {bool demo = false}) {
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
                        _demoOwnerOptions[id] =
                            values.isEmpty ? '' : values.first;
                        _future = Future.value(_demoStage4Snapshot());
                      })
                    : candidate['prediction_available'] == true && !_saving
                        ? (values) => _commit(() async {
                            final value = values.isEmpty || values.first.isEmpty ? null : values.first;
                            await AppLocator.m2.saveDesiredOption(id, candidate['source_revision'] as int, value);
                            final readback = await AppLocator.m2.readEntrepreneurQuestion(id, candidate['source_revision'] as int);
                            if (readback['option_code'] != value) throw StateError('Prediction readback mismatch.');
                          })
                        : null,
              ),
              if (!demo && candidate['prediction_available'] != true)
                p(classes: 'p1-muted', [Component.text('Expected-answer selection is unavailable for this version.')]),
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
                            await _reviewCandidate(id, ResearchReviewAction.approveForReview);
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
                  onClick: _saving ? null : () => _commit(() async {
                    await _reviewCandidate(id, ResearchReviewAction.requestRevision);
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
          p(classes: 'p1-muted', [Component.text('Revises candidate ${_s(candidate['supersedes'])}')]),
        if (_s(candidate['review_rationale']).trim().isNotEmpty)
          p(classes: 'p1-muted', [Component.text('Review reason: ${_s(candidate['review_rationale'])}')]),
        if (!demo && valid && state == 'REQUEST_REVISION' && candidate['context_id'] is String)
          button(attributes: const {'type':'button'}, classes: 'p1-btn p1-btn--small',
            onClick: _saving ? null : () => _reviseCandidate(candidate),
            [Component.text('Generate revised candidate')]),
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
        ),
      ]);
    },
  );
}
