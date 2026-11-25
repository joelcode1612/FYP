/// Stage 4 — Question review.
///
/// Reads the owner's proposals, each proposal's admission state, and — only for
/// a proposal that is genuinely ADMITTED against a fixed objective — the
/// persisted candidate versions for that objective.
///
/// It never drafts a question. Every string on this page came from a persisted
/// row, and when no question exists the page names the gate that is holding it
/// rather than showing an unexplained blank: "no questions" and "the measurement
/// is not approved" are different situations for the reader.
///
/// The three review decisions write to `m2_candidate_owner_reviews`. They record
/// an opinion about a candidate; none of them authorises fielding, and the
/// server returns `fielding_authorized: false` on every one of them, which the
/// page asserts rather than assumes.
library;

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'package:sitewise_jaspr_web/features/assessment/data/bdj_objective_proposal.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/bdj_objective_proposal_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage_four_five_api.dart';

class StageFourQuestionReview extends StatefulComponent {
  const StageFourQuestionReview({
    super.key,
    required this.m2AssessmentId,
    required this.expectedRevision,
    required this.contextId,
    this.api = const StageFourFiveApi(),
    this.proposalApi = const BdjObjectiveProposalApi(),
    this.embedded = false,
    this.onStageProgressChanged,
  });

  final String m2AssessmentId;
  final int expectedRevision;
  final String contextId;
  final StageFourFivePort api;
  final BdjObjectiveProposalPort proposalApi;

  /// Called after a review decision was stored.
  ///
  /// Stage 4 completes when every verified objective carries an approved
  /// question, and those approvals happen here. This panel therefore reports
  /// the save so the owning page can re-read the assessment record — that is
  /// what moves the count from 3/5 (60%) to 4/5 (80%). A notification, not a
  /// completion claim: the server still decides, and the caller re-reads.
  final VoidCallback? onStageProgressChanged;

  /// True when this surface is mounted inside another page's column.
  ///
  /// The standalone mount is a page and needs its own title and section heads.
  /// Embedded, those heads repeat the column header and the banner directly
  /// above them, so they are dropped — but nothing else is: every per-card
  /// statement about what a review does and does not do stays.
  final bool embedded;

  @override
  State<StageFourQuestionReview> createState() => _StageFourState();
}

class _StageFourState extends State<StageFourQuestionReview> {
  bool _loading = true;
  String? _error;
  List<BdjObjectiveProposal> _proposals = const [];
  final Map<String, ProposalAdmission> _admissions = {};
  // Contract 2.1: the owner's approval is the authority, so an approved
  // proposal has a derived objective identity even though no admission row
  // exists. Kept separate from `_admissions` because the two are different
  // records and merging them would imply an admission was read.
  final Map<String, ObjectiveAuthority> _authorities = {};

  /// The owner's QG processing permission, per proposal. Absent means not read
  /// yet, which the interface reports as unknown rather than as "not granted".
  final Map<String, QgConsent> _consents = {};
  bool _grantingConsent = false;
  final Map<String, QuestionHistory> _histories = {};
  final Map<String, QuestionReviewDetail> _details = {};
  final Map<String, String> _rationale = {};
  final Map<String, String> _decisionError = {};
  final Map<String, QuestionReviewReceipt> _receipts = {};
  bool _saving = false;

  // -- Direct-QG candidate readback -----------------------------------------
  //
  // Separate state from the legacy review-question surface on purpose. The two
  // read different tables: `m2_qg_candidates` holds the generated question, and
  // `m2_review_question_versions` holds the older per-objective version chain.
  // Merging them into one list would imply they are the same record.
  List<QgCandidate> _candidates = const [];
  String? _candidateError;
  final Map<String, QgEligibility> _eligibility = {};
  final Map<String, String> _qgError = {};
  bool _qgBusy = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _admissions.clear();
      _authorities.clear();
      _consents.clear();
      _histories.clear();
      _details.clear();
      _eligibility.clear();
      _candidateError = null;
      _candidates = const [];
    });
    final listed = await component.proposalApi.list(
      assessmentId: component.m2AssessmentId,
      expectedRevision: component.expectedRevision,
      contextId: component.contextId,
    );
    if (!mounted) return;
    if (!listed.ok) {
      setState(() {
        _loading = false;
        _error =
            listed.failure?.message ??
            'The proposals could not be read for this confirmation.';
      });
      return;
    }
    final proposals = listed.value!.proposals;
    // One objective's reads run as their own chain, and the objectives run
    // concurrently. The chain per objective is genuinely sequential (an
    // admission decides whether a history exists, a history decides which
    // version to detail), but the objectives do not depend on each other.
    // Running them one after another put the panel in "Reading question
    // records…" for roughly forty seconds on a two-objective assessment, which
    // reads as a hang rather than as a load.
    await Future.wait([
      for (final proposal in proposals) _loadProposal(proposal),
    ]);
    if (!mounted) return;

    // The Direct-QG candidate list is fetched on its own, not derived from the
    // proposals: a fixed O1..O6 admission carries no proposal, so a candidate can
    // legitimately exist with no proposal to hang it from. A failure here is
    // reported separately and does not blank the proposal surface.
    final candidateList = await component.api.candidates(
      assessmentId: component.m2AssessmentId,
    );
    if (!mounted) return;
    final candidates = candidateList.ok
        ? candidateList.value!
        : const <QgCandidate>[];
    final candidateError = candidateList.ok
        ? null
        : candidateList.failure?.message ??
              'The Direct-QG candidates could not be read.';

    // Eligibility is asked per objective, for every objective that either has an
    // admitted proposal or already carries a candidate. Asking about nothing
    // would return the most recent admission of any objective, which is a
    // different question.
    final objectives = <String>{
      for (final authority in _authorities.values)
        if (authority.objectiveId.isNotEmpty) authority.objectiveId,
      for (final admission in _admissions.values)
        if (admission.isAdmitted &&
            (admission.objectiveId ?? '').isNotEmpty)
          admission.objectiveId!,
      for (final candidate in candidates)
        if (candidate.objectiveId.isNotEmpty) candidate.objectiveId,
    };
    // Concurrent for the same reason as the per-objective reads above: each
    // report is independent, and a waterfall of them is what made this panel
    // take half a minute to settle.
    await Future.wait([
      for (final objectiveId in objectives)
        component.api
            .eligibility(
              assessmentId: component.m2AssessmentId,
              objectiveId: objectiveId,
            )
            .then((report) {
              if (mounted && report.ok) _eligibility[objectiveId] = report.value!;
            })
            .catchError((_) {
              // An unread report leaves the objective's eligibility unknown,
              // which the block states rather than filling in.
            }),
    ]);
    if (!mounted) return;

    setState(() {
      _proposals = proposals;
      _candidates = candidates;
      _candidateError = candidateError;
      _loading = false;
    });
  }

  /// Every read this objective needs, in the order the answers determine it.
  ///
  /// Nothing here throws out of the future: a transport failure on one
  /// objective must not blank the others or leave the panel in its reading
  /// state. Each failed read simply leaves its map entry absent, which the
  /// cards report as an unread value rather than as a passed check.
  Future<void> _loadProposal(BdjObjectiveProposal proposal) async {
    try {
      final admission = await component.api.admission(
        assessmentId: component.m2AssessmentId,
        proposalId: proposal.proposalId,
        expectedRevision: component.expectedRevision,
        contextId: component.contextId,
      );
      if (!mounted || !admission.ok) return;
      final value = admission.value!;
      _admissions[proposal.proposalId] = value;
      final objectiveId = value.objectiveId;
      if (value.isAdmitted && objectiveId != null && objectiveId.isNotEmpty) {
        final history = await component.api.history(
          objectiveId: objectiveId,
          expectedRevision: component.expectedRevision,
        );
        if (!mounted || !history.ok) return;
        _histories[objectiveId] = history.value!;
        // The review surface only ever shows the leaf version: the server's
        // entrepreneur-review read refuses a superseded one, so asking for an
        // older version would produce a 404 the page cannot explain.
        final versions = history.value!.versions;
        if (versions.isNotEmpty) {
          final current = versions.last;
          final detail = await component.api.reviewQuestion(
            version: current.version,
            expectedRevision: component.expectedRevision,
          );
          if (!mounted) return;
          if (detail.ok) _details[current.version] = detail.value!;
        }
      }
      // A proposal the owner approved is sufficient authority under 2.1. Ask
      // the server for the objective identity it establishes instead of
      // composing `proposal:<uuid>` here, which would put a server contract in
      // the browser.
      if (proposal.reviewState != BdjReviewState.approved) return;
      final derived = await component.api.objectiveAuthority(
        assessmentId: component.m2AssessmentId,
        proposalId: proposal.proposalId,
        contextId: component.contextId,
      );
      if (!mounted || !derived.ok || !derived.value!.isApproved) return;
      _authorities[proposal.proposalId] = derived.value!;
      // The permission is read, never assumed. A failed read leaves the entry
      // absent so the control says so instead of offering a grant that may
      // already exist.
      final consent = await component.api.qgConsent(
        assessmentId: component.m2AssessmentId,
        proposalId: proposal.proposalId,
      );
      if (!mounted) return;
      if (consent.ok) _consents[proposal.proposalId] = consent.value!;
    } catch (_) {
      // Reported by the card as an unread value, never as a passed check.
    }
  }

  String _stateLabel(BdjReviewState state) => switch (state) {
    BdjReviewState.approved => 'Approved by you',
    BdjReviewState.rejected => 'Rejected by you',
    BdjReviewState.pending => 'Awaiting your decision',
    BdjReviewState.unrecognised => 'Review state unreadable',
  };

  /// The admission badge, in the same words Stage 3 uses for the same value.
  ///
  /// It used to print `admission.state` directly, so Stage 4 showed the wire
  /// token (`ADMISSION_NOT_RESEARCH_SUITABLE_…` in the reason, `UNKNOWN` in the
  /// badge) while Stage 3 showed a sentence. One server value, two projections,
  /// two vocabularies — this is the single vocabulary.
  String _admissionBadge(ProposalAdmission admission) =>
      switch (admission.parsedState) {
        BdjAdmissionState.admitted => 'Admitted',
        BdjAdmissionState.held => 'Held',
        BdjAdmissionState.notAdmissible => 'Not admissible',
        BdjAdmissionState.unrecognised => 'Admission unreadable',
      };

  /// One sentence for an admission that is not `ADMITTED`.
  ///
  /// The server distinguishes "the owner has not decided yet" (`HELD`) from
  /// "the candidate policy says a customer survey cannot answer this"
  /// (`NOT_ADMISSIBLE` + `ADMISSION_NOT_RESEARCH_SUITABLE_*`). Stage 4 rewrote
  /// both as *"The owner has not recorded that this gap is worth researching"*,
  /// which (a) told the owner to take an action that cannot change the outcome
  /// and (b) discarded the server's own refusal. The server's
  /// `pending_requirement` is used verbatim whenever it is present; the switch
  /// is only the fallback for a payload that carried none.
  String _admissionSentence(ProposalAdmission admission) {
    final pending = admission.pendingRequirement;
    if (pending != null && pending.isNotEmpty) return pending;
    final code = admission.reason.isEmpty ? '' : ' (${admission.reason})';
    return switch (admission.parsedState) {
      BdjAdmissionState.admitted => 'Admitted for question generation$code.',
      BdjAdmissionState.held =>
        'Approved by you but held by the server$code. No objective admission '
            'has been recorded for this proposal yet.',
      BdjAdmissionState.notAdmissible =>
        'Not admissible$code. The server refused this objective; the refusal is '
            'a result, not an owner step you have left undone.',
      BdjAdmissionState.unrecognised =>
        'The admission state could not be read from the server.',
    };
  }

  /// The first prerequisite that is missing, in the order the server checks it.
  ///
  /// This is what makes the stage truthful: an absent question is attributed to
  /// a named gate rather than left as an unexplained blank.
  ///
  /// Three different things can hold a question back and they are named
  /// separately, because an owner reading this page needs to know which one they
  /// can act on:
  ///
  /// * the objective decision (an owner action, on Stage 3);
  /// * the admission (a server policy result — sometimes not an owner action);
  /// * QG eligibility (a per-objective measurement property, reported check by
  ///   check under the objective itself).
  String _blockerFor(BdjObjectiveProposal proposal) {
    final admission = _admissions[proposal.proposalId];
    if (!proposal.reviewState.hasDecision) {
      return 'Not approved yet. Approve the objective on Stage 3 before a '
          'question can be prepared.';
    }
    if (proposal.reviewState == BdjReviewState.rejected) {
      return 'Rejected. No question is prepared for a rejected objective.';
    }
    final authority = _authorities[proposal.proposalId];
    if (admission == null) {
      // Under contract 2.1 there is no admission to read: the approval is the
      // authority, and the server has already confirmed it still describes this
      // revision. Reporting "admission could not be read" here would describe
      // the removal of a step as a failure.
      if (authority != null) return '';
      return 'The admission state could not be read for this proposal.';
    }
    if (!admission.isAdmitted) {
      return _admissionSentence(admission);
    }
    if (admission.objectiveId == null) {
      return 'Admitted, but the admission binds no fixed objective. A novel '
          'candidate is not a measurement target until it is registered.';
    }
    if (!admission.qgEligible) {
      // The admission's own precondition, not the objective's eligibility
      // report. Conflating them would make an admitted objective look
      // ineligible for research reasons when only its admission is incomplete.
      return 'Admitted, but the admission does not yet satisfy the QG '
          'precondition'
          '${admission.qgBlocker == null ? '' : ' (${admission.qgBlocker})'}. '
          'This is the admission record, not the objective\'s eligibility.';
    }
    final history = _histories[admission.objectiveId];
    if (history == null) {
      return 'No question has been prepared for ${admission.objectiveId}.';
    }
    if (history.versions.isEmpty) {
      return 'No question version exists for ${admission.objectiveId}.';
    }
    return '';
  }

  /// Records the owner's explicit QG processing permission for one objective.
  ///
  /// The echo sent back is the disclosure the interface is displaying, term by
  /// term. The server re-derives every one of them and refuses any disagreement,
  /// so this cannot widen what the owner agreed to. The full production consent
  /// surface is deferred (DD-022); this is the minimum control that makes a
  /// genuine grant possible without fabricating one.
  Future<void> _grantConsent(BdjObjectiveProposal proposal) async {
    if (_grantingConsent) return;
    final disclosure =
        _consents[proposal.proposalId]?.disclosure ?? const <String, dynamic>{};
    setState(() {
      _grantingConsent = true;
      _candidateError = null;
    });
    try {
      final result = await component.api.grantQgConsent(
        assessmentId: component.m2AssessmentId,
        proposalId: proposal.proposalId,
        contextId: component.contextId,
        echo: {
          'granted': true,
          'disclosure_version': disclosure['contract_version'],
          'provider': disclosure['provider'],
          'purpose': disclosure['purpose'],
          'endpoint': disclosure['endpoint'],
          'model': disclosure['model'],
        },
      );
      if (!mounted) return;
      setState(() {
        _grantingConsent = false;
        if (result.ok) {
          _consents[proposal.proposalId] = result.value!;
        } else {
          _candidateError =
              result.failure?.message ??
              'The QG permission could not be recorded.';
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _grantingConsent = false;
        _candidateError = 'The QG permission could not be recorded: $error';
      });
    }
  }

  Future<void> _decide(String version, String decision) async {
    setState(() {
      _saving = true;
      _decisionError.remove(version);
    });
    final result = await component.api.recordReview(
      version: version,
      decision: decision,
      rationale: (_rationale[version] ?? '').trim(),
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (result.ok) {
        _receipts[version] = result.value!;
      } else {
        _decisionError[version] =
            result.failure?.message ??
            'The decision could not be recorded.';
      }
    });
    // Only on success: a refused decision must not trigger a re-read that
    // could be mistaken for the record having changed.
    if (result.ok) component.onStageProgressChanged?.call();
  }

  Future<void> _expect(String version, String? code) async {
    setState(() {
      _saving = true;
      _decisionError.remove(version);
    });
    final result = await component.api.selectDesiredOption(
      version: version,
      expectedRevision: component.expectedRevision,
      optionCode: code,
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (result.ok) {
        final detail = _details[version];
        if (detail != null) {
          _details[version] = QuestionReviewDetail(
            version: detail.version,
            objectiveId: detail.objectiveId,
            question: detail.question,
            options: detail.options,
            desiredOption: result.value,
          );
        }
      } else {
        _decisionError[version] =
            result.failure?.message ??
            'The expected answer could not be recorded.';
      }
    });
  }

  Component _optionRow(QuestionOption option, {String? expected}) => div(
    classes: 's4-option',
    [
      span(classes: 's4-option__code', [Component.text(option.code)]),
      span(classes: 's4-option__label', [Component.text(option.label)]),
      if (option.eligible == false)
        span(classes: 's4-badge s4-badge--muted', [
          Component.text('not selectable'),
        ]),
      if (expected != null && expected == option.code)
        span(classes: 's4-badge s4-badge--objective', [
          Component.text('your expectation'),
        ]),
    ],
  );

  /// One persisted version.
  ///
  /// When the review view for this version loaded, its options are used instead
  /// of the history projection: only that read carries the server's per-option
  /// `eligible` flag and the recorded expectation, so rendering history's
  /// options would silently drop both.
  Component _candidateCard(
    ResearchQuestionCandidate candidate,
    QuestionReviewDetail? detail,
  ) {
    final options = detail?.options ?? candidate.options;
    return div(
      classes: 's4-candidate',
      [
        div(classes: 's4-candidate__head', [
          span(classes: 's4-badge', [Component.text(candidate.status)]),
          span(
            classes: 'sr-muted',
            [Component.text('version ${candidate.version}')],
          ),
          if (candidate.supersedes != null)
            span(
              classes: 'sr-muted',
              [Component.text('supersedes ${candidate.supersedes}')],
            ),
        ]),
        p(classes: 's4-question', [Component.text(candidate.question)]),
        div(classes: 's4-options', [
          for (final option in options)
            _optionRow(option, expected: detail?.desiredOption),
        ]),
        if (candidate.rationale != null && candidate.rationale!.isNotEmpty)
          p(classes: 'sr-muted', [
            Component.text('Recorded rationale: ${candidate.rationale!}'),
          ]),
      ],
    );
  }

  /// Selection constraints as the server stated them, never inferred.
  String _constraintText(QuestionReviewDetail detail) {
    final eligible = [
      for (final option in detail.options)
        if (option.eligible == true) option.code,
    ];
    final ineligible = [
      for (final option in detail.options)
        if (option.eligible == false) option.code,
    ];
    final parts = <String>[];
    if (eligible.isNotEmpty) parts.add('selectable: ${eligible.join(', ')}');
    if (ineligible.isNotEmpty) {
      parts.add('not selectable: ${ineligible.join(', ')}');
    }
    if (parts.isEmpty) {
      return 'The server did not report a per-option selection constraint.';
    }
    return 'Selection constraints — ${parts.join('; ')}.';
  }

  Component _reviewControls(
    QuestionHistory history,
    ResearchQuestionCandidate current,
  ) {
    final detail = _details[current.version];
    if (detail == null) {
      return p(classes: 'sr-muted', [
        Component.text(
          'The review view for version ${current.version} could not be read, so '
          'no decision control is offered.',
        ),
      ]);
    }
    final receipt = _receipts[current.version];
    final failure = _decisionError[current.version];
    final decided = receipt != null;
    final expected = detail.desiredOption;
    return div(classes: 's4-review', [
      p(classes: 'sr-muted', [Component.text(_constraintText(detail))]),
      p(classes: 'sr-muted', [
        Component.text(
          'Response format: the question is answered by selecting from the '
          'options above. No response format beyond that is recorded for this '
          'version, so none is shown.',
        ),
      ]),
      // The entrepreneur's expectation. Explicitly not a respondent answer.
      div(classes: 's4-review__block', [
        p(classes: 's4-review__label', [
          Component.text('Your expected answer (optional)'),
        ]),
        p(classes: 'sr-muted', [
          Component.text(
            'This records what you expect the answer to be. It is not a '
            'respondent answer and is never counted in a CQ or EE-01 '
            'calculation.',
          ),
        ]),
        div(classes: 's4-row', [
          for (final option in detail.options)
            if (option.eligible != false)
              button(
                classes: expected == option.code
                    ? 'sr-button sr-button--quiet is-selected'
                    : 'sr-button sr-button--quiet',
                attributes: {'type': 'button'},
                onClick: _saving ? null : () => _expect(current.version, option.code),
                [Component.text('Expect ${option.code}')],
              ),
          if (expected != null)
            button(
              classes: 'sr-button sr-button--quiet',
              attributes: {'type': 'button'},
              onClick: _saving ? null : () => _expect(current.version, null),
              [Component.text('Clear expectation')],
            ),
        ]),
        if (expected != null)
          p(classes: 'sr-muted', [
            Component.text('Recorded expectation: $expected.'),
          ]),
      ]),
      div(classes: 's4-review__block', [
        p(classes: 's4-review__label', [Component.text('Your decision')]),
        textarea(
          rows: 2,
          classes: 'm1-textarea',
          attributes: {'aria-label': 'review rationale'},
          onInput: (value) => _rationale[current.version] = value,
          [
            Component.text(
              _rationale[current.version] ??
                  (current.rationale ?? ''),
            ),
          ],
        ),
        div(classes: 's4-row', [
          button(
            classes: 'sr-button',
            attributes: {'type': 'button'},
            onClick: _saving ? null : () => _decide(current.version, 'APPROVE_FOR_REVIEW'),
            [Component.text('Approve for review')],
          ),
          button(
            classes: 'sr-button sr-button--quiet',
            attributes: {'type': 'button'},
            onClick: _saving ? null : () => _decide(current.version, 'REQUEST_REVISION'),
            [Component.text('Request revision')],
          ),
          button(
            classes: 'sr-button sr-button--quiet',
            attributes: {'type': 'button'},
            onClick: _saving ? null : () => _decide(current.version, 'REJECT'),
            [Component.text('Reject')],
          ),
        ]),
        p(classes: 'sr-muted', [
          Component.text(
            'A decision records your review. It does not accept the question '
            'scientifically and does not authorise fielding.',
          ),
        ]),
      ]),
      if (failure != null)
        p(classes: 's4-blocked', [Component.text(failure)]),
      if (decided)
        div(classes: 's4-review__block', [
          p(classes: 'sr-muted', [
            Component.text(
              'Recorded decision: ${receipt.decision}.',
            ),
          ]),
          if (receipt.fieldingAuthorized || receipt.scientificAcceptance)
            p(classes: 's4-blocked', [
              Component.text(
                'The server reported fielding or scientific acceptance on this '
                'decision. That would be a change in authority — stop and review '
                'it rather than continuing.',
              ),
            ])
          else
            p(classes: 'sr-muted', [
              Component.text(
                'The server confirmed fielding authorisation is still false and '
                'scientific acceptance was not granted.',
              ),
            ]),
        ]),
    ]);
  }

  // -- Direct-QG candidate surface ------------------------------------------

  /// The execution provenance, stated as three distinguishable situations.
  ///
  /// A simulated candidate and a live candidate differ by more than a label: the
  /// simulator writes a provider name but no ledger run. Reporting the mode alone
  /// would let a reader mistake a simulated question for live evidence, and
  /// reporting `dispatched` alone would not say which provider was used.
  String _executionLine(QgCandidate candidate) {
    final provider = candidate.modelProvider.isEmpty
        ? 'an unnamed provider'
        : candidate.modelProvider;
    if (candidate.isSimulated) {
      return 'Execution: SIMULATED via $provider. '
          'No provider call produced this question — the ledger has no run for '
          'it. This is a simulator artifact, not live TokenHarbour evidence.';
    }
    if (!candidate.dispatched) {
      return 'Execution: ${candidate.executionMode} via $provider, but no ledger '
          'run exists for this candidate, so no provider was called.';
    }
    final attempt = candidate.attemptNo == null ? '' : ', attempt ${candidate.attemptNo}';
    return 'Execution: ${candidate.executionMode} via $provider, ledger run '
        '${candidate.runId}$attempt.';
  }

  String _statusClass(String status) => switch (status) {
    'PASS' => 's4-badge s4-badge--pass',
    'FAIL' => 's4-badge s4-badge--fail',
    _ => 's4-badge s4-badge--warn',
  };

  /// The proposal a candidate was generated for, when it is in this payload.
  ///
  /// Two routes, both written by the server. A candidate generated against a
  /// recorded admission carries `proposal_id`. A candidate generated against a
  /// contract-2.1 derived objective carries no admission row, and its
  /// `objective_id` *is* the derived identity `proposal:<proposal_id>`. Reading
  /// that prefix is not a guess about the relationship — it is the relationship,
  /// as the server spelled it — and without it the card would say the objective
  /// wording was unavailable while holding the id that names it.
  BdjObjectiveProposal? _proposalFor(QgCandidate candidate) {
    final id = (candidate.proposalId ?? '').isNotEmpty
        ? candidate.proposalId!
        : (candidate.objectiveId.startsWith('proposal:')
              ? candidate.objectiveId.substring('proposal:'.length)
              : '');
    if (id.isEmpty) return null;
    for (final proposal in _proposals) {
      if (proposal.proposalId == id) return proposal;
    }
    return null;
  }

  /// True when the record names a period the answer actually refers to.
  ///
  /// A generator that was given no confirmed window writes a sentence saying so
  /// into `reference_period` rather than leaving the field null, so a non-empty
  /// value is not evidence that a period exists. Reading it as one would let the
  /// interface imply a frequency estimate the item cannot support.
  bool _hasReferencePeriod(QgCandidate candidate) {
    final period = (candidate.referencePeriod ?? '').trim().toLowerCase();
    return period.isNotEmpty && !period.startsWith('not specified');
  }

  /// What the recorded format and period let the answer be read as.
  ///
  /// Both facts are on the record and both change what the result can support.
  /// A single-choice answer with no reference period cannot produce a frequency,
  /// and saying so here is cheaper than a reader assuming it can.
  String _readingNote(QgCandidate candidate) {
    final format = switch (candidate.responseFormat.toUpperCase()) {
      'SINGLE_SELECT' || 'SINGLE_CHOICE' => 'One choice only.',
      'MULTI_SELECT' || 'MULTI_CHOICE' => 'More than one choice may be selected.',
      '' => 'No response format is recorded for this candidate.',
      _ => 'Response format ${candidate.responseFormat}.',
    };
    final basis = _hasReferencePeriod(candidate)
        ? 'Reference period: ${candidate.referencePeriod!.trim()}'
        : 'No reference period is confirmed, so the answer cannot support a '
              'frequency estimate.';
    return '$format $basis';
  }

  /// The owner's intended answer, named rather than marked.
  ///
  /// Absent is stated as absent. A blank space next to a label would leave the
  /// reader unable to tell "not recorded" from "recorded as none".
  String _intendedAnswerLine(QgCandidate candidate) {
    final code = candidate.review.expectedOptionCode;
    if (code == null || code.isEmpty) {
      return 'None recorded. Clicking an option above records what you expect; '
          'clicking it again clears it.';
    }
    final label = candidate.options
        .where((opt) => opt.code == code)
        .map((opt) => opt.label)
        .join();
    return label.isEmpty
        ? 'You expect respondents to choose $code.'
        : 'You expect respondents to choose $code — $label.';
  }

  /// Gaps that are computable from the candidate record itself.
  ///
  /// Deliberately narrow. These are not opinions about wording; each one is a
  /// field that is absent, or a governed code that is missing from the option
  /// set, and a reviewer who has to spot them unaided approves by default.
  ///
  /// The absent reference period is not repeated here: `_readingNote` states it
  /// directly under the wording, where it changes how the answer reads.
  List<String> _reviewFlags(QgCandidate candidate) {
    final flags = <String>[];
    if (candidate.options.isNotEmpty &&
        !candidate.options.any(
          (opt) => opt.code.toUpperCase() == 'PREFER_NOT_TO_ANSWER',
        )) {
      flags.add(
        'No opt-out option. Every governed core question (Q01–Q13) offers '
        'PREFER_NOT_TO_ANSWER, so a respondent who will not answer this item '
        'has no route out of it.',
      );
    }
    if (candidate.measurementId == null) {
      flags.add(
        'No measurement bound to this question. Nothing on the record says '
        'which approved measurement its options operationalise.',
      );
    }
    return flags;
  }

  /// The eligibility report, check by check.
  ///
  /// Rendered even when everything passes: the reader needs to know *which*
  /// requirement was examined, not merely that some aggregate said yes.
  ///
  /// The two axes carry the contract's own names — `generation` and
  /// `scientific` (`sitewise-qg-generation-eligibility/2`). They used to be
  /// printed as `prepare` / `dispatch`, which are v1 words the server no longer
  /// emits, and the requirement list was read from a key that no longer exists,
  /// so a report full of refusals rendered as two `UNVERIFIED` badges and an
  /// empty list.
  Component _eligibilityBlock(QgEligibility report) {
    final blocker = report.firstBlocker;
    return div(classes: 's4-eligibility', [
      div(classes: 's4-row', [
        // The report belongs to an objective, not to a question, so it names
        // the objective it was computed for. Without this the block would be
        // indistinguishable between two objectives that both fail the same way.
        span(classes: 's4-badge s4-badge--muted', [
          Component.text(report.objectiveId ?? 'objective not recorded'),
        ]),
        span(classes: _statusClass(report.prepareStatus), [
          Component.text('generation ${report.prepareStatus}'),
        ]),
        span(classes: _statusClass(report.dispatchStatus), [
          Component.text('scientific ${report.dispatchStatus}'),
        ]),
        if (report.measurementVersion != null)
          span(classes: 's4-badge s4-badge--objective', [
            Component.text(report.measurementVersion!),
          ]),
      ]),
      // The server's own refusal codes, verbatim. They are the reason a
      // generation button would be refused, and paraphrasing them would remove
      // the only string an operator can search the logs for.
      if (report.prepareRefusal.isNotEmpty)
        p(classes: 's4-muted', [
          Component.text('Generation refused: ${report.prepareRefusal}'),
        ]),
      if (report.dispatchRefusal.isNotEmpty)
        p(classes: 's4-muted', [
          Component.text('Scientific refused: ${report.dispatchRefusal}'),
        ]),
      p(classes: 'sr-muted', [
        Component.text(
          'Generation requirements, in the order the server checks them:',
        ),
      ]),
      if (report.checks.isEmpty)
        p(classes: 's4-blocked', [
          Component.text(
            'The server returned no generation checks for this objective, so '
            'nothing is claimed about its eligibility.',
          ),
        ]),
      for (final check in report.checks)
        div(classes: 's4-check', [
          span(classes: _statusClass(check.status), [
            Component.text(check.status),
          ]),
          span(classes: 's4-check__title', [Component.text(check.title)]),
          span(classes: 's4-check__code', [
            Component.text(
              check.reasonCode.isEmpty ? check.checkId : check.reasonCode,
            ),
          ]),
        ]),
      if (report.scientificChecks.isNotEmpty) ...[
        p(classes: 'sr-muted', [
          Component.text(
            'Scientific requirements — whether a measurement that applies to '
            'this objective has been approved. A separate axis from generation: '
            'a question can be generatable and still not measurable.',
          ),
        ]),
        for (final check in report.scientificChecks)
          div(classes: 's4-check', [
            span(classes: _statusClass(check.status), [
              Component.text(check.status),
            ]),
            span(classes: 's4-check__title', [Component.text(check.title)]),
            span(classes: 's4-check__code', [
              Component.text(
                check.reasonCode.isEmpty ? check.checkId : check.reasonCode,
              ),
            ]),
          ]),
      ],
      if (blocker != null && blocker.evidence.isNotEmpty)
        p(classes: 'sr-muted', [
          Component.text(
            'Evidence for ${blocker.reasonCode}: '
            '${blocker.evidence.entries.map((e) => '${e.key}=${e.value}').join('; ')}',
          ),
        ]),
      p(classes: 'sr-muted', [
        Component.text(
          'This report is diagnostic. A generation status of PASS would still '
          'not authorise a provider call — the runner re-verifies every '
          'condition against the real request.',
        ),
      ]),
    ]);
  }

  Future<void> _decideQg(QgCandidate candidate, String decision) async {
    setState(() {
      _qgBusy = true;
      _qgError.remove(candidate.candidateId);
    });
    final result = await component.api.reviewCandidate(
      assessmentId: component.m2AssessmentId,
      candidateId: candidate.candidateId,
      decision: decision,
      // No rationale is collected on this screen. The decision itself is the
      // whole record; an empty string says so rather than inventing a reason.
      rationale: '',
      expectedRevision: component.expectedRevision,
    );
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _qgBusy = false;
        _qgError[candidate.candidateId] =
            result.failure?.message ?? 'The decision could not be recorded.';
      });
      return;
    }
    // The receipt echoes only the decision and the authority flags, so the
    // persisted review is read back rather than reconstructed from the receipt.
    final refreshed = await component.api.candidates(
      assessmentId: component.m2AssessmentId,
    );
    if (!mounted) return;
    final receipt = result.value!;
    setState(() {
      _qgBusy = false;
      if (refreshed.ok) _candidates = refreshed.value!;
      if (receipt.fieldingAuthorized || receipt.scientificallyAccepted) {
        _qgError[candidate.candidateId] =
            'The server reported fielding authorisation or scientific '
            'acceptance on this decision. That is a change in authority — stop '
            'and review it rather than continuing.';
      }
    });
    // A QG decision is a stage-4 review decision like any other: approving the
    // last outstanding question is what completes the stage, so the owner has
    // to be told the record may have moved.
    component.onStageProgressChanged?.call();
  }

  Future<void> _expectQg(QgCandidate candidate, String? code) async {
    setState(() {
      _qgBusy = true;
      _qgError.remove(candidate.candidateId);
    });
    final result = await component.api.setExpectedAnswer(
      assessmentId: component.m2AssessmentId,
      candidateId: candidate.candidateId,
      optionCode: code,
      expectedRevision: component.expectedRevision,
    );
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _qgBusy = false;
        _qgError[candidate.candidateId] =
            result.failure?.message ??
            'The expected answer could not be recorded.';
      });
      return;
    }
    final refreshed = await component.api.candidates(
      assessmentId: component.m2AssessmentId,
    );
    if (!mounted) return;
    setState(() {
      _qgBusy = false;
      if (refreshed.ok) _candidates = refreshed.value!;
    });
  }

  /// The review controls for one persisted candidate.
  /// The decision row for one candidate.
  ///
  /// The rationale box that used to sit here is gone: it asked for prose before
  /// every decision, and the decision itself is what the record needs. The
  /// expectation control lives on the option rows themselves, so the same two
  /// labels are never listed twice in one card.
  Component _qgReviewControls(QgCandidate candidate) {
    final failure = _qgError[candidate.candidateId];
    return div(classes: 's4-decide', [
      div(classes: 's4-decide__btns', [
        button(
          classes: 's4-btn s4-btn--primary',
          attributes: {'type': 'button'},
          onClick: _qgBusy
              ? null
              : () => _decideQg(candidate, 'APPROVE_FOR_REVIEW'),
          [Component.text('Approve for review')],
        ),
        button(
          classes: 's4-btn',
          attributes: {'type': 'button'},
          onClick: _qgBusy
              ? null
              : () => _decideQg(candidate, 'REQUEST_REVISION'),
          [Component.text('Request revision')],
        ),
        button(
          classes: 's4-btn s4-btn--ghost',
          attributes: {'type': 'button'},
          onClick: _qgBusy ? null : () => _decideQg(candidate, 'REJECT'),
          [Component.text('Reject')],
        ),
      ]),
      p(classes: 's4-decide__note', [
        Component.text(
          'A decision records your review. It does not accept the question '
          'scientifically and does not authorise fielding.',
        ),
      ]),
      if (failure != null) p(classes: 's4-blocked', [Component.text(failure)]),
    ]);
  }

  /// One answer option, and the expectation control at the same time.
  ///
  /// The expectation used to be a second list of buttons underneath, which
  /// printed the same two labels twice in one card. Here the option row is the
  /// control: clicking records the expectation, clicking the chosen row clears
  /// it. Nothing about the answer itself is implied — the row is still just an
  /// option.
  Component _qgOption(QgCandidate candidate, CandidateOption option) {
    final chosen = candidate.review.expectedOptionCode == option.code;
    return button(
      classes: 's4-opt${chosen ? ' is-chosen' : ''}',
      attributes: {'type': 'button', 'aria-pressed': chosen.toString()},
      events: events(
        onClick: _qgBusy
            ? null
            : () => _expectQg(candidate, chosen ? null : option.code),
      ),
      [
        span(classes: 's4-opt__radio', []),
        span(classes: 's4-opt__code', [Component.text(option.code)]),
        span(classes: 's4-opt__label', [Component.text(option.label)]),
        if (chosen)
          span(classes: 's4-opt__mark', [Component.text('intended answer')]),
      ],
    );
  }

  /// One persisted Direct-QG candidate, with everything a reviewer must see
  /// before judging it.
  ///
  /// The wording leads; the question is the thing being judged. Provenance and
  /// validation fold into a disclosure underneath, because the 21 audit fields
  /// were previously printed open in a grid that outweighed the question itself
  /// by roughly four to one.
  /// The candidate cards, with each objective's eligibility report printed
  /// exactly once.
  ///
  /// Two candidates can share an objective (a retry produces a second row for
  /// the same slot). Printing the same requirement list under both would read
  /// as two separate assessments of the same objective, so the first card for
  /// an objective carries it and the rest point back at it.
  List<Component> _qgCards() {
    final printed = <String>{};
    return [
      for (final candidate in _candidates)
        _qgCard(candidate, showEligibility: printed.add(candidate.objectiveId)),
    ];
  }

  Component _qgCard(QgCandidate candidate, {bool showEligibility = true}) {
    final review = candidate.review;
    final report = _eligibility[candidate.objectiveId];
    final proposal = _proposalFor(candidate);
    final objectiveText = proposal?.recommendation.researchObjective;
    return section(
      classes: 's4-card',
      [
        // -- what this question was generated for -----------------------------
        //
        // Subordinate to the question, and labelled. The objective and the
        // question used to sit at the same weight in two different panels, so
        // the objective sentence was read as the questionnaire wording. It is
        // not: it is the research aim the question is supposed to serve, and
        // the reader needs to hold both to judge whether the question serves it.
        div(classes: 's4-objref', [
          div(classes: 's4-objref__head', [
            span(classes: 's4-objref__k', [
              Component.text('Research objective'),
            ]),
            span(classes: 's4-badge s4-badge--objective', [
              Component.text(candidate.objectiveId),
            ]),
            if (proposal != null)
              span(classes: 's4-badge', [Component.text('approved by you')]),
          ]),
          if (objectiveText == null || objectiveText.isEmpty)
            p(classes: 's4-objref__text s4-objref__text--absent', [
              Component.text(
                'The candidate record carries the objective identity but not '
                'its wording, so none is printed here rather than one being '
                'reconstructed. The wording is on the objective card below.',
              ),
            ])
          else
            p(classes: 's4-objref__text', [Component.text(objectiveText)]),
          p(classes: 's4-objref__note', [
            Component.text(
              'Not a questionnaire question. The wording below is what a '
              'respondent would read.',
            ),
          ]),
        ]),

        // -- the question head -------------------------------------------------
        div(classes: 's4-card__head', [
          span(classes: 's4-qhead__label', [
            Component.text('Generated question'),
          ]),
          span(classes: 's4-id', [Component.text(candidate.candidateId)]),
          // Each token keeps its own text node: the values are the server's, and
          // joining them into one string would make them unaddressable and
          // unassertable.
          div(classes: 's4-card__meta', [
            span([Component.text(candidate.candidateState)]),
            span([Component.text(candidate.objectiveClassification)]),
            span([Component.text(candidate.responseFormat)]),
          ]),
          span(classes: 's4-card__spacer', []),
          if (review.reviewed)
            span(classes: 's4-pill s4-pill--done', [
              Component.text('reviewed: ${review.decision}'),
            ]),
          // The one badge that must never be missed. A simulated candidate is a
          // simulator artifact, and it looks identical to a live one apart from
          // this.
          if (candidate.isSimulated)
            span(classes: 's4-pill s4-pill--risk', [
              Component.text('simulated — not live evidence'),
            ])
          else if (!candidate.dispatched)
            span(classes: 's4-pill s4-pill--risk', [
              Component.text('no ledger run'),
            ])
          else
            span(classes: 's4-pill s4-pill--live', [
              Component.text('dispatched'),
            ]),
        ]),

        // The question itself. Verbatim, because a paraphrase would be a
        // second wording that no reviewer actually judged.
        p(classes: 's4-q', [Component.text(candidate.question)]),
        // What the recorded format and period allow the answer to be read as.
        p(classes: 's4-qhint', [Component.text(_readingNote(candidate))]),

        div(classes: 's4-opts', [
          for (final option in candidate.options)
            _qgOption(candidate, option),
          if (candidate.options.isEmpty)
            p(classes: 's4-blocked', [
              Component.text(
                'This candidate records no answer options, so it cannot be '
                'fielded or reviewed as a closed question.',
              ),
            ]),
        ]),

        // -- the owner's intended answer --------------------------------------
        //
        // Promoted out of the option rows into a named field. It was a small
        // uppercase tag on the chosen row, which read as a property of the
        // option rather than as a separate record the owner is making. It is a
        // prediction about respondents, not an answer, and the box says so.
        if (candidate.options.isNotEmpty)
          div(classes: 's4-answer', [
            div(classes: 's4-answer__head', [
              span(classes: 's4-answer__k', [
                Component.text('Your intended answer'),
              ]),
              if (candidate.review.expectedOptionCode != null)
                button(
                  classes: 's4-answer__clear',
                  attributes: {'type': 'button'},
                  onClick: _qgBusy
                      ? null
                      : () => _expectQg(candidate, null),
                  [Component.text('Clear')],
                ),
            ]),
            p(classes: 's4-answer__v', [
              Component.text(_intendedAnswerLine(candidate)),
            ]),
            p(classes: 's4-answer__note', [
              Component.text(
                'Your own prediction of what respondents will choose. It is not '
                'a respondent answer, it is not shown to respondents, and it is '
                'never counted in a CQ or EE-01 calculation.',
              ),
            ]),
          ]),

        // Execution provenance, stated as its own strip so a simulator artifact
        // cannot be mistaken for live evidence.
        div(classes: 's4-exec', [
          span(
            classes:
                's4-dot ${candidate.dispatched ? 'is-live' : 'is-risk'}',
            [],
          ),
          span([Component.text(_executionLine(candidate))]),
        ]),

        // -- what this record does not establish -------------------------------
        //
        // Only statements computable from the record itself. A reviewer who has
        // to notice these gaps unaided approves the question by default.
        if (_reviewFlags(candidate).isNotEmpty)
          div(classes: 's4-flags', [
            p(classes: 's4-flags__k', [
              Component.text('What this record does not establish'),
            ]),
            for (final flag in _reviewFlags(candidate))
              p(classes: 's4-flags__i', [Component.text(flag)]),
          ]),

        if (review.reviewed)
          div(classes: 's4-record', [
            p(classes: 's4-record__label', [
              Component.text('Recorded review'),
            ]),
            p(classes: 's4-record__body', [
              Component.text(
                'Decision: ${review.decision}'
                '${review.recordedAt == null ? '' : ' · recorded ${review.recordedAt}'}',
              ),
            ]),
            if ((review.rationale ?? '').isNotEmpty)
              p(classes: 's4-record__body', [
                Component.text('Rationale: ${review.rationale}'),
              ]),
          ]),

        // The generator's own account of what it did and what the item cannot
        // support. Folded: two paragraphs of prose at 11px outweighed every
        // other statement on the card, and the two gaps that actually change a
        // review decision are already named above in the flags block.
        if (candidate.justification != null || candidate.limitations != null)
          details(classes: 's4-aud', [
            summary(classes: 's4-aud__toggle', [
              Component.text("Generator's justification and limitations"),
            ]),
            if (candidate.justification != null)
              p(classes: 's4-muted', [
                Component.text('Justification: ${candidate.justification}'),
              ]),
            if (candidate.limitations != null)
              p(classes: 's4-muted', [
                Component.text('Limitations: ${candidate.limitations}'),
              ]),
          ]),

        // Rendered once per objective, not once per candidate: the requirements
        // are a property of the objective, so repeating them inside every card
        // implied they differed per question. The suppressed cards say where the
        // report went, because a silently missing block reads as "not checked".
        if (report != null)
          showEligibility
              ? _eligibilityBlock(report)
              : p(classes: 's4-muted', [
                  Component.text(
                    'Generation requirements for this objective are reported once, '
                    'under its first question above.',
                  ),
                ]),

        // -- the three authorities this card does not carry --------------------
        //
        // One strip, read at a glance, instead of a sentence about two booleans
        // with a third authority (the measurement) buried in the audit grid.
        // All three are reported by the server and are expected to be negative;
        // if one ever is not, the strip changes and that is the signal.
        div(classes: 's4-auth', [
          span(
            classes:
                's4-auth__i${candidate.fieldingAuthorized ? ' is-on' : ''}',
            [
              Component.text(
                candidate.fieldingAuthorized
                    ? 'Fielding authorised'
                    : 'Fielding not authorised',
              ),
            ],
          ),
          span(
            classes:
                's4-auth__i${candidate.scientificallyAccepted ? ' is-on' : ''}',
            [
              Component.text(
                candidate.scientificallyAccepted
                    ? 'Scientific acceptance given'
                    : 'Scientific acceptance not given',
              ),
            ],
          ),
          span(
            classes:
                's4-auth__i${candidate.measurementId == null ? ' is-off' : ''}',
            [
              Component.text(
                candidate.measurementId == null
                    ? 'No measurement bound'
                    : 'Measurement ${candidate.measurementId}',
              ),
            ],
          ),
        ]),

        _qgReviewControls(candidate),

        // Folded, not deleted. Every audit field stays one click away.
        details(classes: 's4-aud', [
          summary(classes: 's4-aud__toggle', [
            Component.text('Provenance and validation'),
            span(classes: 's4-aud__n', [
              Component.text('${_auditFields.length} fields'),
            ]),
          ]),
          div(classes: 's4-aud__grid', [
            for (final field in _auditFields)
              div(classes: 's4-aud__cell', [
                span(classes: 's4-aud__k', [Component.text(field.$1)]),
                span(
                  classes:
                      's4-aud__v${(field.$2(candidate) ?? '').isEmpty ? ' is-empty' : ''}',
                  [
                    Component.text(
                      (field.$2(candidate) ?? '').isEmpty
                          ? 'not recorded'
                          : field.$2(candidate)!,
                    ),
                  ],
                ),
              ]),
          ]),
        ]),
      ],
    );
  }

  /// The audit fields, in the order the card has always shown them.
  ///
  /// Kept as data rather than 21 hand-written rows so the count in the
  /// disclosure header cannot drift from the rows it summarises.
  static final List<(String, String? Function(QgCandidate))> _auditFields = [
    ('Candidate id', (c) => c.candidateId),
    ('Assessment revision', (c) => '${c.assessmentRevision ?? ''}'),
    ('Confirmation', (c) => c.confirmationId),
    ('Admission', (c) => c.objectiveAdmissionId),
    ('Proposal', (c) => c.proposalId),
    ('Policy disposition', (c) => c.policyDisposition),
    ('Policy version', (c) => c.policyVersion),
    ('Measurement id', (c) => c.measurementId),
    ('Measurement version', (c) => c.measurementVersion),
    ('Contract version', (c) => c.contractVersion),
    ('Adapter version', (c) => c.adapterVersion),
    ('Prompt version', (c) => c.promptVersion),
    ('Prompt sha256', (c) => c.promptSha256),
    ('Model requested', (c) => c.modelRequested),
    ('Model returned', (c) => c.modelReturned),
    ('Ledger run', (c) => c.runId),
    ('QG authorization', (c) => c.qgAuthorizationId),
    ('Created', (c) => c.createdAt),
    ('Structural validation', (c) => c.structuralStatus),
    ('Semantic validation', (c) => c.semanticStatus),
    ('Provenance validation', (c) => c.provenanceStatus),
  ];

  /// The QG permission control for one approved objective.
  ///
  /// Four states are worded differently on purpose: never asked, granted, spent,
  /// and lapsed or withdrawn. A boolean would make "the owner has not been asked"
  /// indistinguishable from "the owner said no", and the two need different
  /// actions from them.
  Component _consentControl(BdjObjectiveProposal proposal) {
    final consent = _consents[proposal.proposalId];
    if (consent == null) {
      return p(classes: 'sr-muted', [
        Component.text(
          'QG processing permission: not read. The server did not return a '
          'state, so none is claimed here.',
        ),
      ]);
    }
    final disclosure = consent.disclosure;
    final shared = disclosure['data_shared'];
    final sharedText = shared is List ? shared.join(', ') : 'not stated';
    switch (consent.state) {
      case 'GRANTED':
        return p(classes: 's4-granted', [
          Component.text(
            'QG processing permission granted. ${consent.maxAttempts} attempt '
            'authorised${consent.expiresAt == null ? '' : ', expiring ${consent.expiresAt}'}.',
          ),
        ]);
      case 'CONSUMED':
        return p(classes: 's4-blocked', [
          Component.text(
            'The single authorised QG attempt for this objective has been spent. '
            'It is not retried automatically; granting again would authorise a '
            'new attempt.',
          ),
        ]);
      case 'EXPIRED':
        return p(classes: 's4-blocked', [
          Component.text(
            'The QG permission for this objective expired'
            '${consent.expiresAt == null ? '' : ' on ${consent.expiresAt}'}. '
            'Granting again would record a new permission.',
          ),
        ]);
      case 'REVOKED':
        return p(classes: 's4-blocked', [
          Component.text(
            'The QG permission for this objective was withdrawn'
            '${consent.revokedReason == null ? '' : ' (${consent.revokedReason})'}.',
          ),
        ]);
      default:
        return div(classes: 's4-consent', [
          p(classes: 'sr-muted', [
            Component.text(
              'Sending these facts to an external model is a separate permission '
              'from approving the objective. You are agreeing to:',
            ),
          ]),
          p(classes: 'sr-muted', [
            Component.text('${disclosure['purpose'] ?? ''}'),
          ]),
          p(classes: 'sr-muted', [
            Component.text('Data sent: $sharedText.'),
          ]),
          p(classes: 'sr-muted', [
            Component.text(
              'Provider ${disclosure['provider'] ?? 'unknown'} · model '
              '${disclosure['model'] ?? 'unknown'} · endpoint '
              '${disclosure['endpoint'] ?? 'unknown'}. '
              '${consent.maxAttempts == 0 ? 1 : consent.maxAttempts} attempt '
              'only.',
            ),
          ]),
          if (disclosure['note'] is String)
            p(classes: 'sr-muted', [Component.text(disclosure['note'] as String)]),
          button(
            classes: 'btn btn--secondary',
            disabled: _grantingConsent,
            onClick: _grantingConsent ? null : () => _grantConsent(proposal),
            [Component.text(_grantingConsent ? 'Recording…' : 'Grant QG permission')],
          ),
        ]);
    }
  }

  Component _proposalCard(BdjObjectiveProposal proposal) {
    final admission = _admissions[proposal.proposalId];
    final objectiveId = admission?.objectiveId;
    final history = objectiveId == null ? null : _histories[objectiveId];
    final blocker = _blockerFor(proposal);
    final refs = proposal.recommendation.sourceRefs;
    return section(
      classes: 'panel asw-inline',
      [
        div(classes: 'panel__body stack stack--sm', [
          div(classes: 's4-row', [
            span(classes: 's4-badge', [
              Component.text(_stateLabel(proposal.reviewState)),
            ]),
            if (admission != null)
              span(classes: 's4-badge', [
                Component.text(_admissionBadge(admission)),
              ]),
            if (objectiveId != null)
              span(
                classes: 's4-badge s4-badge--objective',
                [Component.text(objectiveId)],
              ),
            span(classes: 's4-badge s4-badge--muted', [
              Component.text(proposal.recommendation.status.wire),
            ]),
          ]),
          // Labelled, not bare. This is the research objective the owner
          // approved — it is *not* a questionnaire question, and the generated
          // questions are the cards below. Printing it unlabelled directly above
          // a candidate list let the two be read as the same thing.
          p(classes: 'sr-muted', [
            Component.text('Research objective (not a questionnaire question):'),
          ]),
          p(classes: 'body', [
            Component.text(proposal.recommendation.researchObjective),
          ]),
          // Source provenance: the confirmed answers this objective rests on.
          if (refs.isEmpty)
            p(classes: 'sr-muted', [
              Component.text('No source reference is recorded for this proposal.'),
            ])
          else
            p(classes: 'sr-muted', [
              Component.text(
                'Source: ${refs.map((ref) => ref.shortLabel).join(' · ')}',
              ),
            ]),
          if (proposal.recommendation.reason.isNotEmpty)
            p(classes: 'sr-muted', [
              Component.text(proposal.recommendation.reason),
            ]),
          if (blocker.isNotEmpty)
            p(classes: 's4-blocked', [Component.text(blocker)]),
          // Offered only where it can be honoured: an approved objective with a
          // derived authority. Anywhere else a grant would be refused by the
          // server, so showing the control would be a promise it cannot keep.
          if (_authorities.containsKey(proposal.proposalId))
            _consentControl(proposal),
          if (history != null && history.versions.isNotEmpty) ...[
            for (final candidate in history.versions.reversed)
              _candidateCard(candidate, _details[candidate.version]),
            _reviewControls(history, history.versions.last),
          ],
        ]),
      ],
    );
  }

  @override
  Component build(BuildContext context) {
    if (_loading) {
      return section(
        classes: 'panel asw-inline',
        [
          div(
            classes: 'panel__body',
            [p(classes: 'body', [Component.text('Reading question records…')])],
          ),
        ],
      );
    }
    if (_error != null) {
      return section(
        classes: 'panel asw-inline',
        [
          div(classes: 'panel__body stack stack--sm', [
            p(classes: 'body', [Component.text(_error!)]),
            button(
              classes: 'sr-button',
              attributes: {'type': 'button'},
              onClick: _load,
              [Component.text('Retry')],
            ),
          ]),
        ],
      );
    }
    if (_proposals.isEmpty && _candidates.isEmpty && _candidateError == null) {
      return section(
        classes: 'panel asw-inline',
        [
          div(classes: 'panel__body', [
            p(classes: 'body', [
              Component.text(
                'This confirmation has no research-objective proposals and no '
                'generated question candidates, so there is nothing to review. '
                'Proposals are produced on Stage 3.',
              ),
            ]),
          ]),
        ],
      );
    }
    return section(
      classes: 'stack stack--md',
      [
        if (!component.embedded)
          section(
            classes: 'panel asw-inline',
            [
              div(classes: 'panel__body stack stack--sm', [
                h2([Component.text('Question review')]),
                p(classes: 'sr-muted', [
                  Component.text(
                    'Each question below is a candidate for your review. Nothing '
                    'here is accepted, fielded or sent to a customer, and approving '
                    'a question does not authorise fielding.',
                  ),
                ]),
              ]),
            ],
          ),

        // -- Direct-QG candidates, the generated question itself --------------
        if (!component.embedded)
          section(
            classes: 'panel asw-inline',
            [
              div(classes: 'panel__body stack stack--sm', [
                h3([Component.text('Generated question candidates')]),
                p(classes: 'sr-muted', [
                  Component.text(
                    'These are the questions Direct-QG has actually persisted for '
                    'this assessment. Each one is shown with the execution that '
                    'produced it, so a simulated artifact is never mistaken for '
                    'live model output.',
                  ),
                ]),
              ]),
            ],
          ),
        if (_candidateError != null)
          section(
            classes: 'panel asw-inline',
            [
              div(classes: 'panel__body stack stack--sm', [
                p(classes: 's4-blocked', [Component.text(_candidateError!)]),
                button(
                  classes: 'sr-button',
                  attributes: {'type': 'button'},
                  onClick: _load,
                  [Component.text('Retry')],
                ),
              ]),
            ],
          )
        else if (_candidates.isEmpty)
          section(
            classes: 'panel asw-inline',
            [
              div(classes: 'panel__body stack stack--sm', [
                p(classes: 'body', [
                  Component.text(
                    'No question candidate has been generated for this '
                    'assessment. Generation requires an admitted objective and a '
                    'measurement that applies to it; the requirements below are '
                    'the server\'s own report of what is still missing.',
                  ),
                ]),
                for (final report in _eligibility.values)
                  _eligibilityBlock(report),
                if (_eligibility.isEmpty)
                  p(classes: 'sr-muted', [
                    Component.text(
                      'No objective is admitted for this assessment yet, so there '
                      'is no objective to ask about eligibility for.',
                    ),
                  ]),
              ]),
            ],
          )
        else
          ..._qgCards(),

        // -- The legacy per-objective version chain ---------------------------
        if (_proposals.isNotEmpty) ...[
          section(
            classes: 'panel asw-inline',
            [
              div(classes: 'panel__body stack stack--sm', [
                h3([Component.text('Objective proposals')]),
                p(classes: 'sr-muted', [
                  Component.text(
                    'Each proposal below is shown with its admission state and, '
                    'where one exists, its versioned review-question history. '
                    'This is the objective-level record; the Direct-QG questions '
                    'are the cards above, and the two are reviewed separately.',
                  ),
                ]),
              ]),
            ],
          ),
          for (final proposal in _proposals) _proposalCard(proposal),
        ],
      ],
    );
  }
}
