"""D27b — server-side fail-closed stale-display fixture.

CRITICAL / bound to FLUTTER_API_PASS. NEW FILE ONLY: the existing
`tests/candidate/test_customer_candidate.py` is imported read-only for its
fixture helper; it is NOT edited.

Precision note: stale `expected_revision` and idempotency are ALREADY covered at
`test_customer_candidate.py`:220-233; S counts at :253-260; stale Q08 in the
handoff oracle at `test_router.py`:212. The genuinely new branch here is a
replayed `display_id` with a VALID `expected_revision` but a mismatched
`context_digest` (`customer_questionnaire_candidate.py`:286-289).
"""

import importlib.util
import unittest
from pathlib import Path
from uuid import uuid4

from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from sitewise.services.customer_questionnaire_candidate import CustomerCandidateService

_EXISTING = (
    Path(__file__).resolve().parents[1] / "candidate" / "test_customer_candidate.py"
)
_spec = importlib.util.spec_from_file_location("_existing_candidate_tests", _EXISTING)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
fixture_asset = _mod.fixture_asset


class D27ServerFailClosedTests(unittest.TestCase):
    def setUp(self):
        self.engine = create_engine(
            "sqlite:///:memory:",
            poolclass=StaticPool,
            connect_args={"check_same_thread": False},
        )
        self.assets = {
            k: fixture_asset(k)
            for k in ("concept", "menu", "offer", "occasion", "features")
        }
        self.svc = CustomerCandidateService(self.engine, assets=self.assets)

    def tearDown(self):
        self.engine.dispose()

    def ready(self):
        sid = "SYN-" + str(uuid4())
        self.svc.create(
            sid, qualification="ACCEPTED_SYNTHETIC",
            asset_ids={k: k for k in self.assets},
        )
        self.answer(sid, "Q01", ["LIVE"])
        rev = self.svc.route(sid)["revision"]
        self.svc.expose(sid, "concept", expected_revision=rev)
        return sid

    def answer(self, sid, q, value, feature=""):
        rev = self.svc.route(sid)["revision"]
        display = self.svc.show(sid, q, expected_revision=rev, feature=feature)
        return self.svc.answer(
            sid, q, value, expected_revision=rev,
            request_id=str(uuid4()), display_id=display["id"], feature=feature,
        )

    def test_d27b_01_replayed_display_with_valid_revision_but_stale_digest_rejected(self):
        """The genuinely untested branch: valid expected_revision, stale digest."""
        sid = self.ready()
        rev = self.svc.route(sid)["revision"]
        display = self.svc.show(sid, "Q05", expected_revision=rev)
        display_id = display["id"]
        digest_before = display.get("context_digest")

        # Change Q01 so downstream context/route changes without deleting history.
        self.answer(sid, "Q01", ["RARELY"])
        rev2 = self.svc.route(sid)["revision"]

        # Replay the OLD display_id with a NEW request_id (so rejection is not
        # attributable to idempotency) and a VALID expected_revision.
        with self.assertRaisesRegex(ValueError, "Current authorized synthetic display is required"):
            self.svc.answer(
                sid, "Q05", "DEF_YES",
                expected_revision=rev2,
                request_id=str(uuid4()),
                display_id=display_id,
            )
        self.assertIsNotNone(digest_before)

    def test_d27b_02_stale_revision_rejected(self):
        sid = self.ready()
        rev = self.svc.route(sid)["revision"]
        display = self.svc.show(sid, "Q05", expected_revision=rev)
        with self.assertRaisesRegex(ValueError, "Stale session revision"):
            self.svc.answer(
                sid, "Q05", "DEF_YES",
                expected_revision=rev + 5,
                request_id=str(uuid4()),
                display_id=display["id"],
            )

    def test_d27b_03_show_on_withheld_item_rejected(self):
        sid = self.ready()
        self.answer(sid, "Q04", ["ZERO"])
        rev = self.svc.route(sid)["revision"]
        with self.assertRaisesRegex(ValueError, "Item withheld"):
            self.svc.show(sid, "Q08", expected_revision=rev)

    def test_d27b_04_withheld_item_counts_not_shown(self):
        sid = self.ready()
        self.answer(sid, "Q04", ["ZERO"])
        counts = self.svc.counts(sid, "Q08")
        self.assertEqual(counts["S"], 0)
        self.assertEqual(counts["A"], 0)
        self.assertEqual(counts["V"], 0)
        self.assertEqual(counts["not_shown"], 1)
        self.assertEqual(counts["estimate_status"], "NOT_ESTIMABLE")

    def test_d27b_05_no_ghost_event_on_rejection(self):
        sid = self.ready()
        before = len(self.svc.history(sid))
        rev = self.svc.route(sid)["revision"]
        with self.assertRaises(ValueError):
            self.svc.answer(
                sid, "Q05", "DEF_YES", expected_revision=rev + 3,
                request_id=str(uuid4()), display_id="DOES-NOT-EXIST",
            )
        self.assertEqual(len(self.svc.history(sid)), before)

    def test_d27b_06_reused_request_id_with_different_body_rejected(self):
        sid = self.ready()
        rev = self.svc.route(sid)["revision"]
        display = self.svc.show(sid, "Q05", expected_revision=rev)
        rid = str(uuid4())
        self.svc.answer(
            sid, "Q05", "DEF_YES", expected_revision=rev,
            request_id=rid, display_id=display["id"],
        )
        rev2 = self.svc.route(sid)["revision"]
        display2 = self.svc.show(sid, "Q06", expected_revision=rev2)
        with self.assertRaisesRegex(ValueError, "Idempotency request reused with different input"):
            self.svc.answer(
                sid, "Q06", "COFFEE", expected_revision=rev2,
                request_id=rid, display_id=display2["id"],
            )


if __name__ == "__main__":
    unittest.main()
