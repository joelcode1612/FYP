import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:sitewise_jaspr_web/core/di/app_locator.dart';

/// PROJECT1 research flow UI (four logical steps, not the legacy persisted
/// property-assessment state machine).
///
/// All data are supplied by an authenticated, version-aware API adapter.
/// Callbacks must enforce ownership, optimistic version checks, authorization,
/// idempotency and audit history on the SERVER. No local action grants
/// scientific acceptance, fielding or publication authority.
///
/// Expected sequence:
/// 1 M2 (owned by the existing M2 screen)
/// 2 Review BDJ findings / confirm objective / add entrepreneur uncertainty
/// 3 Evaluate question candidates / assigned reviewer approve or reject
/// 4 Customer questionnaire preview / explicit publication decision
///
/// Add research_workflow_panel.css to the app's existing stylesheet pipeline.
/// This component intentionally uses no fabricated candidate or review data.
///
/// LOCAL ADAPTATION: the uploaded file marks this `@client`, but Jaspr's client
/// codegen cannot serialize its `ResearchWorkflowSnapshot` object or its
/// `Future<void> Function(...)` callbacks. Every `@client` shell in this app
/// takes primitive params only, and non-`@client` children (M2EntryPanel,
/// AssessmentListComponent, ...) are mounted inside such shells. This panel is
/// mounted under the primitive-param `@client` AssessmentWorkspacePage, so it
/// is deliberately a plain StatefulComponent. It still runs fully client-side.
/// When hosted by the four-step flow it is passed `hideInternalHeading: true`,
/// because that host renders the single shared stepper.

class ResearchFindingView {
  final String id;
  final String title;
  final String explanation;
  final String origin; // E.g. 'BDJ', 'ENTREPRENEUR'; source-owned.
  final String evidenceState;
  final List<String> sourceRefs;
  final String? linkedObjectiveId;

  const ResearchFindingView({
    required this.id,
    required this.title,
    required this.explanation,
    required this.origin,
    required this.evidenceState,
    this.sourceRefs = const [],
    this.linkedObjectiveId,
  });
}

class ResearchObjectiveView {
  final String id;
  final int revision;
  final String text;
  final String origin; // 'ENTREPRENEUR_M2' or 'BDJ_FINDING'.
  final String confirmationState;
  final String? parentId;
  final List<String> sourceRefs;

  const ResearchObjectiveView({
    required this.id,
    required this.revision,
    required this.text,
    required this.origin,
    required this.confirmationState,
    this.parentId,
    this.sourceRefs = const [],
  });
}

class ResearchAnswerOptionView {
  final String code;
  final String label;
  const ResearchAnswerOptionView(this.code, this.label);
}

class ResearchCandidateView {
  final String id;
  final String version;
  final String objectiveId;
  final String question;
  final String? stimulus;
  final List<ResearchAnswerOptionView> options;
  final String source; // BANK_REUSE / QG_LIVE / QG_REPLAY etc.
  final String match; // Source classification; not an owner-editable score.
  final List<String> strengths;
  final List<String> weaknesses;
  final String ownerDecision; // e.g. PENDING / APPROVE_FOR_REVIEW / REJECT.
  final String scientificState;
  final String fieldingState;
  final bool syntheticOnly;

  const ResearchCandidateView({
    required this.id,
    required this.version,
    required this.objectiveId,
    required this.question,
    required this.options,
    required this.source,
    required this.match,
    required this.ownerDecision,
    required this.scientificState,
    required this.fieldingState,
    this.strengths = const [],
    this.weaknesses = const [],
    this.stimulus,
    this.syntheticOnly = false,
  });
}

class ResearchPreviewItemView {
  final String questionId;
  final String version;
  final String text;
  final List<ResearchAnswerOptionView> options;
  final bool isAdditional;

  /// The effective manifest already defines this order. The UI does not
  /// append or route candidate questions on its own.
  const ResearchPreviewItemView({
    required this.questionId,
    required this.version,
    required this.text,
    required this.options,
    this.isAdditional = false,
  });
}

class ResearchWorkflowSnapshot {
  final String assessmentId;
  final int m2Revision;
  final String instrumentVersion;
  final bool verifiedM2Binding;
  final List<ResearchFindingView> findings;
  final List<ResearchObjectiveView> objectives;
  final List<ResearchCandidateView> candidates;
  final List<ResearchPreviewItemView> questionnaire;
  final String? releaseManifestId;
  final bool authorizedReleaseGrants;
  final bool published;
  final bool isolatedTestOnly;
  final String publicationStatus;

  const ResearchWorkflowSnapshot({
    required this.assessmentId,
    required this.m2Revision,
    required this.instrumentVersion,
    required this.verifiedM2Binding,
    this.findings = const [],
    this.objectives = const [],
    this.candidates = const [],
    this.questionnaire = const [],
    this.releaseManifestId,
    this.authorizedReleaseGrants = false,
    this.published = false,
    this.isolatedTestOnly = true,
    this.publicationStatus = 'NOT_VERIFIED',
  });
}

// The backend owns all writes; callbacks should refresh the snapshot after a
// successful commit, and throw on failure. A missing callback disables the UI.
typedef ConfirmResearchObjective = Future<void> Function(
    String assessmentId, String objectiveId, int revision);
typedef RecordFindingDisposition = Future<void> Function(
    String assessmentId, String findingId, String disposition, String rationale);
typedef RaiseResearchUncertainty = Future<void> Function(
    String assessmentId, String uncertaintyText);
typedef ReviseResearchObjective = Future<void> Function(
    String assessmentId, String objectiveId, int revision,
    String mode, String proposedText);
typedef ReviewResearchCandidate = Future<void> Function(
    String assessmentId, String candidateId, String candidateVersion,
    String decision, String rationale);
typedef RequestResearchPublication = Future<void> Function(
    String assessmentId, String releaseManifestId);
typedef WithholdResearchPublication = Future<void> Function(
    String assessmentId, String rationale);

class ResearchWorkflowPanel extends StatefulComponent {
  /// Only 2 (findings), 3 (candidate review), and 4 (customer preview/publish)
  /// are rendered here; Step 1 retains the existing M2 page.
  final int step;
  final ResearchWorkflowSnapshot snapshot;
  final bool canReviewCandidates;
  final bool hideInternalHeading; // host renders one four-step progress bar.
  final ConfirmResearchObjective? onConfirmObjective;
  final RecordFindingDisposition? onRecordFinding;
  final RaiseResearchUncertainty? onRaiseUncertainty;
  final ReviseResearchObjective? onReviseObjective;
  final ReviewResearchCandidate? onReviewCandidate;
  final RequestResearchPublication? onRequestPublish;
  final WithholdResearchPublication? onWithholdPublish;
  final Future<void> Function()? onRefresh;

  const ResearchWorkflowPanel({
    super.key,
    required this.step,
    required this.snapshot,
    this.canReviewCandidates = false,
    this.hideInternalHeading = false,
    this.onConfirmObjective,
    this.onRecordFinding,
    this.onRaiseUncertainty,
    this.onReviseObjective,
    this.onReviewCandidate,
    this.onRequestPublish,
    this.onWithholdPublish,
    this.onRefresh,
  }) : assert(step >= 2 && step <= 4);

  @override
  State<ResearchWorkflowPanel> createState() => _ResearchWorkflowState();
}

class _ResearchWorkflowState extends State<ResearchWorkflowPanel> {
  String? _expandedFinding;
  String? _activeObjective;
  String? _selectedCandidate;
  String? _dialog; // 'new_uncertainty', 'revise_objective', 'review', 'withhold'.
  String _text = '';
  String _rationale = '';
  String _mode = 'CLARIFY';
  String _decision = 'APPROVE_FOR_REVIEW';
  bool _saving = false;
  String? _notice;
  String? _error;

  @override
  void didUpdateComponent(covariant ResearchWorkflowPanel previous) {
    super.didUpdateComponent(previous);
    if (previous.snapshot.assessmentId != component.snapshot.assessmentId ||
        previous.step != component.step) {
      _expandedFinding = null;
      _activeObjective = null;
      _selectedCandidate = null;
      _dialog = null;
      _text = '';
      _rationale = '';
      _notice = null;
      _error = null;
    }
  }

  void _open(String name, {String? id, String initial = ''}) => setState(() {
    _dialog = name;
    _selectedCandidate = name == 'review' ? id : _selectedCandidate;
    _activeObjective = name == 'revise_objective' ? id : _activeObjective;
    _text = initial;
    _rationale = '';
    _error = null;
    _notice = null;
  });

  Future<void> _commit(Future<void> Function() action) async {
    if (_saving) return;
    setState(() { _saving = true; _error = null; _notice = null; });
    try {
      await action();
      if (component.onRefresh != null) await component.onRefresh!();
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dialog = null;
        _notice = 'Saved by the server. Reloaded or refreshed source state is required to verify the new decision.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Save failed. No successful change can be assumed. Review the server response.';
      });
    }
  }

  Component _button(String label, {VoidCallback? onClick, bool secondary = false,
      bool danger = false, String? testId}) => button(
    classes: 'rw-button ${secondary ? 'rw-button--outline' : ''} ${danger ? 'rw-button--danger' : ''}',
    disabled: _saving || onClick == null,
    onClick: _saving ? null : onClick,
    attributes: {'type':'button', 'data-testid': ?testId},
    [Component.text(label)],
  );

  Component _pill(String value, {bool? positive}) => span(
    classes: 'rw-pill ${positive == true ? 'rw-pill--good' : positive == false ? 'rw-pill--warn' : ''}',
    [Component.text(value)],
  );

  Component _noticeBox() => div(classes: 'rw-feedback', [
    if (_notice != null) p(classes: 'rw-success', [Component.text(_notice!)]),
    if (_error != null) p(classes: 'rw-error', [Component.text(_error!)]),
  ]);

  @override
  Component build(BuildContext context) {
    final data = component.snapshot;
    return section(classes: 'rw-workspace', attributes: {
      'data-testid':'research-workflow-step-${component.step}',
    }, [
      if (!component.hideInternalHeading) div(classes: 'rw-header', [
        div([
          h2([Component.text(component.step == 2 ? 'Findings & research objectives'
            : component.step == 3 ? 'Research question review'
            : 'Customer questionnaire preview')]),
          // LOCAL ADAPTATION: do not print a numeric "M2 revision 0" as if it
          // were a real revision when the M2 binding has not been verified.
          p(classes: 'rw-muted', [Component.text(data.verifiedM2Binding
            ? 'Assessment ${data.assessmentId} · M2 revision ${data.m2Revision} · ${data.instrumentVersion}'
            : 'Assessment ${data.assessmentId} · M2 revision not verified · ${data.instrumentVersion}')]),
        ]),
        _pill('Step ${component.step} of 4'),
      ]),
      if (!component.hideInternalHeading) div(classes: 'rw-steps', [
        for (final label in ['1 · M2', '2 · Findings', '3 · Questions', '4 · Questionnaire'])
          span(classes: 'rw-step ${label.startsWith('${component.step} ') ? 'rw-step--current' : ''}',
            [Component.text(label)]),
      ]),
      if (!data.verifiedM2Binding)
        div(classes: 'rw-alert', [Component.text('The M2 assessment binding is not verified. Viewing is permitted; write actions are disabled until the source relationship is established.')]),
      if (data.isolatedTestOnly)
        div(classes: 'rw-alert', [Component.text('Isolated/test evidence. Preview does not authorize real customer fielding or publication.')]),
      _noticeBox(),
      if (component.step == 2) _stageTwo(),
      if (component.step == 3) _stageThree(),
      if (component.step == 4) _stageFour(),
      if (_dialog != null) _dialogView(),
    ]);
  }

  Component _stageTwo() {
    final data = component.snapshot;
    return div(classes: 'rw-stack', [
      div(classes: 'rw-card', [
        div(classes: 'rw-card-head', [
          h3([Component.text('Findings requiring entrepreneur review')]),
          _pill('${data.findings.length} finding(s)'),
        ]),
        if (data.findings.isEmpty)
          p(classes: 'rw-muted', [Component.text('No BDJ findings are included in this verified source snapshot. This does not prove that the live BDJ returned no issues.')]),
        for (final finding in data.findings)
          div(classes: 'rw-list-item', [
            div(classes: 'rw-row', [
              div([
                strong([Component.text(finding.title)]),
                p(classes: 'rw-muted', [Component.text('${finding.origin} · ${finding.evidenceState}')]),
              ]),
              _button(_expandedFinding == finding.id ? 'Hide details' : 'Review finding',
                secondary: true, onClick: () => setState(() => _expandedFinding =
                  _expandedFinding == finding.id ? null : finding.id)),
            ]),
            if (_expandedFinding == finding.id) ...[
              p([Component.text(finding.explanation)]),
              p(classes: 'rw-muted', [Component.text('Source references: ${finding.sourceRefs.isEmpty ? 'Not supplied' : finding.sourceRefs.join(', ')}')]),
              div(classes: 'rw-actions', [
                _button('Confirm this uncertainty', onClick: !data.verifiedM2Binding || component.onRecordFinding == null
                  ? null : () => _commit(() => component.onRecordFinding!(data.assessmentId, finding.id, 'CONFIRM', 'Entrepreneur confirmed this uncertainty for review.'))),
                _button('Not my research priority', secondary: true, onClick: !data.verifiedM2Binding || component.onRecordFinding == null
                  ? null : () => _commit(() => component.onRecordFinding!(data.assessmentId, finding.id, 'NOT_SELECTED', 'Entrepreneur did not select this issue for customer research.'))),
              ]),
            ],
          ]),
      ]),
      div(classes: 'rw-card', [
        div(classes: 'rw-card-head', [
          h3([Component.text('Confirm the actual research objective')]),
          _button('+ Add my own uncertainty', onClick: data.verifiedM2Binding && component.onRaiseUncertainty != null
            ? () => _open('new_uncertainty') : null, testId: 'rw-add-uncertainty'),
        ]),
        if (data.objectives.isEmpty)
          p(classes: 'rw-muted', [Component.text('No confirmed or proposed research objectives were supplied. An entrepreneur-originated objective can be added without inventing a BDJ finding.')]),
        for (final objective in data.objectives)
          div(classes: 'rw-list-item', [
            div(classes: 'rw-row', [
              div([
                strong([Component.text(objective.text)]),
                p(classes: 'rw-muted', [Component.text('Origin: ${objective.origin} · Revision ${objective.revision} · ${objective.confirmationState}')]),
                if (objective.parentId != null)
                  p(classes: 'rw-muted', [Component.text('Exploratory child of ${objective.parentId}')]),
              ]),
              _pill(objective.confirmationState),
            ]),
            div(classes: 'rw-actions', [
              _button('Yes, this objective is correct', onClick: data.verifiedM2Binding && component.onConfirmObjective != null
                ? () => _commit(() => component.onConfirmObjective!(data.assessmentId, objective.id, objective.revision)) : null,
                testId:'rw-confirm-objective'),
              _button('Clarify / explore more', secondary: true, onClick: data.verifiedM2Binding && component.onReviseObjective != null
                ? () => _open('revise_objective', id: objective.id, initial: objective.text) : null,
                testId:'rw-clarify-explore'),
            ]),
          ]),
      ]),
      p(classes: 'rw-note', [Component.text('Confirming an uncertainty or objective does not invoke QJ/QG, approve a question, or start customer fielding. It only records an authorized entrepreneur decision.')]),
    ]);
  }

  bool _highRelevance(String match) =>
      match == 'MATCH' || match == 'HIGH_MATCH' || match == 'HIGH_RELEVANCE';

  Component _candidateItem(ResearchCandidateView candidate) {
    final data = component.snapshot;
    return div(classes: 'rw-list-item', [
      div(classes: 'rw-row', [
        div([
          strong([Component.text(candidate.question)]),
          p(classes: 'rw-muted', [Component.text(
            'Source: ${candidate.source} · Candidate ${candidate.id} · '
            'Version ${candidate.version}'
          )]),
        ]),
        _pill(candidate.match, positive: _highRelevance(candidate.match)),
      ]),
      if (candidate.stimulus != null && candidate.stimulus!.isNotEmpty)
        p(classes: 'rw-muted', [Component.text('Stimulus: ${candidate.stimulus}')]),
      div(classes: 'rw-options', [
        for (final option in candidate.options)
          div(classes: 'rw-option', [Component.text('${option.code} — ${option.label}')]),
      ]),
      div(classes: 'rw-cols', [
        div(classes: 'rw-subcard', [
          h4([Component.text('Supported strengths')]),
          if (candidate.strengths.isEmpty)
            p(classes: 'rw-muted', [Component.text('No verified strengths supplied')]),
          for (final strength in candidate.strengths)
            p([Component.text('• $strength')]),
        ]),
        div(classes: 'rw-subcard', [
          h4([Component.text('Weaknesses and missing evidence')]),
          if (candidate.weaknesses.isEmpty)
            p(classes: 'rw-muted', [Component.text(
              'No reviewed weaknesses supplied; this does not mean no weaknesses exist.'
            )]),
          for (final weakness in candidate.weaknesses)
            p([Component.text('• $weakness')]),
        ]),
      ]),
      div(classes: 'rw-row', [
        p(classes: 'rw-muted', [Component.text(
          'Owner: ${candidate.ownerDecision} · '
          'Scientific: ${candidate.scientificState} · '
          'Fielding: ${candidate.fieldingState}'
        )]),
        if (candidate.syntheticOnly) _pill('Synthetic / test only', positive: false),
      ]),
      div(classes: 'rw-actions', [
        _button('Approve for further review',
          onClick: component.canReviewCandidates && data.verifiedM2Binding &&
                   component.onReviewCandidate != null
            ? () { _decision = 'APPROVE_FOR_REVIEW'; _open('review', id: candidate.id); }
            : null, testId: 'rw-approve-for-review'),
        _button('Reject candidate', secondary: true, danger: true,
          onClick: component.canReviewCandidates && data.verifiedM2Binding &&
                   component.onReviewCandidate != null
            ? () { _decision = 'REJECT'; _open('review', id: candidate.id); }
            : null, testId: 'rw-reject-candidate'),
      ]),
    ]);
  }

  Component _stageThree() {
    final candidates = component.snapshot.candidates;
    final high = candidates.where((x) => _highRelevance(x.match)).toList();
    final needsReview = candidates.where((x) => !_highRelevance(x.match)).toList();
    return div(classes: 'rw-stack', [
      div(classes: 'rw-card', [
        div(classes: 'rw-card-head', [
          h3([Component.text('Question candidates · ${candidates.length}')]),
          _pill('Owner decision is separate from relevance'),
        ]),
        if (candidates.isEmpty)
          p(classes: 'rw-muted', [Component.text(
            'No candidate questions returned for this assessment. '
            'Do not synthesize a candidate locally.'
          )]),
        if (high.isNotEmpty) ...[
          h4(classes: 'rw-group-title rw-group-title--high', [
            Component.text('High relevance (${high.length})')
          ]),
          for (final candidate in high) _candidateItem(candidate),
        ],
        if (needsReview.isNotEmpty) ...[
          h4(classes: 'rw-group-title rw-group-title--low', [
            Component.text('Low, partial, or unverified relevance (${needsReview.length})')
          ]),
          for (final candidate in needsReview) _candidateItem(candidate),
        ],
      ]),
      p(classes: 'rw-note', [Component.text(
        'Relevance is the supplied candidate classification, not a scientific '
        'acceptance. An assigned reviewer may approve even a partial match '
        'for further review, or reject it, with mandatory rationale. Neither '
        'action publishes a customer question.'
      )]),
    ]);
  }

  Component _stageFour() {
    final data = component.snapshot;
    final mayRequestPublication = data.verifiedM2Binding &&
        !data.isolatedTestOnly && data.authorizedReleaseGrants &&
        data.releaseManifestId != null && component.onRequestPublish != null &&
        !data.published;
    return div(classes: 'rw-stack', [
      div(classes: 'rw-card', [
        div(classes: 'rw-card-head', [
          h3([Component.text('Customer questionnaire — effective manifest')]),
          _pill(data.releaseManifestId ?? 'No release manifest'),
        ]),
        p(classes:'rw-muted',[Component.text('Display order comes from the authorized manifest. Applicable Q01–Q13 precede any eligible additional question; this UI does not assign, reroute or force extra questions.')]),
        if (data.questionnaire.isEmpty)
          p(classes:'rw-muted',[Component.text('No effective questionnaire manifest returned. A candidate cannot be appended locally.')]),
        for (final item in data.questionnaire)
          div(classes:'rw-list-item',[
            div(classes:'rw-row',[
              strong([Component.text('${item.questionId}: ${item.text}')]),
              if (item.isAdditional) _pill('Additional question'),
            ]),
            for (final option in item.options)
              p(classes:'rw-option',[Component.text('${option.code} — ${option.label}')]),
          ]),
      ]),
      div(classes:'rw-card',[
        div(classes:'rw-card-head',[
          h3([Component.text('Publication confirmation')]),
          _pill(data.publicationStatus, positive: data.published),
        ]),
        p([Component.text(data.published
          ? 'The backend reports this release as published. Inspect the final manifest and authorization receipts.'
          : 'Questionnaire not published. Candidate approval, preview and synthetic test success do not grant customer access.')]),
        p(classes:'rw-muted',[Component.text('Scientific/fielding/publication grants verified: ${data.authorizedReleaseGrants ? 'Reported yes — server must recheck' : 'No'}')]),
        div(classes:'rw-actions',[
          _button(data.published ? 'Already published' : 'Publish questionnaire',
            onClick: mayRequestPublication ? () => _commit(() => component.onRequestPublish!(data.assessmentId, data.releaseManifestId!)) : null,
            testId:'rw-publish'),
          _button('Do not publish', secondary:true,
            onClick: data.verifiedM2Binding && component.onWithholdPublish != null && !data.published
              ? () => _open('withhold') : null, testId:'rw-withhold'),
        ]),
        if (!mayRequestPublication && !data.published)
          p(classes:'rw-note',[Component.text('Publication disabled until the server confirms the exact manifest, scientific/fielding grants, assessment ownership, production scope and active release permission. The customer form remains held.')]),
      ]),
    ]);
  }

  Component _dialogView() {
    final data = component.snapshot;
    final mode = _dialog;
    final selectedCandidate = data.candidates.where((c) => c.id == _selectedCandidate).toList();
    final selectedObjective = data.objectives.where((o) => o.id == _activeObjective).toList();
    final objective = selectedObjective.isEmpty ? null : selectedObjective.first;
    final candidate = selectedCandidate.isEmpty ? null : selectedCandidate.first;
    final title = switch(mode) {
      'new_uncertainty' => 'Add your research uncertainty',
      'revise_objective' => 'Clarify or explore the objective',
      'review' => _decision == 'REJECT' ? 'Reject question candidate' : 'Approve for further review',
      'withhold' => 'Keep questionnaire unpublished',
      _ => 'Review',
    };
    return div(classes:'rw-modal-shade',[
      section(classes:'rw-modal', attributes:{'role':'dialog','aria-modal':'false','aria-label':title,'data-testid':'rw-decision-dialog'},[
        div(classes:'rw-card-head',[
          h3([Component.text(title)]),
          _button('Close',secondary:true,onClick:() => setState(() => _dialog = null)),
        ]),
        if (mode == 'revise_objective') ...[
          p(classes:'rw-muted',[Component.text('The original objective remains versioned. Confirming a broader objective creates a governed child; it is not an automatically approved question.')]),
          div(classes:'rw-actions',[
            _button('Clarify original objective', secondary: _mode != 'CLARIFY',
              onClick:() => setState(() => _mode='CLARIFY')),
            _button('Explore one broader objective', secondary: _mode != 'EXPLORE',
              onClick:() => setState(() => _mode='EXPLORE')),
          ]),
        ],
        if (mode == 'review' && candidate != null)
          p([Component.text('Candidate ${candidate.id} (${candidate.version}) · classification ${candidate.match}. A reviewer decision does not publish this question.')]),
        if (mode == 'new_uncertainty' || mode == 'revise_objective') ...[
          label(attributes:{'for':'rw-content'},[Component.text(mode == 'new_uncertainty' ? 'Describe your uncertainty' : 'Confirmed revised research objective')]),
          // LOCAL ADAPTATION: Jaspr 0.23.5 `textarea` has no `value:`
          // parameter — its content is its children.
          textarea(id:'rw-content',rows:4,onInput:(value) => setState(() => _text=value),
            attributes:{'maxlength':'1200'},[Component.text(_text)]),
        ],
        if (mode == 'review' || mode == 'withhold') ...[
          label(attributes:{'for':'rw-rationale'},[Component.text('Rationale (required)')]),
          // LOCAL ADAPTATION: see the note on `rw-content` above.
          textarea(id:'rw-rationale',rows:4,onInput:(value) => setState(() => _rationale=value),
            attributes:{'maxlength':'1200'},[Component.text(_rationale)]),
        ],
        _noticeBox(),
        div(classes:'rw-actions',[
          _button('Cancel',secondary:true,onClick:() => setState(() => _dialog=null)),
          _button('Save decision',testId:'rw-save-dialog', onClick: !data.verifiedM2Binding ? null : () {
            if (mode == 'new_uncertainty' && _text.trim().isNotEmpty && component.onRaiseUncertainty != null) {
              _commit(() => component.onRaiseUncertainty!(data.assessmentId,_text.trim()));
            } else if (mode == 'revise_objective' && objective != null && _text.trim().isNotEmpty && component.onReviseObjective != null) {
              _commit(() => component.onReviseObjective!(data.assessmentId,objective.id,objective.revision,_mode,_text.trim()));
            } else if (mode == 'review' && candidate != null && _rationale.trim().isNotEmpty && component.onReviewCandidate != null && component.canReviewCandidates) {
              _commit(() => component.onReviewCandidate!(data.assessmentId,candidate.id,candidate.version,_decision,_rationale.trim()));
            } else if (mode == 'withhold' && _rationale.trim().isNotEmpty && component.onWithholdPublish != null) {
              _commit(() => component.onWithholdPublish!(data.assessmentId,_rationale.trim()));
            } else {
              setState(() => _error = 'Provide a rationale/objective and verify that an authorized action is available.');
            }
          }),
        ]),
        p(classes:'rw-muted',[Component.text('The server must enforce revision locks, authorization and a complete audit receipt. No action here bypasses scientific or fielding gates.')]),
      ]),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Live research-question candidate
// ---------------------------------------------------------------------------
//
// Everything below drives the CP-04 routes directly. Parsing, status rules and
// outcome classification live in `shared_logic` so the Flutter screen shows the
// same thing; this file only renders and forwards intents.
//
// What this panel deliberately does NOT do:
//  * it never calls the candidate "approved", "validated" or "ready to field";
//  * it never invents a missing business fact or a question;
//  * it never decides review authority — the server refuses an unassigned
//    reviewer and the refusal is shown verbatim;
//  * it has no QJ step and no shared-bank readiness copy (both are retired or
//    deferred by contract).

class ResearchCandidatePanel extends StatefulComponent {
  /// The confirmed research objective the candidate belongs to.
  final String objectiveId;

  /// The assessment revision the objective is pinned to. The server rejects a
  /// stale value with 409, which is rendered as a conflict.
  final int expectedRevision;

  /// The persisted business context id. Without it a candidate cannot be
  /// prepared, and the action stays disabled with the reason shown.
  final String? contextId;

  /// The objective wording, for context above the candidate.
  final String objectiveText;

  const ResearchCandidatePanel({
    super.key,
    required this.objectiveId,
    required this.expectedRevision,
    this.contextId,
    this.objectiveText = '',
  });

  @override
  State<ResearchCandidatePanel> createState() => _ResearchCandidatePanelState();
}

class _ResearchCandidatePanelState extends State<ResearchCandidatePanel> {
  bool _busy = false;
  String? _error;
  String? _notice;

  CandidatePrepareOutcome? _outcome;
  ResearchCandidate? _candidate;
  ResearchCandidateHistory? _history;
  bool _historyOpen = false;

  bool _reviewOpen = false;
  ResearchReviewAction _action = ResearchReviewAction.approveForReview;
  String _rationale = '';

  bool get _canPrepare => component.contextId != null && !_busy;

  @override
  void didUpdateComponent(covariant ResearchCandidatePanel previous) {
    super.didUpdateComponent(previous);
    if (previous.objectiveId != component.objectiveId ||
        previous.expectedRevision != component.expectedRevision ||
        previous.contextId != component.contextId) {
      _outcome = null;
      _candidate = null;
      _history = null;
      _historyOpen = false;
      _reviewOpen = false;
      _rationale = '';
      _notice = null;
      _error = null;
    }
  }

  // --- actions -------------------------------------------------------------

  Future<void> _prepare() async {
    final contextId = component.contextId;
    if (contextId == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final outcome = await AppLocator.m2.prepareCandidate(
        objectiveId: component.objectiveId,
        expectedRevision: component.expectedRevision,
        contextId: contextId,
      );
      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _candidate = outcome.candidate;
        _notice = outcome.hasCandidate
            ? 'The server stored candidate version ${outcome.candidate!.version}. '
                  'It is a proposal awaiting your decision.'
            : null;
      });
      if (outcome.hasCandidate) await _loadHistory(silent: true);
    } on FormatException {
      if (mounted) {
        setState(
          () => _error =
              'The service answered with a candidate this screen could not '
              'verify. Nothing is displayed.',
        );
      }
    } on UnauthorizedFailure {
      if (mounted) {
        setState(
          () => _error =
              'Your session is no longer authorized for this objective. Sign '
              'in again; nothing was generated.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revise() async {
    final candidate = _candidate;
    final contextId = component.contextId;
    if (candidate == null || contextId == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final outcome = await AppLocator.m2.reviseCandidate(
        version: candidate.version,
        expectedRevision: component.expectedRevision,
        contextId: contextId,
      );
      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        if (outcome.hasCandidate) _candidate = outcome.candidate;
        _notice = outcome.hasCandidate
            ? 'The server stored child version ${outcome.candidate!.version}, '
                  'which supersedes ${candidate.version}.'
            : null;
      });
      if (outcome.hasCandidate) await _loadHistory(silent: true);
    } on FormatException {
      if (mounted) {
        setState(
          () => _error =
              'The revision answered with a version this screen could not '
              'verify. Nothing is displayed.',
        );
      }
    } on UnauthorizedFailure {
      if (mounted) {
        setState(
          () => _error =
              'Your session is no longer authorized for this objective. Sign '
              'in again; no revision was generated.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadHistory({bool silent = false}) async {
    if (_busy && !silent) return;
    try {
      final history = await AppLocator.m2.candidateHistory(
        component.objectiveId,
        component.expectedRevision,
      );
      if (!mounted) return;
      setState(() {
        _history = history;
        _historyOpen = true;
        if (!silent) _notice = 'History reloaded from the server.';
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'The candidate history could not be read. The versions already '
              'on screen are unchanged.',
        );
      }
    }
  }

  Future<void> _openVersion(String version) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final stored = await AppLocator.m2.readCandidate(version);
      if (!mounted) return;
      setState(() {
        _candidate = stored;
        _outcome = null;
        _notice = 'Showing stored version $version and its recorded status.';
      });
    } on NotFoundFailure {
      if (mounted) {
        setState(
          () => _error = 'That candidate version is not available to you.',
        );
      }
    } on FormatException {
      if (mounted) {
        setState(
          () => _error =
              'The stored version could not be verified against this objective.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitReview() async {
    final candidate = _candidate;
    if (candidate == null || _busy) return;
    final rationale = _rationale.trim();
    if (rationale.isEmpty) {
      setState(
        () => _error =
            'A rationale is required. For a revision it is the reason the next '
            'question must address.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await AppLocator.m2.recordOwnerReview(candidate.version, _action, rationale);
      // Re-read the version: the status shown must be the server's, not the
      // one this screen assumed.
      final refreshed = await AppLocator.m2.readCandidate(candidate.version);
      if (!mounted) return;
      setState(() {
        _candidate = refreshed;
        _reviewOpen = false;
        _rationale = '';
        _notice =
            'The server recorded "${_action.wireCode}" for version '
            '${candidate.version}.';
      });
      await _loadHistory(silent: true);
    } on NotFoundFailure {
      if (mounted) {
        setState(
          () => _error =
              'No current pending review assignment exists for you on this '
              'version, so nothing was recorded.',
        );
      }
    } on ConflictFailure catch (failure) {
      if (mounted) {
        setState(
          () => _error = candidateConflictExplanation(failure.backendCode),
        );
      }
    } on UnauthorizedFailure {
      if (mounted) {
        setState(
          () => _error =
              'Your session is no longer authorized to record this decision. '
              'Nothing was recorded.',
        );
      }
    } on FormatException {
      if (mounted) {
        setState(
          () => _error =
              'The server answered with a decision this screen could not '
              'verify. Reload the version before acting again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // --- rendering -----------------------------------------------------------

  Component _button(
    String label, {
    VoidCallback? onClick,
    bool secondary = false,
    bool danger = false,
    String? testId,
  }) => button(
    classes:
        'rw-button ${secondary ? 'rw-button--outline' : ''} '
        '${danger ? 'rw-button--danger' : ''}',
    disabled: _busy || onClick == null,
    onClick: _busy ? null : onClick,
    attributes: {'type': 'button', 'data-testid': ?testId},
    [Component.text(label)],
  );

  Component _pill(String value, {bool? positive}) => span(
    classes:
        'rw-pill ${positive == true ? 'rw-pill--good' : positive == false ? 'rw-pill--warn' : ''}',
    [Component.text(value)],
  );

  Component _facts(String title, List<String> values, {String empty = 'None supplied'}) =>
      div(classes: 'rw-subcard', [
        h4([Component.text(title)]),
        if (values.isEmpty) p(classes: 'rw-muted', [Component.text(empty)]),
        for (final value in values) p([Component.text('• $value')]),
      ]);

  Component _proposalMarker(FieldAuthority authority) => div(classes: 'rw-proposal', [
    span(classes: 'rw-proposal__badge', [
      Component.text(
        authority.isProposal
            ? 'PROPOSAL — not confirmed'
            : 'AUTHORITY FLAG PRESENT — review before use',
      ),
    ]),
    p(classes: 'rw-proposal__text', [Component.text(candidateProposalNotice)]),
    p(classes: 'rw-muted', [
      Component.text('Server flags: ${authority.flagSummary}'),
    ]),
  ]);

  Component _candidateCard(ResearchCandidate candidate) {
    final actions = reviewActionsFor(candidate.decision);
    return div(classes: 'rw-card', attributes: {
      'data-testid': 'rw-candidate-card',
    }, [
      div(classes: 'rw-card-head', [
        h3([Component.text('Question candidate')]),
        _pill(candidate.decision.label, positive: false),
      ]),
      p(classes: 'rw-muted', [
        Component.text(
          'Version ${candidate.version}'
          '${candidate.supersedes == null ? '' : ' · supersedes ${candidate.supersedes}'}'
          '${candidate.recordedAt == null ? '' : ' · decided ${candidate.recordedAt}'}',
        ),
      ]),
      if (component.objectiveText.isNotEmpty)
        p(classes: 'rw-muted', [
          Component.text('Objective: ${component.objectiveText}'),
        ]),
      p(classes: 'rw-question', [Component.text(candidate.question)]),
      if (candidate.options.isEmpty)
        p(classes: 'rw-muted', [
          Component.text('The candidate returned no answer options.'),
        ])
      else
        div(classes: 'rw-options', [
          for (final option in candidate.options)
            div(classes: 'rw-option', [
              Component.text('${option.code} — ${option.label}'),
            ]),
        ]),
      _proposalMarker(candidate.fieldAuthority),
      if (candidate.referencePeriod != null)
        p([Component.text('Reference period: ${candidate.referencePeriod}')]),
      if (candidate.measurementDescription != null)
        p([
          Component.text(
            'Measurement: ${candidate.measurementDescription}',
          ),
        ]),
      if (candidate.denominatorSpecification != null)
        p([
          Component.text(
            'Denominator: ${candidate.denominatorSpecification}',
          ),
        ]),
      if (candidate.constructInterpretation != null)
        p(classes: 'rw-muted', [
          Component.text(
            'How the objective was read: ${candidate.constructInterpretation}',
          ),
        ]),
      div(classes: 'rw-cols', [
        _facts('Limitations', candidate.limitations),
        _facts('Unresolved assumptions', candidate.unresolvedAssumptions),
      ]),
      if (candidate.rationale != null)
        p(classes: 'rw-muted', [
          Component.text('Recorded rationale: ${candidate.rationale}'),
        ]),
      if (actions.isEmpty)
        p(classes: 'rw-note', [
          Component.text(
            'This version already has a recorded decision. A decision is '
            'terminal: asking for a revision creates a child version instead of '
            'reopening this one.',
          ),
        ]),
      div(classes: 'rw-actions', [
        for (final action in actions)
          _button(
            action.label,
            secondary: action != ResearchReviewAction.approveForReview,
            danger: action == ResearchReviewAction.reject,
            testId: 'rw-review-${action.wireCode.toLowerCase()}',
            onClick: () => setState(() {
              _action = action;
              _rationale = '';
              _reviewOpen = true;
              _error = null;
              _notice = null;
            }),
          ),
        if (canGenerateRevision(candidate.decision))
          _button(
            'Generate revision',
            secondary: true,
            testId: 'rw-generate-revision',
            onClick: _revise,
          ),
      ]),
      p(classes: 'rw-note', [Component.text(candidateReviewAssignmentNotice)]),
    ]);
  }

  Component _abstentionCard(CandidatePrepareOutcome outcome) => div(
    classes: 'rw-card',
    attributes: {'data-testid': 'rw-candidate-abstention'},
    [
      div(classes: 'rw-card-head', [
        h3([Component.text('What we still need to know')]),
        _pill('No question drafted', positive: false),
      ]),
      p([
        Component.text(
          'The engine could not draft a question from your confirmed facts, so '
          'it named the facts that are missing. This is a valid answer, not a '
          'failure.',
        ),
      ]),
      if (outcome.missingBusinessFacts.isEmpty)
        p(classes: 'rw-muted', [
          Component.text(
            'The answer did not name a specific fact. Add the confirmed detail '
            'the question needs, then prepare again.',
          ),
        ])
      else
        for (final code in outcome.missingBusinessFacts)
          div(classes: 'rw-list-item', [
            strong([Component.text(missingBusinessFactLabel(code))]),
            p(classes: 'rw-muted', [Component.text('Fact code: $code')]),
          ]),
      p(classes: 'rw-note', [
        Component.text(
          'No candidate was stored. Add the confirmed fact to your business '
          'understanding, then prepare the question again.',
        ),
      ]),
    ],
  );

  Component _refusalCard(CandidatePrepareOutcome outcome) {
    final copy = candidateRefusalCopy(outcome);
    return div(classes: 'rw-alert', attributes: {
      'data-testid': 'rw-candidate-refusal',
    }, [
      strong([Component.text(copy.title)]),
      p([Component.text(copy.body)]),
      if (outcome.code != null)
        p(classes: 'rw-muted', [Component.text('Server code: ${outcome.code}')]),
    ]);
  }

  Component _historyCard() {
    final history = _history;
    return div(classes: 'rw-card', [
      div(classes: 'rw-card-head', [
        h3([Component.text('Version history')]),
        _button(
          _historyOpen ? 'Refresh history' : 'Show history',
          secondary: true,
          testId: 'rw-history-toggle',
          // Written as a block, not a conditional expression: a `? a() : () {}`
          // arrow returns the closure instead of calling it.
          onClick: () {
            if (_historyOpen) {
              _loadHistory();
            } else {
              setState(() => _historyOpen = true);
              _loadHistory();
            }
          },
        ),
      ]),
      if (!_historyOpen)
        p(classes: 'rw-muted', [
          Component.text(
            'Open the history to see every stored version and its recorded '
            'decision. Opening it changes nothing.',
          ),
        ])
      else if (history == null)
        p(classes: 'rw-muted', [Component.text('Loading stored versions…')])
      else if (history.versions.isEmpty)
        p(classes: 'rw-muted', [
          Component.text('No stored version exists for this objective yet.'),
        ])
      else ...[
        p(classes: 'rw-muted', [
          Component.text(
            '${history.versions.length} stored '
            '${history.versions.length == 1 ? 'version' : 'versions'}, oldest '
            'first. A recorded decision is shown exactly as stored.',
          ),
        ]),
        for (final version in history.versions)
          div(classes: 'rw-list-item', [
            div(classes: 'rw-row', [
              div([
                strong([Component.text(version.question)]),
                p(classes: 'rw-muted', [
                  Component.text(
                    'Version ${version.version}'
                    '${version.supersedes == null ? '' : ' · supersedes ${version.supersedes}'}',
                  ),
                ]),
                if (version.rationale != null)
                  p(classes: 'rw-muted', [
                    Component.text('Rationale: ${version.rationale}'),
                  ]),
              ]),
              _pill(version.decision.label, positive: false),
            ]),
            div(classes: 'rw-actions', [
              _button(
                'Open this version',
                secondary: true,
                onClick: () => _openVersion(version.version),
              ),
            ]),
          ]),
      ],
    ]);
  }

  Component _reviewDialog() {
    final candidate = _candidate;
    if (candidate == null) return Component.fragment(const []);
    final isRevision = _action == ResearchReviewAction.requestRevision;
    return div(classes: 'rw-modal-shade', [
      section(
        classes: 'rw-modal',
        attributes: {
          'role': 'dialog',
          'aria-modal': 'false',
          'aria-label': _action.label,
          'data-testid': 'rw-candidate-decision-dialog',
        },
        [
          div(classes: 'rw-card-head', [
            h3([Component.text(_action.label)]),
            _button(
              'Close',
              secondary: true,
              onClick: () => setState(() => _reviewOpen = false),
            ),
          ]),
          p([
            Component.text(
              'Version ${candidate.version}. Your decision is recorded against '
              'this version only; it does not publish the question or authorize '
              'fielding.',
            ),
          ]),
          label(attributes: {'for': 'rw-candidate-rationale'}, [
            Component.text(
              isRevision
                  ? 'Reason for the revision (required — the next question must '
                        'address it)'
                  : 'Rationale (required)',
            ),
          ]),
          textarea(
            id: 'rw-candidate-rationale',
            rows: 4,
            onInput: (value) => setState(() => _rationale = value),
            attributes: {'maxlength': '1000'},
            [Component.text(_rationale)],
          ),
          if (_error != null) p(classes: 'rw-error', [Component.text(_error!)]),
          div(classes: 'rw-actions', [
            _button(
              'Cancel',
              secondary: true,
              onClick: () => setState(() => _reviewOpen = false),
            ),
            _button(
              'Record decision',
              testId: 'rw-candidate-save-decision',
              onClick: _submitReview,
            ),
          ]),
        ],
      ),
    ]);
  }

  @override
  Component build(BuildContext context) {
    final candidate = _candidate;
    final outcome = _outcome;
    final refused = outcome != null &&
        outcome.kind != CandidateOutcomeKind.validated &&
        outcome.kind != CandidateOutcomeKind.abstention;
    return section(
      classes: 'rw-workspace',
      attributes: {'data-testid': 'research-candidate-panel'},
      [
        div(classes: 'rw-header', [
          div([
            h2([Component.text('Research question candidate')]),
            p(classes: 'rw-muted', [
              Component.text(
                'Prepare a candidate from this objective, read it, and record '
                'your decision. Generated fields are proposals only.',
              ),
            ]),
          ]),
          _pill('Proposal workflow', positive: false),
        ]),
        if (component.contextId == null)
          div(classes: 'rw-alert', [
            Component.text(
              'A persisted business context is required before a candidate can '
              'be prepared. Read the business-context status for this '
              'confirmation first; this panel will not invent one.',
            ),
          ]),
        if (_notice != null) p(classes: 'rw-success', [Component.text(_notice!)]),
        if (_error != null && !_reviewOpen)
          p(classes: 'rw-error', [Component.text(_error!)]),
        div(classes: 'rw-actions', [
          _button(
            'Prepare question',
            testId: 'rw-prepare-candidate',
            onClick: _canPrepare ? _prepare : null,
          ),
        ]),
        if (outcome != null && outcome.isAbstention) _abstentionCard(outcome),
        if (refused) _refusalCard(outcome),
        if (candidate != null) _candidateCard(candidate),
        if (candidate == null && outcome == null && component.contextId != null)
          p(classes: 'rw-muted', [
            Component.text(
              'No candidate has been prepared in this session. Preparing one '
              'calls the live engine; it does not reuse a previous answer.',
            ),
          ]),
        _historyCard(),
        if (_reviewOpen) _reviewDialog(),
      ],
    );
  }
}
