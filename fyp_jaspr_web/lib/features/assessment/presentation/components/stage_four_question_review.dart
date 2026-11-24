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
  });

  final String m2AssessmentId;
  final int expectedRevision;
  final String contextId;
  final StageFourFivePort api;
  final BdjObjectiveProposalPort proposalApi;

  @override
  State<StageFourQuestionReview> createState() => _StageFourState();
}

class _StageFourState extends State<StageFourQuestionReview> {
  bool _loading = true;
  String? _error;
  List<BdjObjectiveProposal> _proposals = const [];
  final Map<String, ProposalAdmission> _admissions = {};
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
  final Map<String, String> _qgRationale = {};
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
    for (final proposal in proposals) {
      final admission = await component.api.admission(
        assessmentId: component.m2AssessmentId,
        proposalId: proposal.proposalId,
        expectedRevision: component.expectedRevision,
        contextId: component.contextId,
      );
      if (!mounted) return;
      if (!admission.ok) continue;
      final value = admission.value!;
      _admissions[proposal.proposalId] = value;
      final objectiveId = value.objectiveId;
      if (value.isAdmitted && objectiveId != null && objectiveId.isNotEmpty) {
        final history = await component.api.history(
          objectiveId: objectiveId,
          expectedRevision: component.expectedRevision,
        );
        if (!mounted) return;
        if (!history.ok) continue;
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
    }

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
      for (final admission in _admissions.values)
        if (admission.isAdmitted &&
            (admission.objectiveId ?? '').isNotEmpty)
          admission.objectiveId!,
      for (final candidate in candidates)
        if (candidate.objectiveId.isNotEmpty) candidate.objectiveId,
    };
    for (final objectiveId in objectives) {
      final report = await component.api.eligibility(
        assessmentId: component.m2AssessmentId,
        objectiveId: objectiveId,
      );
      if (!mounted) return;
      if (report.ok) _eligibility[objectiveId] = report.value!;
    }

    setState(() {
      _proposals = proposals;
      _candidates = candidates;
      _candidateError = candidateError;
      _loading = false;
    });
  }

  String _stateLabel(BdjReviewState state) => switch (state) {
    BdjReviewState.approved => 'Approved by you',
    BdjReviewState.rejected => 'Rejected by you',
    BdjReviewState.pending => 'Awaiting your decision',
    BdjReviewState.unrecognised => 'Review state unreadable',
  };

  /// The first prerequisite that is missing, in the order the server checks it.
  ///
  /// This is what makes the stage truthful: an absent question is attributed to
  /// a named gate rather than left as an unexplained blank.
  String _blockerFor(BdjObjectiveProposal proposal) {
    final admission = _admissions[proposal.proposalId];
    if (!proposal.reviewState.hasDecision) {
      return 'Not approved yet. Approve the objective on Stage 3 before a '
          'question can be prepared.';
    }
    if (proposal.reviewState == BdjReviewState.rejected) {
      return 'Rejected. No question is prepared for a rejected objective.';
    }
    if (admission == null) {
      return 'The admission state could not be read for this proposal.';
    }
    if (!admission.isAdmitted) {
      return 'Admission ${admission.state} (${admission.reason}). The owner has '
          'not recorded that this gap is worth researching.';
    }
    if (admission.objectiveId == null) {
      return 'Admitted, but the admission binds no fixed objective. A novel '
          'candidate is not a measurement target until it is registered.';
    }
    if (!admission.qgEligible) {
      return 'Admitted, but not eligible for question generation'
          '${admission.qgBlocker == null ? '' : ' (${admission.qgBlocker})'}.';
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

  /// One labelled fact. An absent value prints "not recorded" rather than being
  /// omitted: a missing column and a column the page forgot to render must not
  /// look the same to a reviewer.
  Component _meta(String label, String? value) => div(
    classes: 's4-meta',
    [
      span(classes: 's4-meta__label', [Component.text(label)]),
      span(classes: 's4-meta__value', [
        Component.text(
          value == null || value.isEmpty ? 'not recorded' : value,
        ),
      ]),
    ],
  );

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

  /// The eligibility report, check by check.
  ///
  /// Rendered even when everything passes: the reader needs to know *which*
  /// requirement was examined, not merely that some aggregate said yes.
  Component _eligibilityBlock(QgEligibility report) {
    final blocker = report.firstBlocker;
    return div(classes: 's4-eligibility', [
      div(classes: 's4-row', [
        span(classes: 's4-badge s4-badge--muted', [
          Component.text('prepare ${report.prepareStatus}'),
        ]),
        span(classes: 's4-badge s4-badge--muted', [
          Component.text('dispatch ${report.dispatchStatus}'),
        ]),
        if (report.measurementVersion != null)
          span(classes: 's4-badge s4-badge--objective', [
            Component.text(report.measurementVersion!),
          ]),
      ]),
      p(classes: 'sr-muted', [
        Component.text(
          'Generation requirements, in the order the server checks them:',
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
      if (blocker != null && blocker.evidence.isNotEmpty)
        p(classes: 'sr-muted', [
          Component.text(
            'Evidence for ${blocker.reasonCode}: '
            '${blocker.evidence.entries.map((e) => '${e.key}=${e.value}').join('; ')}',
          ),
        ]),
      p(classes: 'sr-muted', [
        Component.text(
          'This report is diagnostic. A dispatch status of PASS would still not '
          'authorise a provider call — the runner re-verifies every condition '
          'against the real request.',
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
      rationale: (_qgRationale[candidate.candidateId] ?? '').trim(),
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
  Component _qgReviewControls(QgCandidate candidate) {
    final failure = _qgError[candidate.candidateId];
    final expected = candidate.review.expectedOptionCode;
    return div(classes: 's4-review', [
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
          for (final option in candidate.options)
            button(
              classes: expected == option.code
                  ? 'sr-button sr-button--quiet is-selected'
                  : 'sr-button sr-button--quiet',
              attributes: {'type': 'button'},
              onClick: _qgBusy ? null : () => _expectQg(candidate, option.code),
              [Component.text('Expect ${option.code}')],
            ),
          if (expected != null)
            button(
              classes: 'sr-button sr-button--quiet',
              attributes: {'type': 'button'},
              onClick: _qgBusy ? null : () => _expectQg(candidate, null),
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
          attributes: {'aria-label': 'candidate review rationale'},
          onInput: (value) => _qgRationale[candidate.candidateId] = value,
          [Component.text(_qgRationale[candidate.candidateId] ?? '')],
        ),
        div(classes: 's4-row', [
          button(
            classes: 'sr-button',
            attributes: {'type': 'button'},
            onClick: _qgBusy
                ? null
                : () => _decideQg(candidate, 'APPROVE_FOR_REVIEW'),
            [Component.text('Approve for review')],
          ),
          button(
            classes: 'sr-button sr-button--quiet',
            attributes: {'type': 'button'},
            onClick: _qgBusy
                ? null
                : () => _decideQg(candidate, 'REQUEST_REVISION'),
            [Component.text('Request revision')],
          ),
          button(
            classes: 'sr-button sr-button--quiet',
            attributes: {'type': 'button'},
            onClick: _qgBusy ? null : () => _decideQg(candidate, 'REJECT'),
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
      if (failure != null) p(classes: 's4-blocked', [Component.text(failure)]),
    ]);
  }

  /// One persisted Direct-QG candidate, with everything a reviewer must see
  /// before judging it.
  Component _qgCard(QgCandidate candidate) {
    final review = candidate.review;
    final report = _eligibility[candidate.objectiveId];
    return section(
      classes: 'panel asw-inline',
      [
        div(classes: 'panel__body stack stack--sm', [
          div(classes: 's4-row', [
            span(classes: 's4-badge', [
              Component.text(candidate.candidateState),
            ]),
            span(classes: 's4-badge s4-badge--objective', [
              Component.text(
                candidate.objectiveId.isEmpty
                    ? 'no objective'
                    : candidate.objectiveId,
              ),
            ]),
            span(classes: 's4-badge s4-badge--muted', [
              Component.text(candidate.objectiveClassification),
            ]),
            span(classes: 's4-badge s4-badge--muted', [
              Component.text(candidate.responseFormat),
            ]),
            if (candidate.isSimulated)
              span(classes: 's4-badge s4-badge--warn', [
                Component.text('simulated — not live evidence'),
              ])
            else if (!candidate.dispatched)
              span(classes: 's4-badge s4-badge--warn', [
                Component.text('no ledger run'),
              ])
            else
              span(classes: 's4-badge s4-badge--pass', [
                Component.text('dispatched'),
              ]),
            if (review.reviewed)
              span(classes: 's4-badge s4-badge--muted', [
                Component.text('reviewed: ${review.decision}'),
              ]),
          ]),

          // The question itself. Verbatim, because a paraphrase would be a
          // second wording that no reviewer actually judged.
          p(classes: 's4-question', [Component.text(candidate.question)]),

          div(classes: 's4-options', [
            for (final option in candidate.options)
              div(classes: 's4-option', [
                span(classes: 's4-option__code', [
                  Component.text(option.code),
                ]),
                span(classes: 's4-option__label', [
                  Component.text(option.label),
                ]),
                span(classes: 's4-badge s4-badge--muted', [
                  Component.text('#${option.order} · ${option.orderSource}'),
                ]),
                if (review.expectedOptionCode == option.code)
                  span(classes: 's4-badge s4-badge--objective', [
                    Component.text('your expectation'),
                  ]),
              ]),
            if (candidate.options.isEmpty)
              p(classes: 's4-blocked', [
                Component.text(
                  'This candidate records no answer options, so it cannot be '
                  'fielded or reviewed as a closed question.',
                ),
              ]),
          ]),

          p(classes: 'sr-muted', [
            Component.text(_executionLine(candidate)),
          ]),

          // Provenance, field by field.
          div(classes: 's4-meta-grid', [
            _meta('Candidate id', candidate.candidateId),
            _meta('Assessment revision', '${candidate.assessmentRevision ?? ''}'),
            _meta('Confirmation', candidate.confirmationId),
            _meta('Admission', candidate.objectiveAdmissionId),
            _meta('Proposal', candidate.proposalId),
            _meta('Policy disposition', candidate.policyDisposition),
            _meta('Policy version', candidate.policyVersion),
            _meta('Measurement id', candidate.measurementId),
            _meta('Measurement version', candidate.measurementVersion),
            _meta('Contract version', candidate.contractVersion),
            _meta('Adapter version', candidate.adapterVersion),
            _meta('Prompt version', candidate.promptVersion),
            _meta('Prompt sha256', candidate.promptSha256),
            _meta('Model requested', candidate.modelRequested),
            _meta('Model returned', candidate.modelReturned),
            _meta('Ledger run', candidate.runId),
            _meta('QG authorization', candidate.qgAuthorizationId),
            _meta('Created', candidate.createdAt),
            _meta('Structural validation', candidate.structuralStatus),
            _meta('Semantic validation', candidate.semanticStatus),
            _meta('Provenance validation', candidate.provenanceStatus),
          ]),

          if (candidate.referencePeriod != null)
            p(classes: 'sr-muted', [
              Component.text('Reference period: ${candidate.referencePeriod}'),
            ]),
          if (candidate.justification != null)
            p(classes: 'sr-muted', [
              Component.text('Justification: ${candidate.justification}'),
            ]),
          if (candidate.limitations != null)
            p(classes: 'sr-muted', [
              Component.text('Limitations: ${candidate.limitations}'),
            ]),

          // Recorded review, read back from the database.
          if (review.reviewed)
            div(classes: 's4-review__block', [
              p(classes: 's4-review__label', [
                Component.text('Recorded review'),
              ]),
              p(classes: 'sr-muted', [
                Component.text(
                  'Decision: ${review.decision}'
                  '${review.recordedAt == null ? '' : ' · recorded ${review.recordedAt}'}',
                ),
              ]),
              if ((review.rationale ?? '').isNotEmpty)
                p(classes: 'sr-muted', [
                  Component.text('Rationale: ${review.rationale}'),
                ]),
            ]),

          if (report != null) _eligibilityBlock(report),

          p(classes: 'sr-muted', [
            Component.text(
              'Fielding authorisation: ${candidate.fieldingAuthorized ? 'true' : 'false'} · '
              'scientific acceptance: ${candidate.scientificallyAccepted ? 'true' : 'false'}. '
              'Both are reported by the server and are expected to be false.',
            ),
          ]),

          _qgReviewControls(candidate),
        ]),
      ],
    );
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
              span(classes: 's4-badge', [Component.text(admission.state)]),
            if (objectiveId != null)
              span(
                classes: 's4-badge s4-badge--objective',
                [Component.text(objectiveId)],
              ),
            span(classes: 's4-badge s4-badge--muted', [
              Component.text(proposal.recommendation.status.wire),
            ]),
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
          for (final candidate in _candidates) _qgCard(candidate),

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
                    'where one exists, its versioned review-question history.',
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
