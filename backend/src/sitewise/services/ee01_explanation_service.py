"""Candidate-only EE-01 explanations over the server-held readback context.

This service does NOT dispatch a prompt. V1.0 has no disclosure adapter for the
EXPLANATION stage (the only synthetic adapter is BDJ-scoped, and the attempt
ledger registers BDJ/QJ/QG only), so every candidate is rendered locally by the
deterministic template:

* an empty authorized-claim set yields the insufficient-evidence candidate
  (prompt spec section 8);
* an authorized-claim set yields a template that restates the supplied counts,
  denominators, percentages, labels and reference periods without computing,
  rounding or aggregating anything.

``candidate.origin`` records which producer ran, so a consumer that persists only
the candidate can distinguish template prose from model prose. An optional
``candidate_source`` callable may supply an already-produced candidate; it is
validated and used only when it passes every guard, and otherwise the template is
rendered instead. No composition in this repository supplies one, because doing
so requires the adopted EXPLANATION disclosure adapter.

This service NEVER writes to a report, admission table or any other durable
store. It reads the immutable EE-01 snapshot through its restricted principal
and returns a candidate envelope whose authority markers are all false.
"""
from __future__ import annotations

import json
from uuid import UUID

from sitewise.domain.cq_runtime import CqRefused
from sitewise.project1.contracts import canonical, no_authority
from sitewise.project1.explanation_contracts import (
    MAX_TEMPLATE_FINDINGS,
    SCHEMA_VERSION,
    ExplanationOutput,
    authorized_finding_output,
    insufficient_evidence_output,
    validate_candidate,
)

CONTRACT_VERSION = 'ee01-explanation-candidate/2'
TEMPLATE_PRODUCER = 'EE01-EXPLANATION-TEMPLATE-1'
EXTERNAL_PRODUCER = 'EXTERNAL_EXPLANATION_CANDIDATE'


def _numbers_in(value) -> set[str]:
    """Every number the server actually holds, so narrative cannot invent one."""
    from sitewise.project1.explanation_contracts import _NUMBER_RE
    return set(_NUMBER_RE.findall(canonical(value)))


def _explanation_authorized(finding) -> bool:
    """A finding is interpretable only when the server marked it authorized.

    Fail closed: an unmarked or malformed finding is a governance error, never a
    licence to explain held data.
    """
    return (isinstance(finding, dict) and finding.get('authorized') is True
            and isinstance(finding.get('claim_id'), str) and bool(finding['claim_id']))


class Ee01ExplanationService:
    """Reads EE-01 readback; produces a non-authoritative candidate only."""

    def __init__(self, ee01, *, candidate_source=None):
        self.ee01 = ee01
        # Validation-only seam: receives the server-built packet and returns a
        # candidate mapping. It is never a provider client, and no caller may
        # wire a disclosure-bound runner here until the EXPLANATION stage has an
        # adopted disclosure adapter.
        self.candidate_source = candidate_source

    @staticmethod
    def _packet(task_mode: str, context: dict, snapshot: dict, context_hash: str) -> dict:
        """Assemble the V1.0 input contract strictly from server-held data.

        Missing fields stay empty/absent — they are never guessed from the
        client body or from an external document. ``_read`` (ee01_service.py)
        already verifies every digest before this point.
        """
        metadata = snapshot.get('metadata_json') or {}
        if isinstance(metadata, str):
            metadata = json.loads(metadata)
        findings = context.get('findings') or []
        gates = context.get('gates') or []
        codes = sorted({str(cell.get('code')) for cell in snapshot.get('cells', [])
                        if cell.get('code')})
        return {
            'task_mode': task_mode,
            'context_id': context_hash,
            'assessment_id': str(snapshot['assessment_id']),
            'campaign_id': str(snapshot['campaign_id']),
            'cohort_id': None,
            'snapshot_id': str(snapshot['id']),
            'snapshot_hash': snapshot['fingerprint'],
            'measurement_ruleset_id': str(snapshot['question_version']),
            'measurement_ruleset_version': metadata.get('instrument_version', ''),
            'qualification_policy_version': metadata.get('qualification_versions', []),
            'privacy_policy_version': metadata.get('privacy_policy', ''),
            'report_admission_references': gates,
            'authorized_claims': findings,
            'question_versions': {
                'instrument_version': metadata.get('instrument_version', ''),
                'bank_version': metadata.get('bank_version', ''),
                'routing_version': metadata.get('routing_version', ''),
                'consent_version': metadata.get('consent_version', ''),
            },
            'approved_response_labels': [],
            'measurement_definitions': {
                'rule': metadata.get('rule', ''),
                'selection': metadata.get('selection', ''),
                'cutoff_basis': metadata.get('cutoff_basis', ''),
                'scope': snapshot.get('scope', ''),
            },
            'limitations': metadata.get('scientific_gaps', []),
            'allowed_report_destinations': [],
            'reference_universe': (
                list(gates) + [f.get('claim_id', '') for f in findings if f.get('claim_id')]
            ),
        }

    def explain(self, actor: UUID, assessment_id: UUID, campaign_id: UUID,
                snapshot_id: UUID, *, task_mode: str, claim_ids: list[str],
                context_hash: str) -> dict:
        readback = self.ee01.report_readback(actor, assessment_id, campaign_id, snapshot_id)
        if readback['context_hash'] != context_hash:
            raise CqRefused('EXPLANATION_CONTEXT_HASH_MISMATCH', 409)
        if readback['status'] != 'REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE':
            raise CqRefused('EXPLANATION_ADMISSION_STATE_CHANGED', 503)
        context = readback['context']
        if isinstance(context, str):
            context = json.loads(context)
        if context.get('authority') != 'AUTHORITY_UNVERIFIED':
            # An adopted scientific/admission authority changes the governance
            # position; V1.0 has no disclosure gate for that path. Findings being
            # present is a different question and no longer refuses here: each
            # finding must carry the server's own authorization marker.
            raise CqRefused('EXPLANATION_ADAPTER_UNVERIFIED', 503)
        findings = context.get('findings') or []
        if not all(_explanation_authorized(f) for f in findings):
            raise CqRefused('EXPLANATION_FINDING_NOT_AUTHORIZED', 503)

        snapshot = self.ee01.read(actor, assessment_id, campaign_id, snapshot_id)
        packet = self._packet(task_mode, context, snapshot, context_hash)
        permitted = {f['claim_id'] for f in findings}
        if not set(claim_ids) <= permitted:
            raise CqRefused('EXPLANATION_CLAIM_NOT_AUTHORIZED', 409)

        selected = []
        wanted = set(claim_ids)
        for finding in findings:
            if not wanted or finding['claim_id'] in wanted:
                selected.append(finding)

        output, llm_execution, producer = self._render(packet, selected, permitted)
        validate_candidate(output, packet=packet, allowed_claim_ids=permitted,
                           allowed_numbers=_numbers_in(packet))
        return {
            'contract_version': CONTRACT_VERSION,
            # No prompt executed, so no prompt version is attributed. The template
            # is named instead, and the candidate carries its own origin.
            'producer': producer,
            'prompt_version': None,
            'authority': 'CANDIDATE_UNVERIFIED',
            'llm_execution': llm_execution,
            'candidate': output.model_dump(),
            **no_authority(),
        }

    def _render(self, packet: dict, selected: list[dict], permitted: set[str]):
        """Prefer a validated model candidate; otherwise render the template."""
        if selected and self.candidate_source is not None:
            try:
                proposed = ExplanationOutput.model_validate(self.candidate_source(packet))
                validate_candidate(proposed, packet=packet,
                                   allowed_claim_ids=permitted,
                                   allowed_numbers=_numbers_in(packet))
                if proposed.origin == 'LLM':
                    return proposed, 'RETURNED', EXTERNAL_PRODUCER
            except Exception:
                # Any failure of the optional source (absent, malformed, invented
                # number, unauthorized claim) falls back to the deterministic
                # template. It must never raise and never emit partial prose.
                pass
            return self._template(packet, selected), 'REJECTED_FELL_BACK', TEMPLATE_PRODUCER
        return self._template(packet, selected), 'NOT_ATTEMPTED', TEMPLATE_PRODUCER

    @staticmethod
    def _template(packet: dict, selected: list[dict]) -> ExplanationOutput:
        missing = list(packet['report_admission_references'])
        if not selected:
            # Section 8: no authorized claim ⇒ no interpretation, produced locally.
            return insufficient_evidence_output(
                context_id=packet['context_id'],
                snapshot_id=packet['snapshot_id'],
                task_mode=packet['task_mode'],
                missing=missing,
            )
        if len(selected) > MAX_TEMPLATE_FINDINGS:
            # A faithful restatement no longer fits the field limits; refuse
            # rather than truncate the claim set silently.
            raise CqRefused('EXPLANATION_TEMPLATE_SCOPE_EXCEEDED', 503)
        return authorized_finding_output(
            context_id=packet['context_id'],
            snapshot_id=packet['snapshot_id'],
            task_mode=packet['task_mode'],
            findings=selected,
            missing=missing,
        )
