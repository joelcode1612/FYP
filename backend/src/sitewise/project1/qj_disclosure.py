"""Stage-scoped synthetic-only disclosure adapter for exactly one QJ attempt.

``ModelRunner.__call__`` invokes ``disclosure.require_current(stage, packet,
ENDPOINT, MODEL)`` *before* ``ledger.reserve()`` and before any socket exists.
The BDJ adapter is deliberately BDJ-scoped and refuses stage QJ, so QJ could not
be dispatched without either weakening it or adding a bypass. This module is
neither: it is a second, independently scoped control that decides the QJ case
from the same port and refuses everything it was not given.

Two layers, deliberately separate
---------------------------------
**The BCB layer** is the governed context: a real packet produced by
``BusinessContextBuilderV1`` under contract ``BCB-V1-1.1.0``. This adapter does
not trust the caller's word for that -- it re-checks the exact builder shape
(key set, ``schema_version`` for the declared contract, recomputed
``packet_hash``, access/confirmation/instrument/concept blocks, permissions,
provenance) and refuses anything that is not builder output. ``geography`` must
be ``null``: under re-affirmed D02 and BCB 1.1, GEO is excluded, and a packet
carrying a geography object is refused rather than tolerated.

**The synthetic layer** is layered on top and never substitutes for a BCB check:
the envelope carries ``synthetic`` (data class, ``synthetic``, ``human_subjects``,
fixture id), and the test authorization names the exact tenant it covers. A BCB
packet alone therefore cannot authorise QJ -- without the synthetic layer the
disclosure refuses. Nor does the synthetic layer excuse any BCB check.

Refused, in this order:

  1. any stage other than QJ;
  2. a missing/real synthetic layer, or a packet for a tenant the test record
     does not name, or a real authenticated-declaration marker;
  3. a packet that is not genuine ``BusinessContextBuilderV1`` output;
  4. any assessment id / confirmation id / confirmed revision / context version
     / builder version / packet hash that differs from the immutable references;
  5. a missing, unconfirmed or mis-bound research uncertainty;
  6. a purpose other than ``QJ_CONTEXT``, a non-null geography, an old contract,
     or a concept/confirmation that is no longer current;
  7. any endpoint/model other than the adopted provider/model;
  8. a missing, expired, or over-scoped test authorization.

What this control does **not** do, and must never be read as doing: it does not
authorize a research objective, does not confer scientific acceptance, does not
make an Owner signature or GEO authority appear, and does not turn the model's
QJ candidate route into an approved question. The receipt records that explicitly
(``authority='NONE'``, every authority flag ``False``).

No raw source text, provider payload or credential is read, stored or logged
here. All refusals are the project's fixed ``WorkflowHeld`` codes.
"""
from dataclasses import dataclass
from datetime import datetime, timezone

from sitewise.project1.contracts import WorkflowHeld, digest
from sitewise.project1.provider import ENDPOINT, MODEL
from sitewise.services.business_context_v1 import CONTRACTS, CURRENT_CONTEXT_VERSION

QJ_STAGE = 'QJ'
QJ_CONTEXT_PURPOSE = 'QJ_CONTEXT'
SYNTHETIC_DATA_CLASS = 'SYNTHETIC_NONHUMAN'
TEST_SCOPE = 'TEST_ONLY'
TEST_OPERATION = 'QJ_SYNTHETIC_DISPATCH'

#: The real-confirmed marker. BCB's structural ``evidence_class`` is always
#: ``ENTREPRENEUR_DECLARED`` (it describes the kind of evidence, not whether a
#: human is real), so it cannot be used to detect a non-synthetic source.
REAL_TRUST_CLASSES = frozenset({'T2_AUTHENTICATED_ENTREPRENEUR_DECLARATION'})

CHECK_STAGE_SCOPED = 'QJ_STAGE_SCOPED'
CHECK_SYNTHETIC_NONHUMAN = 'QJ_SYNTHETIC_NONHUMAN'
CHECK_BUILDER_OUTPUT = 'QJ_BUILDER_OUTPUT_VERIFIED'
CHECK_IMMUTABLE_VERSIONS_MATCH = 'QJ_IMMUTABLE_VERSIONS_MATCH'
CHECK_UNCERTAINTY_CONFIRMED = 'QJ_UNCERTAINTY_CONFIRMED'
CHECK_PURPOSE_CURRENT = 'QJ_PURPOSE_QJ_CONTEXT_CURRENT'
CHECK_ENDPOINT_MODEL_MATCH = 'QJ_ENDPOINT_MODEL_MATCH'
CHECK_TEST_AUTHORIZATION_CURRENT = 'QJ_TEST_AUTHORIZATION_CURRENT'

CHECKS = (
    CHECK_STAGE_SCOPED,
    CHECK_SYNTHETIC_NONHUMAN,
    CHECK_BUILDER_OUTPUT,
    CHECK_IMMUTABLE_VERSIONS_MATCH,
    CHECK_UNCERTAINTY_CONFIRMED,
    CHECK_PURPOSE_CURRENT,
    CHECK_ENDPOINT_MODEL_MATCH,
    CHECK_TEST_AUTHORIZATION_CURRENT,
)

# Exact key sets emitted by BusinessContextBuilderV1._build(). A packet that
# differs in even one key is not that builder's output.
BCB_PACKET_KEYS = frozenset({
    'schema_version', 'context_version', 'identity', 'access', 'confirmation',
    'instrument', 'm2_answers', 'business_description', 'concept', 'findings',
    'confirmed_uncertainty', 'geography', 'supporting_sources', 'unknowns',
    'contradictions', 'limitations', 'permissions', 'provenance', 'packet_hash',
})
BCB_IDENTITY_KEYS = frozenset({'assessment_id', 'tenant_id', 'owner_id'})
BCB_ACCESS_KEYS = frozenset({'scope', 'decision_id', 'policy_version', 'allowed'})
BCB_SCOPE_KEYS = frozenset({
    'viewer_id', 'tenant_id', 'assessment_id', 'purpose', 'role',
    'confirmation_id', 'confirmed_revision', 'concept_version',
})
BCB_CONFIRMATION_KEYS = frozenset({'id', 'revision', 'digest', 'status'})
BCB_INSTRUMENT_KEYS = frozenset({'id', 'version_tag', 'schema_digest', 'approval_state'})
BCB_CONCEPT_KEYS = frozenset({
    'tenant_id', 'assessment_id', 'version', 'confirmation_id',
    'assessment_revision', 'status', 'confirmed_by', 'confirmation_event_id',
    'content', 'valid_until', 'm2_snapshot_digest', 'source_hash',
})
BCB_DECLARATION_KEYS = frozenset({
    'item_key', 'answer_revision_id', 'item_version_id', 'answer_state', 'value',
    'question', 'question_version', 'response_version', 'codebook_version',
    'codebook_hash', 'question_definition_hash', 'source_hash', 'evidence_class',
    'facts_independently_verified',
})
BCB_FINDING_KEYS = frozenset({
    'id', 'rule_id', 'rule_version', 'source_answer_ids', 'issue_type',
    'explanation', 'not_proven', 'next_action', 'review_state',
    'authority_reference', 'source_hash', 'business_facts_verified',
    'report_admitted',
})
BCB_PERMISSION_KEYS = frozenset({
    'report_admission', 'report_release', 'qj_execution', 'qg_execution',
})
BCB_PROVENANCE_KEYS = frozenset({
    'algorithm', 'canonicalization', 'snapshot_id', 'm2_confirmation_hash',
    'instrument_hash', 'item_definitions_hash', 'bindings_hash',
    'access_decision_hash',
})


@dataclass(frozen=True)
class SyntheticQjTestScopeAuthorization:
    """A test-scoped receipt for one synthetic QJ disclosure decision.

    Mirrors ``tests/project1/llm_campaign/qj_scope/qj_test_scope_authorization.json``:
    the scope is ``TEST_ONLY``, production adoption is false, and the three
    authority fields are ``None``. A record that carries an Owner signature, a
    scientific approval or GEO authority is refused rather than honoured -- this
    adapter cannot manufacture any of them. ``tenant_id`` binds the record to the
    one synthetic tenant whose BCB packet it covers.
    """

    authorization_id: str
    valid_until: str
    tenant_id: str
    authorised_operations: tuple[str, ...] = ()
    scope: str = TEST_SCOPE
    purpose: str = QJ_CONTEXT_PURPOSE
    data_class: str = SYNTHETIC_DATA_CLASS
    synthetic: bool = True
    human_subjects: bool = False
    production_adoption: bool = False
    owner_signature: str | None = None
    scientific_approval: str | None = None
    geo_authority: str | None = None
    stage: str = QJ_STAGE
    endpoint: str = ENDPOINT
    model: str = MODEL


@dataclass(frozen=True)
class QjImmutableContextReferences:
    """The exact BCB context this authorization was issued for.

    Supplied by the trusted composition, never by the packet or an HTTP caller.
    ``builder_version`` is the registered builder contract version; the persisted
    store defines it as ``packet['context_version']``.
    """

    assessment_id: str
    confirmation_id: str
    confirmed_revision: int
    context_version: str
    builder_version: str
    context_hash: str


@dataclass(frozen=True)
class QjDisclosureReceipt:
    """What was accepted, and the checks that were performed to accept it.

    ``authority='NONE'`` and the all-false flags are the record that this
    decision confers no research, scientific, publication or fielding authority.
    """

    stage: str
    tenant_id: str
    assessment_id: str
    confirmation_id: str
    confirmed_revision: int
    context_version: str
    builder_version: str
    context_hash: str
    authorization_id: str
    authorization_scope: str
    research_objective_ignored: bool
    checks: tuple[str, ...]
    authority: str = 'NONE'
    candidate_only: bool = True
    scientific_acceptance: bool = False
    owner_authorization: bool = False
    publication_authorized: bool = False
    fielding_authorized: bool = False
    report_release_authorized: bool = False


def context_hash(packet: dict) -> str:
    """Digest of the packet content, excluding its own ``packet_hash``."""
    return digest({key: value for key, value in packet.items() if key != 'packet_hash'})


def _context_of(packet):
    """Unwrap ``{'context': <bcb packet>, 'synthetic': ..., ...}``.

    A bare BCB packet is returned unchanged; it then fails the synthetic-layer
    check, which is the point -- a BCB packet alone cannot authorise QJ.
    """
    if not isinstance(packet, dict):
        raise WorkflowHeld('QJ_DISCLOSURE_CONTEXT_INVALID')
    nested = packet.get('context')
    if isinstance(nested, dict):
        return nested
    return packet


def _synthetic_layer_of(packet):
    layer = packet.get('synthetic')
    return layer if isinstance(layer, dict) else None


def _exact_keys(value, expected, code):
    if not isinstance(value, dict) or frozenset(value) != expected:
        raise WorkflowHeld(code)


def _is_expired(valid_until, now) -> bool:
    try:
        expiry = datetime.fromisoformat(str(valid_until).replace('Z', '+00:00'))
    except (TypeError, ValueError):
        return True
    if expiry.tzinfo is None or now.tzinfo is None:
        return True
    return expiry <= now


def _require_references(references):
    if (not isinstance(references.assessment_id, str) or not references.assessment_id
            or not isinstance(references.confirmation_id, str) or not references.confirmation_id
            or type(references.confirmed_revision) is not int
            or references.confirmed_revision < 0
            or not isinstance(references.context_version, str)
            or not references.context_version
            or not isinstance(references.builder_version, str)
            or not references.builder_version
            or not isinstance(references.context_hash, str)
            or len(references.context_hash) != 64):
        raise WorkflowHeld('QJ_DISCLOSURE_REFERENCES_INVALID')


def _require_builder_output(context):
    """Refuse anything that is not genuine ``BusinessContextBuilderV1`` output."""
    _exact_keys(context, BCB_PACKET_KEYS, 'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')
    contract = context.get('context_version')
    if contract not in CONTRACTS or context.get('schema_version') != CONTRACTS[contract][0]:
        raise WorkflowHeld('QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')
    if context_hash(context) != context.get('packet_hash'):
        raise WorkflowHeld('QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')

    identity = context['identity']
    _exact_keys(identity, BCB_IDENTITY_KEYS, 'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')
    if not all(isinstance(identity[key], str) and identity[key]
               for key in BCB_IDENTITY_KEYS):
        raise WorkflowHeld('QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')

    access = context['access']
    _exact_keys(access, BCB_ACCESS_KEYS, 'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')
    scope = access['scope']
    _exact_keys(scope, BCB_SCOPE_KEYS, 'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')
    if (access['allowed'] is not True
            or not isinstance(access['decision_id'], str) or not access['decision_id']
            or not isinstance(access['policy_version'], str) or not access['policy_version']
            or scope['tenant_id'] != identity['tenant_id']
            or scope['assessment_id'] != identity['assessment_id']
            or type(scope['confirmed_revision']) is not int
            or not isinstance(scope['concept_version'], str) or not scope['concept_version']):
        raise WorkflowHeld('QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')

    confirmation = context['confirmation']
    _exact_keys(confirmation, BCB_CONFIRMATION_KEYS, 'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')
    if (not isinstance(confirmation['id'], str) or not confirmation['id']
            or type(confirmation['revision']) is not int
            or not isinstance(confirmation['digest'], str)
            or len(confirmation['digest']) != 64
            or confirmation['id'] != scope['confirmation_id']
            or confirmation['revision'] != scope['confirmed_revision']):
        raise WorkflowHeld('QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')

    instrument = context['instrument']
    _exact_keys(instrument, BCB_INSTRUMENT_KEYS, 'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')
    if (instrument['approval_state'] != 'AUTHORIZED'
            or not isinstance(instrument['version_tag'], str) or not instrument['version_tag']
            or not isinstance(instrument['schema_digest'], str)
            or not instrument['schema_digest']):
        raise WorkflowHeld('QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')

    concept = context['concept']
    _exact_keys(concept, BCB_CONCEPT_KEYS, 'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')
    _exact_keys(concept['content'], {'description'}, 'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')
    if (not isinstance(concept['content']['description'], str)
            or not concept['content']['description'].strip()
            or concept['source_hash'] != digest(concept['content'])
            or concept['m2_snapshot_digest'] != confirmation['digest']):
        raise WorkflowHeld('QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')

    declarations = context['m2_answers']
    if not isinstance(declarations, list):
        raise WorkflowHeld('QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')
    for declaration in declarations:
        _exact_keys(declaration, BCB_DECLARATION_KEYS, 'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')
    for finding in context['findings']:
        _exact_keys(finding, BCB_FINDING_KEYS, 'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')
    for key in ('supporting_sources', 'unknowns', 'contradictions'):
        if not isinstance(context[key], list) or not all(
                isinstance(row, dict) for row in context[key]):
            raise WorkflowHeld('QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')

    permissions = context['permissions']
    _exact_keys(permissions, BCB_PERMISSION_KEYS, 'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')
    if any(value is not False for value in permissions.values()):
        raise WorkflowHeld('QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')

    provenance = context['provenance']
    _exact_keys(provenance, BCB_PROVENANCE_KEYS, 'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')
    if (provenance['algorithm'] != 'SHA-256'
            or provenance['canonicalization'] != 'PYTHON-JSON-SORTED-UTF8-V1'):
        raise WorkflowHeld('QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')

    limitations = context['limitations']
    if (not isinstance(limitations, list) or not limitations
            or not all(isinstance(row, str) and row.strip() for row in limitations)):
        raise WorkflowHeld('QJ_DISCLOSURE_NOT_BUILDER_OUTPUT')


class SyntheticQjDisclosure:
    """Implements the ModelRunner disclosure port for stage QJ only.

    ``require_current`` is a pure decision over the authorization, the immutable
    references and the packet, so the same predicate can run as a preflight
    before a ``project1_ai.runs`` row exists. ``project1_ai.runs`` is append-only,
    so a refusal that happened after provisioning would leave an orphan row.
    """

    def __init__(self, authorization, references, *, clock=None):
        self.authorization = authorization
        self.references = references
        self._clock = clock or (lambda: datetime.now(timezone.utc))
        self._records: list[QjDisclosureReceipt] = []

    @property
    def records(self) -> tuple[QjDisclosureReceipt, ...]:
        return tuple(self._records)

    def require_current(self, stage, packet, endpoint, model):
        receipt = validate_qj_synthetic(
            stage=stage, packet=packet, endpoint=endpoint, model=model,
            authorization=self.authorization, references=self.references,
            now=self._clock())
        self._records.append(receipt)
        return receipt


def validate_qj_synthetic(*, stage, packet, endpoint, model, authorization,
                          references, now):
    """Every refusal condition, as a pure predicate. Raises ``WorkflowHeld``."""
    if not isinstance(authorization, SyntheticQjTestScopeAuthorization):
        raise WorkflowHeld('QJ_DISCLOSURE_AUTHORIZATION_INVALID')
    if not authorization.authorization_id or not authorization.tenant_id:
        raise WorkflowHeld('QJ_DISCLOSURE_AUTHORIZATION_INVALID')
    if not isinstance(references, QjImmutableContextReferences):
        raise WorkflowHeld('QJ_DISCLOSURE_REFERENCES_INVALID')
    _require_references(references)

    context = _context_of(packet)
    synthetic = _synthetic_layer_of(packet)

    # 1. Stage scope. Both the authorization and the dispatch site must say QJ.
    if stage != QJ_STAGE or authorization.stage != QJ_STAGE:
        raise WorkflowHeld('QJ_DISCLOSURE_STAGE_NOT_AUTHORIZED')

    # 2. The synthetic layer, separate from and additional to every BCB check.
    if (authorization.data_class != SYNTHETIC_DATA_CLASS
            or authorization.synthetic is not True
            or authorization.human_subjects is not False):
        raise WorkflowHeld('QJ_DISCLOSURE_REAL_DATA_NOT_AUTHORIZED')
    if synthetic is None:
        # A bare BCB packet is governed context, not a synthetic dispatch.
        raise WorkflowHeld('QJ_DISCLOSURE_REAL_DATA_NOT_AUTHORIZED')
    if (synthetic.get('data_class') != SYNTHETIC_DATA_CLASS
            or synthetic.get('synthetic') is not True
            or synthetic.get('human_subjects') is not False
            or not isinstance(synthetic.get('fixture_id'), str)
            or not synthetic['fixture_id'].strip()):
        raise WorkflowHeld('QJ_DISCLOSURE_REAL_DATA_NOT_AUTHORIZED')
    identity = context.get('identity')
    if not isinstance(identity, dict) or identity.get('tenant_id') != authorization.tenant_id:
        raise WorkflowHeld('QJ_DISCLOSURE_REAL_DATA_NOT_AUTHORIZED')
    declarations = context.get('m2_answers')
    for declaration in declarations if isinstance(declarations, list) else []:
        if isinstance(declaration, dict) and declaration.get('trust_class') in REAL_TRUST_CLASSES:
            raise WorkflowHeld('QJ_DISCLOSURE_REAL_DATA_NOT_AUTHORIZED')

    # 3. Genuine BusinessContextBuilderV1 output, not a hand-made shape.
    _require_builder_output(context)
    confirmation = context['confirmation']

    # 4. Immutable version references. A mismatch is refused, never reconciled.
    if (identity['assessment_id'] != references.assessment_id
            or confirmation['id'] != references.confirmation_id
            or confirmation['revision'] != references.confirmed_revision
            or context['context_version'] != references.context_version
            or context['context_version'] != references.builder_version
            or context['packet_hash'] != references.context_hash):
        raise WorkflowHeld('QJ_DISCLOSURE_VERSION_MISMATCH')

    # 5. A genuinely confirmed, correctly bound research uncertainty.
    uncertainty = context.get('confirmed_uncertainty')
    if not isinstance(uncertainty, dict):
        raise WorkflowHeld('QJ_DISCLOSURE_UNCERTAINTY_NOT_CONFIRMED')
    exact_text = uncertainty.get('exact_text')
    if (not uncertainty.get('id')
            or uncertainty.get('confirmation_id') != confirmation['id']
            or uncertainty.get('actor_user_id') != identity['owner_id']
            or not isinstance(exact_text, str) or not exact_text.strip()
            or len(exact_text) > 1000):
        raise WorkflowHeld('QJ_DISCLOSURE_UNCERTAINTY_NOT_CONFIRMED')
    unknown_codes = {row.get('code') for row in context['unknowns']}
    if 'UNCERTAINTY_NOT_CONFIRMED' in unknown_codes:
        raise WorkflowHeld('QJ_DISCLOSURE_UNCERTAINTY_NOT_CONFIRMED')

    # 6. BCB purpose, GEO exclusion (D02), and currency of contract/concept.
    if (context['access']['scope']['purpose'] != QJ_CONTEXT_PURPOSE
            or authorization.purpose != QJ_CONTEXT_PURPOSE):
        raise WorkflowHeld('QJ_DISCLOSURE_PURPOSE_MISMATCH')
    if context['geography'] is not None:
        raise WorkflowHeld('QJ_DISCLOSURE_GEOGRAPHY_NOT_EXCLUDED')
    concept = context['concept']
    if (context['context_version'] != CURRENT_CONTEXT_VERSION
            or confirmation['status'] != 'CURRENT_CONFIRMED'
            or concept['status'] != 'ENTREPRENEUR_CONFIRMED'
            or concept['confirmation_id'] != confirmation['id']
            or concept['assessment_revision'] != references.confirmed_revision
            or concept['confirmed_by'] != identity['owner_id']
            or concept['tenant_id'] != identity['tenant_id']
            or concept['assessment_id'] != identity['assessment_id']
            or _is_expired(concept['valid_until'], now)):
        raise WorkflowHeld('QJ_DISCLOSURE_CONTEXT_STALE')

    # 7. Endpoint and model. The authorization cannot widen what the runner sends.
    if endpoint != ENDPOINT or authorization.endpoint != ENDPOINT:
        raise WorkflowHeld('QJ_DISCLOSURE_ENDPOINT_MISMATCH')
    if model != MODEL or authorization.model != MODEL:
        raise WorkflowHeld('QJ_DISCLOSURE_MODEL_MISMATCH')

    # 8. Test authorization: present, single-operation, non-adopting, current.
    if (authorization.scope != TEST_SCOPE
            or authorization.production_adoption is not False
            or authorization.owner_signature is not None
            or authorization.scientific_approval is not None
            or authorization.geo_authority is not None
            or TEST_OPERATION not in tuple(authorization.authorised_operations)):
        raise WorkflowHeld('QJ_DISCLOSURE_TEST_AUTHORIZATION_INVALID')
    if _is_expired(authorization.valid_until, now):
        raise WorkflowHeld('QJ_DISCLOSURE_TEST_AUTHORIZATION_STALE')

    return QjDisclosureReceipt(
        stage=QJ_STAGE,
        tenant_id=identity['tenant_id'],
        assessment_id=identity['assessment_id'],
        confirmation_id=confirmation['id'],
        confirmed_revision=confirmation['revision'],
        context_version=context['context_version'],
        builder_version=references.builder_version,
        context_hash=context['packet_hash'],
        authorization_id=authorization.authorization_id,
        authorization_scope=authorization.scope,
        research_objective_ignored=isinstance(packet.get('context'), dict),
        checks=CHECKS,
    )
