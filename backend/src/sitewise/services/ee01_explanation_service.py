"""Candidate-only EE-01 explanations over the server-held readback context.

V1.0 deliberately does NOT call an LLM. The held context carries zero admitted
findings, there is no production disclosure adapter, and the project1_ai ledger
has no run row for an explanation. Prompt spec section 8 is therefore executed
locally: an insufficient-evidence candidate, no invented claim and no numbers.

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
    SCHEMA_VERSION,
    ExplanationOutput,
    insufficient_evidence_output,
    validate_candidate,
)


def _numbers_in(value) -> set[str]:
    """Every number the server actually holds, so narrative cannot invent one."""
    from sitewise.project1.explanation_contracts import _NUMBER_RE
    return set(_NUMBER_RE.findall(canonical(value)))


class Ee01ExplanationService:
    """Reads EE-01 readback; produces a non-authoritative candidate only."""

    def __init__(self, ee01):
        self.ee01 = ee01

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
        if context.get('authority') != 'AUTHORITY_UNVERIFIED' or context.get('findings'):
            # An adopted authority adapter or newly admitted claim changes the
            # governance position; V1.0 has no disclosure gate for that path.
            raise CqRefused('EXPLANATION_ADAPTER_UNVERIFIED', 503)

        snapshot = self.ee01.read(actor, assessment_id, campaign_id, snapshot_id)
        packet = self._packet(task_mode, context, snapshot, context_hash)
        permitted = {c['claim_id'] for c in context['findings'] if c.get('claim_id')}
        if not set(claim_ids) <= permitted:
            raise CqRefused('EXPLANATION_CLAIM_NOT_AUTHORIZED', 409)

        # Section 8: no admitted claim ⇒ no interpretation, produced locally.
        output: ExplanationOutput = insufficient_evidence_output(
            context_id=packet['context_id'],
            snapshot_id=packet['snapshot_id'],
            task_mode=task_mode,
            missing=list(packet['report_admission_references']),
        )
        validate_candidate(output, packet=packet, allowed_claim_ids=permitted,
                           allowed_numbers=_numbers_in(packet))
        return {
            'contract_version': 'ee01-explanation-candidate/1',
            'prompt_version': 'EE01-EXPLANATION-1-CAND',
            'authority': 'CANDIDATE_UNVERIFIED',
            'llm_execution': 'NOT_ATTEMPTED',
            'candidate': output.model_dump(),
            **no_authority(),
        }
