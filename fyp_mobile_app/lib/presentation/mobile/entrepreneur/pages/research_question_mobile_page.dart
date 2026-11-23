import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../core/di/service_locator.dart';
import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../../../shared/presentation/layouts/mobile_app_shell.dart';
import '../../../../shared/presentation/components/m3_kit.dart';

/// The confirmed research objective a candidate belongs to.
///
/// Travels as a route argument. Every id comes from persisted M2 state: the
/// assessment, its confirmation and the confirmed objective. `expectedRevision`
/// is the confirmation revision the objective is pinned to — the server answers
/// 409 when it is stale, and that conflict is shown rather than retried blindly.
@immutable
class ResearchQuestionTarget {
  final String assessmentId;
  final String confirmationId;
  final String objectiveId;
  final int expectedRevision;
  final String? contextId;
  final String objectiveText;

  const ResearchQuestionTarget({
    required this.assessmentId,
    required this.confirmationId,
    required this.objectiveId,
    required this.expectedRevision,
    this.contextId,
    this.objectiveText = '',
  });

  /// Builds a target only from persisted ids.
  ///
  /// An unconfirmed objective has no confirmation id, so it cannot produce a
  /// target: the caller must show the honest empty state instead of inventing
  /// one. A missing context id is allowed here — the screen then shows its
  /// explicit "persisted business context required" state rather than preparing.
  factory ResearchQuestionTarget.fromPersistedIds({
    required String assessmentId,
    required String confirmationId,
    required String objectiveId,
    required int expectedRevision,
    String? contextId,
    String objectiveText = '',
  }) {
    if (assessmentId.isEmpty ||
        confirmationId.isEmpty ||
        objectiveId.isEmpty ||
        expectedRevision < 0) {
      throw ArgumentError(
        'A research target requires persisted assessment, confirmation and '
        'objective ids with a non-negative revision.',
      );
    }
    return ResearchQuestionTarget(
      assessmentId: assessmentId,
      confirmationId: confirmationId,
      objectiveId: objectiveId,
      expectedRevision: expectedRevision,
      contextId: contextId,
      objectiveText: objectiveText,
    );
  }

  /// Accepts the typed target or a plain map, so a deep link and an in-app
  /// push use the same route without a second argument format. A map missing
  /// the assessment or confirmation ids is rejected — that would be an
  /// unconfirmed objective, which this screen must not invent.
  static ResearchQuestionTarget? fromArguments(Object? arguments) {
    if (arguments is ResearchQuestionTarget) return arguments;
    if (arguments is Map) {
      final assessment = arguments['assessment'];
      final confirmation = arguments['confirmation'];
      final objective = arguments['objective'] ?? arguments['objectiveId'];
      final revision = arguments['revision'] ?? arguments['expectedRevision'];
      if (assessment is! String ||
          assessment.isEmpty ||
          confirmation is! String ||
          confirmation.isEmpty ||
          objective is! String ||
          objective.isEmpty ||
          revision is! int) {
        return null;
      }
      return ResearchQuestionTarget(
        assessmentId: assessment,
        confirmationId: confirmation,
        objectiveId: objective,
        expectedRevision: revision,
        contextId: arguments['context'] is String
            ? arguments['context'] as String
            : null,
        objectiveText: arguments['objectiveText'] is String
            ? arguments['objectiveText'] as String
            : '',
      );
    }
    return null;
  }
}

/// Entrepreneur research-question review (mobile).
///
/// The mobile counterpart of `ResearchCandidatePanel` in the Jaspr app. All
/// parsing, status rules and outcome wording come from `shared_logic`; this
/// widget only renders and forwards intents, exactly like the web panel.
///
/// **A candidate is a proposal.** It is never labelled approved, validated
/// scientifically or ready to field, and the proposal marker is driven by the
/// server's `field_authority`.
///
/// **Review authority is the server's.** The owner-review route records a
/// decision only for an assigned reviewer with a current pending assignment;
/// a refusal is shown verbatim instead of being pre-empted here.
class ResearchQuestionMobilePage extends StatefulWidget {
  final ResearchQuestionTarget? target;

  const ResearchQuestionMobilePage({super.key, this.target});

  @override
  State<ResearchQuestionMobilePage> createState() =>
      _ResearchQuestionMobilePageState();
}

class _ResearchQuestionMobilePageState
    extends State<ResearchQuestionMobilePage> {
  bool _busy = false;
  String? _error;
  String? _notice;

  CandidatePrepareOutcome? _outcome;
  ResearchCandidate? _candidate;
  ResearchCandidateHistory? _history;
  bool _historyOpen = false;

  bool get _canPrepare => widget.target?.contextId != null && !_busy;

  // --- actions -------------------------------------------------------------

  Future<void> _prepare() async {
    final target = widget.target;
    final contextId = target?.contextId;
    if (target == null || contextId == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final outcome = await ServiceLocator.m2.prepareCandidate(
        objectiveId: target.objectiveId,
        expectedRevision: target.expectedRevision,
        contextId: contextId,
      );
      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _candidate = outcome.candidate;
        _notice = outcome.hasCandidate
            ? 'Candidate version ${outcome.candidate!.version} stored. It is a '
                  'proposal awaiting your decision.'
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
    final contextId = widget.target?.contextId;
    if (candidate == null || contextId == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final outcome = await ServiceLocator.m2.reviseCandidate(
        version: candidate.version,
        expectedRevision: widget.target!.expectedRevision,
        contextId: contextId,
      );
      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        if (outcome.hasCandidate) _candidate = outcome.candidate;
        _notice = outcome.hasCandidate
            ? 'Child version ${outcome.candidate!.version} stored; it supersedes '
                  '${candidate.version}.'
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
    final target = widget.target;
    if (target == null) return;
    try {
      final history = await ServiceLocator.m2.candidateHistory(
        target.objectiveId,
        target.expectedRevision,
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
              'The candidate history could not be read. Versions already on '
              'screen are unchanged.',
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
      final stored = await ServiceLocator.m2.readCandidate(version);
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
              'The stored version could not be verified against this '
              'objective.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _record(ResearchReviewAction action) async {
    final candidate = _candidate;
    if (candidate == null || _busy) return;
    final rationale = await _askRationale(action);
    if (rationale == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await ServiceLocator.m2.recordOwnerReview(
        candidate.version,
        action,
        rationale,
      );
      // Re-read: the status shown must be the server's, not the one assumed.
      final refreshed = await ServiceLocator.m2.readCandidate(candidate.version);
      if (!mounted) return;
      setState(() {
        _candidate = refreshed;
        _notice =
            'The server recorded "${action.wireCode}" for version '
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

  Future<String?> _askRationale(ResearchReviewAction action) async {
    final controller = TextEditingController();
    final isRevision = action == ResearchReviewAction.requestRevision;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(action.label),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Version ${_candidate?.version ?? ''}. The decision is recorded '
              'against this version only; it does not publish the question or '
              'authorize fielding.',
              style: const TextStyle(fontSize: 12, height: 1.45),
            ),
            const SizedBox(height: 14),
            Text(
              isRevision
                  ? 'Reason for the revision (required — the next question must '
                        'address it)'
                  : 'Rationale (required)',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            TextField(
              controller: controller,
              maxLines: 4,
              maxLength: 1000,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Explain the decision',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Record decision'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return null;
    final text = result.trim();
    if (text.isEmpty) {
      if (mounted) {
        setState(
          () => _error =
              'A rationale is required. For a revision it is the reason the '
              'next question must address.',
        );
      }
      return null;
    }
    return text;
  }

  // --- rendering -----------------------------------------------------------

  Widget _proposalMarker(FieldAuthority authority) => Container(
    margin: const EdgeInsets.only(top: 14),
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: const Color(0xFFFFFAF0),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFE8B95C)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF7A4D05),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            authority.isProposal
                ? 'PROPOSAL — NOT CONFIRMED'
                : 'AUTHORITY FLAG PRESENT — REVIEW BEFORE USE',
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          candidateProposalNotice,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 11.5,
            height: 1.5,
            color: Color(0xFF5C421A),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Server flags: ${authority.flagSummary}',
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 10.5,
            color: SitewiseM3.muted,
          ),
        ),
      ],
    ),
  );

  Widget _factList(String title, List<String> values) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: SitewiseM3.ink,
          ),
        ),
        const SizedBox(height: 4),
        if (values.isEmpty)
          const Text(
            'None supplied',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 11,
              color: SitewiseM3.muted,
            ),
          ),
        for (final value in values)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              '• $value',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11.5,
                height: 1.45,
                color: SitewiseM3.ink,
              ),
            ),
          ),
      ],
    ),
  );

  Widget _candidateCard(ResearchCandidate candidate) {
    final actions = reviewActionsFor(candidate.decision);
    return M3Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Question candidate',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: SitewiseM3.ink,
                  ),
                ),
              ),
              M3Tag(label: candidate.decision.label, positive: false),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Version ${candidate.version}'
            '${candidate.supersedes == null ? '' : ' · supersedes ${candidate.supersedes}'}',
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 10.5,
              color: SitewiseM3.muted,
            ),
          ),
          if (widget.target?.objectiveText.isNotEmpty ?? false) ...[
            const SizedBox(height: 6),
            Text(
              'Objective: ${widget.target!.objectiveText}',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11,
                height: 1.45,
                color: SitewiseM3.muted,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            candidate.question,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              height: 1.45,
              color: SitewiseM3.ink,
            ),
          ),
          const SizedBox(height: 10),
          if (candidate.options.isEmpty)
            const Text(
              'The candidate returned no answer options.',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11,
                color: SitewiseM3.muted,
              ),
            ),
          for (final option in candidate.options)
            Container(
              margin: const EdgeInsets.only(bottom: 5),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              decoration: BoxDecoration(
                color: SitewiseM3.quiet,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${option.code} — ${option.label}',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 11.5,
                  color: SitewiseM3.ink,
                ),
              ),
            ),
          _proposalMarker(candidate.fieldAuthority),
          if (candidate.referencePeriod != null) ...[
            const SizedBox(height: 10),
            Text(
              'Reference period: ${candidate.referencePeriod}',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11.5,
                height: 1.45,
                color: SitewiseM3.ink,
              ),
            ),
          ],
          if (candidate.measurementDescription != null) ...[
            const SizedBox(height: 6),
            Text(
              'Measurement: ${candidate.measurementDescription}',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11.5,
                height: 1.45,
                color: SitewiseM3.ink,
              ),
            ),
          ],
          if (candidate.denominatorSpecification != null) ...[
            const SizedBox(height: 6),
            Text(
              'Denominator: ${candidate.denominatorSpecification}',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11.5,
                height: 1.45,
                color: SitewiseM3.ink,
              ),
            ),
          ],
          if (candidate.constructInterpretation != null) ...[
            const SizedBox(height: 6),
            Text(
              'How the objective was read: ${candidate.constructInterpretation}',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11,
                height: 1.45,
                color: SitewiseM3.muted,
              ),
            ),
          ],
          _factList('Limitations', candidate.limitations),
          _factList('Unresolved assumptions', candidate.unresolvedAssumptions),
          if (candidate.rationale != null) ...[
            const SizedBox(height: 10),
            Text(
              'Recorded rationale: ${candidate.rationale}',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11,
                height: 1.45,
                color: SitewiseM3.muted,
              ),
            ),
          ],
          const SizedBox(height: 14),
          if (actions.isEmpty)
            const Text(
              'This version already has a recorded decision. A decision is '
              'terminal: asking for a revision creates a child version instead '
              'of reopening this one.',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11,
                height: 1.5,
                color: SitewiseM3.muted,
              ),
            ),
          for (final action in actions)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  key: ValueKey('research-action-${action.wireCode}'),
                  onPressed: _busy ? null : () => _record(action),
                  child: Text(action.label),
                ),
              ),
            ),
          if (canGenerateRevision(candidate.decision))
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: M3PrimaryButton(
                label: 'Generate revision',
                icon: Icons.refresh_rounded,
                onTap: _revise,
              ),
            ),
          const SizedBox(height: 10),
          Text(
            candidateReviewAssignmentNotice,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 10.5,
              height: 1.5,
              color: SitewiseM3.muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _abstentionCard(CandidatePrepareOutcome outcome) => M3Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'What we still need to know',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: SitewiseM3.ink,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'The engine could not draft a question from your confirmed facts, so '
          'it named the facts that are missing. This is a valid answer, not a '
          'failure.',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 11.5,
            height: 1.5,
            color: SitewiseM3.ink,
          ),
        ),
        const SizedBox(height: 10),
        if (outcome.missingBusinessFacts.isEmpty)
          const Text(
            'The answer did not name a specific fact. Add the confirmed detail '
            'the question needs, then prepare again.',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 11,
              color: SitewiseM3.muted,
            ),
          ),
        for (final code in outcome.missingBusinessFacts)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  missingBusinessFactLabel(code),
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    height: 1.4,
                    color: SitewiseM3.ink,
                  ),
                ),
                Text(
                  'Fact code: $code',
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 10,
                    color: SitewiseM3.muted,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        const Text(
          'No candidate was stored. Add the confirmed fact to your business '
          'understanding, then prepare the question again.',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 11,
            height: 1.5,
            color: SitewiseM3.muted,
          ),
        ),
      ],
    ),
  );

  Widget _refusalCard(CandidatePrepareOutcome outcome) {
    final copy = candidateRefusalCopy(outcome);
    return M3Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            copy.title,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: SitewiseM3.ink,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            copy.body,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 11.5,
              height: 1.5,
              color: SitewiseM3.ink,
            ),
          ),
          if (outcome.code != null) ...[
            const SizedBox(height: 6),
            Text(
              'Server code: ${outcome.code}',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 10.5,
                color: SitewiseM3.muted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _historyCard() {
    final history = _history;
    return M3Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Version history',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: SitewiseM3.ink,
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  if (_historyOpen) {
                    _loadHistory();
                  } else {
                    setState(() => _historyOpen = true);
                    _loadHistory();
                  }
                },
                child: Text(_historyOpen ? 'Refresh' : 'Show history'),
              ),
            ],
          ),
          if (!_historyOpen)
            const Text(
              'Open the history to see every stored version and its recorded '
              'decision. Opening it changes nothing.',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11,
                height: 1.5,
                color: SitewiseM3.muted,
              ),
            )
          else if (history == null)
            const Text(
              'Loading stored versions…',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11,
                color: SitewiseM3.muted,
              ),
            )
          else if (history.versions.isEmpty)
            const Text(
              'No stored version exists for this objective yet.',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11,
                color: SitewiseM3.muted,
              ),
            )
          else ...[
            Text(
              '${history.versions.length} stored '
              '${history.versions.length == 1 ? 'version' : 'versions'}, oldest '
              'first. A recorded decision is shown exactly as stored.',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 10.5,
                height: 1.5,
                color: SitewiseM3.muted,
              ),
            ),
            for (final version in history.versions)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      version.question,
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        height: 1.45,
                        color: SitewiseM3.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Version ${version.version}'
                            '${version.supersedes == null ? '' : ' · supersedes ${version.supersedes}'}',
                            style: const TextStyle(
                              fontFamily: kFontFamily,
                              fontSize: 10,
                              color: SitewiseM3.muted,
                            ),
                          ),
                        ),
                        M3Tag(label: version.decision.label, positive: false),
                      ],
                    ),
                    if (version.rationale != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          'Rationale: ${version.rationale}',
                          style: const TextStyle(
                            fontFamily: kFontFamily,
                            fontSize: 10.5,
                            height: 1.45,
                            color: SitewiseM3.muted,
                          ),
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: _busy
                            ? null
                            : () => _openVersion(version.version),
                        child: const Text('Open this version'),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final target = widget.target;
    final outcome = _outcome;
    final candidate = _candidate;
    final refused =
        outcome != null &&
        outcome.kind != CandidateOutcomeKind.validated &&
        outcome.kind != CandidateOutcomeKind.abstention;

    return MobileAppShell(
      title: 'Research question',
      currentRoute: '/entrepreneur/research-questions',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          const M3ScreenHeading(
            eyebrow: 'Research question',
            title: 'Prepare, read and decide.',
            lead:
                'A question generated from your confirmed business facts is a '
                'proposal. You decide what happens to it.',
          ),
          if (target == null)
            M3EmptyState(
              icon: Icons.help_outline_rounded,
              title: 'No research objective selected',
              message:
                  'This screen prepares a question from one confirmed research '
                  'objective. Open it from an objective in your M2 assessment; '
                  'no objective is attached to this screen yet.',
            )
          else ...[
            // Identify the assessment this screen belongs to. These are the
            // persisted ids carried by the target, not display labels invented
            // here: the confirmation id is what the server pins the objective
            // and its expected revision to.
            M3Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Assessment: ${target.assessmentId}',
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 11,
                      height: 1.45,
                      color: SitewiseM3.muted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Confirmation: ${target.confirmationId}',
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 11,
                      height: 1.45,
                      color: SitewiseM3.muted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Objective: ${target.objectiveId}',
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 11,
                      height: 1.45,
                      color: SitewiseM3.muted,
                    ),
                  ),
                ],
              ),
            ),
            if (target.objectiveText.isNotEmpty)
              M3Card(
                child: Text(
                  'Objective text: ${target.objectiveText}',
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 12,
                    height: 1.5,
                    color: SitewiseM3.ink,
                  ),
                ),
              ),
            if (target.contextId == null)
              const M3Banner(
                icon: Icons.lock_outline_rounded,
                text:
                    'A persisted business context is required before a '
                    'candidate can be prepared. Read the business-context '
                    'status for this confirmation first; this screen will not '
                    'invent one.',
              ),
            if (_notice != null)
              M3Banner(icon: Icons.check_circle_outline, text: _notice!),
            if (_error != null)
              M3Banner(icon: Icons.error_outline_rounded, text: _error!),
            const SizedBox(height: 14),
            M3PrimaryButton(
              label: _busy ? 'Working…' : 'Prepare question',
              icon: Icons.auto_awesome_rounded,
              onTap: _canPrepare ? _prepare : () {},
            ),
            const SizedBox(height: 14),
            if (outcome != null && outcome.isAbstention)
              _abstentionCard(outcome),
            if (refused) _refusalCard(outcome),
            if (candidate != null) _candidateCard(candidate),
            if (candidate == null && outcome == null && target.contextId != null)
              const M3DataNote(
                text:
                    'No candidate has been prepared in this session. Preparing '
                    'one calls the live engine; it does not reuse a previous '
                    'answer.',
              ),
            const SizedBox(height: 14),
            _historyCard(),
          ],
        ],
      ),
    );
  }
}
