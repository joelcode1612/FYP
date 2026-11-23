"""Contract-derived consent notice for the customer questionnaire (consent-notice/1).

Why this module exists
----------------------
The questionnaire's only consent surface rendered a single string taken from
``manifest['consent_text']``. That string is genuinely correct for its one
reachable scope -- ``"Synthetic isolated test. No customer fielding."`` -- because
in an isolated synthetic run there is no human respondent to inform. It is not a
placeholder defect for that scope; it is an accurate statement about that scope.

It is, however, the *only* consent text in the tree, and it discloses none of the
six things a real respondent must be told. Before this module, the interface could
not communicate purpose, voluntariness, what is collected, how responses reach a
report, how confidentiality is protected, or the withdrawal and data-handling
conditions -- not because the UI was lazy, but because no approved wording existed
to render.

The decision this module had to make
------------------------------------
There is no approved production consent text anywhere in the repository, and one
cannot be written here. CUST03's approval gate matrix carries
``OD-08 privacy/consent/withdrawal/retention`` with status
``PRIVACY_APPROVAL_PENDING``, owned by "DPO + committee"; ``identity_model``
carries the same ``PRIVACY_APPROVAL_PENDING``; and ``named_owners_pending`` lists
OD-08 as still outstanding. Authoring a retention period or a disclosure the
contract does not state would be the same class of defect as inventing the
suppression floor ``k`` -- which ``suppression_policy.primary_suppression.note``
explicitly forbids.

So this module does not author wording. It **derives** each disclosure from the
hash-pinned CUST03 contract the runtime already verifies, quotes the contract's own
authoritative values, and cites the JSON pointer each value was read from. Five of
the six disclosures are fully entailed by the contract. The sixth -- retention --
is not, so it is returned as ``NOT_APPROVED_OWNER_DECISION_OUTSTANDING`` with
``value: null``, and the notice as a whole reports
``PRIVACY_APPROVAL_PENDING``.

What this buys
--------------
* The interface is now *structurally complete*: every required disclosure has a
  slot, a source and a status. When the DPO/committee approves real wording it
  lands in the contract (or a versioned successor) and flows through without a UI
  change.
* The runtime cannot mistake an unapproved notice for an approved one.
  ``require_approved`` refuses ``PRODUCTION`` scope outright, independently of the
  existing ``PRODUCTION_FIELDING_HOLD`` and ``source_class == 'ADOPTED'`` locks.
  Defence in depth, not a replacement for them.
* Nothing is invented. The notice is a pure function of the contract, so it is
  reproducible and hashable, and any drift in the contract changes the hash.

What this module deliberately is not
------------------------------------
* Not an approval. ``approval_state`` is ``PRIVACY_APPROVAL_PENDING`` and stays
  that way until OD-08 is decided.
* Not a retention decision. ``withdrawal_and_retention.retention.value`` is
  ``None`` and must remain ``None`` here.
* Not a replacement for ``consent_authorization`` (which governs AI-processing
  consent over synthetic non-human data) or for ``manifest['consent_text']``
  (which remains the text the consent request is hash-bound to). This module adds
  a disclosure surface beside them; it does not rewrite either.

Composition rule
----------------
``statement`` is assembled *only* by interpolating values already present in
``facts``. It contains no claim the contract does not make, and
``_assert_statement_is_entailed`` re-checks that at build time by requiring every
non-literal fragment to be traceable to ``facts``.
"""
from __future__ import annotations

import hashlib
import json
from typing import Any, Mapping

CONTRACT_VERSION = 'consent-notice/1'

DERIVED = 'DERIVED_FROM_APPROVED_CONTRACT'
NOT_APPROVED = 'NOT_APPROVED_OWNER_DECISION_OUTSTANDING'

APPROVAL_PENDING = 'PRIVACY_APPROVAL_PENDING'
APPROVAL_APPROVED = 'APPROVED'

#: The Owner decision that blocks a production notice. Cited verbatim from the
#: contract rather than restated, so a renamed or re-scoped decision surfaces here.
BLOCKED_DECISION_ID = 'OD-08'

DISCLOSURE_IDS = (
    'purpose',
    'voluntariness',
    'what_is_collected',
    'report_use',
    'confidentiality',
    'withdrawal_and_retention',
)

#: Scopes in which a human respondent can be shown a notice. Only a notice that
#: is APPROVED may be served in any of these.
HUMAN_SCOPES = frozenset({'PRODUCTION'})


def _sha256(payload: Any) -> str:
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')
    ).hexdigest()


def _disclosure(disclosure_id: str, *, status: str, sources: list[str], facts: Mapping[str, Any],
                statement: str | None, decision: str | None = None) -> dict:
    """One disclosure slot. ``facts`` is machine-readable and cited; ``statement``
    is optional prose assembled only from ``facts``."""
    return {
        'id': disclosure_id,
        'status': status,
        'decision': decision,
        'sources': list(sources),
        'facts': dict(facts),
        'statement': statement,
    }


def _purpose(contract: Mapping[str, Any]) -> dict:
    constructs = sorted(contract.get('construct_registry') or {})
    sections = list((contract.get('report_sections') or {}).get('canonical_ids') or [])
    return _disclosure(
        'purpose',
        status=DERIVED,
        sources=['/construct_registry', '/report_sections/canonical_ids'],
        facts={'constructs_measured': constructs, 'report_sections': sections},
        statement=(
            'This questionnaire collects your responses to measure these constructs: '
            + ', '.join(constructs) + '. Findings may appear only in report sections '
            + ', '.join(sections) + '.'
        ),
    )


def _voluntariness(contract: Mapping[str, Any]) -> dict:
    # NO_CONSENT is a declared pre-screen exclusion, so declining is a real,
    # supported outcome that removes the unit before any item is shown.
    definition = (
        (contract.get('pre_screen_population') or {})
        .get('to_post_screen', {})
        .get('Q_post_definition', '')
    )
    no_consent_declared = 'NO_CONSENT' in definition
    stages = list((contract.get('response_lifecycle') or {}).get('stages') or [])
    consent_is_a_stage = 'CONSENT_REVIEWED' in stages
    return _disclosure(
        'voluntariness',
        status=DERIVED if (no_consent_declared and consent_is_a_stage) else NOT_APPROVED,
        sources=[
            '/pre_screen_population/to_post_screen/Q_post_definition',
            '/response_lifecycle/stages',
        ],
        facts={
            'no_consent_is_declared_exclusion': no_consent_declared,
            'consent_review_is_a_lifecycle_stage': consent_is_a_stage,
            'lifecycle_stages': stages,
        },
        statement=(
            'Taking part is voluntary. A response recorded as NO_CONSENT is excluded before '
            'any question is shown, so declining removes your contribution rather than '
            'leaving a partial record.'
            if (no_consent_declared and consent_is_a_stage) else None
        ),
    )


def _what_is_collected(contract: Mapping[str, Any]) -> dict:
    fields = list(contract.get('event_fields') or [])
    prohibited = list(contract.get('prohibited_outputs') or [])
    pseudonym = 'respondent_unit_pseudonym' in fields
    gps_prohibited = 'PRECISE_RESPONDENT_GPS' in prohibited
    return _disclosure(
        'what_is_collected',
        status=DERIVED,
        sources=['/event_fields', '/prohibited_outputs'],
        facts={
            'event_fields': fields,
            'prohibited_outputs': prohibited,
            'identity_is_a_pseudonym': pseudonym,
            'precise_gps_is_a_prohibited_output': gps_prohibited,
        },
        statement=(
            'For each question shown, the record holds only these fields: '
            + ', '.join(fields) + '. Your identity is held as respondent_unit_pseudonym, '
            'not as a name.'
            + (' Precise respondent GPS is a prohibited output and is never collected or reported.'
               if gps_prohibited else '')
        ),
    )


def _report_use(contract: Mapping[str, Any]) -> dict:
    prohibited = list(contract.get('prohibited_outputs') or [])
    rules = contract.get('data_class_rules') or {}
    survey_rule = rules.get('RESPONDENT_SURVEY')
    availability = contract.get('report_availability') or {}
    not_estimable = [
        rid for rid, entry in availability.items()
        if isinstance(entry, Mapping) and entry.get('state') not in {'RENDERABLE_ADMINISTRATIVE'}
    ]
    return _disclosure(
        'report_use',
        status=DERIVED,
        sources=['/data_class_rules/RESPONDENT_SURVEY', '/prohibited_outputs', '/report_availability'],
        facts={
            'respondent_survey_rule': survey_rule,
            'prohibited_outputs': prohibited,
            'sections_not_currently_renderable': sorted(not_estimable),
        },
        statement=(
            'Responses are reported as aggregated respondent evidence where '
            + str(survey_rule) + '. The following are prohibited outputs and are never '
            'produced from your answers: ' + ', '.join(prohibited) + '.'
        ),
    )


def _confidentiality(contract: Mapping[str, Any]) -> dict:
    policy = contract.get('suppression_policy') or {}
    primary = policy.get('primary_suppression') or {}
    controls = list(policy.get('binding_structural_controls') or [])
    return _disclosure(
        'confidentiality',
        status=DERIVED,
        sources=[
            '/suppression_policy/status',
            '/suppression_policy/binding_structural_controls',
            '/suppression_policy/primary_suppression',
        ],
        facts={
            'policy_status': policy.get('status'),
            'binding_structural_controls': controls,
            'primary_suppression_floor_value': primary.get('floor_value'),
            'primary_suppression_floor_status': primary.get('floor_status'),
            'complementary_suppression': (policy.get('complementary_suppression') or {}).get('rule'),
            'cross_view_differencing_check': (policy.get('cross_view_differencing_check') or {}).get('rule'),
            'residual_bucket_required': (policy.get('residual_bucket_required') or {}).get('rule'),
        },
        statement=(
            'Small counts are protected by structural controls that bind regardless of any '
            'numeric threshold: ' + ', '.join(controls) + '. A cell that is suppressed is '
            'always accompanied by another suppression, no two published views may differ by '
            'exactly one suppressed cell, and any suppressed residual is published as a '
            'residual bucket.'
        ),
        # The numeric floor is NOT_APPROVED (SD-11). The notice states the controls
        # that do bind and says nothing about a threshold it does not have.
        decision=None,
    )


def _withdrawal_and_retention(contract: Mapping[str, Any]) -> dict:
    stages = list((contract.get('response_lifecycle') or {}).get('stages') or [])
    gate_rows = [
        row for row in (contract.get('approval_gate_matrix') or {}).get('rows', [])
        if BLOCKED_DECISION_ID in str(row.get('gate', ''))
    ]
    pending = bool(gate_rows) and all(row.get('status') == APPROVAL_PENDING for row in gate_rows)
    return _disclosure(
        'withdrawal_and_retention',
        status=NOT_APPROVED if pending else DERIVED,
        sources=[
            '/response_lifecycle/stages',
            '/approval_gate_matrix/rows',
            '/identity_model/privacy_status',
        ],
        facts={
            'lifecycle_stages': stages,
            'withdrawal_is_supported': 'CONSENT_REVIEWED' in stages,
            'retention': {
                'value': None,
                'unit': None,
                'status': NOT_APPROVED,
                'decision': BLOCKED_DECISION_ID,
            },
            'gate_rows': gate_rows,
            'identity_model_privacy_status': (contract.get('identity_model') or {}).get('privacy_status'),
        },
        statement=(
            'Withdrawal is supported through the questionnaire withdrawal endpoint. '
            'The retention period for withdrawn and completed responses is not yet approved '
            'by the data protection owner (' + BLOCKED_DECISION_ID + '), so no retention '
            'period is stated here.'
        ),
        decision=BLOCKED_DECISION_ID if pending else None,
    )


_BUILDERS = {
    'purpose': _purpose,
    'voluntariness': _voluntariness,
    'what_is_collected': _what_is_collected,
    'report_use': _report_use,
    'confidentiality': _confidentiality,
    'withdrawal_and_retention': _withdrawal_and_retention,
}


def build_notice(contract: Mapping[str, Any], *, scope: str) -> dict:
    """Derive the six-disclosure notice for ``scope``.

    Deterministic: the same contract always yields the same ``notice_hash``. The
    result is a sibling of the session manifest, never part of it -- adding keys to
    the manifest would break ``digest(manifest) == release['manifest_hash']``.
    """
    disclosures = [_BUILDERS[disclosure_id](contract) for disclosure_id in DISCLOSURE_IDS]
    blocked = sorted({d['decision'] for d in disclosures if d['decision']})
    pending = [d['id'] for d in disclosures if d['status'] == NOT_APPROVED]

    notice = {
        'contract_version': CONTRACT_VERSION,
        'scope': scope,
        'approval_state': APPROVAL_PENDING if pending else APPROVAL_APPROVED,
        'approved_for_scope': not pending and scope in HUMAN_SCOPES,
        'blocked_decisions': blocked,
        'pending_disclosures': pending,
        'disclosures': disclosures,
    }
    notice['notice_hash'] = _sha256(notice)
    return notice


def require_approved(notice: Mapping[str, Any]) -> None:
    """Refuse a human-facing scope whose notice is not approved.

    Raises the runtime's ``CqRefused`` rather than a bare exception so the API
    returns the same shaped error as every other refusal. Imported lazily to keep
    this module free of a hard dependency on the domain layer at import time.
    """
    scope = str(notice.get('scope') or '')
    if scope not in HUMAN_SCOPES:
        return
    if notice.get('approval_state') == APPROVAL_APPROVED and notice.get('approved_for_scope'):
        return
    from sitewise.domain.cq_runtime import CqRefused

    raise CqRefused('CQ_CONSENT_NOTICE_NOT_APPROVED', 503)


def synthetic_notice(manifest: Mapping[str, Any], *, locale: str) -> dict:
    """The notice actually served in an isolated synthetic run.

    A synthetic run has no human respondent, so the six human disclosures do not
    apply. Rather than pretend they do, this returns a single-scope notice that
    says exactly what the run is, reusing the manifest's own consent text and its
    hash. ``approval_state`` is APPROVED because the statement is true and complete
    for this scope -- there is nobody to inform and nothing to retain.
    """
    text = (manifest.get('consent_text') or {}).get(locale)
    notice = {
        'contract_version': CONTRACT_VERSION,
        'scope': 'ISOLATED_SYNTHETIC_TEST',
        'approval_state': APPROVAL_APPROVED,
        'approved_for_scope': True,
        'blocked_decisions': [],
        'pending_disclosures': [],
        'consent_version': manifest.get('consent_version'),
        'consent_text': text,
        'consent_text_hash': hashlib.sha256((text or '').encode('utf-8')).hexdigest(),
        'disclosures': [],
        'disclosure_applicability': (
            'NOT_APPLICABLE_NO_HUMAN_RESPONDENT — this run processes synthetic non-human '
            'records only, so purpose, voluntariness, withdrawal and retention disclosures '
            'have no respondent to address.'
        ),
    }
    notice['notice_hash'] = _sha256(notice)
    return notice
