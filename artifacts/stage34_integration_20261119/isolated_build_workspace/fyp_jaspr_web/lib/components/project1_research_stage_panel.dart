import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../data/app_locator.dart';

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
  String _editingObjective = '';
  String _clarificationCategory = 'FOCUS';
  String _clarification = '';
  String _editingCandidateId = '';
  String _editedQuestion = '';

  @override
  void didUpdateComponent(covariant Project1ResearchStagePanel oldComponent) {
    super.didUpdateComponent(oldComponent);
    if (oldComponent.marketplaceAssessmentId != component.marketplaceAssessmentId ||
        oldComponent.stageNumber != component.stageNumber) {
      _editingObjective = '';
      _clarification = '';
      _editingCandidateId = '';
      _editedQuestion = '';
      _message = null;
      _future = _fetch();
    }
  }

  // Only reads the M2 explicitly linked to this marketplace assessment.
  // Never infer an M2 id from its owner, creation time or list ordering.
  Future<Map<String, dynamic>> _fetch() async {
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
        assessmentId: m2Id, confirmationId: confId, revision: draft.revision);
    final workspace = await AppLocator.m2.readResearchWorkspace(m2Id, confId, draft.revision);
    // A second read prevents a revision change during the two source reads
    // from being presented as a current workspace.
    final current = await AppLocator.m2.currentConfirmation(m2Id);
    if (current == null || current['id'] != confId ||
        current['assessment_revision'] != draft.revision) {
      throw StateError('The M2 confirmation changed during the read.');
    }
    final currentLink = await AppLocator.m2.linkForMarketplace(component.marketplaceAssessmentId);
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
        'objective_version': null,
        'exact_text': row['exact_text'],
        'source_finding_ids': findingId is String ? [findingId] : <String>[],
        'approval_status': 'AUTHORITY_UNVERIFIED',
      };
    }
    final data = <String, dynamic>{
      'marketplace_assessment_id': component.marketplaceAssessmentId,
      'm2_assessment_id': m2Id,
      'confirmation_id': confId,
      'm2_revision': draft.revision,
      'source_current': true,
      'findings': [for (final finding in review.findings) {
        'finding_id': finding.id, 'uncertainty_text': finding.explanation,
        'review_status': finding.reviewState, 'source_refs': finding.sourceAnswerIds,
      }],
      'objectives': unique.values.toList(),
      // The existing workspace response does not prove objective approval,
      // objective version, candidate currentness or BCB authority.
      'candidates': <Object>[],
      'unmapped_candidate_count': workspace.rows.where((row) => row['version'] != null).length,
      'readiness': {'stage3_ready': false, 'stage4_ready': false},
    };
    if (data['marketplace_assessment_id'] != component.marketplaceAssessmentId ||
        data['m2_assessment_id'] != m2Id ||
        data['confirmation_id'] != confId ||
        data['m2_revision'] != draft.revision ||
        data['source_current'] != true) {
      throw StateError('Research workspace source identity is unverified or stale.');
    }
    if (data['findings'] is! List ||
        data['objectives'] is! List ||
        data['candidates'] is! List ||
        data['readiness'] is! Map) {
      throw StateError('Research workspace result is missing required fields.');
    }
    return data;
  }

  Future<void> _unsupportedResearchWrite() async => throw UnsupportedError(
      'The required source-bound review contract is not yet available.');

  Future<void> _commit(Future<void> Function() action) async {
    if (_saving) return;
    setState(() { _saving = true; _message = null; });
    try {
      await action();
      // Reload server state before indicating the new decision.
      final refreshed = await _fetch();
      if (!mounted) return;
      setState(() {
        _saving = false;
        _editingObjective = '';
        _clarification = '';
        _editingCandidateId = '';
        _editedQuestion = '';
        _future = Future.value(refreshed);
        _message = 'Saved and reloaded from the server.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _message = 'Could not verify the save. Nothing is marked approved; check the current source and try again.';
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

  Component _notice(String title, String message) =>
      section(classes: 'panel asw-inline', [
        div(classes: 'panel__body stack stack--md', [
          h3([Component.text(title)]),
          p([Component.text(message)]),
          button(
            attributes: const {'type': 'button'},
            classes: 'sr-button',
            onClick: () => setState(() { _message = null; _future = _fetch(); }),
            [Component.text('Retry verified read')],
          ),
        ]),
      ]);

  Component _heading(String title, String help) =>
      div(classes: 'asw-stepbar', [
        h2(classes: 'asw-stepbar__title', [Component.text(title)]),
        p(classes: 'small asw-muted', [Component.text(help)]),
      ]);

  Component _step3(Map<String, dynamic> data) {
    final findings = _rows(data['findings']);
    final objectives = _rows(data['objectives']);
    final ready = data['readiness'] as Map;
    return div(classes: 'p1-research-stage stack stack--md', [
      _heading(
        'Business review and research goals',
        'BDJ identifies possible uncertainties and proposes research objectives. '
        'You approve or clarify them; opening this stage does not run BDJ.',
      ),
      if (findings.isEmpty)
        _notice('BDJ findings unavailable in this view',
            'The confirmed-source projection did not return findings. Post-confirmation findings require a verified source integration.'),
      for (final finding in findings)
        section(classes: 'panel asw-inline p1-finding', [
          div(classes: 'panel__body stack stack--sm', [
            strong([Component.text('Candidate business uncertainty · ${_s(finding['finding_id'])}')]),
            p([Component.text(_s(finding['uncertainty_text']))]),
            p(classes: 'small asw-muted', [
              Component.text('Finding review: ${_s(finding['review_status'])}'),
            ]),
          ]),
        ]),
      for (final objective in objectives) _objectiveCard(objective, findings),
      if (objectives.isEmpty)
        _notice('No proposed objective available',
          'The server has not supplied a source-linked objective. BDJ proposal and review '
          'must be integrated before the assessment can proceed.'),
      if (objectives.isNotEmpty)
        _notice('Objective approval unavailable',
          'The current response does not establish objective version or approval authority. Approval and clarification remain held.'),
      if (_message != null) p(classes: 'notice notice-warn', [Component.text(_message!)]),
      div(classes: 'actions-row', [
        button(
          attributes: const {'type': 'button'},
          onClick: component.onOpenStage == null ? null : () => component.onOpenStage!('business_requirements'),
          classes: 'sr-button',
          [Component.text('Back to Stage 2')],
        ),
        if (ready['stage3_ready'] == true && objectives.any((o) =>
            o['approval_status'] == 'APPROVED' &&
            o['source_finding_ids'] is List &&
            (o['source_finding_ids'] as List).isNotEmpty))
          a(
            href: '/entrepreneur/assessments?id=${Uri.encodeComponent(component.propertyId)}&stage=ai_explanation',
            classes: 'sr-button',
            [Component.text('Continue to Stage 4: Question review')],
          )
        else
          p(classes: 'small asw-muted', [
            Component.text('Stage 4 awaits server-authorized research objectives.'),
          ]),
      ]),
    ]);
  }

  Component _objectiveCard(
    Map<String, dynamic> objective,
    List<Map<String, dynamic>> findings,
  ) {
    final id = _s(objective['objective_id']);
    final version = objective['objective_version'];
    final status = _s(objective['approval_status']);
    final sources = objective['source_finding_ids'];
    final validSource = sources is List && sources.isNotEmpty &&
        sources.every((sourceId) => findings.any((f) => f['finding_id'] == sourceId));
    final valid = id.isNotEmpty && version is int && version > 0 &&
        _s(objective['exact_text']).trim().isNotEmpty && validSource;
    final approved = status == 'APPROVED';
    final editing = _editingObjective == id;
    return section(classes: 'panel asw-inline p1-objective', [
      div(classes: 'panel__body stack stack--md', [
        div(classes: 'actions-row', [
          strong([Component.text('Research objective · ${id.isEmpty ? 'Unidentified' : id}')]),
          span(classes: 'small asw-muted', [
            Component.text('Version ${_v(version)} · $status'),
          ]),
        ]),
        p(classes: 'body', [Component.text(_s(objective['exact_text']))]),
        p(classes: 'small asw-muted', [
          Component.text('Linked BDJ finding(s): ${sources is List ? sources.join(', ') : 'None'}'),
        ]),
        if (!valid)
          p(classes: 'notice notice-warn', [
            Component.text('Objective version or approval authority is unverified; approval is blocked.'),
          ]),
        if (valid && !approved) ...[
          div(classes: 'actions-row', [
            button(
              attributes: const {'type': 'button'},
              classes: 'sr-button',
              onClick: _saving ? null : () => _commit(() async {
                await _unsupportedResearchWrite();
              }),
              [Component.text('Approve objective')],
            ),
            button(
              attributes: const {'type': 'button'},
              classes: 'sr-button',
              onClick: _saving ? null : () => setState(() {
                _editingObjective = editing ? '' : id;
                _clarification = '';
              }),
              [Component.text(editing ? 'Cancel clarification' : 'Clarify objective')],
            ),
          ]),
          if (editing) ...[
            p([Component.text('What part of this objective should change?')]),
            select(
              [
                option([Component.text('Target customer group')], value: 'TARGET_GROUP'),
                option([Component.text('Time or occasion')], value: 'TIME'),
                option([Component.text('Research focus')], value: 'FOCUS'),
                option([Component.text('Other relevant clarification')], value: 'OTHER'),
              ],
              value: _clarificationCategory,
              classes: 'asw-entry__select',
              onChange: (values) => setState(() =>
                  _clarificationCategory = values.isEmpty ? 'FOCUS' : values.first),
            ),
            textarea(
              rows: 3,
              classes: 'm1-textarea',
              attributes: const {'maxlength': '600', 'aria-label': 'Clarify objective'},
              onInput: (value) => setState(() => _clarification = value),
              [Component.text(_clarification)],
            ),
            button(
              attributes: const {'type': 'button'},
              classes: 'sr-button',
              onClick: _saving || _clarification.trim().isEmpty || _clarification.length > 600
                  ? null
                  : () => _commit(() async {
                    await _unsupportedResearchWrite();
                  }),
              [Component.text('Submit clarification for review')],
            ),
          ],
        ],
        if (approved)
          p(classes: 'small asw-muted', [
            Component.text('Entrepreneur-approved objective. This is a research direction, not customer demand evidence.'),
          ]),
      ]),
    ]);
  }

  Component _step4(Map<String, dynamic> data) {
    final objectives = _rows(data['objectives']);
    final candidates = _rows(data['candidates']);
    final ready = data['readiness'] as Map;
    final approvedObjectives = [
      for (final objective in objectives)
        if (objective['approval_status'] == 'APPROVED') objective,
    ];
    return div(classes: 'p1-research-stage stack stack--md', [
      _heading('Question review',
        'These questions are generated from the approved research objectives. '
        'Review the answer options, predict the most likely response (optional), '
        'and approve or reject each draft. Owner predictions are not customer responses.'),
      if (approvedObjectives.isEmpty)
        _notice('No approved objective',
          'Return to Stage 3 and approve a current, linked research objective.'),
      for (final objective in approvedObjectives) ...[
        section(classes: 'panel asw-inline p1-objective-heading', [
          div(classes: 'panel__body', [
            h3([Component.text('Research objective · ${_s(objective['objective_id'])}')]),
            p([Component.text(_s(objective['exact_text']))]),
            p(classes: 'small asw-muted', [
              Component.text('Approved version ${_v(objective['objective_version'])}'),
            ]),
          ]),
        ]),
        for (final candidate in candidates)
          if (candidate['source_objective_id'] == objective['objective_id'] &&
              candidate['source_objective_version'] == objective['objective_version'])
            _candidateCard(candidate),
      ],
      if (candidates.isEmpty && data['unmapped_candidate_count'] == 0)
        _notice('No Direct-QG candidates returned',
          'No question candidates were provided by the server. '
          'Opening Stage 4 does not automatically call a cloud model.'),
      if ((data['unmapped_candidate_count'] as int? ?? 0) > 0)
        _notice('Candidate provenance unavailable',
          'Stored questions exist, but their objective version and context cannot yet be verified for this view.'),
      if (_message != null) p(classes: 'notice notice-warn', [Component.text(_message!)]),
      div(classes: 'actions-row', [
        button(
          attributes: const {'type': 'button'},
          onClick: component.onOpenStage == null ? null : () => component.onOpenStage!('location_evidence'),
          classes: 'sr-button',
          [Component.text('Back to Stage 3')],
        ),
        if (ready['stage4_ready'] == true && candidates.isNotEmpty)
          a(
            href: '/entrepreneur/assessments?id=${Uri.encodeComponent(component.propertyId)}&stage=assessment_report',
            classes: 'sr-button',
            [Component.text('Continue to Stage 5 (subject to release gates)')],
          )
        else
          p(classes: 'small asw-muted', [
            Component.text('Stage 5 requires saved decisions and server readiness.'),
          ]),
      ]),
    ]);
  }

  Component _candidateCard(Map<String, dynamic> candidate) {
    final id = _s(candidate['candidate_id']);
    final version = _v(candidate['candidate_version']);
    final options = _rows(candidate['options']);
    final selected = _s(candidate['owner_expected_option_id']);
    final state = _s(candidate['owner_review_decision']);
    final response = _s(candidate['response_kind']);
    final optionIds = options.map((v) => _s(v['option_id'])).toSet();
    final valid = id.isNotEmpty && version.isNotEmpty &&
        _s(candidate['question_text']).trim().isNotEmpty &&
        (options.isEmpty || optionIds.every((x) => x.isNotEmpty));
    return section(classes: 'panel asw-inline p1-question-card', [
      div(classes: 'panel__body stack stack--md', [
        div(classes: 'actions-row', [
          strong([Component.text(_s(candidate['question_text']))]),
          span(classes: 'small asw-muted', [Component.text('$response · $state')]),
        ]),
        if (options.isNotEmpty) ...[
          p(classes: 'small asw-muted', [Component.text('Generated answer options:')]),
          ul(classes: 'p1-answer-options', [
            for (final item in options)
              li(classes: 'p1-answer-option', [Component.text(_s(item['label']))]),
          ]),
          p(classes: 'small asw-muted', [
            Component.text(response == 'MULTI'
              ? 'Owner prediction — most likely selected option (optional)'
              : 'Owner answer — expected customer response (optional)'),
          ]),
          select(
            [
              option([Component.text('No prediction')], value: ''),
              for (final item in options)
                option([Component.text(_s(item['label']))], value: _s(item['option_id'])),
            ],
            value: optionIds.contains(selected) ? selected : '',
            classes: 'asw-entry__select',
            attributes: const {'aria-label': 'Owner expected answer'},
            onChange: _saving || !valid ? null : (values) => _commit(() async {
              await _unsupportedResearchWrite();
            }),
          ),
        ] else
          p(classes: 'small asw-muted', [
            Component.text('No fixed choices: owner-answer dropdown not applicable.'),
          ]),
        p(classes: 'small asw-muted', [
          Component.text('Expected answers are entrepreneur predictions only; never count them in EE-01.'),
        ]),
        if (valid && _editingCandidateId == id) ...[
          p([Component.text('Revise question wording — this creates a new candidate version for review.')]),
          textarea(
            rows: 2,
            classes: 'm1-textarea',
            attributes: const {'maxlength': '400', 'aria-label': 'Revised question wording'},
            onInput: (value) => setState(() => _editedQuestion = value),
            [Component.text(_editedQuestion)],
          ),
          div(classes: 'actions-row', [
            button(
              attributes: const {'type': 'button'},
              classes: 'sr-button',
              onClick: _saving || _editedQuestion.trim().isEmpty || _editedQuestion.length > 400
                  ? null
                  : () => _commit(() async {
                    await _unsupportedResearchWrite();
                  }),
              [Component.text('Save new question revision')],
            ),
            button(
              attributes: const {'type': 'button'},
              classes: 'sr-button',
              onClick: _saving ? null : () => setState(() => _editingCandidateId = ''),
              [Component.text('Cancel edit')],
            ),
          ]),
        ],
        if (!valid)
          p(classes: 'notice notice-warn', [
            Component.text('Candidate or option identity is incomplete; review is blocked.'),
          ]),
        if (valid) div(classes: 'actions-row', [
          button(
            attributes: const {'type': 'button'},
            classes: 'sr-button',
            onClick: _saving ? null : () => setState(() {
              _editingCandidateId = id;
              _editedQuestion = _s(candidate['question_text']);
            }),
            [Component.text('Edit question')],
          ),
          button(
            attributes: const {'type': 'button'},
            classes: 'sr-button',
            onClick: _saving ? null : () => _commit(() async {
              await _unsupportedResearchWrite();
            }),
            [Component.text('Approve for review')],
          ),
          button(
            attributes: const {'type': 'button'},
            classes: 'sr-button',
            onClick: _saving ? null : () => _commit(() async {
              await _unsupportedResearchWrite();
            }),
            [Component.text('Reject candidate')],
          ),
        ]),
      ]),
    ]);
  }

  @override
  Component build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return section(classes: 'panel asw-inline', [
          div(classes: 'panel__body', [Component.text('Loading verified research records…')]),
        ]);
      }
      if (snapshot.hasError || snapshot.data == null) {
        return _notice('Research integration is not ready',
          'A current authenticated research workspace could not be verified. '
          'Check the assessment, sign-in and service availability, then retry.');
      }
      return component.stageNumber == 3
          ? _step3(snapshot.data!)
          : _step4(snapshot.data!);
    },
  );
}
