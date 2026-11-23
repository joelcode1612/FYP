"""Candidate-only EE-01 explanations over the server-held readback context.

This service does NOT dispatch a prompt. V1.0 has no disclosure adapter for the
EXPLANATION stage (the only synthetic adapter is BDJ-scoped, and the attempt
ledger registers BDJ/QJ/QG only), so every candidate is rendered locally:

* an empty authorized-claim set yields the insufficient-evidence candidate
  (prompt spec section 8);
* an authorized-claim set yields a template that restates the supplied counts,
  denominators, percentages, labels and reference periods without computing,
  rounding or aggregating anything;
* when the snapshot resolves to a Q01–Q13 item, the registry-backed
  deterministic template supplies the item-specific prose and the evidence-state
  sentence instead of the generic text. The registry is the single source of that
  prose; this module holds none of its own.

There is exactly one explanation module. The registry path is a *renderer choice*
inside it, not a second contract: the output object, the envelope, the guards and
the authority markers are unchanged.

Selection policy is strict and ordered: a validated model candidate if one is
supplied and passes every guard, otherwise the approved deterministic template,
otherwise HOLD. There is no path that emits partial prose.

``candidate.origin`` records which producer ran, so a consumer that persists only
the candidate can distinguish template prose from model prose.

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
    question_evidence_output,
    validate_candidate,
)
from sitewise.project1.explanation_registry import (
    decide_state,
    effective_state,
    load_registry,
    render_question,
    resolve_question,
)

CONTRACT_VERSION = 'ee01-explanation-candidate/3'
TEMPLATE_PRODUCER = 'EE01-EXPLANATION-TEMPLATE-1'
QUESTION_TEMPLATE_PRODUCER = 'EE01-EXPLANATION-QUESTION-REGISTRY-1'
EXTERNAL_PRODUCER = 'EXTERNAL_EXPLANATION_CANDIDATE'


def _numbers_in(value) -> set[str]:
    """Every number the server actually holds, so narrative cannot invent one."""
    from sitewise.project1.explanation_contracts import extract_numbers
    return extract_numbers(canonical(value))


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
    def _counts(snapshot: dict) -> dict:
        """Read the stored funnel counts without recomputing anything."""
        counts = snapshot.get('counts_json') or {}
        if isinstance(counts, str):
            counts = json.loads(counts)
        return {
            'q': int(snapshot.get('q') or 0),
            's': int(snapshot.get('s') or 0),
            'a': int(snapshot.get('a') or 0),
            'v': int(snapshot.get('v') or 0),
            'refused': int(counts.get('REFUSED') or 0),
            'invalid': int(counts.get('INVALID') or 0),
            'excluded': int(counts.get('excluded') or 0),
            'total_units': int(snapshot.get('q') or 0) + int(counts.get('excluded') or 0),
        }

    def _question_block(self, snapshot: dict, *, question_id: str | None = None) -> dict | None:
        """Resolve the snapshot to a Q01–Q13 item and decide its evidence state.

        Returns ``None`` when the item cannot be resolved, in which case the caller
        keeps the generic explanation rather than guessing which item this is. The
        registry supplies the item's gate and routing resolution; the counts come
        from the stored snapshot, never from the caller.
        """
        registry = load_registry()
        slot_id = snapshot.get('slot_id')
        if question_id and slot_id and not slot_id.startswith('Q10:'):
            # A caller-supplied item that disagrees with the snapshot's own slot
            # would bind one item's prose to another item's measurement.
            if question_id != slot_id:
                raise CqRefused('EXPLANATION_QUESTION_BINDING_MISMATCH', 409)
        entry, basis = resolve_question(registry, question_id=question_id,
                                        slot_id=slot_id)
        if entry is None:
            return None
        counts = self._counts(snapshot)
        gate, state = decide_state(entry, **counts)
        return {
            'question_id': entry.question_id,
            'resolution_basis': basis,
            'instrument_gate': gate,
            'evidence_state': state,
            'effective_state': effective_state(gate, state),
            'routing_resolved': entry.routing_resolved,
            'report_sections': list(entry.report_sections),
            'template_usable_for_substantive_report':
                entry.template_usable_for_substantive_report,
            'registry_version': registry.registry_version,
            'registry_sha256': registry.sha256,
            'counts': counts,
        }

    @staticmethod
    def _packet(task_mode: str, context: dict, snapshot: dict, context_hash: str,
                question: dict | None = None) -> dict:
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
        reference_universe = (
            list(gates) + [f.get('claim_id', '') for f in findings if f.get('claim_id')]
        )
        if question:
            # The state code and item id are themselves evidence references, so a
            # caller may name them without inventing a claim.
            reference_universe.extend([question['question_id'],
                                       question['effective_state'],
                                       question['evidence_state']])
            if question['instrument_gate']:
                reference_universe.append(question['instrument_gate'])
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
            'question': question,
            'reference_universe': reference_universe,
        }

    def explain(self, actor: UUID, assessment_id: UUID, campaign_id: UUID,
                snapshot_id: UUID, *, task_mode: str, claim_ids: list[str],
                context_hash: str, question_id: str | None = None) -> dict:
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
        question = self._question_block(snapshot, question_id=question_id)
        packet = self._packet(task_mode, context, snapshot, context_hash, question)
        permitted = {f['claim_id'] for f in findings}
        if not set(claim_ids) <= permitted:
            raise CqRefused('EXPLANATION_CLAIM_NOT_AUTHORIZED', 409)

        selected = []
        wanted = set(claim_ids)
        for finding in findings:
            if not wanted or finding['claim_id'] in wanted:
                selected.append(finding)

        output, llm_execution, producer = self._render(packet, selected, permitted)
        # Only the deterministic template may draw on the registry's own vocabulary;
        # the model path is validated with the strict guard alone.
        registry_literals = (load_registry().literals
                             if producer == QUESTION_TEMPLATE_PRODUCER else None)
        validate_candidate(output, packet=packet, allowed_claim_ids=permitted,
                           allowed_numbers=_numbers_in(packet),
                           registry_literals=registry_literals)
        return {
            'contract_version': CONTRACT_VERSION,
            # No prompt executed, so no prompt version is attributed. The template
            # is named instead, and the candidate carries its own origin.
            'producer': producer,
            'prompt_version': None,
            'authority': 'CANDIDATE_UNVERIFIED',
            'llm_execution': llm_execution,
            'candidate': output.model_dump(),
            'question': question,
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
            output, producer = self._template(packet, selected)
            return output, 'REJECTED_FELL_BACK', producer
        output, producer = self._template(packet, selected)
        return output, 'NOT_ATTEMPTED', producer

    @classmethod
    def _template(cls, packet: dict, selected: list[dict]) -> tuple[ExplanationOutput, str]:
        """Render the deterministic candidate, and name which template produced it."""
        missing = list(packet['report_admission_references'])
        question = packet.get('question')
        if question:
            rendered = cls._question_template(packet, question, selected, missing)
            if rendered is not None:
                return rendered, QUESTION_TEMPLATE_PRODUCER
        if not selected:
            # Section 8: no authorized claim ⇒ no interpretation, produced locally.
            return insufficient_evidence_output(
                context_id=packet['context_id'],
                snapshot_id=packet['snapshot_id'],
                task_mode=packet['task_mode'],
                missing=missing,
            ), TEMPLATE_PRODUCER
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
        ), TEMPLATE_PRODUCER

    @staticmethod
    def _question_template(packet: dict, question: dict, selected: list[dict],
                           missing: list[str]) -> ExplanationOutput | None:
        """Registry-backed rendering for a resolved Q01–Q13 item.

        Returns ``None`` only when the item resolved but the registry cannot render
        it, in which case the caller keeps the generic template. A ``VALID_APPROVED``
        state with no authorized finding for the item is not such a case: the
        measurement exists but may not be interpreted, so it holds.
        """
        registry = load_registry()
        entry = registry.question(question['question_id'])
        if entry is None:
            return None
        state = question['effective_state']
        gate = question['instrument_gate']
        counts = question['counts']
        state_refs = [question['question_id'], state]

        if state == 'VALID_APPROVED':
            # Figures come from an authorized finding bound to this item. Without
            # one there is a measurement but no permission to explain it.
            bound = [f for f in selected if f.get('question_id') == entry.question_id]
            if not bound:
                raise CqRefused('EXPLANATION_FINDING_NOT_AUTHORIZED', 503)
            figures = dict(bound[0])
            figures.setdefault('V', counts['v'])
            rendered = render_question(
                registry, entry, gate=None, state=state,
                question_id=entry.question_id, figures=figures,
                missing=state_refs + [str(f['claim_id']) for f in bound])
            return question_evidence_output(
                context_id=packet['context_id'],
                snapshot_id=packet['snapshot_id'],
                task_mode=packet['task_mode'],
                rendered=rendered,
                used_claim_ids=[str(f['claim_id']) for f in bound],
                missing=rendered['missing_evidence_references'],
            )

        rendered = render_question(
            registry, entry, gate=gate, state=state,
            question_id=entry.question_id,
            figures={'count': counts['a'] - counts['v'], 'shown': counts['s'],
                     'V': counts['v']},
            missing=missing + state_refs)
        return question_evidence_output(
            context_id=packet['context_id'],
            snapshot_id=packet['snapshot_id'],
            task_mode=packet['task_mode'],
            rendered=rendered,
            used_claim_ids=[],
            missing=rendered['missing_evidence_references'],
        )
