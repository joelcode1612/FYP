import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/bdj_objective_proposal.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/bdj_objective_proposal_api.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';

/// Stage 3 research objectives, sourced only from the governed BDJ endpoints.
///
/// This panel never renders a placeholder proposal. Three states are kept
/// strictly apart:
///
/// * **empty** — the governed pass produced nothing for this confirmation;
/// * **stale** — the M2 confirmation or the persisted business context moved,
///   so nothing is shown until the source is re-read;
/// * **failed** — the service did not answer, with its own message.
///
/// Approval and admission are also kept apart. A recorded `APPROVED` decision
/// is the entrepreneur's own record and is shown as such; the separate
/// admission block reports `HELD` / `M2_UNCERTAINTY_LINK_REQUIRED` and states
/// that question generation is **not** authorised. The two are never merged
/// into a single "approved" badge.
///
/// This remains a plain child component rather than an `@client` component:
/// the injectable transport port is a custom interface, which Jaspr cannot
/// serialize as an `@client` constructor parameter. It is mounted beneath the
/// primitive-parameter `@client` AssessmentWorkspacePage.
class BdjObjectiveProposalPanel extends StatefulComponent {
  /// The marketplace assessment whose linked M2 confirmation supplies context.
  ///
  /// Exactly one of [marketplaceAssessmentId] and [m2AssessmentId] must be set.
  /// The linked marketplace Stage 3 path uses this one; the standalone M2
  /// workflow uses [m2AssessmentId] because it already knows the M2 id and no
  /// marketplace association exists for it (DEF-01).
  final String marketplaceAssessmentId;

  /// A directly known M2 assessment id, used by the standalone M2 workflow.
  ///
  /// This is *not* a trust bypass: it only replaces the marketplace→M2 link
  /// lookup. The server still enforces ownership, a current confirmation, a
  /// persisted current business context and source integrity on every call, and
  /// this panel refuses to render anything until all of them agree.
  final String m2AssessmentId;

  /// The governed objective-proposal transport. Defaults to the real
  /// authenticated client; a component test substitutes a recorded result.
  final BdjObjectiveProposalPort api;

  const BdjObjectiveProposalPanel({
    super.key,
    this.marketplaceAssessmentId = '',
    this.m2AssessmentId = '',
    this.api = const BdjObjectiveProposalApi(),
  });

  /// Which assessment this panel is bound to, for the runtime guard below.
  ///
  /// A `const` constructor cannot evaluate `String.isEmpty`, and an `assert`
  /// would not survive a release build anyway, so the exactly-one rule is
  /// enforced where it actually matters: before the first read.
  String? get _bindingError {
    final count = (marketplaceAssessmentId.isEmpty ? 0 : 1) +
        (m2AssessmentId.isEmpty ? 0 : 1);
    if (count == 1) return null;
    return 'BdjObjectiveProposalPanel needs exactly one of '
        'marketplaceAssessmentId or m2AssessmentId.';
  }

  @override
  State<BdjObjectiveProposalPanel> createState() =>
      _BdjObjectiveProposalPanelState();
}

class _BdjObjectiveProposalPanelState
    extends State<BdjObjectiveProposalPanel> {
  bool _loading = true;
  bool _proposing = false;
  String? _busyProposalId;
  String? _error;
  String? _staleMessage;
  String? _notice;

  String _m2Id = '';
  String _contextId = '';
  int _revision = 0;

  /// The confirmation this panel resolved, kept even when no context exists yet.
  ///
  /// Without it the "no persisted business context" state could only be re-read:
  /// the build control needs the confirmation id, and the panel used to discard
  /// it on the early return.
  String _confirmationId = '';

  /// True when the confirmation has no persisted context to read from. This is
  /// the one state where a build is the remedy, so it is the only state that
  /// offers the control.
  bool _contextMissing = false;
  bool _buildingContext = false;

  List<BdjObjectiveProposal> _proposals = const [];
  final Map<String, BdjObjectiveDecision> _decisions = {};
  BdjExecution? _execution;

  /// Persisted provenance per proposal, read from the single-proposal route.
  ///
  /// The list endpoint deliberately carries no execution block (it is a read of
  /// stored rows, not of a run), so without this a page opened on already-
  /// persisted proposals could not say which model produced the text it shows.
  final Map<String, BdjProposalReadback> _readbacks = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateComponent(covariant BdjObjectiveProposalPanel oldComponent) {
    super.didUpdateComponent(oldComponent);
    if (oldComponent.marketplaceAssessmentId !=
            component.marketplaceAssessmentId ||
        oldComponent.m2AssessmentId != component.m2AssessmentId) {
      _decisions.clear();
      _readbacks.clear();
      _proposals = const [];
      _execution = null;
      _notice = null;
      _load();
    }
  }

  /// Resolves the current M2 confirmation and its persisted business context,
  /// then reads the persisted proposals. Every step can independently make the
  /// view stale, so the panel refuses to show proposals unless all three agree.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _staleMessage = null;
      // The list endpoint reads persisted rows and carries no execution block,
      // so a provenance note from an earlier pass must not outlive this read.
      _execution = null;
    });
    try {
      final bindingError = component._bindingError;
      if (bindingError != null) {
        _fail(bindingError);
        return;
      }
      // Two entry points, one governed read. The standalone M2 workflow already
      // holds a verified M2 id, so it skips only the marketplace→M2 link lookup;
      // every ownership, confirmation, context and source check below still runs.
      final String m2Id;
      if (component.m2AssessmentId.isNotEmpty) {
        m2Id = component.m2AssessmentId;
      } else {
        final linked = await AppLocator.m2.linkForMarketplace(
          component.marketplaceAssessmentId,
        );
        final linkedId = linked?['m2_assessment_id'];
        if (linkedId is! String || linkedId.isEmpty) {
          _fail(
            'No verified M2 assessment is linked to this assessment, so there is '
            'no confirmed source to propose objectives from.',
          );
          return;
        }
        m2Id = linkedId;
      }
      final draft = await AppLocator.m2.read(m2Id);
      final confirmation = await AppLocator.m2.currentConfirmation(m2Id);
      if (confirmation == null ||
          confirmation['assessment_revision'] != draft.revision) {
        _stale(
          'The M2 confirmation is missing or no longer matches revision '
          '${draft.revision}. Return to Stage 2 and confirm again.',
        );
        return;
      }
      final confirmationId = confirmation['id'];
      if (confirmationId is! String || confirmationId.isEmpty) {
        _fail('The M2 confirmation has no persisted identifier.');
        return;
      }

      final status = await AppLocator.m2.contextStatus(
        m2Id,
        confirmationId,
        draft.revision,
      );
      final contextId = status['context_id'];
      // Keep the confirmation identity before the early return: the build
      // control is offered in exactly this branch and needs all three values.
      _m2Id = m2Id;
      _revision = draft.revision;
      _confirmationId = confirmationId;
      _contextMissing =
          status['status'] != 'PERSISTED' || contextId is! String || contextId.isEmpty;
      if (_contextMissing || status['source_is_current'] != true) {
        _stale(
          'No persisted business context is current for this confirmation '
          '(status ${status['status'] ?? 'unknown'}). Objectives are only '
          'proposed from a current persisted context.',
        );
        return;
      }

      _contextId = contextId;

      final listed = await component.api.list(
        assessmentId: m2Id,
        expectedRevision: draft.revision,
        contextId: contextId,
      );
      if (!listed.ok) {
        _handleFailure(listed.failure!);
        return;
      }
      _proposals = listed.value!.proposals;

      // Persisted provenance for each row. A failure here must not hide the
      // proposal: the card simply omits the provenance line rather than
      // inventing one. A transport that *throws* is treated exactly like one
      // that returns a failed result — an uncaught exception would abort the
      // rest of this load and blank a list that has already been read.
      _readbacks.clear();
      for (final proposal in _proposals) {
        try {
          final detail = await component.api.read(
            assessmentId: m2Id,
            proposalId: proposal.proposalId,
            expectedRevision: draft.revision,
            contextId: contextId,
          );
          if (detail.ok) _readbacks[proposal.proposalId] = detail.value!;
        } catch (_) {
          // No provenance line for this card; the proposal still renders.
        }
      }

      // Persisted decision readback: a proposal that already carries a review
      // state must show the stored decision and its admission, not a guess.
      for (final proposal in _proposals) {
        if (!proposal.reviewState.hasDecision) continue;
        final decision = await component.api.readDecision(
          assessmentId: m2Id,
          proposalId: proposal.proposalId,
          expectedRevision: draft.revision,
          contextId: contextId,
        );
        if (decision.ok) {
          _decisions[proposal.proposalId] = decision.value!;
        }
      }
      setState(() => _loading = false);
    } on Object catch (error) {
      _fail('The research objectives could not be read: $error');
    }
  }

  void _fail(String message) => setState(() {
    _loading = false;
    _error = message;
  });

  void _stale(String message) => setState(() {
    _loading = false;
    _staleMessage = message;
  });

  void _handleFailure(AssessmentFailure failure) {
    if (isStaleSourceCode(failure.code)) {
      _stale(
        'The confirmed source or the business context changed while this page '
        'was open (${failure.code}). Nothing is shown until it is re-read.',
      );
      return;
    }
    _fail(failure.message);
  }

  /// Persists the business context for the confirmation this panel resolved.
  ///
  /// Reuses the existing `POST …/business-context` route through the same client
  /// the rest of the panel uses — there is no second endpoint and no new
  /// permission. `objectiveId` is deliberately omitted: a first build has no
  /// confirmed objective to bind, and the route treats the parameter as optional.
  ///
  /// Nothing is built until the owner clicks, and a refused build reports the
  /// server's reason instead of retrying by itself. The M2 confirmation is not
  /// touched, so this cannot make a confirmed source stale.
  Future<void> _buildContext() async {
    setState(() {
      _buildingContext = true;
      _notice = null;
    });
    try {
      await AppLocator.m2.buildContext(_m2Id, _confirmationId, _revision);
      _buildingContext = false;
      await _load();
    } on Object catch (error) {
      setState(() {
        _buildingContext = false;
        _stale(
          'The business context could not be built for confirmation '
          '$_confirmationId (revision $_revision): $error',
        );
      });
    }
  }

  Future<void> _propose() async {
    setState(() {
      _proposing = true;
      _notice = null;
    });
    try {
      final result = await component.api.evaluate(
        assessmentId: _m2Id,
        expectedRevision: _revision,
        contextId: _contextId,
      );
      if (!result.ok) {
        final failure = result.failure!;
        if (isStaleSourceCode(failure.code)) {
          _stale(
            'The source changed before the proposal pass ran '
            '(${failure.code}). Re-read before proposing again.',
          );
          return;
        }
        // A refused candidate or a held execution is a result, not a crash:
        // the server's own sentence is shown and nothing is persisted.
        setState(() {
          _proposing = false;
          _notice = failure.message;
        });
        return;
      }
      final evaluation = result.value!;
      setState(() {
        _proposing = false;
        _proposals = evaluation.proposals;
        _execution = evaluation.execution;
        _decisions.removeWhere(
          (id, _) => !evaluation.proposals.any((row) => row.proposalId == id),
        );
        _notice = evaluation.isEmpty
            ? 'The governed pass completed but produced no research objective '
                  'for this confirmation. Nothing is shown rather than a '
                  'placeholder.'
            : null;
      });
    } on Object catch (error) {
      setState(() {
        _proposing = false;
        _notice = 'The proposal pass could not complete: $error';
      });
    }
  }

  Future<void> _decide(BdjObjectiveProposal proposal, String decision) async {
    setState(() {
      _busyProposalId = proposal.proposalId;
      _notice = null;
    });
    try {
      final result = await component.api.decide(
        assessmentId: _m2Id,
        proposalId: proposal.proposalId,
        expectedRevision: _revision,
        contextId: _contextId,
        decision: decision,
      );
      if (!result.ok) {
        final failure = result.failure!;
        if (isStaleSourceCode(failure.code)) {
          _stale(
            'The source changed before your decision was recorded '
            '(${failure.code}). Re-read, then decide again.',
          );
          return;
        }
        setState(() {
          _busyProposalId = null;
          _notice = failure.message;
        });
        return;
      }
      final stored = result.value!;
      setState(() {
        _busyProposalId = null;
        _decisions[proposal.proposalId] = stored;
        _proposals = [
          for (final row in _proposals)
            row.proposalId == proposal.proposalId
                ? row.withReviewState(stored.reviewState)
                : row,
        ];
        _notice = stored.decisionCreated == false
            ? 'This decision was already recorded; the stored decision is shown.'
            : null;
      });
    } on Object catch (error) {
      setState(() {
        _busyProposalId = null;
        _notice = 'The decision could not be recorded: $error';
      });
    }
  }

  @override
  Component build(BuildContext context) {
    if (_loading) {
      return section(classes: 'panel stack stack--sm', [
        const p(
          attributes: {'role': 'status'},
          [Component.text('Reading persisted research objectives…')],
        ),
      ]);
    }
    if (_staleMessage != null) {
      return section(classes: 'panel stack stack--sm', [
        EmptyState(
          title: 'The confirmed source is not current',
          body: _staleMessage!,
          // A missing context is the one case the owner can fix from here, and
          // only on an explicit click. Re-read stays available either way.
          action: div(classes: 'row-actions', [
            if (_contextMissing)
              ActionButton(
                _buildingContext
                    ? 'Building business context…'
                    : 'Build business context',
                onClick: _buildingContext
                    ? null
                    : () {
                        _buildContext();
                      },
              ),
            ActionButton(
              'Re-read',
              variant: 'ghost',
              onClick: _buildingContext
                  ? null
                  : () {
                      _load();
                    },
            ),
          ]),
        ),
      ]);
    }
    if (_error != null) {
      return section(classes: 'panel stack stack--sm', [
        EmptyState(
          title: 'Research objectives could not be read',
          body: _error!,
          action: ActionButton(
            'Retry',
            onClick: () {
              _load();
            },
          ),
        ),
      ]);
    }

    final mostSuggested = _proposals
        .where((row) => row.recommendation.status.isSourceConfirmed)
        .length;
    final decided = _proposals.where((row) => row.reviewState.hasDecision).length;

    return section(classes: 'panel stack stack--sm', [
      div(classes: 'panel-head panel-head--split', [
        div(classes: 'stack stack--xs', [
          const h3([Component.text('Research objectives')]),
          p(classes: 'muted', [
            Component.text(
              _proposals.isEmpty
                  ? 'No objective proposals are persisted for this '
                        'confirmation.'
                  : '${_proposals.length} proposal'
                        '${_proposals.length == 1 ? '' : 's'} · '
                        '$mostSuggested source-confirmed · $decided reviewed. '
                        'Candidate only: nothing here is approved research '
                        'until you decide, and no approval authorises question '
                        'generation.',
            ),
          ]),
        ]),
        div(classes: 'row-actions', [
          ActionButton(
            _proposals.isEmpty ? 'Propose research objectives' : 'Re-run',
            variant: 'secondary',
            onClick: _proposing
                ? null
                : () {
                    _propose();
                  },
          ),
          ActionButton(
            'Refresh',
            variant: 'ghost',
            onClick: _proposing
                ? null
                : () {
                    _load();
                  },
          ),
        ]),
      ]),
      if (_execution != null) _executionNote(_execution!),
      if (_notice != null)
        div(classes: 'card card--flat', [
          p(classes: 'muted', [Component.text(_notice!)]),
        ]),
      if (_proposing)
        const p(
          attributes: {'role': 'status'},
          [
            Component.text(
              'Running the governed proposal pass. This may reuse an existing '
              'attempt rather than dispatching a new one…',
            ),
          ],
        ),
      if (_proposals.isEmpty && !_proposing)
        const EmptyState(
          title: 'No research objectives yet',
          body:
              'The governed BDJ pass has not produced a proposal for this '
              'confirmation. An empty result is shown as empty: no example or '
              'placeholder objective is displayed in its place.',
        )
      else
        for (final proposal in _proposals)
          _proposalCard(proposal, _decisions[proposal.proposalId]),
    ]);
  }

  /// Makes the execution provenance visible, because a simulated pass must not
  /// read like a live model result.
  Component _executionNote(BdjExecution execution) {    final parts = <String>[
      if (execution.isSimulated)
        'Simulated pass — no cloud model was called'
      else
        'Execution mode ${execution.executionMode}',
      if (execution.modelProvider.isNotEmpty) execution.modelProvider,
      if (execution.promptVersion.isNotEmpty) 'prompt ${execution.promptVersion}',
      if (execution.attemptNo != null) 'attempt ${execution.attemptNo}',
      if (execution.receiptOutcome != null) 'receipt ${execution.receiptOutcome}',
      if (execution.reused) 'reused an existing governed attempt',
    ];
    return div(classes: 'card card--flat', [
      p(classes: 'muted', [Component.text(parts.join(' · '))]),
    ]);
  }

  /// Persisted provenance of an already-stored proposal.
  ///
  /// Read from the row itself, so a page that only *reads* proposals still says
  /// which model produced them. Returns nothing when the server did not report
  /// it — an absent fact is never replaced by a guess.
  Component? _provenanceLine(String proposalId) {
    final read = _readbacks[proposalId];
    if (read == null) return null;
    final parts = <String>[
      if (read.executionMode.isNotEmpty)
        read.executionMode == 'SIMULATED'
            ? 'Simulated pass — no cloud model was called'
            : 'Execution mode ${read.executionMode}',
      if (read.modelProvider != null) read.modelProvider!,
      if (read.modelRequested != null)
        read.modelRequested == read.modelReturned
            ? 'model ${read.modelRequested}'
            : 'requested ${read.modelRequested} · returned ${read.modelReturned ?? 'none'}',
      if (read.promptVersion != null) 'prompt ${read.promptVersion}',
      if (read.validationStatus.isNotEmpty)
        'validation ${read.validationStatus}',
    ];
    if (parts.isEmpty) return null;
    return p(classes: 'muted', [Component.text(parts.join(' · '))]);
  }

  Component _proposalCard(
    BdjObjectiveProposal proposal,
    BdjObjectiveDecision? decision,
  ) {
    final recommendation = proposal.recommendation;
    final busy = _busyProposalId == proposal.proposalId;
    final isDecided = proposal.reviewState.hasDecision;
    final admission = decision?.admission;
    final provenance = _provenanceLine(proposal.proposalId);

    return div(classes: 'card stack stack--sm', [
      div(classes: 'row row--sm', [
        StatusBadge(
          recommendation.status.isSourceConfirmed
              ? 'Most suggested'
              : recommendation.status == BdjRecommendationStatus.suggested
              ? 'Suggested'
              : 'Unrecognised status',
          tone: recommendation.status.isSourceConfirmed ? 'action' : 'neutral',
          dot: true,
        ),
        StatusBadge(
          switch (proposal.reviewState) {
            BdjReviewState.approved => 'Approved by you',
            BdjReviewState.rejected => 'Rejected by you',
            BdjReviewState.pending => 'Awaiting your decision',
            BdjReviewState.unrecognised => 'Review state unreadable',
          },
          tone: switch (proposal.reviewState) {
            BdjReviewState.approved => 'success',
            BdjReviewState.rejected => 'danger',
            BdjReviewState.pending => 'warning',
            BdjReviewState.unrecognised => 'neutral',
          },
        ),
      ]),
      h4([Component.text(recommendation.researchObjective)]),
      if (recommendation.problem != null)
        p([Component.text('Confirmed gap: ${recommendation.problem}')]),
      if (recommendation.reason.isNotEmpty)
        p(classes: 'muted', [Component.text(recommendation.reason)]),
      if (recommendation.sourceRefs.isNotEmpty)
        div(classes: 'chips', [
          for (final ref in recommendation.sourceRefs)
            span(
              classes: 'chip',
              attributes: {
                'title':
                    'answer revision ${ref.answerRevisionId} · item version '
                    '${ref.itemVersionId}',
              },
              [Component.text(ref.shortLabel)],
            ),
        ])
      else
        p(classes: 'muted', [
          Component.text(
            'No source reference: this is an exploratory objective, not a '
            'source-confirmed gap.',
          ),
        ]),
      if (!recommendation.isProperlySourced)
        p(classes: 'muted', [
          Component.text(
            'This proposal claims a source-confirmed gap but does not carry '
            'both a problem statement and a source reference. Treat it as '
            'unverified.',
          ),
        ]),
      // Provenance of the stored row, so a reader can tell a live model result
      // from a simulated one without running anything.
      if (provenance != null) provenance,
      // Decision and admission are rendered as two separate facts.
      if (isDecided && admission != null)
        div(classes: 'card card--flat stack stack--xs', [
          div(classes: 'row row--sm', [
            StatusBadge(
              switch (admission.state) {
                BdjAdmissionState.held => 'Admission held',
                BdjAdmissionState.notAdmissible => 'Not admissible',
                BdjAdmissionState.unrecognised => 'Admission unreadable',
              },
              tone: switch (admission.state) {
                BdjAdmissionState.held => 'warning',
                BdjAdmissionState.notAdmissible => 'danger',
                BdjAdmissionState.unrecognised => 'neutral',
              },
              dot: true,
            ),
          ]),
          p([Component.text(admission.summary)]),
          if (admission.pendingRequirement != null)
            p(classes: 'muted', [
              Component.text(admission.pendingRequirement!),
            ]),
          p(classes: 'muted', [
            Component.text(
              'Question generation: '
              '${admission.qgExecution ? 'authorised' : 'not authorised'} · '
              'Fielding: '
              '${admission.fieldingAuthorized ? 'authorised' : 'not authorised'}',
            ),
          ]),
        ])
      else if (isDecided)
        p(classes: 'muted', [
          Component.text(
            'The decision is recorded. Its admission state could not be read '
            'back, so no downstream authority is claimed.',
          ),
        ])
      else
        div(classes: 'row-actions', [
          ActionButton(
            'Approve',
            variant: 'primary',
            onClick: busy
                ? null
                : () {
                    _decide(proposal, 'APPROVED');
                  },
          ),
          ActionButton(
            'Reject',
            variant: 'ghost',
            onClick: busy
                ? null
                : () {
                    _decide(proposal, 'REJECTED');
                  },
          ),
        ]),
      if (busy)
        const p(
          attributes: {'role': 'status'},
          [Component.text('Recording your decision…')],
        ),
    ]);
  }
}
