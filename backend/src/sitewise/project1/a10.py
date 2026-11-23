"""A10 ReportAdmission adapter: the boundary between evidence and a published figure.

What this module is
-------------------
An evaluator that decides whether one claim, backed by one EE-01 measurement
snapshot, may appear in one report section. It verifies; it does not measure. Every
number it sees comes from the snapshot, and every permission it grants comes from
a register it is handed.

What it cannot do
-----------------
Produce ``ADMITTED`` in this checkout. Reaching ``ADMITTED`` requires, at the same
time, an adopted claim register (D-01), an approved suppression floor (D-02), a
section whose state is ``REPORTABLE_WITH_VALID_EVIDENCE`` (D-03), and every
blocking gate closed by a dated act (D-05..D-20). None of those holds, so the
production evaluator returns ``HELD`` or ``REFUSED`` for every input — which is
the intended behaviour, not a gap in the code.

Three structural guarantees
---------------------------
1. **Status is computed, never accepted.** ``ReportAdmissionDecision`` has no
   public constructor that takes a status. ``admit()`` takes no ``admitted``,
   ``status``, ``renderable``, ``skip_gates``, ``assume_floor`` or
   ``trust_snapshot`` parameter, and a test asserts the signature.

2. **A synthetic admission is not an admission.** With a test-only policy the
   status is ``ADMITTED_SYNTHETIC``, a distinct value. The chart bridge maps only
   the exact string ``ADMITTED`` to a renderable chart, so a synthetic decision
   can never make a bar render — even if it were passed into a production path by
   mistake. The evaluator also refuses a test-only policy when constructed for
   ``PRODUCTION``.

3. **Refusal is a fixed code.** Every failure returns one of ``REFUSAL_CODES``
   with the component that failed. Nothing is a free-text message and nothing
   echoes input values, so a refusal cannot leak a protected count.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Literal, Protocol

from sitewise.project1 import a10_gates
from sitewise.project1.a10_claims import AdoptedClaimRegister, Claim
from sitewise.project1.chart_spec import ChartAdmission, MeasurementCounts
from sitewise.project1.contracts import WorkflowHeld, digest

DECISION_VERSION = 'a10-report-admission/1'

ADMITTED = 'ADMITTED'
#: A synthetic test admission. Deliberately *not* ``ADMITTED``: no consumer may
#: treat it as authority, and the chart bridge refuses it.
ADMITTED_SYNTHETIC = 'ADMITTED_SYNTHETIC'
HELD = 'HELD'
REFUSED = 'REFUSED'

#: Fixed, machine-readable refusal codes. Grouped by contract component so a
#: reviewer can tell which prerequisite was missing.
REFUSAL_CODES: dict[str, str] = {
    # C0 — policy provenance
    'A10_SYNTHETIC_POLICY_IN_PRODUCTION': 'C0',
    'A10_SYNTHETIC_IDENTITY_MISSING': 'C0',
    'A10_POLICY_VERSION_MISSING': 'C0',
    'A10_POLICY_VERSION_MISMATCH': 'C0',
    # C2 — claim identity and authorization
    'A10_SECTION_UNKNOWN': 'C2',
    'A10_CLAIM_NOT_REGISTERED': 'C2',
    'A10_CLAIM_NOT_APPROVED': 'C2',
    'A10_CLAIM_SECTION_MISMATCH': 'C2',
    'A10_CLAIM_CONSTRUCT_MISMATCH': 'C2',
    'A10_CLAIM_PERMITS_PROHIBITED_INFERENCE': 'C2',
    # C3 — measurement completeness
    'A10_MEASUREMENT_INVARIANT_VIOLATED': 'C3',
    'A10_DENOMINATOR_ZERO': 'C3',
    'A10_DENOMINATOR_NOT_ITEM_SPECIFIC': 'C3',
    'A10_OPTION_COUNTS_EXCEED_DENOMINATOR': 'C3',
    'A10_FEATURE_SLOT_REQUIRED': 'C3',
    # C4 — section eligibility
    'A10_SECTION_NOT_REPORTABLE': 'C4',
    'A10_SECTION_ADMINISTRATIVE_ONLY': 'C4',
    'A10_ITEM_NOT_IN_SECTION': 'C4',
    # C5 — gate closure
    'A10_GATE_OPEN': 'C5',
    # C6 — suppression
    'A10_SUPPRESSION_FLOOR_NOT_APPROVED': 'C6',
    'A10_SUPPRESSION_CONTROL_VIOLATED': 'C6',
    # C8 — binding
    'A10_INSTRUMENT_VERSION_MISMATCH': 'C8',
    'A10_QUESTION_VERSION_MISMATCH': 'C8',
    'A10_SNAPSHOT_FINGERPRINT_INVALID': 'C8',
    'A10_CONTEXT_HASH_INVALID': 'C8',
    'A10_CONTEXT_HASH_MISMATCH': 'C8',
    'A10_COHORT_MISMATCH': 'C8',
    'A10_CONSENT_MISSING': 'C8',
    'A10_CROSS_OWNER': 'C8',
    'A10_SNAPSHOT_STALE': 'C8',
    # authorization
    'A10_ACTOR_NOT_AUTHORIZED': 'C2',
    'A10_AUTHORITY_EXPIRED': 'C2',
    # C9 — invalidation
    'A10_REVISION_INVALIDATED': 'C9',
    'A10_SUPERSEDES_UNKNOWN': 'C9',
}

_HEX64 = frozenset('0123456789abcdef')


def _is_hex64(value: object) -> bool:
    return isinstance(value, str) and len(value) == 64 and set(value) <= _HEX64


# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class EvidenceSnapshot:
    """One EE-01 measurement identity. Nothing here is inferred."""

    snapshot_id: str
    fingerprint: str
    context_hash: str
    question_id: str
    question_version: str
    instrument_version: str
    instrument_sha256: str
    option_bank_version: str
    stimulus_hash: str
    concept_version: str
    cohort_id: str
    cohort_scope: str
    cutoff: datetime
    measurement: MeasurementCounts
    owner_id: str
    assessment_id: str
    consent_scope: str
    research_mode: str
    ruleset_id: str
    ruleset_hash: str
    #: Per-option counts within ``V``. Empty when the caller has no distribution.
    option_counts: dict[str, int] = field(default_factory=dict)
    #: Set for a matrix item: the feature this slot measures.
    feature_slot: str | None = None


@dataclass(frozen=True)
class Actor:
    """Who is asking, on what basis, until when."""

    actor_id: str
    roles: frozenset[str]
    authority_basis: str
    expires_at: datetime | None = None

    def is_expired(self, now: datetime) -> bool:
        if self.expires_at is None:
            return False
        return self.expires_at <= now


@dataclass(frozen=True)
class AdmissionPolicy:
    """The suppression policy in force. A floor of ``None`` means unapproved."""

    policy_version: str
    floor_value: int | None
    structural_controls: tuple[str, ...] = (
        'COMPLEMENTARY_SUPPRESSION',
        'CROSS_VIEW_DIFFERENCING_CHECK',
        'RESIDUAL_BUCKET_REQUIRED',
    )
    #: True only for the synthetic fixture. Refused on a PRODUCTION evaluator.
    test_only: bool = False
    test_identity: str = ''
    #: The cohort this policy was written for. Empty means "not constrained
    #: here"; set, it is compared against the snapshot's own cohort scope.
    expected_cohort_scope: str = ''
    #: How old a snapshot may be and still be admitted. ``None`` means the
    #: policy says nothing, and the adapter refuses to guess a maximum age.
    max_snapshot_age_days: int | None = None


@dataclass(frozen=True)
class AdmissionRequest:
    section_id: str
    claim_id: str
    snapshot: EvidenceSnapshot
    actor: Actor
    requesting_owner_id: str
    policy: AdmissionPolicy
    revision: int = 1
    #: The decision this one replaces, for an additive invalidation.
    supersedes: str | None = None
    #: Present only on a synthetic test path.
    synthetic_test_identity: str = ''
    #: Claim text being admitted, when the caller has a composed sentence. The
    #: adapter checks it against the claim's prohibited inferences.
    claim_text: str = ''
    #: The ``context_hash`` the caller read back from the stored snapshot. When
    #: supplied it must equal ``snapshot.context_hash``; a difference means the
    #: chart and the explanation would describe different evidence.
    expected_context_hash: str = ''
    #: The chart identity this admission is for. Recorded so a decision names the
    #: exact specification it admitted, not just the section.
    chart_spec_id: str = ''
    chart_schema_version: str = 'chart-spec/1'
    #: The explanation template identity and version. An admission that named no
    #: template could not say which narrative it authorized.
    explanation_template_id: str = ''
    explanation_template_version: str = ''
    #: Privacy clearance state as decided by the adopted policy, recorded
    #: verbatim. Never inferred from the presence of a suppression result.
    disclosure_clearance: str = 'NOT_ASSESSED'
    #: The declared numerator rule, so the permitted numerator is named rather
    #: than left implicit in a count.
    numerator_rule_id: str = ''
    #: When this admission stops being valid. ``None`` means the policy declared
    #: no horizon, and the decision records that rather than inventing one.
    valid_until: datetime | None = None


@dataclass(frozen=True)
class ReportAdmissionDecision:
    """An immutable admission record. Status is computed by ``admit()``."""

    decision_version: str
    decision_id: str
    section_id: str
    #: The version of the section specification the claim was admitted into.
    section_version: str
    claim_id: str
    #: What kind of statement was admitted (see ``Claim.claim_type``).
    claim_type: str
    admission_status: str
    admission_reason: str
    failed_component: str | None
    snapshot_id: str
    context_hash: str
    suppression: dict
    gate_evidence: tuple[str, ...]
    revision: int
    supersedes: str | None
    decided_at: datetime
    #: When this decision lapses. ``None`` means no horizon was declared.
    valid_until: datetime | None
    decided_by: str
    authority: str
    decision_hash: str
    #: The chart and explanation identities the decision binds together. Defaults
    #: exist so an older record stays readable; a real decision always fills them.
    chart_spec_id: str = ''
    chart_schema_version: str = 'chart-spec/1'
    explanation_template_id: str = ''
    explanation_template_version: str = ''
    disclosure_clearance: str = 'NOT_ASSESSED'
    numerator_rule_id: str = ''
    #: The permitted denominator, restated on the decision so a reader never has
    #: to open the snapshot to learn what the figures were divided by.
    denominator_scope: str = ''
    source_references: tuple[str, ...] = ()

    @property
    def is_admitted(self) -> bool:
        """True only for a real admission. A synthetic one is not admitted."""
        return self.admission_status == ADMITTED


# ---------------------------------------------------------------------------
# Suppression
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class SuppressionResult:
    status: str
    floor_value: int | None
    dispositions: dict[str, str]
    residual_bucket: int | None
    controls_run: tuple[str, ...]
    control_failures: tuple[str, ...]

    @property
    def publishable(self) -> bool:
        return self.status == 'SATISFIED'


def evaluate_suppression(cells: dict[str, int], *, floor: int | None,
                         policy: AdmissionPolicy) -> SuppressionResult:
    """Apply the three structural controls, and refuse while the floor is unset.

    The floor is read, never defaulted. With ``floor is None`` no cell is
    publishable — the structural controls still run so their implementation is
    exercised, but the result is ``FLOOR_NOT_APPROVED`` regardless.
    """
    controls = tuple(policy.structural_controls)
    failures: list[str] = []
    dispositions: dict[str, str] = {}
    residual: int | None = None

    if floor is None:
        # Nothing may be published. Still classify, so a caller can see what the
        # controls *would* have done; the status is what stops publication.
        for code, count in cells.items():
            dispositions[code] = 'WITHHELD_FLOOR_NOT_APPROVED'
        return SuppressionResult(
            status='FLOOR_NOT_APPROVED', floor_value=None,
            dispositions=dispositions, residual_bucket=None,
            controls_run=controls, control_failures=())

    if floor < 2:
        # A floor below 2 cannot protect anything: a cell of 1 is a person.
        failures.append('FLOOR_BELOW_MINIMUM')
        return SuppressionResult(
            status='CONTROL_VIOLATED', floor_value=floor,
            dispositions={c: 'WITHHELD_INVALID_FLOOR' for c in cells},
            residual_bucket=None, controls_run=controls,
            control_failures=tuple(failures))

    suppressed = {code: n for code, n in cells.items() if n < floor}
    published = {code: n for code, n in cells.items() if n >= floor}
    for code in cells:
        dispositions[code] = ('SUPPRESSED_PRIMARY' if code in suppressed
                              else 'PUBLISHED')

    if 'COMPLEMENTARY_SUPPRESSION' in controls and len(suppressed) == 1:
        # Exactly one suppressed cell is recoverable by subtraction from the
        # total. Suppress the smallest published cell as well.
        if published:
            smallest = min(published, key=lambda c: (published[c], c))
            dispositions[smallest] = 'SUPPRESSED_COMPLEMENTARY'
            suppressed[smallest] = published.pop(smallest)
        else:
            failures.append('COMPLEMENTARY_SUPPRESSION_IMPOSSIBLE')

    if 'CROSS_VIEW_DIFFERENCING_CHECK' in controls and len(suppressed) == 1:
        # A single suppressed cell across views is the differencing risk itself.
        failures.append('CROSS_VIEW_DIFFERENCING_RISK')

    if 'RESIDUAL_BUCKET_REQUIRED' in controls and suppressed:
        residual = sum(suppressed.values())
        if residual < floor:
            failures.append('RESIDUAL_BUCKET_BELOW_FLOOR')
        else:
            for code in suppressed:
                dispositions[code] = 'BUCKETED_RESIDUAL'

    status = 'CONTROL_VIOLATED' if failures else 'SATISFIED'
    return SuppressionResult(
        status=status, floor_value=floor, dispositions=dispositions,
        residual_bucket=residual, controls_run=controls,
        control_failures=tuple(failures))


# ---------------------------------------------------------------------------
# Register protocols, so the evaluator is testable without a database
# ---------------------------------------------------------------------------

class GateProvider(Protocol):
    def open_gates_for_section(self, section_id: str) -> tuple: ...


class SectionProvider(Protocol):
    def section_map(self) -> dict: ...


# ---------------------------------------------------------------------------
# The evaluator
# ---------------------------------------------------------------------------

class AdmissionEvaluator:
    """Evaluates one request against injected registers. Fail-closed by default."""

    def __init__(self, *, claims: AdoptedClaimRegister | None = None,
                 policy: AdmissionPolicy | None = None,
                 gate_provider: GateProvider | None = None,
                 section_provider: SectionProvider | None = None,
                 environment: Literal['PRODUCTION', 'SYNTHETIC'] = 'PRODUCTION'):
        self.claims = claims if claims is not None else AdoptedClaimRegister.empty()
        self.policy = policy or AdmissionPolicy(
            policy_version='a10-policy-unadopted/0', floor_value=None)
        self.gates = gate_provider or a10_gates
        self.sections = section_provider or a10_gates
        self.environment = environment
        if self.policy.test_only and environment != 'SYNTHETIC':
            # Refused at construction, not at evaluation: a production evaluator
            # holding a synthetic policy is a wiring error that must not survive
            # to a request.
            raise WorkflowHeld('A10_SYNTHETIC_POLICY_IN_PRODUCTION')

    # -- helpers ---------------------------------------------------------
    def _refuse(self, request: AdmissionRequest, code: str, *,
                now: datetime, gates: tuple[str, ...] = (),
                suppression: dict | None = None,
                claim: Claim | None = None) -> ReportAdmissionDecision:
        if code not in REFUSAL_CODES:
            raise WorkflowHeld('A10_REFUSAL_CODE_UNREGISTERED')
        status = HELD if code.startswith('A10_GATE_OPEN') else REFUSED
        # A missing prerequisite is HELD (waiting on an act); a wrong input is
        # REFUSED (the caller must change something). Section eligibility and
        # gate closure are holds; everything else is a refusal.
        if code in ('A10_SECTION_NOT_REPORTABLE', 'A10_SUPPRESSION_FLOOR_NOT_APPROVED'):
            status = HELD
        return self._build(request, status=status, reason=code,
                           failed_component=REFUSAL_CODES[code],
                           now=now, gates=gates, suppression=suppression,
                           claim=claim)

    def _build(self, request: AdmissionRequest, *, status: str, reason: str,
               failed_component: str | None, now: datetime,
               gates: tuple[str, ...] = (),
               suppression: dict | None = None,
               claim: Claim | None = None) -> ReportAdmissionDecision:
        payload = {
            'decision_version': DECISION_VERSION,
            'section_id': request.section_id,
            'claim_id': request.claim_id,
            'snapshot_id': request.snapshot.snapshot_id,
            'context_hash': request.snapshot.context_hash,
            'admission_status': status,
            'admission_reason': reason,
            'revision': request.revision,
            'supersedes': request.supersedes,
            'decided_at': now.isoformat(),
            'decided_by': request.actor.actor_id,
            'gate_evidence': list(gates),
            'suppression': suppression or {},
        }
        decision_hash = digest(payload)
        return ReportAdmissionDecision(
            decision_version=DECISION_VERSION,
            decision_id=decision_hash[:32],
            section_id=request.section_id,
            section_version=a10_gates.contract_version(),
            claim_id=request.claim_id,
            claim_type=(claim.claim_type if claim else 'UNREGISTERED'),
            admission_status=status,
            admission_reason=reason,
            failed_component=failed_component,
            snapshot_id=request.snapshot.snapshot_id,
            context_hash=request.snapshot.context_hash,
            suppression=suppression or {},
            gate_evidence=gates,
            revision=request.revision,
            supersedes=request.supersedes,
            decided_at=now,
            valid_until=request.valid_until,
            decided_by=request.actor.actor_id,
            authority=('AUTHORITY_SYNTHETIC_TEST_ONLY' if status == ADMITTED_SYNTHETIC
                       else 'AUTHORITY_UNVERIFIED' if status != ADMITTED
                       else 'AUTHORITY_VERIFIED'),
            decision_hash=decision_hash,
            chart_spec_id=request.chart_spec_id,
            chart_schema_version=request.chart_schema_version,
            explanation_template_id=request.explanation_template_id,
            explanation_template_version=request.explanation_template_version,
            disclosure_clearance=request.disclosure_clearance,
            numerator_rule_id=request.numerator_rule_id,
            denominator_scope=request.snapshot.cohort_scope,
            source_references=tuple(request.snapshot.ruleset_id and
                                    [request.snapshot.ruleset_id] or []),
        )

    # -- the evaluation --------------------------------------------------
    def admit(self, request: AdmissionRequest, *,
              now: datetime | None = None) -> ReportAdmissionDecision:
        """Evaluate in contract order. First failure wins and is returned."""
        now = now or datetime.now(timezone.utc)
        snapshot = request.snapshot
        policy = request.policy

        # C0 — policy provenance. A test-only policy needs the test identity.
        if not policy.policy_version:
            return self._refuse(request, 'A10_POLICY_VERSION_MISSING', now=now)
        if policy.test_only and not request.synthetic_test_identity:
            return self._refuse(request, 'A10_SYNTHETIC_IDENTITY_MISSING', now=now)

        # C2 — claim identity.
        sections = self.sections.section_map()
        section = sections.get(request.section_id)
        if section is None:
            return self._refuse(request, 'A10_SECTION_UNKNOWN', now=now)
        claim = self.claims.get(request.claim_id)
        if claim is None:
            return self._refuse(request, 'A10_CLAIM_NOT_REGISTERED', now=now)
        if not claim.approved:
            return self._refuse(request, 'A10_CLAIM_NOT_APPROVED', now=now)
        if claim.section_id != request.section_id:
            return self._refuse(request, 'A10_CLAIM_SECTION_MISMATCH', now=now)
        if claim.question_id != snapshot.question_id:
            return self._refuse(request, 'A10_CLAIM_CONSTRUCT_MISMATCH', now=now)
        if request.claim_text and claim.prohibits(request.claim_text):
            return self._refuse(
                request, 'A10_CLAIM_PERMITS_PROHIBITED_INFERENCE', now=now)

        # authorization, before anything expensive.
        if not request.actor.roles & {'REPORT_ADMISSION', 'SCIENTIFIC_OWNER'}:
            return self._refuse(request, 'A10_ACTOR_NOT_AUTHORIZED', now=now)
        if request.actor.is_expired(now):
            return self._refuse(request, 'A10_AUTHORITY_EXPIRED', now=now)

        # C3 — measurement completeness.
        counts = snapshot.measurement
        if not (counts.V <= counts.A <= counts.S <= counts.Q):
            return self._refuse(request, 'A10_MEASUREMENT_INVARIANT_VIOLATED', now=now)
        if counts.V == 0:
            # Never 0%. Withheld is not absent and absent is not zero.
            return self._refuse(request, 'A10_DENOMINATOR_ZERO', now=now)
        if snapshot.option_counts:
            if any(n < 0 for n in snapshot.option_counts.values()):
                return self._refuse(
                    request, 'A10_MEASUREMENT_INVARIANT_VIOLATED', now=now)
            if sum(snapshot.option_counts.values()) > counts.V:
                # Only valid for a single-select item; a multi-select sum may
                # exceed V legitimately, so the caller must not supply one here.
                return self._refuse(
                    request, 'A10_OPTION_COUNTS_EXCEED_DENOMINATOR', now=now)
        if snapshot.question_id == 'Q10' and not snapshot.feature_slot:
            return self._refuse(request, 'A10_FEATURE_SLOT_REQUIRED', now=now)

        # C4 — section eligibility.
        if getattr(section, 'state', '') in ('RENDERABLE_ADMINISTRATIVE',):
            return self._refuse(request, 'A10_SECTION_ADMINISTRATIVE_ONLY', now=now)
        if not getattr(section, 'reportable_with_valid_evidence', False):
            return self._refuse(request, 'A10_SECTION_NOT_REPORTABLE', now=now)

        # C5 — gate closure.
        open_gates = self.gates.open_gates_for_section(request.section_id)
        if open_gates:
            return self._refuse(
                request, 'A10_GATE_OPEN', now=now,
                gates=tuple(g.gate for g in open_gates))

        # C6 — suppression. The evaluator's policy is authoritative: a request
        # naming a different policy version is refused rather than silently
        # evaluated against its own floor, so a caller cannot smuggle in a
        # threshold the owner never approved.
        if policy.policy_version != self.policy.policy_version:
            return self._refuse(request, 'A10_POLICY_VERSION_MISMATCH', now=now)
        suppression = evaluate_suppression(
            snapshot.option_counts or {}, floor=self.policy.floor_value,
            policy=self.policy)
        if suppression.status == 'FLOOR_NOT_APPROVED':
            return self._refuse(
                request, 'A10_SUPPRESSION_FLOOR_NOT_APPROVED', now=now,
                suppression={'status': suppression.status,
                             'floor_value': None,
                             'dispositions': suppression.dispositions})
        if not suppression.publishable:
            return self._refuse(
                request, 'A10_SUPPRESSION_CONTROL_VIOLATED', now=now,
                suppression={'status': suppression.status,
                             'control_failures': list(suppression.control_failures)})

        # C8 — same-source binding. A mismatch is a refusal, never a warning.
        from sitewise.project1.explanation_registry import load_registry
        reg = load_registry()
        if snapshot.instrument_version != reg.instrument_version:
            return self._refuse(request, 'A10_INSTRUMENT_VERSION_MISMATCH', now=now)
        if snapshot.instrument_sha256 != reg.instrument_sha256:
            return self._refuse(request, 'A10_INSTRUMENT_VERSION_MISMATCH', now=now)
        if not _is_hex64(snapshot.fingerprint):
            return self._refuse(request, 'A10_SNAPSHOT_FINGERPRINT_INVALID', now=now)
        if not _is_hex64(snapshot.context_hash):
            return self._refuse(request, 'A10_CONTEXT_HASH_INVALID', now=now)
        if snapshot.question_version != snapshot.instrument_version:
            # The question version must be the instrument version it came from;
            # a question cannot be read out of a different instrument.
            return self._refuse(request, 'A10_QUESTION_VERSION_MISMATCH', now=now)
        if snapshot.owner_id != request.requesting_owner_id:
            return self._refuse(request, 'A10_CROSS_OWNER', now=now)
        if (request.expected_context_hash
                and request.expected_context_hash != snapshot.context_hash):
            # The chart's join key and the explanation's context id must be the
            # same value; if the readback disagrees, one of them is stale.
            return self._refuse(request, 'A10_CONTEXT_HASH_MISMATCH', now=now)
        if (self.policy.expected_cohort_scope
                and snapshot.cohort_scope != self.policy.expected_cohort_scope):
            return self._refuse(request, 'A10_COHORT_MISMATCH', now=now)
        max_age = self.policy.max_snapshot_age_days
        if max_age is not None:
            age = now - snapshot.cutoff
            if age.days > max_age or age.total_seconds() < 0:
                return self._refuse(request, 'A10_SNAPSHOT_STALE', now=now)
        if 'REPORT_PUBLICATION' not in snapshot.consent_scope:
            return self._refuse(request, 'A10_CONSENT_MISSING', now=now)
        if not section.items or snapshot.question_id not in section.items:
            # The item does not feed this section at all, so no cohort reading
            # of it can be admitted here.
            return self._refuse(request, 'A10_ITEM_NOT_IN_SECTION', now=now)

        # Every component held. The status still depends on provenance.
        status = ADMITTED_SYNTHETIC if policy.test_only else ADMITTED
        return self._build(
            request, status=status, reason='ALL_COMPONENTS_SATISFIED',
            failed_component=None, now=now,
            gates=tuple(g.gate for g in self.gates.open_gates_for_section(
                request.section_id)),
            suppression={'status': suppression.status,
                         'floor_value': suppression.floor_value,
                         'dispositions': suppression.dispositions,
                         'residual_bucket': suppression.residual_bucket})

    # -- invalidation ----------------------------------------------------
    def invalidate(self, decision: ReportAdmissionDecision, *, trigger: str,
                   actor: Actor, evidence: str,
                   now: datetime | None = None) -> ReportAdmissionDecision:
        """Write a new record that supersedes ``decision``. Never mutates it."""
        now = now or datetime.now(timezone.utc)
        if trigger not in INVALIDATION_TRIGGERS:
            raise WorkflowHeld('A10_INVALIDATION_TRIGGER_UNKNOWN')
        if not evidence:
            raise WorkflowHeld('A10_INVALIDATION_EVIDENCE_REQUIRED')
        request = AdmissionRequest(
            section_id=decision.section_id,
            claim_id=decision.claim_id,
            snapshot=EvidenceSnapshot(
                snapshot_id=decision.snapshot_id, fingerprint='0' * 64,
                context_hash=decision.context_hash, question_id='', question_version='',
                instrument_version='', instrument_sha256='', option_bank_version='',
                stimulus_hash='', concept_version='', cohort_id='', cohort_scope='',
                cutoff=now,
                measurement=MeasurementCounts(
                    I='UNKNOWN_NOT_ENUMERABLE', Q=0, S=0, A=0, V=0),
                owner_id='', assessment_id='', consent_scope='', research_mode='',
                ruleset_id='', ruleset_hash=''),
            actor=actor, requesting_owner_id='', policy=self.policy,
            revision=decision.revision + 1, supersedes=decision.decision_id)
        return self._build(
            request, status=REFUSED, reason=f'INVALIDATED_{trigger}',
            failed_component='C9', now=now)


INVALIDATION_TRIGGERS = frozenset({
    'GATE_CHANGED', 'MEASUREMENT_CHANGED', 'DIFFERENCING_RISK',
    'CLAIM_CHANGED', 'FLOOR_CHANGED', 'CONSENT_WITHDRAWN', 'STATUS_REGRESSED',
})


def chart_admission_from_decision(decision: ReportAdmissionDecision) -> ChartAdmission:
    """Map a decision to the chart contract. Only a real admission passes.

    ``ADMITTED_SYNTHETIC`` is mapped to ``HELD`` with an explicit gate, so a
    synthetic test decision can never make a bar render even if it reaches this
    function. This is the second structural barrier; the first is that
    ``ADMITTED_SYNTHETIC`` is a different string.
    """
    if decision.admission_status == ADMITTED:
        return ChartAdmission(status='ADMITTED', authority=decision.authority,
                              gates=[], real_reportable=True)
    gate = ('A10_SYNTHETIC_NOT_REPORTABLE'
            if decision.admission_status == ADMITTED_SYNTHETIC
            else decision.admission_reason)
    return ChartAdmission(status='HELD', authority=decision.authority,
                          gates=[gate], real_reportable=False)


__all__ = [
    'ADMITTED', 'ADMITTED_SYNTHETIC', 'DECISION_VERSION', 'HELD', 'INVALIDATION_TRIGGERS',
    'REFUSED', 'REFUSAL_CODES', 'Actor', 'AdmissionEvaluator', 'AdmissionPolicy',
    'AdmissionRequest', 'EvidenceSnapshot', 'GateProvider', 'ReportAdmissionDecision',
    'SectionProvider', 'SuppressionResult', 'chart_admission_from_decision',
    'evaluate_suppression',
]
