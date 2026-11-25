"""The report's EE-01 measurement association: identity and admission, never counts.

Why this module exists
----------------------
The nine-section report could not say anything about a questionnaire measurement
even when one existed one link away. ``generate_assessment_report`` had no
parameter for it, so section 05 could only print the specification's held
notice — and that notice says *"no admitted measurement line exists for this
assessment"*, which for an assessment with seven frozen snapshots reads as
"no measurement exists". The two states are different and the report has to be
able to tell them apart.

What it resolves, in order
--------------------------
marketplace assessment -> M2 assessment -> CQ campaign -> frozen snapshot, using
only authoritative server-side sources:

* the M2 id comes from ``AssessmentService.payload()['m2_confirmation']``, which
  already resolves ``m2_assessment_links`` (unrevoked), the owner match, the
  current ``confirmed_revision`` and the matching confirmation snapshot. This
  module does not re-derive that join and never accepts an id from a caller.
* the campaign and snapshots come from ``Ee01Service.explanation_binding``, the
  same server-resolved envelope the workspace uses, which filters by assessment
  **and** owner and echoes the id it was addressed with.

What it deliberately does not do
--------------------------------
* It never returns a count, a percentage, an option list or a derived line. The
  ordinary report is not an admitted-findings surface: ``counts_disclosed`` is
  ``False`` unconditionally, and the numbers stay where they are — in EE-01,
  behind ``/cq/.../measurements/{snapshot}`` and its admission gate. A chart
  built from this section would have to invent its own numbers, which is exactly
  what ``chart_spec.from_ee01`` refuses to allow.
* It never decides that evidence *is* admitted. ``detail_readable`` is ``False``
  until an A10 admission adapter is adopted, mirroring the module-level hold the
  availability endpoint already reports
  (``report_admission_authorized: False``). Flipping it here would be an
  admission override, which is out of scope for a report integration.
* It never raises. A report must not fail because the questionnaire store is
  unreachable: every failure degrades to an explicit, named state, and the
  distinction between "no link", "no campaign", "exists but withheld" and
  "could not read" is preserved rather than collapsed into one blank section.
"""
from __future__ import annotations

from datetime import datetime
from typing import Any, Callable
from uuid import UUID

CONTRACT_VERSION = 'report-measurement/1'

#: Section 05 reserves R03 for the concept-intent distribution, and Q05 is the
#: slot that carries it. The other measured slots are listed as identity only —
#: the report has no section for them and inventing one would be a new report.
FOCUS_SLOT = 'Q05'

#: Evidence exists, the assessment is linked, and admission is withheld. This is
#: the only reachable state while no A10 adapter is adopted.
HELD = 'HELD'
#: The assessment has no current M2 confirmation, so it cannot own a campaign.
NO_M2_LINK = 'NO_M2_LINK'
#: The M2 record is confirmed but owns no questionnaire campaign.
NO_CAMPAIGN = 'NO_CAMPAIGN'
#: The questionnaire store could not be read. Distinct from the two above: this
#: is a failure to look, not an answer of "nothing there".
UNAVAILABLE = 'UNAVAILABLE'
#: No resolver ran at all (the report was composed without one).
NOT_RESOLVED = 'NOT_RESOLVED'

_HELD_REASON = (
    'A questionnaire measurement exists for this assessment and is held: no '
    'authorized report-admission adapter is adopted, so its counts and shares '
    'are withheld rather than estimated. This section reports the association, '
    'not a finding.'
)
_NO_LINK_REASON = (
    'This assessment has no current M2 confirmation, so no questionnaire '
    'campaign can be associated with it.'
)
_NO_CAMPAIGN_REASON = (
    'The confirmed M2 assessment for this business has no questionnaire '
    'campaign, so no measurement exists yet.'
)
_UNAVAILABLE_REASON = (
    'The questionnaire store could not be read while this report was composed, '
    'so no measurement association can be reported. This is not a measured '
    'zero.'
)


def _blank(status: str, reason_code: str, reason: str, **extra) -> dict:
    """One shape for every state, so a client never has to branch on presence."""
    return {
        'contract_version': CONTRACT_VERSION,
        'available': False,
        'status': status,
        'reason_code': reason_code,
        'reason': reason,
        'counts_disclosed': False,
        'detail_readable': False,
        'identity': None,
        'slots': [],
        'admission': {'state': None, 'report_release_authorized': False},
        **extra,
    }


def default_section() -> dict:
    """The section a report carries when no resolver was supplied."""
    return _blank(
        NOT_RESOLVED,
        'MEASUREMENT_NOT_RESOLVED',
        'This report was composed without resolving the questionnaire '
        'association, so none is reported.',
    )


def _cutoff_key(value: Any) -> datetime:
    """Sort key for a cutoff. Unparseable values sort oldest rather than raise."""
    if isinstance(value, datetime):
        return value
    try:
        return datetime.fromisoformat(str(value))
    except (TypeError, ValueError):
        return datetime.min.replace(tzinfo=None)


def _iso(value: Any) -> str | None:
    """ISO-8601 text for a cutoff, so a client never has to parse two formats.

    psycopg2 hands back a ``datetime``, but ``Ee01Service.explanation_binding``
    passes its result through ``plain()`` first, which serialises that datetime
    to ``"2026-11-25 18:00:00+08:00"`` — a space separator, not the ISO-T form.
    Both reach this function, so a string is re-parsed and re-emitted rather
    than passed through: the wire format must be identical either way, and a
    client that splits on ``T`` must not silently lose the cutoff.
    """
    if value is None:
        return None
    if isinstance(value, datetime):
        return value.isoformat()
    text_value = str(value)
    try:
        return datetime.fromisoformat(text_value).isoformat()
    except (TypeError, ValueError):
        return text_value


def _slots(binding: dict) -> list[dict]:
    """Latest snapshot per slot, ordered by slot.

    ``explanation_binding`` returns every snapshot the campaign ever produced,
    newest first. The report names one cutoff per slot; listing all five Q05
    cutoffs would invite a reader to compare them as if they were revisions of
    one finding, which they are not — each is a separate frozen cohort.
    """
    latest: dict[str, dict] = {}
    for entry in binding.get('snapshots') or []:
        if not isinstance(entry, dict):
            continue
        slot = entry.get('slot_id')
        if not slot:
            continue
        current = latest.get(str(slot))
        if current is None or _cutoff_key(entry.get('cutoff')) > _cutoff_key(
            current.get('cutoff')
        ):
            latest[str(slot)] = entry
    return [latest[slot] for slot in sorted(latest)]


def _identity(m2_id: str, campaign_id: str, release_id: str | None, entry: dict) -> dict:
    return {
        'm2_assessment_id': m2_id,
        'campaign_id': campaign_id,
        'release_id': release_id,
        'slot_id': entry.get('slot_id'),
        'snapshot_id': entry.get('snapshot_id'),
        'question_version': entry.get('question_version'),
        'cutoff': _iso(entry.get('cutoff')),
        'fingerprint': entry.get('fingerprint'),
        'context_hash': entry.get('context_hash'),
        'admission_state': entry.get('admission_state'),
    }


def resolve_report_measurement(
    *,
    record: dict | None,
    actor_user_id: Any,
    ee01_factory: Callable[[], Any],
) -> dict:
    """Resolve the measurement association for one already-owner-checked report.

    ``record`` is ``AssessmentService.payload()`` for an assessment the caller
    has already been proven to own, so this function performs no ownership check
    of its own — it must not be reachable with an unchecked record.

    ``ee01_factory`` returns an ``Ee01Service`` bound to the restricted
    ``p1_ee01_runtime`` principal. It is injected rather than imported so this
    module stays free of API-layer wiring, and so a test can supply a fake.
    """
    confirmation = (record or {}).get('m2_confirmation') or {}
    m2_id = confirmation.get('m2_assessment_id')
    if not m2_id:
        return _blank(NO_M2_LINK, 'NO_M2_LINK', _NO_LINK_REASON)

    try:
        service = ee01_factory()
    except Exception:  # noqa: BLE001 - an unreachable store degrades, never raises
        return _blank(UNAVAILABLE, 'MEASUREMENT_STORE_UNAVAILABLE', _UNAVAILABLE_REASON)

    try:
        binding = service.explanation_binding(actor_user_id, UUID(str(m2_id)))
    except Exception as exc:  # noqa: BLE001 - CqRefused(404) and friends
        code = getattr(exc, 'code', '') or ''
        if code == 'EXPLANATION_BINDING_NOT_FOUND':
            return _blank(NO_CAMPAIGN, 'NO_CAMPAIGN', _NO_CAMPAIGN_REASON)
        return _blank(UNAVAILABLE, 'MEASUREMENT_STORE_UNAVAILABLE', _UNAVAILABLE_REASON)

    if not isinstance(binding, dict):
        return _blank(UNAVAILABLE, 'MEASUREMENT_STORE_UNAVAILABLE', _UNAVAILABLE_REASON)

    # Fail closed on an envelope that names a different assessment than the one
    # we asked about. The server resolves this id, so a mismatch is a defect,
    # not a caller error — and it must never be reported as this assessment's.
    if str(binding.get('assessment_id') or '') != str(m2_id):
        return _blank(UNAVAILABLE, 'MEASUREMENT_IDENTITY_MISMATCH', _UNAVAILABLE_REASON)

    slots = _slots(binding)
    if not slots:
        return _blank(NO_CAMPAIGN, 'NO_MEASUREMENT', _NO_CAMPAIGN_REASON)

    focus = next((s for s in slots if str(s.get('slot_id')) == FOCUS_SLOT), None)
    admission_state = (focus or slots[0]).get('admission_state')

    return {
        'contract_version': CONTRACT_VERSION,
        'available': True,
        'status': HELD,
        'reason_code': str(admission_state or 'REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE'),
        'reason': _HELD_REASON,
        'counts_disclosed': False,
        'detail_readable': False,
        'identity': _identity(
            str(m2_id),
            str(binding.get('campaign_id') or ''),
            str(binding.get('release_id') or '') or None,
            focus or slots[0],
        ),
        'slots': [
            {
                'slot_id': s.get('slot_id'),
                'snapshot_id': s.get('snapshot_id'),
                'question_version': s.get('question_version'),
                'cutoff': _iso(s.get('cutoff')),
                'admission_state': s.get('admission_state'),
            }
            for s in slots
        ],
        'admission': {
            'state': admission_state,
            'report_release_authorized': False,
        },
    }
