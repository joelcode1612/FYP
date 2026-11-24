"""Authenticated, assessment-bound readback of candidate explanation results.

This is a read-only companion to the existing explanation service. It does not
render new prose, create a second explanation model or decide admission. It proves
that a stored result belongs to the caller's assessment, campaign, EE-01 snapshot
and question before returning it, and it refuses stale or authority-asserting
rows.
"""
from __future__ import annotations

import json
from uuid import UUID

from sitewise.domain.cq_runtime import CqRefused
from sitewise.project1.explanation_registry import load_registry
from sitewise.project1.explanation_store import staleness_reason

WITHHELD_STATE = 'REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE'


class ExplanationReadService:
    def __init__(self, ee01, store):
        self.ee01 = ee01
        self.store = store

    @staticmethod
    def _context(readback) -> dict:
        context = readback.get('context')
        if isinstance(context, str):
            context = json.loads(context)
        if not isinstance(context, dict):
            raise CqRefused('EXPLANATION_CONTEXT_UNAVAILABLE', 503)
        return context

    @staticmethod
    def _question_matches(snapshot_slot: str | None, question_id: str) -> bool:
        if not snapshot_slot:
            return True
        if snapshot_slot.startswith('Q10:') or question_id.startswith('Q10:'):
            return snapshot_slot.split(':', 1)[0] == question_id.split(':', 1)[0]
        return snapshot_slot == question_id

    def read(self, actor: UUID, assessment_id: UUID, campaign_id: UUID,
             snapshot_id: UUID, question_id: str,
             *, expected_context_hash: str | None = None,
             official: bool = False) -> dict:
        if official:
            raise CqRefused('EXPLANATION_OFFICIAL_RELEASE_NOT_AUTHORIZED', 403)
        readback = self.ee01.report_readback(actor, assessment_id, campaign_id, snapshot_id)
        if readback.get('status') != WITHHELD_STATE:
            raise CqRefused('EXPLANATION_ADMISSION_STATE_CHANGED', 503)
        context = self._context(readback)
        context_hash = str(readback.get('context_hash') or '')
        if expected_context_hash and context_hash != expected_context_hash:
            raise CqRefused('EXPLANATION_CONTEXT_HASH_MISMATCH', 409)
        if (str(context.get('assessment_id')) != str(assessment_id)
                or str(context.get('campaign_id')) != str(campaign_id)
                or str(context.get('snapshot_id')) != str(snapshot_id)
                or context.get('authority') != 'AUTHORITY_UNVERIFIED'):
            raise CqRefused('EXPLANATION_SOURCE_BINDING_INVALID', 409)

        snapshot = self.ee01.read(actor, assessment_id, campaign_id, snapshot_id)
        if (str(snapshot.get('assessment_id')) != str(assessment_id)
                or str(snapshot.get('campaign_id')) != str(campaign_id)
                or str(snapshot.get('id')) != str(snapshot_id)
                or not self._question_matches(snapshot.get('slot_id'), question_id)):
            raise CqRefused('EXPLANATION_SNAPSHOT_BINDING_INVALID', 409)

        result = self.store.current(
            assessment_id=str(assessment_id), snapshot_id=str(snapshot_id),
            question_id=question_id)
        if result is None:
            raise CqRefused('EXPLANATION_RESULT_NOT_FOUND', 404)
        if (result.owner_user_id != str(actor)
                or result.assessment_id != str(assessment_id)
                or result.campaign_id != str(campaign_id)
                or result.snapshot_id != str(snapshot_id)):
            raise CqRefused('EXPLANATION_RESULT_BINDING_INVALID', 409)

        registry = load_registry()
        reason = staleness_reason(
            result, source_fingerprint=str(snapshot.get('fingerprint')),
            registry_version=registry.registry_version,
            ruleset_version=str(snapshot.get('question_version')))
        if reason:
            raise CqRefused(f'EXPLANATION_RESULT_STALE:{reason}', 409)
        if result.validation_status != 'valid':
            raise CqRefused('EXPLANATION_RESULT_INVALID', 409)
        if result.admitted or result.authority != 'CANDIDATE_UNVERIFIED':
            raise CqRefused('EXPLANATION_RESULT_AUTHORITY_INVALID', 409)

        return {
            'contract_version': 'ee01-explanation-readback/1',
            'assessment_id': str(assessment_id),
            'campaign_id': str(campaign_id),
            'snapshot_id': str(snapshot_id),
            'question_id': question_id,
            'result_id': result.result_id,
            'source_fingerprint': result.source_fingerprint,
            'context_id': result.context_id,
            'registry_version': result.registry_version,
            'registry_sha256': result.registry_sha256,
            'ruleset_version': result.ruleset_version,
            'validation_status': result.validation_status,
            'validation_failures': [dict(item) for item in result.validation_failures],
            'stale_reason': result.stale_reason,
            'admission_state': readback['status'],
            'admitted': False,
            'authority': result.authority,
            'execution_kind': result.execution_kind,
            'outcome': result.outcome,
            'run_id': result.run_id,
            'attempt_no': result.attempt_no,
            'prompt_version': result.prompt_version,
            'created_at': result.created_at,
            'candidate': {
                'headline': result.headline,
                'observation_interpretation': result.observation_interpretation,
                'research_interpretation': result.research_interpretation,
                'planning_implication': result.planning_implication,
                'limitations': result.limitations,
                'summary': result.summary,
                'insufficient_evidence': result.insufficient_evidence,
                'missing_evidence_references': list(result.missing_evidence_references),
                'report_sections': list(result.report_sections),
            },
            'scientific_acceptance': False,
            'report_release_authorized': False,
        }
