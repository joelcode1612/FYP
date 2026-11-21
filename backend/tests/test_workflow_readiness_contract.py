"""Synthetic tests for the versioned, read-only assessment readiness contract."""
import unittest
from contextlib import contextmanager
from types import SimpleNamespace
from uuid import uuid4
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

from sitewise.core.exceptions import ConflictError
from sitewise.services.assessment_link_service import AssessmentLinkError
from sitewise.services.assessment_workflow_readiness import workflow_readiness


class ReadinessTests(unittest.TestCase):
    def setUp(self):
        self.actor = uuid4()
        self.assessment = SimpleNamespace(assessment_id=uuid4(), property_selected_at="set")
        self.m2_id = uuid4()
        self.receipt = uuid4()
        outer = self

        class Link:
            def resolve(self, **kwargs):
                assert kwargs["user_id"] == outer.actor
                assert kwargs["create_if_missing"] is False
                return SimpleNamespace(m2_assessment_id=outer.m2_id)

        class Repo:
            def latest_confirmation(self, assessment_id, actor):
                assert assessment_id == outer.m2_id and actor == outer.actor
                return {"id": outer.receipt, "assessment_revision": 7, "is_current": True}

        class M2:
            repo = Repo()

            @contextmanager
            def locked_confirmed_source(self, assessment_id, actor, *, confirmation_id, expected_revision):
                assert assessment_id == outer.m2_id and actor == outer.actor
                assert confirmation_id == outer.receipt and expected_revision == 7
                yield {"confirmation_id": confirmation_id, "assessment_revision": 7,
                       "snapshot_digest": "fixture-digest"}

        self.link, self.m2 = Link(), M2()

    def run_read(self):
        return workflow_readiness(self.assessment, self.actor, "test@example.invalid", self.link, self.m2)

    def test_current_confirmation_enables_stage_three_without_downstream_completion(self):
        result = self.run_read()
        self.assertTrue(result["stage_2"]["complete"])
        self.assertTrue(result["stage_3"]["enterable"])
        self.assertFalse(result["stage_3"]["complete"])
        self.assertFalse(result["stage_4"]["complete"])
        self.assertFalse(result["stage_5"]["complete"])
        self.assertTrue(result["stage_5"]["preview_enterable"])
        self.assertEqual(result["stage_2"]["assessment_revision"], 7)

    def test_unlinked_and_stale_confirmation_fail_closed(self):
        self.link.resolve = lambda **kw: (_ for _ in ()).throw(AssessmentLinkError("ASSESSMENT_NOT_LINKED", "missing", 404))
        unlinked = self.run_read()
        self.assertFalse(unlinked["stage_3"]["enterable"])
        self.assertTrue(unlinked["stage_5"]["preview_enterable"])
        self.assertFalse(unlinked["stage_5"]["complete"])
        self.setUp()
        self.m2.repo.latest_confirmation = lambda *args: {"is_current": False}
        self.assertEqual(self.run_read()["stage_2"]["reason"], "CURRENT_CONFIRMATION_REQUIRED")

    def test_invalid_provenance_fails_closed(self):
        @contextmanager
        def invalid(*args, **kwargs):
            raise ConflictError("stale")
            yield
        self.m2.locked_confirmed_source = invalid
        self.assertEqual(self.run_read()["stage_2"]["reason"], "CONFIRMATION_STALE_OR_INVALID")
        self.assertFalse(self.run_read()["stage_3"]["enterable"])

    def test_foreign_owner_refusal_is_not_swallowed(self):
        self.link.resolve = lambda **kw: (_ for _ in ()).throw(AssessmentLinkError("ASSESSMENT_NOT_OWNED", "forbidden", 403))
        with self.assertRaises(AssessmentLinkError):
            self.run_read()

    def test_stage_one_still_required(self):
        self.assessment.property_selected_at = None
        self.assertFalse(self.run_read()["stage_3"]["enterable"])

    def test_authenticated_http_route_uses_owned_assessment(self):
        from sitewise.api.v1 import assessments
        app = FastAPI()
        app.include_router(assessments.router, prefix="/assessments")
        app.dependency_overrides[assessments.get_db] = lambda: object()
        app.dependency_overrides[assessments.get_analytics_db] = lambda: object()
        app.dependency_overrides[assessments.require_entrepreneur] = lambda: SimpleNamespace(
            user_id=self.actor, email="test@example.invalid")
        app.dependency_overrides[assessments.get_assessment_link_service] = lambda: self.link
        app.dependency_overrides[assessments.get_m2_service] = lambda: self.m2
        service = SimpleNamespace(get_owned=lambda aid, owner: self.assessment
                                  if aid == self.assessment.assessment_id and owner == self.actor
                                  else None)
        with patch.object(assessments, "_service", return_value=service):
            response = TestClient(app).get(f"/assessments/{self.assessment.assessment_id}/workflow-readiness")
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.headers["cache-control"], "private, no-store")
        self.assertTrue(response.json()["stage_3"]["enterable"])

    def test_preview_http_exposes_only_bound_unavailable_state(self):
        from sitewise.api.v1 import assessments
        app = FastAPI()
        app.include_router(assessments.router, prefix="/assessments")
        app.dependency_overrides[assessments.get_db] = lambda: object()
        app.dependency_overrides[assessments.get_analytics_db] = lambda: object()
        app.dependency_overrides[assessments.require_entrepreneur] = lambda: SimpleNamespace(
            user_id=self.actor, email="test@example.invalid")
        app.dependency_overrides[assessments.get_assessment_link_service] = lambda: self.link
        app.dependency_overrides[assessments.get_m2_service] = lambda: self.m2
        service = SimpleNamespace(get_owned=lambda aid, owner: self.assessment)
        with patch.object(assessments, "_service", return_value=service):
            response = TestClient(app).get(f"/assessments/{self.assessment.assessment_id}/questionnaire-preview")
        self.assertEqual(response.status_code, 200, response.text)
        result = response.json()
        self.assertEqual(result['marketplace_assessment_id'], str(self.assessment.assessment_id))
        self.assertEqual(result['m2_assessment_id'], str(self.m2_id))
        self.assertEqual(result['confirmation_id'], str(self.receipt))
        self.assertEqual(result['assessment_revision'], 7)
        self.assertEqual(result['status'], 'UNAVAILABLE')
        self.assertEqual(result['question_items'], [])
        self.assertFalse(result['fielding_authorized'])
        self.assertFalse(result['publication_authorized'])

    def test_preview_refuses_cross_owner_before_link_read(self):
        from fastapi import HTTPException
        from sitewise.api.v1 import assessments
        app = FastAPI()
        app.include_router(assessments.router, prefix="/assessments")
        app.dependency_overrides[assessments.get_db] = lambda: object()
        app.dependency_overrides[assessments.get_analytics_db] = lambda: object()
        app.dependency_overrides[assessments.require_entrepreneur] = lambda: SimpleNamespace(
            user_id=self.actor, email="test@example.invalid")
        def forbidden(**kwargs):
            raise AssertionError('foreign assessment must not resolve a link')
        self.link.resolve = forbidden
        app.dependency_overrides[assessments.get_assessment_link_service] = lambda: self.link
        app.dependency_overrides[assessments.get_m2_service] = lambda: self.m2
        def refuse(aid, owner):
            raise HTTPException(status_code=404, detail='Assessment not found')
        with patch.object(assessments, "_service", return_value=SimpleNamespace(get_owned=refuse)):
            response = TestClient(app).get(f"/assessments/{uuid4()}/questionnaire-preview")
        self.assertEqual(response.status_code, 404)


if __name__ == "__main__":
    unittest.main()
