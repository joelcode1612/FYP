import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:sitewise_jaspr_web/features/assessment/application/execution_status_poller.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage_four_five_api.dart';

/// [RailReadState] is defined beside the poller that produces it, and
/// re-exported here because the rail is its only consumer: a caller that mounts
/// this panel should not have to import the polling controller to say whether a
/// read has answered.
export 'package:sitewise_jaspr_web/features/assessment/application/execution_status_poller.dart'
    show RailReadState;

/// A compact, vertical, evidence-driven execution rail for one AI purpose.
///
/// Why four milestones and not five
/// --------------------------------
/// ``DISPATCHED`` is absent because nothing durable records it: the ledger has
/// no dispatch timestamp and the provider adapter's ``dispatched`` flag is set
/// when the response headers arrive, then dies with the request. Drawing a
/// "Dispatched" tick would assert a fact the system cannot prove, so the
/// milestone is omitted and named in [unprovable] instead (CP-PROG-03).
///
/// What this component will not do
/// -------------------------------
/// * It never computes a percentage. The rail shows discrete evidence, and the
///   only moving element is an indeterminate pulse on the step whose evidence
///   has not arrived.
/// * It never changes execution state. Expanding a milestone is a local
///   ``setState``; it issues no request, retries nothing and authorises nothing.
/// * It never invents a transition. Milestone statuses come from the server's
///   own projection of the ledger state; when an older server does not send
///   them, the rail degrades to "status unavailable" rather than guessing.
///
/// Accessibility
/// -------------
/// Each milestone is a native ``button`` with ``aria-expanded`` and
/// ``aria-controls``, so it is reachable and operable by keyboard without a
/// custom key handler, and screen readers announce the expanded state.
///
/// What the reader is allowed to conclude about the *read*, as distinct from
/// the execution it describes, is [RailReadState] — defined with
/// `ExecutionStatusPoller`, which is what produces it.

/// One label/value pair for the collapsed "More details" block.
///
/// A record rather than a map so the caller's order is preserved and two rows
/// with the same label cannot silently collapse into one.
typedef ExecutionDetail = ({String label, String value});

class AiExecutionProgressPanel extends StatefulComponent {
  const AiExecutionProgressPanel({
    required this.title,
    required this.execution,
    this.purposeKey = 'ai',
    this.readState = RailReadState.loaded,
    this.milestones = const <String>[
      'RESERVED',
      'RETURNED',
      'VALIDATED',
      'PERSISTED',
    ],
    this.unprovable = const <String>['DISPATCHED'],
    this.detailFacts = const <ExecutionDetail>[],
    this.detailScope =
        'These are recorded facts about one attempt.',
    this.onRefresh,
    this.refreshBusy = false,
  });

  /// Card heading, e.g. "Business review status".
  final String title;

  /// The current execution, or null when the status read failed.
  final AiExecutionPurpose? execution;

  /// Namespace for DOM ids, so two rails on one page cannot collide.
  final String purposeKey;

  /// Whether the read has answered, not answered yet, or failed.
  final RailReadState readState;

  /// The milestones to draw, in order. Supplied by the server contract.
  final List<String> milestones;

  /// Milestones the system cannot prove. Rendered as a single muted footnote,
  /// never as a tick and never as a fifth row.
  final List<String> unprovable;

  /// Verified technical facts for the collapsed "More details" block.
  ///
  /// The caller supplies only what the backend actually returned; an absent
  /// fact is omitted rather than printed as a placeholder. The block is
  /// presentation only — expanding it issues no request.
  final List<ExecutionDetail> detailFacts;

  /// One sentence saying what [detailFacts] contains, printed under them.
  ///
  /// The default is the attempt-only wording, because a rail built from one
  /// purpose contains nothing else. A caller that also passes facts about the
  /// *source* the attempt read supplies its own sentence, so the footnote stays
  /// true instead of describing source facts as attempt facts. The two classes
  /// come from different stores and must not read as one (DD-124).
  final String detailScope;

  /// Re-reads the status. Absent when the caller has no refresh action.
  final void Function()? onRefresh;

  final bool refreshBusy;

  @override
  State<AiExecutionProgressPanel> createState() =>
      _AiExecutionProgressPanelState();
}

class _AiExecutionProgressPanelState extends State<AiExecutionProgressPanel> {
  /// Which milestones are expanded. Presentation only — never sent anywhere.
  final Set<String> _open = <String>{};

  static const _labels = <String, String>{
    'RESERVED': 'Reserved',
    'RETURNED': 'Returned',
    'VALIDATED': 'Validated',
    'PERSISTED': 'Persisted',
  };

  static const _descriptions = <String, String>{
    'RESERVED':
        'An authorised attempt was durably reserved in the execution ledger, '
        'and the reservation was committed before anything was sent to the '
        'provider. This is the only step that is certain to have happened once '
        'an attempt exists.',
    'RETURNED':
        'The provider answered this exact attempt. A receipt is recorded whether '
        'the answer was usable or refused, so a receipt alone does not mean the '
        'output was good.',
    'VALIDATED':
        'The returned output passed the required technical and domain checks. '
        'The structural check runs before the receipt is written; the domain '
        'checks are recorded against the stored result.',
    'PERSISTED':
        'The validated result was committed and is bound to this exact attempt. '
        'A stored record that cannot be tied to this attempt does not count.',
  };

  static const _statusWords = <String, String>{
    'COMPLETED': 'Completed',
    'ACTIVE': 'In progress',
    'PENDING': 'Pending',
    'FAILED': 'Failed',
    'UNKNOWN': 'Outcome unknown',
  };

  static const _marks = <String, String>{
    'COMPLETED': '✓',
    'ACTIVE': '·',
    'PENDING': '○',
    'FAILED': '!',
    'UNKNOWN': '?',
  };

  String _statusFor(String name) {
    final execution = component.execution;
    if (execution == null) return 'PENDING';
    for (final milestone in execution.milestones) {
      if (milestone.name == name) return milestone.status;
    }
    // An older server that does not send per-milestone status cannot place the
    // rail. Say so rather than drawing a plausible one.
    return 'PENDING';
  }

  String? _factFor(String name) {
    final execution = component.execution;
    if (execution == null) return null;
    switch (name) {
      case 'RESERVED':
        final at = execution.reservedAt;
        final attempt = execution.attemptNo;
        final parts = <String>[
          if (attempt != null) 'attempt $attempt',
          if (at != null) 'reserved $at',
          if (execution.attemptsReserved > 1)
            '${execution.attemptsReserved} attempts recorded',
        ];
        return parts.isEmpty ? null : parts.join(' · ');
      case 'RETURNED':
        final outcome = execution.receiptOutcome;
        final at = execution.receiptAt;
        if (outcome == null) return null;
        return [
          'receipt: $outcome',
          if (at != null) 'recorded $at',
        ].join(' · ');
      case 'VALIDATED':
        if (execution.pendingValidation > 0) {
          return '${execution.pendingValidation} record(s) still awaiting validation';
        }
        return null;
      case 'PERSISTED':
        if (execution.persisted > 0) {
          return '${execution.persisted} record(s) bound to this attempt';
        }
        if (!execution.attributable && execution.assessmentWidePersisted > 0) {
          // The count is real; the attribution is not. Say both.
          return '${execution.assessmentWidePersisted} record(s) stored for this '
              'assessment, none attributable to this attempt';
        }
        return null;
      default:
        return null;
    }
  }

  /// A short, non-diagnostic explanation of a blocker.
  ///
  /// Reason codes are engineering vocabulary. They are shown only for a failed
  /// or unknown outcome, where withholding them would leave the owner without
  /// any account of what stopped.
  String? _blockerFor() {
    final execution = component.execution;
    if (execution == null) return null;
    switch (execution.state) {
      case 'FAILED':
        return 'This attempt was refused. It is spent and is not retried '
            'automatically.';
      case 'UNKNOWN_OUTCOME':
        return 'The attempt was reserved and no receipt was recorded. Whether '
            'the provider was reached is unknown, the attempt is spent, and it '
            'is not retried automatically.';
      default:
        return null;
    }
  }

  @override
  Component build(BuildContext context) {
    final execution = component.execution;
    return section(
      classes: 'aip',
      attributes: {'aria-label': component.title},
      [
        div(classes: 'aip__head', [
          h4(classes: 'aip__title', [Component.text(component.title)]),
          if (execution != null && execution.stale)
            span(classes: 'aip__badge aip__badge--stale', [
              Component.text('Not current'),
            ]),
        ]),
        if (component.readState == RailReadState.pending)
          _pending()
        else if (execution == null)
          component.readState == RailReadState.failed
              ? _unavailable()
              : _missing()
        else ...[
          div(classes: 'aip__rail', [
            for (var i = 0; i < component.milestones.length; i++)
              _milestone(component.milestones[i], i, component.milestones.length),
          ]),
          if (_blockerFor() case final blocker?)
            p(classes: 'aip__blocker', [Component.text(blocker)]),
          if (component.unprovable.isNotEmpty)
            p(classes: 'aip__note', [
              Component.text(
                '${component.unprovable.map(_human).join(', ')} is not recorded by '
                'the execution ledger, so it is not shown as a step.',
              ),
            ]),
          _moreDetails(),
        ],
      ],
    );
  }

  /// Not asked yet. Deliberately makes no statement about the ledger.
  Component _pending() => div(classes: 'aip__pending', [
    p(classes: 'aip__pending-line', [
      Component.text('Reading execution status…'),
    ]),
    for (var i = 0; i < component.milestones.length; i++)
      div(classes: 'aip__pending-row', [
        span(
          classes: 'aip__pending-dot',
          attributes: const {'aria-hidden': 'true'},
          const [],
        ),
        span(
          classes: 'aip__pending-bar',
          attributes: const {'aria-hidden': 'true'},
          const [],
        ),
      ]),
  ]);

  /// The response arrived but did not carry this purpose. A gap in the
  /// contract, not a failed read and not a stage that never ran.
  ///
  /// The disclosure still renders when it has facts. A reading that omits this
  /// purpose says nothing about the *source* the stage reads, and the source
  /// facts are true whether or not an attempt exists — hiding them here would
  /// make a contract gap look like an empty record.
  Component _missing() => div(classes: 'aip__unavailable', [
    p([
      Component.text(
        'This status response did not include ${component.title.toLowerCase()}. '
        'Nothing is inferred from its absence.',
      ),
    ]),
    if (component.onRefresh != null)
      button(
        attributes: const {'type': 'button'},
        classes: 'aip__refresh',
        onClick: component.refreshBusy ? null : component.onRefresh,
        [Component.text(component.refreshBusy ? 'Checking…' : 'Check again')],
      ),
    _moreDetails(),
  ]);

  /// Collapsed technical traceability.
  ///
  /// A native ``details`` element: closed by default, keyboard-operable, and
  /// purely local. Opening it issues no request and changes nothing but this
  /// one flag.
  ///
  /// The flag is held here instead of being left to the browser. A bare
  /// ``details`` keeps `open` only in the DOM, while this card is re-rendered
  /// every time a status reading arrives — and jaspr re-applies the attribute
  /// set it was given, which has no `open` in it. The reader would open the
  /// panel and it would snap shut on the next poll. Owning the flag makes the
  /// disclosure survive a re-read.
  ///
  /// The browser's own toggle is left alone rather than suppressed: it flips
  /// the element in the same direction as this flag, once per click, and the
  /// next render writes the flag back over it. Suppressing it would also mean
  /// calling `preventDefault`, which the server-side test DOM cannot do.
  bool _moreOpen = false;

  Component _moreDetails() {
    if (component.detailFacts.isEmpty) return div(const []);
    return details(
      classes: 'aip__more',
      open: _moreOpen,
      [
        summary(
          classes: 'aip__more-summary',
          events: {'click': (_) => setState(() => _moreOpen = !_moreOpen)},
          [Component.text('More details')],
        ),
        dl(classes: 'aip__facts', [
          for (final fact in component.detailFacts) ...[
            dt(classes: 'aip__fact-label', [Component.text(fact.label)]),
            dd(classes: 'aip__fact-value', [Component.text(fact.value)]),
          ],
        ]),
        p(classes: 'aip__more-note', [
          Component.text(
            '${component.detailScope} Opening this panel does not contact the '
            'provider or change anything.',
          ),
        ]),
      ],
    );
  }

  Component _unavailable() => div(classes: 'aip__unavailable', [
    p([
      Component.text(
        'Execution status is unavailable. The ledger could not be read, which is '
        'not the same as "nothing has run".',
      ),
    ]),
    if (component.onRefresh != null)
      button(
        attributes: const {'type': 'button'},
        classes: 'aip__refresh',
        onClick: component.refreshBusy ? null : component.onRefresh,
        [Component.text(component.refreshBusy ? 'Checking…' : 'Check again')],
      ),
    // A failed ledger read says nothing about the *source* facts, which the
    // caller read from a different endpoint. Keeping them visible is what
    // stops one failed read from erasing another read's answer.
    _moreDetails(),
  ]);

  Component _milestone(String name, int index, int total) {
    final status = _statusFor(name);
    final open = _open.contains(name);
    final id = '${component.purposeKey}-${name.toLowerCase()}';
    final fact = _factFor(name);
    final label = _labels[name] ?? _human(name);
    final last = index == total - 1;
    return div(
      classes: 'aip__row aip__row--${status.toLowerCase()}'
          '${last ? ' aip__row--last' : ''}',
      [
        div(classes: 'aip__marker', [
          span(
            classes: 'aip__dot aip__dot--${status.toLowerCase()}',
            attributes: {'aria-hidden': 'true'},
            [Component.text(_marks[status] ?? '○')],
          ),
        ]),
        div(classes: 'aip__content', [
          button(
            attributes: {
              'type': 'button',
              'aria-expanded': open ? 'true' : 'false',
              'aria-controls': id,
            },
            classes: 'aip__toggle',
            onClick: () => setState(() {
              if (!_open.remove(name)) _open.add(name);
            }),
            [
              span(classes: 'aip__name', [Component.text(label)]),
              span(classes: 'aip__status', [
                Component.text(_statusWords[status] ?? status),
              ]),
            ],
          ),
          if (open)
            div(
              attributes: {'id': id, 'role': 'region'},
              classes: 'aip__detail',
              [
                p([Component.text(_descriptions[name] ?? '')]),
                if (fact != null) p(classes: 'aip__fact', [Component.text(fact)]),
              ],
            ),
        ]),
      ],
    );
  }

  static String _human(String value) {
    if (value.isEmpty) return value;
    final lower = value.toLowerCase().replaceAll('_', ' ');
    return lower[0].toUpperCase() + lower.substring(1);
  }
}
