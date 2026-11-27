import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/bdj_objective_proposal.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/bdj_objective_proposal_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/fixed_objectives.dart';
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

  /// Called after a decision was recorded on the server.
  ///
  /// An accepted objective is the evidence stage 3 is waiting for, but this
  /// panel cannot know that the *assessment* moved — it only knows the decision
  /// was stored. So it reports the save and lets the owner re-read the record,
  /// which is what turns 2/5 into 3/5 (60%). It never claims a stage completed.
  final VoidCallback? onDecisionRecorded;

  /// Page-owned cards rendered under this panel's own sections.
  ///
  /// Stage 3 owns an entrepreneur-authored objective form and a review-history
  /// card that belong in the same reading column as the objectives. Passing
  /// them in keeps one column and one sticky rail; rendering them after the
  /// panel instead would stack a second full-width block underneath the rail
  /// and break the alignment the rail depends on.
  final List<Component> trailingSections;

  /// Page-owned cards rendered above this panel's own rail cards.
  ///
  /// Stage 3's execution status belongs on the right, beside the objectives it
  /// describes. Passing it in keeps one sticky rail; rendering it as a sibling
  /// column of the whole page instead produced three columns — objectives, this
  /// rail, and a second rail — which is the "two status panels side by side"
  /// shape the audit found (D-H01 / D-M07).
  final List<Component> railLead;

  const BdjObjectiveProposalPanel({
    super.key,
    this.marketplaceAssessmentId = '',
    this.m2AssessmentId = '',
    this.api = const BdjObjectiveProposalApi(),
    this.onDecisionRecorded,
    this.trailingSections = const [],
    this.railLead = const [],
  });

  /// Which assessment this panel is bound to, for the runtime guard below.
  ///
  /// A `const` constructor cannot evaluate `String.isEmpty`, and an `assert`
  /// would not survive a release build anyway, so the exactly-one rule is
  /// enforced where it actually matters: before the first read.
  String? get _bindingError {
    final count =
        (marketplaceAssessmentId.isEmpty ? 0 : 1) +
        (m2AssessmentId.isEmpty ? 0 : 1);
    if (count == 1) return null;
    return 'BdjObjectiveProposalPanel needs exactly one of '
        'marketplaceAssessmentId or m2AssessmentId.';
  }

  @override
  State<BdjObjectiveProposalPanel> createState() =>
      _BdjObjectiveProposalPanelState();
}

class _BdjObjectiveProposalPanelState extends State<BdjObjectiveProposalPanel> {
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

  /// The server's answer to "can this context still be generated?".
  ///
  /// This is the *only* input to whether the generate control is drawn. It is
  /// not inferred from [_proposals] being empty, from a remembered run id, or
  /// from any count, because each of those can disagree with what the evaluate
  /// route will actually do (D-H05 / CP-AUDIT-09).
  BdjObjectiveGeneration _generation = BdjObjectiveGeneration.unknown;

  /// Proposal ids returned by the most recent governed LLM pass.
  ///
  /// Kept separately from [_execution] because the pass is followed by a
  /// persisted readback: the readback proves which model actually produced the
  /// stored rows, while this set answers the narrower question "which research
  /// objectives did the pass just update?".
  final Set<String> _updatedProposalIds = <String>{};

  /// Execution block of the most recent pass, preserved across that readback.
  BdjExecution? _lastRunExecution;

  /// Persisted provenance per proposal, read from the single-proposal route.
  ///
  /// The list endpoint deliberately carries no execution block (it is a read of
  /// stored rows, not of a run), so without this a page opened on already-
  /// persisted proposals could not say which model produced the text it shows.
  final Map<String, BdjProposalReadback> _readbacks = {};

  /// Guards the asynchronous provenance/decision hydration against a newer
  /// load. The proposals themselves render as soon as the list returns; the
  /// per-proposal reads only enrich the cards afterwards.
  int _loadRequest = 0;

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
      _generation = BdjObjectiveGeneration.unknown;
      _updatedProposalIds.clear();
      _lastRunExecution = null;
      _notice = null;
      _load();
    }
  }

  /// Resolves the current M2 confirmation and its persisted business context,
  /// then reads the persisted proposals. Every step can independently make the
  /// view stale, so the panel refuses to show proposals unless all three agree.
  Future<void> _load({bool preserveLastRun = false, bool quiet = false}) async {
    final request = ++_loadRequest;
    setState(() {
      // A quiet re-read keeps the page on screen. It is used after an action
      // whose result the reader is already watching (a pass, a refresh), where
      // replacing the page with a spinner hides the very change being reported.
      if (!quiet) _loading = true;
      _error = null;
      _staleMessage = null;
      // The list endpoint reads persisted rows and carries no execution block,
      // so a provenance note from an earlier pass must not outlive this read.
      _execution = preserveLastRun ? _lastRunExecution : null;
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
          status['status'] != 'PERSISTED' ||
          contextId is! String ||
          contextId.isEmpty;
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
      if (!mounted || request != _loadRequest) return;
      final proposals = listed.value!.proposals;
      final proposalIds = proposals.map((row) => row.proposalId).toSet();

      // The list is the authoritative read, so render it immediately. The
      // single-proposal reads below only enrich the cards with persisted
      // provenance and decisions; waiting for them kept the whole panel in
      // "Reading persisted research objectives…" for many seconds.
      setState(() {
        _proposals = proposals;
        _loading = false;
        _generation = listed.value!.generation;
        _readbacks.clear();
        _decisions.removeWhere((id, _) => !proposalIds.contains(id));
      });

      // Persisted provenance for each row. A failure here must not hide the
      // proposal: the card simply omits the provenance line rather than
      // inventing one. A transport that *throws* is treated exactly like one
      // that returns a failed result — an uncaught exception would abort the
      // rest of this load and blank a list that has already been read.
      final readbacks = await Future.wait([
        for (final proposal in proposals)
          _readback(
            m2Id: m2Id,
            proposal: proposal,
            revision: draft.revision,
            contextId: contextId,
          ),
      ]);
      if (!mounted || request != _loadRequest) return;
      setState(() {
        for (final entry
            in readbacks.whereType<MapEntry<String, BdjProposalReadback>>()) {
          _readbacks[entry.key] = entry.value;
        }
      });

      // Persisted decision readback: a proposal that already carries a review
      // state must show the stored decision and its admission, not a guess.
      final decisions = await Future.wait([
        for (final proposal in proposals)
          if (proposal.reviewState.hasDecision)
            _decision(
              m2Id: m2Id,
              proposal: proposal,
              revision: draft.revision,
              contextId: contextId,
            ),
      ]);
      if (!mounted || request != _loadRequest) return;
      setState(() {
        for (final entry
            in decisions.whereType<MapEntry<String, BdjObjectiveDecision>>()) {
          _decisions[entry.key] = entry.value;
        }
        // A successful evaluate is followed by this readback so the persisted
        // LIVE provenance replaces the in-memory result. Keep the just-completed
        // pass visible while that happens; a manual refresh does not preserve it.
        if (preserveLastRun && _lastRunExecution != null) {
          _execution = _lastRunExecution;
        }
      });
    } on Object catch (error) {
      if (!mounted || request != _loadRequest) return;
      _fail('The research objectives could not be read: $error');
    }
  }

  Future<MapEntry<String, BdjProposalReadback>?> _readback({
    required String m2Id,
    required BdjObjectiveProposal proposal,
    required int revision,
    required String contextId,
  }) async {
    try {
      final detail = await component.api.read(
        assessmentId: m2Id,
        proposalId: proposal.proposalId,
        expectedRevision: revision,
        contextId: contextId,
      );
      if (!detail.ok) return null;
      return MapEntry(proposal.proposalId, detail.value!);
    } catch (_) {
      // No provenance line for this card; the proposal still renders.
      return null;
    }
  }

  Future<MapEntry<String, BdjObjectiveDecision>?> _decision({
    required String m2Id,
    required BdjObjectiveProposal proposal,
    required int revision,
    required String contextId,
  }) async {
    try {
      final decision = await component.api.readDecision(
        assessmentId: m2Id,
        proposalId: proposal.proposalId,
        expectedRevision: revision,
        contextId: contextId,
      );
      if (!decision.ok) return null;
      return MapEntry(proposal.proposalId, decision.value!);
    } catch (_) {
      // The decision badge is omitted rather than failing the whole list.
      return null;
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
        // A refused pass may still have spent its attempt. Re-read the
        // authoritative eligibility quietly, so a spent attempt hides the
        // control instead of inviting a second dispatch the route will refuse.
        await _load(quiet: true);
        return;
      }
      final evaluation = result.value!;
      // A reused response reports the already-persisted set; it did not run a
      // model and must not be presented as an update to anything.
      final reused = evaluation.execution?.reused ?? false;
      setState(() {
        _proposing = false;
        _proposals = evaluation.proposals;
        _execution = evaluation.execution;
        _lastRunExecution = evaluation.execution;
        _updatedProposalIds.clear();
        if (!reused) {
          _updatedProposalIds.addAll(
            evaluation.proposals.map((row) => row.proposalId),
          );
        }
        _decisions.removeWhere(
          (id, _) => !evaluation.proposals.any((row) => row.proposalId == id),
        );
        _notice = evaluation.isEmpty
            ? 'The governed pass completed but produced no research objective '
                  'for this confirmation. Nothing is shown rather than a '
                  'placeholder.'
            : reused
            ? 'This confirmation already used its objective pass. The proposals '
                  'shown are the ones it stored; no new model call was made.'
            : null;
      });
      // Re-read the stored rows and their per-proposal provenance. Without this
      // the browser keeps the evaluate envelope in memory and only a manual
      // Refresh reveals that the result came from a live TokenHarbour call.
      await _load(preserveLastRun: true, quiet: true);
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
      // The decision is stored, so the assessment may have moved a stage. Tell
      // the owner; it re-reads the authoritative record rather than trusting a
      // local increment.
      component.onDecisionRecorded?.call();
    } on Object catch (error) {
      setState(() {
        _busyProposalId = null;
        _notice = 'The decision could not be recorded: $error';
      });
    }
  }

  /// The whole region while it is loading, stale or failed.
  ///
  /// The page's own cards still render beneath the state, so a read in flight
  /// never removes the entrepreneur's objective form from the page.
  Component _state(Component body) => section(classes: 's3o', [
    _shell([
      section(classes: 's3o-section', [body]),
      ...component.trailingSections,
    ], rail: component.railLead),
  ]);

  /// The reading column, plus the rail when there is one.
  ///
  /// A single helper so the three early-return states and the loaded page share
  /// one definition of the layout. `rail` empty means the shell collapses to the
  /// column alone rather than reserving an empty sticky strip.
  Component _shell(List<Component> main, {List<Component> rail = const []}) {
    if (rail.isEmpty) {
      return div(classes: 's3o-main', main);
    }
    return div(classes: 's3o-shell', [
      div(classes: 's3o-main', main),
      aside(classes: 's3o-rail', rail),
    ]);
  }

  @override
  Component build(BuildContext context) {
    if (_loading) {
      return _state(
        const p(
          attributes: {'role': 'status'},
          [Component.text('Reading persisted research objectives…')],
        ),
      );
    }
    if (_staleMessage != null) {
      return _state(
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
      );
    }
    if (_error != null) {
      return _state(
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
      );
    }

    // Partitioned once, in list order, so every count on this page comes from
    // the same three lists and cannot disagree with the cards below.
    final approved = <BdjObjectiveProposal>[];
    final rejected = <BdjObjectiveProposal>[];
    final awaiting = <BdjObjectiveProposal>[];
    for (final proposal in _proposals) {
      switch (proposal.reviewState) {
        case BdjReviewState.approved:
          approved.add(proposal);
        case BdjReviewState.rejected:
          rejected.add(proposal);
        case BdjReviewState.pending:
        case BdjReviewState.unrecognised:
          awaiting.add(proposal);
      }
    }

    // The card's ordinal (`A01`…) is its position in the persisted list, not its
    // position in a partition: a proposal that moves from awaiting to approved
    // keeps the number the reader already saw.
    final ordinal = <String, int>{
      for (var index = 0; index < _proposals.length; index++)
        _proposals[index].proposalId: index + 1,
    };

    final mostSuggested = _proposals
        .where((row) => row.recommendation.status.isSourceConfirmed)
        .length;
    final updatedCount = _proposals
        .where((row) => _updatedProposalIds.contains(row.proposalId))
        .length;

    return section(classes: 's3o', [
      // ------------------------------------------------------------ header
      div(classes: 's3o-head', [
        div(classes: 's3o-head__text', [
          // No eyebrow here. It read "Stage 3 · Business review", which is the
          // page heading immediately above this card in the same words — the
          // stage number is already on the stepper and in the breadcrumb. The
          // card's own title is "Research objectives", so the two levels are
          // page heading then section heading, with nothing repeated between.
          h2(classes: 's3o-title', [Component.text('Research objectives')]),
          p(classes: 's3o-sub', [
            Component.text(
              'Six objectives apply to every assessment. Anything beyond them '
              'is a proposal from the governed BDJ pass, and every proposal '
              'waits for your decision before it joins the research scope.',
            ),
          ]),
        ]),
        div(classes: 's3o-head__actions', [
          ActionButton(
            'Refresh saved view',
            variant: 'ghost',
            onClick: _proposing
                ? null
                : () {
                    // A refresh is a fresh read, not the latest LLM pass: drop
                    // the "updated by this pass" markers before re-reading.
                    _updatedProposalIds.clear();
                    _lastRunExecution = null;
                    _load(quiet: true);
                  },
          ),
          // One control, one label, one authority. It is drawn only while the
          // server reports that this exact context has no recorded attempt, so
          // it disappears once the pass has run — including when it produced
          // nothing — and a rejected proposal cannot bring it back.
          if (_generation.canGenerate)
            ActionButton(
              'Generate research objectives',
              variant: 'secondary',
              onClick: _proposing
                  ? null
                  : () {
                      _propose();
                    },
            ),
        ]),
      ]),

      _shell(
        // ---------------------------------------------------------- main
        [
          if (_execution != null) _executionNote(_execution!),
          if (updatedCount > 0) _noticeCard(updatedCount),
          if (_notice != null)
            div(classes: 'card card--flat', [
              p(classes: 'muted', [Component.text(_notice!)]),
            ]),
          if (_proposing)
            const p(
              attributes: {'role': 'status'},
              [
                Component.text(
                  'Running the governed proposal pass. This may reuse an '
                  'existing attempt rather than dispatching a new one…',
                ),
              ],
            ),

          // ------------------------------------------------- Section A
          _sectionA(),

          // ------------------------------------------------- Section B
          _sectionB(
            // In-scope = everything not rejected, in persisted order.
            inScope: [
              for (final proposal in _proposals)
                if (proposal.reviewState != BdjReviewState.rejected) proposal,
            ],
            ordinal: ordinal,
          ),

          // ------------------------------------------------- history
          _historySection(rejected: rejected, ordinal: ordinal),

          ...component.trailingSections,
        ],
        // ------------------------------------------------------------- rail
        rail: [
          // The execution status first: it answers "is the work this page
          // depends on running?" before the reader asks about scope.
          ...component.railLead,
          _scopeRail(
            approved: approved.length,
            awaiting: awaiting.length,
            rejected: rejected.length,
            mostSuggested: mostSuggested,
          ),
          _contextCard(),
          // A third card used to sit here titled "Business review status",
          // carrying an objectives/decided/rejected/validation checklist. Every
          // count on it was already in the scope rail above, and its title
          // collided with the execution panel's — two different cards on one
          // page claiming to be the business review status (D-H01 / D-M07).
        ],
      ),
    ]);
  }

  /// Section A — the six fixed objectives.
  ///
  /// Read-only on purpose. The set is a property of the instrument, so offering
  /// a remove control here would promise something the server would refuse; the
  /// only decision Stage 3 takes is on the proposals in Section B.
  Component _sectionA() => section(classes: 's3o-section', [
    div(classes: 's3o-section__head', [
      div(classes: 's3o-section__text', [
        p(classes: 's3o-kicker', [Component.text('Section A · Required')]),
        h3(classes: 's3o-section__title', [
          Component.text('Fixed research objectives'),
        ]),
        p(classes: 's3o-section__help', [
          Component.text(
            'The same six objectives apply to every assessment. They are not '
            'removed or replaced here, and a proposal that cites one is bound '
            'to it.',
          ),
        ]),
      ]),
      StatusBadge(
        '${fixedResearchObjectives.length} included',
        tone: 'neutral',
      ),
    ]),
    div(classes: 's3o-grid', [
      for (final objective in fixedResearchObjectives) _fixedTile(objective),
    ]),
    p(classes: 's3o-foot', [
      Icon('verified', size: 'sm'),
      Component.text(
        'All six are included in every assessment. Inclusion does not '
        'establish measurement validity.',
      ),
    ]),
  ]);

  Component _fixedTile(FixedObjective objective) => div(classes: 's3o-tile', [
    div(classes: 's3o-tile__top', [
      span(classes: 's3o-tile__id', [Component.text(objective.id)]),
      span(
        classes: 's3o-tile__info',
        attributes: {'title': objective.describes},
        [Icon('info', size: 'sm')],
      ),
    ]),
    span(classes: 's3o-tile__label', [Component.text(objective.label)]),
    span(classes: 's3o-tile__meta', [Component.text('Required')]),
    p(classes: 's3o-tile__desc', [Component.text(objective.describes)]),
  ]);

  /// Section B — the additional objectives the governed pass proposed.
  ///
  /// Awaiting and approved proposals share the section because they share a
  /// meaning: both are in scope. Rejected ones are excluded and move to the
  /// history card, which is the only place a rejection is shown.
  ///
  /// The cards keep the persisted list order rather than grouping by decision.
  /// Grouping would renumber the reader's list on every approval — `A03` would
  /// jump above `A01` the moment `A01` was accepted — and the ordinal is the
  /// only stable handle a reader has on a proposal.
  Component _sectionB({
    required List<BdjObjectiveProposal> inScope,
    required Map<String, int> ordinal,
  }) {
    return section(classes: 's3o-section', [
      div(classes: 's3o-section__head', [
        div(classes: 's3o-section__text', [
          p(classes: 's3o-kicker', [Component.text('Section B · Optional')]),
          h3(classes: 's3o-section__title', [
            Component.text('Additional research objectives'),
          ]),
          p(classes: 's3o-section__help', [
            Component.text(
              'Proposed from the confirmed business context. Each one is a '
              'candidate: approving records your direction and does not '
              'authorise question generation.',
            ),
          ]),
        ]),
        StatusBadge('${_proposals.length} proposed', tone: 'neutral'),
      ]),

      if (_proposals.isEmpty && !_proposing)
        // "Empty" has two causes and the reader is owed the right one: a pass
        // that ran and stored nothing, or a pass that has not run. The server's
        // eligibility answer is what distinguishes them.
        div(classes: 's3o-empty', [
          Component.text(switch (_generation.reason) {
            BdjGenerationReason.attemptSpent ||
            BdjGenerationReason.inProgress =>
              'The governed BDJ pass for this confirmation has run and stored '
                  'no proposal. An empty result is shown as empty: no example '
                  'or placeholder objective is displayed in its place.',
            BdjGenerationReason.notStarted =>
              'No objective proposal has been generated for this confirmation '
                  'yet. Generating one runs the governed BDJ pass and stores '
                  'what it proposes.',
            _ =>
              'No proposal is stored for this confirmation. Whether a pass has '
                  'already run here could not be established, so nothing is '
                  'inferred from the empty list.',
          }),
        ])
      else if (inScope.isEmpty)
        const div(classes: 's3o-empty', [
          Component.text(
            'Every proposal for this confirmation has been rejected. The '
            'rejected records are listed under read-only history below.',
          ),
        ])
      else
        for (final proposal in inScope)
          _proposalCard(
            proposal,
            _decisions[proposal.proposalId],
            ordinal: ordinal[proposal.proposalId] ?? 0,
          ),

      if (inScope.any(
        (row) => row.reviewState == BdjReviewState.approved,
      ))
        p(classes: 's3o-inline-note', [
          Icon('info', size: 'sm'),
          Component.text(
            'An approved objective is a research direction, not evidence of '
            'demand. Question generation needs its own permission on Stage 4.',
          ),
        ]),
    ]);
  }

  /// The rejected objectives, read-only.
  ///
  /// Shown even when empty, because "nothing was rejected" is a fact a reader
  /// checking the scope needs, and an absent section reads as "not checked".
  Component _historySection({
    required List<BdjObjectiveProposal> rejected,
    required Map<String, int> ordinal,
  }) =>
      // Collapsed by default. Rejected objectives are a record, not a task, so
      // they must not occupy the working view; the count stays visible in the
      // summary line so their existence is never hidden. `details`/`summary`
      // give keyboard operation and expanded-state semantics for free.
      details(classes: 's3o-section s3o-section--history', [
        summary(classes: 's3o-section__head', [
          div(classes: 's3o-section__text', [
            p(classes: 's3o-kicker', [Component.text('Read-only history')]),
            h3(classes: 's3o-section__title', [
              Component.text('Rejected objectives (${rejected.length})'),
            ]),
            p(classes: 's3o-section__help', [
              Component.text(
                'Excluded from the current research scope and from Stage 4. A '
                'rejection is a persisted record; re-running the pass does not '
                'undo it.',
              ),
            ]),
          ]),
        ]),
        if (rejected.isEmpty)
          const div(classes: 's3o-empty', [
            Component.text(
                'No objective has been rejected for this confirmation.'),
          ])
        else
          for (final proposal in rejected)
            _proposalCard(
              proposal,
              _decisions[proposal.proposalId],
              ordinal: ordinal[proposal.proposalId] ?? 0,
              readOnly: true,
            ),
      ]);

  /// The rail's scope summary.
  Component _scopeRail({
    required int approved,
    required int awaiting,
    required int rejected,
    required int mostSuggested,
  }) {
    final total = _proposals.length;
    final decided = approved + rejected;
    final selected = fixedResearchObjectives.length + approved;
    final share = total == 0 ? 0.0 : decided / total;

    return div([
      p(classes: 's3o-rail__label', [
        Component.text('Current research scope'),
      ]),
      div(classes: 's3o-rail__card', [
        h4(classes: 's3o-rail__title', [Component.text('Research summary')]),
        p(classes: 's3o-rail__hint', [
          Component.text(
            'Counts are of persisted rows on this confirmation.',
          ),
        ]),
        div(classes: 's3o-row', [
          span(classes: 's3o-row__label', [
            Component.text('Fixed objectives'),
          ]),
          span(
            classes: 's3o-row__value',
            [Component.text('${fixedResearchObjectives.length}')],
          ),
        ]),
        div(classes: 's3o-row', [
          span(classes: 's3o-row__label', [
            Component.text('Additional proposed'),
          ]),
          span(
            classes: 's3o-row__value',
            [Component.text('$total')],
          ),
        ]),
        div(classes: 's3o-row', [
          span(classes: 's3o-row__label', [
            Component.text('Additional approved'),
          ]),
          span(classes: 's3o-row__value', [Component.text('$approved')]),
        ]),
        div(classes: 's3o-row', [
          span(classes: 's3o-row__label', [
            Component.text('Awaiting decision'),
          ]),
          span(classes: 's3o-row__value', [Component.text('$awaiting')]),
        ]),
        div(classes: 's3o-row s3o-row--muted', [
          span(classes: 's3o-row__label', [
            Component.text('Rejected · history'),
          ]),
          span(classes: 's3o-row__value', [Component.text('$rejected')]),
        ]),
        if (mostSuggested > 0)
          div(classes: 's3o-row s3o-row--muted', [
            span(classes: 's3o-row__label', [
              Component.text('Source-confirmed'),
            ]),
            span(
              classes: 's3o-row__value',
              [Component.text('$mostSuggested')],
            ),
          ]),
        div(classes: 's3o-meter', [
          div(
            classes: 's3o-meter__track',
            attributes: {
              'role': 'img',
              'aria-label':
                  '${(share * 100).round()} percent of proposals decided',
            },
            [
              div(
                classes: 's3o-meter__fill',
                attributes: {
                  'style': 'width: ${(share * 100).toStringAsFixed(0)}%',
                },
                const [],
              ),
            ],
          ),
          div(classes: 's3o-meter__legend', [
            span([Component.text('$decided of $total decided')]),
            span([Component.text('${(share * 100).round()}%')]),
          ]),
        ]),
        div(classes: 's3o-total', [
          span(classes: 's3o-total__label', [
            Component.text('Objectives in scope'),
          ]),
          span(classes: 's3o-total__value', [Component.text('$selected')]),
        ]),
      ]),
    ]);
  }

  /// The confirmed business context this review is bound to.
  ///
  /// Collapsed by default: it is provenance, not something the reader decides
  /// on. The identifiers are shown because a stale-source report names them, and
  /// a reader comparing the two needs to see the same values.
  Component _contextCard() => details(classes: 's3o-context', [
    summary([
      Component.text('View confirmed business context'),
      Icon('chevron_right', size: 'sm'),
    ]),
    div(classes: 's3o-context__body', [
      div(classes: 's3o-row', [
        span(classes: 's3o-row__label', [
          Component.text('M2 assessment'),
        ]),
        span(classes: 's3o-row__value', [Component.text(_m2Id)]),
      ]),
      div(classes: 's3o-row', [
        span(classes: 's3o-row__label', [Component.text('Revision')]),
        span(classes: 's3o-row__value', [Component.text('$_revision')]),
      ]),
      div(classes: 's3o-row', [
        span(classes: 's3o-row__label', [
          Component.text('Confirmation'),
        ]),
        span(classes: 's3o-row__value', [Component.text(_confirmationId)]),
      ]),
      div(classes: 's3o-row', [
        span(classes: 's3o-row__label', [Component.text('Context')]),
        span(classes: 's3o-row__value', [Component.text(_contextId)]),
      ]),
      p(classes: 's3o-note', [
        Component.text(
          'Objectives are only proposed from a context that is current for this '
          'confirmation. If either side moves, this page stops showing '
          'proposals until it is re-read.',
        ),
      ]),
    ]),
  ]);

  Component _noticeCard(int updatedCount) => div(
    classes: 'card card--flat',
    attributes: const {'role': 'status', 'aria-live': 'polite'},
    [
      p([
        Component.text(
          'Latest governed LLM result updated $updatedCount '
          'research objective${updatedCount == 1 ? '' : 's'}; '
          'the updated objective(s) are highlighted below.',
        ),
      ]),
      if (_lastRunExecution != null && !_lastRunExecution!.isSimulated)
        p(classes: 'muted', [
          const Component.text(
            'Source: live model result from TokenHarbour, not synthetic data.',
          ),
        ]),
    ],
  );

  /// Which producer wrote these rows.
  ///
  /// Deliberately narrow: the execution rail already reports state, attempt,
  /// receipt and persistence for the same pass, and repeating them here was the
  /// "redundant execution note" the audit found. What the rail cannot report is
  /// *who produced the text* — a simulated pass must never read like a live
  /// model result — so only that survives.
  Component _executionNote(BdjExecution execution) {
    final parts = <String>[
      if (execution.isSimulated)
        'Simulated pass — no cloud model was called'
      else
        'Execution mode ${execution.executionMode}',
      if (execution.modelProvider.isNotEmpty) execution.modelProvider,
      if (execution.promptVersion.isNotEmpty)
        'prompt ${execution.promptVersion}',
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

  /// One proposal, as a card in Section B or in the read-only history.
  ///
  /// The card leads with what the reader must judge — the objective and the
  /// decision it still needs — and folds the provenance behind a disclosure.
  /// Nothing is dropped: the gap, the source citations, the execution
  /// provenance and the admission block all remain, one click away. The
  /// admission *state* stays in the badge row when it exists, because
  /// "admitted" and "held" change what the reader can do next and must not need
  /// a disclosure to be seen.
  Component _proposalCard(
    BdjObjectiveProposal proposal,
    BdjObjectiveDecision? decision, {
    required int ordinal,
    bool readOnly = false,
  }) {
    final recommendation = proposal.recommendation;
    final busy = _busyProposalId == proposal.proposalId;
    final isDecided = proposal.reviewState.hasDecision;
    final admission = decision?.admission;
    final provenance = _provenanceLine(proposal.proposalId);
    final updated = _updatedProposalIds.contains(proposal.proposalId);

    return div(classes: 's3o-prop', [
      div(classes: 's3o-prop__top', [
        span(classes: 's3o-prop__id', [
          Component.text('A${ordinal.toString().padLeft(2, '0')}'),
        ]),
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
            BdjReviewState.pending => 'Pending review',
            BdjReviewState.unrecognised => 'Review state unreadable',
          },
          tone: switch (proposal.reviewState) {
            BdjReviewState.approved => 'success',
            BdjReviewState.rejected => 'danger',
            BdjReviewState.pending => 'warning',
            BdjReviewState.unrecognised => 'neutral',
          },
        ),
        if (isDecided && admission != null)
          StatusBadge(
            switch (admission.state) {
              BdjAdmissionState.admitted => 'Admitted',
              BdjAdmissionState.held => 'Admission held',
              BdjAdmissionState.notAdmissible => 'Not admissible',
              BdjAdmissionState.unrecognised => 'Admission unreadable',
            },
            tone: switch (admission.state) {
              BdjAdmissionState.admitted => 'success',
              BdjAdmissionState.held => 'warning',
              BdjAdmissionState.notAdmissible => 'danger',
              BdjAdmissionState.unrecognised => 'neutral',
            },
            dot: true,
          ),
        if (updated) StatusBadge('Updated by latest LLM pass', tone: 'action'),
      ]),
      h4(classes: 's3o-prop__title', [
        Component.text(recommendation.researchObjective),
      ]),
      // The subtitle names the objective's *kind*, nothing else.
      //
      // It used to read "An additional objective you approved", and it rendered
      // for every additional objective whatever its `review_state` — so a
      // candidate still awaiting a decision, and objectives the owner had
      // rejected, each carried a claim of approval the record did not support.
      //
      // It is now shown only while the decision is genuinely outstanding, and it
      // names the kind rather than the decision. Once decided, the badge above is
      // the only statement about the decision, and this line disappears so the
      // two can never disagree.
      if (proposal.reviewState == BdjReviewState.pending)
        p(classes: 's3o-prop__body', [
          Component.text('Additional to the mandatory research objectives'),
        ]),
      if (recommendation.reason.isNotEmpty)
        p(classes: 's3o-prop__body', [Component.text(recommendation.reason)]),

      details(classes: 's3o-details', [
        summary([Component.text('Supporting information')]),
        div(classes: 's3o-details__body', [
          if (recommendation.problem != null)
            p(classes: 's3o-prop__body', [
              Component.text('Confirmed gap: ${recommendation.problem}'),
            ]),
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
            p(classes: 's3o-prop__body', [
              Component.text(
                'No source reference: this is an exploratory objective, not a '
                'source-confirmed gap.',
              ),
            ]),
          if (!recommendation.isProperlySourced)
            p(classes: 's3o-prop__body', [
              Component.text(
                'This proposal claims a source-confirmed gap but does not carry '
                'both a problem statement and a source reference. Treat it as '
                'unverified.',
              ),
            ]),
          // Provenance of the stored row, so a reader can tell a live model
          // result from a simulated one without running anything.
          ?provenance,
          // Decision and admission are rendered as two separate facts.
          if (isDecided && admission != null)
            div(classes: 'card card--flat stack stack--xs', [
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
              // Three different things, named separately, because an owner
              // reading this card needs to know which of them is waiting on
              // them. Before this line the block was read as "approval was not
              // enough, do something else" — which is wrong under contract 2.1:
              // the approval is the authority, the admission is a separate axis,
              // and eligibility is a property of the objective's measurement.
              p(classes: 'muted', [
                Component.text(
                  'Three separate things. Your approval is the authority for '
                  'this objective (contract 2.1) and is not repeated later. '
                  'Admission is a second, independent record: a refusal here is '
                  'a policy result, not an unfinished step of yours. QG '
                  'eligibility — whether this objective can be turned into a '
                  'fixed-option question at all — is reported check by check on '
                  'Stage 4, next to the objective.',
                ),
              ]),
            ])
          else if (isDecided)
            p(classes: 's3o-prop__body', [
              Component.text(
                'The decision is recorded. Its admission state could not be read '
                'back, so no downstream authority is claimed.',
              ),
            ]),
        ]),
      ]),

      if (!isDecided && !readOnly)
        div(classes: 's3o-prop__actions', [
          ActionButton(
            'Reject',
            variant: 'ghost',
            onClick: busy
                ? null
                : () {
                    _decide(proposal, 'REJECTED');
                  },
          ),
          ActionButton(
            'Approve objective',
            // `accent` rather than `primary`: the page's primary pill is ink,
            // which reads as a neutral control beside a destructive Reject.
            // The affirmative action takes the theme's blue action token.
            variant: 'accent',
            onClick: busy
                ? null
                : () {
                    _decide(proposal, 'APPROVED');
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
