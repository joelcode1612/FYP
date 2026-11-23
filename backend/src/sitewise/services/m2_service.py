"""Database-backed M2 draft use cases; no hardcoded questionnaire seeding."""
import hashlib
import json
from contextlib import contextmanager
from uuid import UUID

from sitewise.core.exceptions import ConflictError, NotFoundError
from sitewise.modules.decision_engine.domain.m2_rules import validate_m2_answer, resolve_m2_items, derived_m2_selections
from sitewise.domain.m2_provenance import pins_match
from sitewise.services.instrument_authorization import instrument_is_usable
from sitewise.services.ports.m2_repository_port import M2RepositoryPort


class M2Service:
    def __init__(self, repository: M2RepositoryPort):
        self.repo = repository

    def list_instruments(self,limit=50,offset=0):
        return {'contract_version':'m2-instrument-list/1','items':self.repo.list_authorized_instruments(limit,offset),
            'limit':limit,'offset':offset}

    def list_assessments(self,actor_id,limit=50,offset=0):
        return {'contract_version':'m2-assessment-list/1','items':self.repo.list_owned_assessments(actor_id,limit,offset),
            'limit':limit,'offset':offset}

    def activity(self,assessment_id,actor_id,limit=50):
        from datetime import timezone
        try:
            a=self.repo.get_assessment_for_update(assessment_id,actor_id)
            if a is None:raise NotFoundError('Assessment not found.')
            events=self.repo.read_activity(assessment_id,actor_id,a['revision'],limit)
            extra=self.repo.read_activity_supplement(assessment_id,actor_id,a['revision'],limit)
            events += extra['events']
            modules={'BDJ_EVALUATED':'BDJ','REVIEW_RECORDED':'Business Understanding',
                     'CONTEXT_CONFIRMED':'Business Understanding',
                     'CLARIFICATION_RECORDED':'Business Understanding'}
            unique={}
            for e in events:
                at=e['occurred_at']
                e['occurred_at']=at.replace(tzinfo=timezone.utc) if at.tzinfo is None else at.astimezone(timezone.utc)
                e.setdefault('module',modules.get(e['kind'],'M2'))
                e['source_is_current']=e.get('source_is_current',e['assessment_revision']==a['revision'])
                # Namespaced identity prevents UUID collision across source tables.
                unique[(e['kind'],str(e['event_id']))]=e
            events=sorted(unique.values(),key=lambda e:(e['occurred_at'],e['kind'],str(e['event_id'])),reverse=True)
            return {'contract_version':'m2-activity/1','assessment_id':assessment_id,'assessment_revision':a['revision'],
                'scope':'PERSISTED_M2_ACTIVITY','events':events[:limit],'truncated':len(events)>limit,
                'history_extension':'workflow-history-metadata/2',
                'bcb_statuses':extra['bcb_statuses'],
                'bcb_statuses_truncated':extra['bcb_statuses_truncated'],
                'bcb_history_available':extra['bcb_available'],
                'authorization_decisions_included':False}
        finally:
            self.repo.rollback()

    def read_instrument(self, instrument_id: UUID) -> dict:
        instrument = self.repo.get_instrument(instrument_id)
        if not instrument_is_usable(instrument):
            raise NotFoundError("Authorized instrument version not found.")
        return {"instrument": instrument, "items": self.repo.list_items(instrument_id)}

    def create_assessment(self, instrument_id: UUID, actor_id: UUID) -> dict:
        instrument = self.repo.get_instrument(instrument_id)
        if not instrument_is_usable(instrument):
            raise ConflictError("No authorized M2 instrument version is available.")
        try:
            result = self.repo.create_assessment(instrument_id, actor_id)
            self.repo.commit()
            return result
        except Exception:
            self.repo.rollback()
            raise

    def read_assessment(self, assessment_id: UUID, actor_id: UUID) -> dict:
        assessment = self.repo.get_assessment(assessment_id, actor_id)
        if assessment is None:
            raise NotFoundError("Assessment not found.")
        items = self.repo.list_items(assessment["instrument_id"])
        answers = self.repo.get_latest_answers(assessment_id, assessment["revision"])
        return {"assessment": assessment, "instrument":self.repo.get_instrument(assessment['instrument_id']), "items": resolve_m2_items(items, answers), "answers": answers,
                "derived_selections": derived_m2_selections(items, answers),
                "current_review_completed": self.repo.get_review(assessment_id, assessment["revision"]) is not None,
                "current_confirmation_valid": assessment["confirmed_revision"] == assessment["revision"]}

    def read_confirmed_source(self, assessment_id: UUID, actor_id: UUID, *,
                              confirmation_id: UUID, expected_revision: int) -> dict:
        with self.locked_confirmed_source(assessment_id, actor_id,
                confirmation_id=confirmation_id, expected_revision=expected_revision) as source:
            return source

    @contextmanager
    def locked_confirmed_source(self, assessment_id: UUID, actor_id: UUID, *,
                                confirmation_id: UUID, expected_revision: int):
        """Retrieve persisted source facts, without granting downstream authority.

        Hold the existing assessment lock through all reads so an answer edit
        cannot race the currentness check. Release it even on invalid input.
        This is not a new confirmation or a Business Context Builder packet.
        """
        try:
            assessment = self.repo.get_assessment_for_update(assessment_id, actor_id)
            if assessment is None:
                raise NotFoundError("Assessment not found.")
            if (assessment["revision"] != expected_revision or
                    assessment["confirmed_revision"] != expected_revision):
                raise ConflictError("Confirm the current M2 revision before continuing.")
            record = self.repo.get_confirmation(confirmation_id, actor_id)
            if record is None or record["assessment_id"] != assessment_id:
                raise NotFoundError("Confirmation snapshot not found.")
            if (record["actor_user_id"] != actor_id or
                    record["assessment_revision"] != expected_revision):
                raise ConflictError("Confirmation source does not match the current owner and revision.")
            instrument = self.repo.get_instrument(assessment["instrument_id"])
            if not instrument_is_usable(instrument):
                raise ConflictError("An authorized instrument version is required.")
            snapshot = record["snapshot_json"]
            if not isinstance(snapshot, dict):
                raise ConflictError("Confirmation source integrity check failed.")
            digest = hashlib.sha256(json.dumps(
                snapshot, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
            ).encode("utf-8")).hexdigest()
            answers = self.repo.get_latest_answers(assessment_id, expected_revision)
            expected_answers = [
                {"item_key": key, "answer_revision_id": str(a["id"]),
                 "item_version_id": str(a["item_version_id"]),
                 "answer_state": a["answer_state"], "value": a["value_json"]}
                for key, a in sorted(answers.items())
            ]
            if (digest != record["snapshot_digest"] or
                    snapshot.get("assessment_id") != str(assessment_id) or
                    snapshot.get("assessment_revision") != expected_revision or
                    snapshot.get("instrument_id") != str(instrument["id"]) or
                    snapshot.get("instrument_version") != instrument["version_tag"] or
                    snapshot.get("instrument_digest") != instrument["schema_digest"] or
                    snapshot.get("answer_revisions") != expected_answers):
                raise ConflictError("Confirmation source integrity check failed.")
            if 'snapshot_contract_version' in snapshot:
                version = snapshot.get('bdj_rule_version')
                findings = [f for f in self.repo.get_findings(assessment_id,expected_revision)
                            if f['rule_version']==version]
                if not pins_match(snapshot,
                        self.repo.get_evaluation(assessment_id,expected_revision,version),
                        self.repo.get_review(assessment_id,expected_revision),findings,
                        self.repo.list_items(assessment['instrument_id'])):
                    raise ConflictError('Confirmation provenance has changed.')
            yield {
                "assessment_id": assessment_id, "confirmation_id": record["id"],
                "assessment_revision": expected_revision,
                "snapshot_digest": digest, "snapshot": snapshot,
                "trust_class": "T2_AUTHENTICATED_ENTREPRENEUR_DECLARATION",
                "source_status": "CURRENT_CONFIRMED_SOURCE",
                "qj_handoff_authorized": False,
            }
        finally:
            # This use case performs no writes and never commits auth/source data.
            self.repo.rollback()

    def update_answer(self, assessment_id: UUID, actor_id: UUID, *, expected_revision: int,
                      item_key: str, state: str, value: object,
                      marketplace_assessment_id: UUID | None = None) -> dict:
        # Owner-scoped row lock prevents an edit racing a confirmation or
        # clarification decision in PostgreSQL. The CAS remains authoritative.
        try:
            assessment = self.repo.get_assessment_for_update(assessment_id, actor_id)
            if assessment is None:
                raise NotFoundError("Assessment not found.")
            if marketplace_assessment_id is not None and not self.repo.lock_active_marketplace_binding(
                    assessment_id, actor_id, marketplace_assessment_id):
                raise ConflictError('The linked assessment changed; reload before saving.')
            if assessment["revision"] != expected_revision:
                raise ConflictError("Assessment revision is stale; reload before saving.")
            instrument = self.repo.get_instrument(assessment['instrument_id'])
            if not instrument_is_usable(instrument):
                raise ConflictError('An authorized instrument version is required.')
            item = self.repo.get_item(assessment["instrument_id"], item_key)
            if item is None:
                raise NotFoundError("Item not found for this instrument version.")
            current_answers = self.repo.get_latest_answers(assessment_id, expected_revision)
            item = next(q for q in resolve_m2_items(
                self.repo.list_items(assessment['instrument_id']), current_answers) if q['item_key'] == item_key)
            validate_m2_answer(item, state, value)
            if not self.repo.bump_revision(assessment_id, expected_revision):
                raise ConflictError("Assessment revision is stale; reload before saving.")
            answer = self.repo.save_answer(assessment_id, item["id"], expected_revision + 1, state, value)
            self.repo.commit()
            return {"assessment_revision": expected_revision + 1, "answer": answer,
                    "current_review_required": True,
                    "previous_confirmation_is_historical": assessment["confirmed_revision"] is not None}
        except Exception:
            self.repo.rollback()
            raise
