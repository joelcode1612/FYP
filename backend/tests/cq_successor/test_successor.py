"""Synthetic-only successor route-preview tests. Author run, not independent verification."""

import unittest

from fastapi.testclient import TestClient

from sitewise.cq_successor.app import allowed_app, create_successor_app
from sitewise.cq_successor.contracts import (
    CONCEPT_VERSION,
    INSTRUMENT_VERSION,
    M2_CONTEXT_VERSION,
    Q01_SUCCESSOR_NO_CONNECTION,
    QUESTION_BANK_VERSION,
    ROUTING_POLICY_VERSION,
    QUESTION_IDS,
    ConsentSnapshot,
    Principal,
    StaticConsentPort,
    StaticPrincipalPort,
)
from sitewise.cq_successor.policy import SyntheticAuthority, classify_q01


BASE = {
    "assessment_id": "SYN-ASSESSMENT",
    "tenant_id": "SYN-TENANT",
    "q01_codes": ["LIVE"],
    "q02_code": "DAYS_1_3",
    "q04_code": "ONE",
}


def body(**changes):
    return {**BASE, **changes}


def permissions(result):
    return {p["item_id"]: (p["state"], p["reason"]) for p in result["preview_permissions"]}


class SuccessorPolicyTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(allowed_app())

    def post(self, payload):
        return self.client.post(
            "/api/v1/customer/questionnaires/SYN-ASSESSMENT/route-preview",
            json=payload,
        )

    def ok(self, payload):
        r = self.post(payload)
        self.assertEqual(r.status_code, 200, r.text)
        return r.json()

    # --- common invariants ------------------------------------------------
    def assert_no_authority(self, result):
        self.assertEqual(result["mode"], "SYNTHETIC_ONLY")
        self.assertFalse(result["production_fielding_authorized"])
        self.assertFalse(result["report_release_authorized"])
        self.assertFalse(result["actual_display_logged"])

    def test_01_all_thirteen_ids_preserved(self):
        result = self.ok(body())
        self.assertEqual(tuple(p["item_id"] for p in result["preview_permissions"]), QUESTION_IDS)
        self.assert_no_authority(result)

    # --- D02 ∧ D08 P0 composite -------------------------------------------
    def test_02_d02_and_d08_composite_no_connection_zero_days_zero_purchases(self):
        """CRITICAL: NO_CURRENT_CONNECTION + Q02 NONE + Q04 ZERO.

        Q08 must be NOT_SHOWN, Q05 must remain eligible with an approved
        synthetic concept, and the route must NOT screen out.
        """
        result = self.ok(body(
            q01_codes=[Q01_SUCCESSOR_NO_CONNECTION],
            q02_code="NONE",
            q04_code="ZERO",
        ))
        p = permissions(result)
        self.assertEqual(result["connection_group"], "NO_CURRENT_CONNECTION")
        self.assertNotIn(result["route_state"], ("SCREENED_OUT", "WITHDRAWN"))
        self.assertEqual(result["route_state"], "IN_PROGRESS")
        self.assertEqual(p["Q08"], ("NOT_SHOWN", "Q04_NOT_SUBSTANTIVE_NONZERO"))
        self.assertEqual(p["Q05"][0], "ELIGIBLE_TO_SHOW")
        self.assertEqual(p["Q02"][0], "ELIGIBLE_TO_SHOW")  # zero days is not a threshold
        self.assertEqual(p["Q01"][0], "ELIGIBLE_TO_SHOW")
        self.assert_no_authority(result)

    def test_03_historical_current_connection_still_works(self):
        result = self.ok(body(q01_codes=["WORK"], q02_code="DAYS_1_3", q04_code="ONE"))
        self.assertEqual(result["connection_group"], "CURRENT_CONNECTION")
        self.assertEqual(permissions(result)["Q08"][0], "ELIGIBLE_TO_SHOW")
        self.assert_no_authority(result)

    # --- Q01 classification ------------------------------------------------
    def test_04_live_plus_never_invalid(self):
        self.assertEqual(classify_q01(("LIVE", "NEVER")), "INVALID_CONFLICT")
        result = self.ok(body(q01_codes=["LIVE", "NEVER"]))
        self.assertEqual(result["route_state"], "VALIDATION_REQUIRED")
        self.assertEqual(permissions(result)["Q03"][0], "BLOCKED")
        self.assert_no_authority(result)

    def test_05_duplicate_q01_invalid(self):
        self.assertEqual(classify_q01(("LIVE", "LIVE")), "INVALID_DUPLICATE")

    def test_06_legacy_codes_never_recoded(self):
        self.assertEqual(classify_q01(("RARELY",)), "HISTORICAL_AMBIGUOUS")
        self.assertEqual(classify_q01(("NEVER",)), "HISTORICAL_AMBIGUOUS")
        self.assertEqual(classify_q01(("NOT_SURE",)), "HISTORICAL_AMBIGUOUS")
        self.assertIn("HISTORICAL_AMBIGUOUS", classify_q01(("NEVER",)))

    def test_07_unknown_q01_code_rejected(self):
        self.assertEqual(classify_q01(("MADE_UP",)), "INVALID_CODE")
        result = self.ok(body(q01_codes=["MADE_UP"]))
        self.assertEqual(result["route_state"], "VALIDATION_REQUIRED")
        self.assert_no_authority(result)

    # --- Q02 / Q04 / Q05 ---------------------------------------------------
    def test_08_q02_zero_days_never_terminates(self):
        result = self.ok(body(q02_code="NONE"))
        self.assertNotIn(result["route_state"], ("SCREENED_OUT", "WITHDRAWN"))
        self.assertEqual(permissions(result)["Q04"][0], "ELIGIBLE_TO_SHOW")
        self.assert_no_authority(result)

    def test_09_q04_cannot_remember_withholds_q08_only(self):
        result = self.ok(body(q04_code="CANNOT_REMEMBER"))
        p = permissions(result)
        self.assertEqual(p["Q08"], ("NOT_SHOWN", "Q04_NOT_SUBSTANTIVE_NONZERO"))
        self.assertEqual(p["Q05"][0], "ELIGIBLE_TO_SHOW")
        self.assertEqual(p["Q04"][0], "ELIGIBLE_TO_SHOW")
        self.assert_no_authority(result)

    def test_10_negative_q05_is_not_a_route_exit(self):
        negative = self.ok(body(q05_code="DEF_NO"))
        positive = self.ok(body(q05_code="DEF_YES"))
        self.assertEqual(permissions(negative), permissions(positive))
        self.assert_no_authority(negative)

    def test_11_q02_invalid_code_rejected(self):
        result = self.ok(body(q02_code="NOT_A_CODE"))
        self.assertEqual(result["route_state"], "VALIDATION_REQUIRED")
        self.assertEqual(permissions(result)["Q01"][1], "INVALID_Q02_CODE")
        self.assert_no_authority(result)

    # --- scientific gates --------------------------------------------------
    def test_12_q09_q10_always_withheld(self):
        result = self.ok(body())
        p = permissions(result)
        self.assertEqual(p["Q09"], ("NOT_SHOWN", "SCIENTIFIC_GATE_UNAPPROVED"))
        self.assertEqual(p["Q10"], ("NOT_SHOWN", "SCIENTIFIC_GATE_UNAPPROVED"))
        self.assertEqual(result["q10_feature_ids"], [])
        self.assert_no_authority(result)

    def test_13_q13_needs_price_reference_item(self):
        result = self.ok(body())
        self.assertEqual(permissions(result)["Q13"][0], "NOT_SHOWN")
        self.assert_no_authority(result)

    def test_14_not_shown_distinct_from_refused(self):
        result = self.ok(body(q04_code="ZERO"))
        p = permissions(result)
        self.assertEqual(p["Q08"][0], "NOT_SHOWN")
        self.assertNotIn(p["Q08"][0], ("REFUSED", "INVALID", "NO"))
        self.assertNotIn("REFUSED", p["Q08"][1])
        self.assert_no_authority(result)

    # --- version / authority fail-closed -----------------------------------
    def test_15_version_mismatch_blocked(self):
        for field in (
            "instrument_version", "routing_policy_version", "question_bank_version",
            "concept_version", "m2_context_version",
        ):
            with self.subTest(field=field):
                result = self.ok(body(**{field: "STALE-V0"}))
                self.assertEqual(result["route_state"], "BLOCKED")
                self.assertEqual(permissions(result)["Q01"][1], f"VERSION_MISMATCH:{field}")
                self.assert_no_authority(result)

    def test_16_stale_revision_blocked(self):
        result = self.ok(body(expected_revision=99))
        self.assertEqual(result["route_state"], "BLOCKED")
        self.assertEqual(permissions(result)["Q01"][1], "STALE_REVISION")
        self.assert_no_authority(result)

    def test_17_unauthenticated_denied(self):
        client = TestClient(create_successor_app())  # default ports DENY
        r = client.post(
            "/api/v1/customer/questionnaires/SYN-ASSESSMENT/route-preview", json=body()
        )
        self.assertEqual(r.status_code, 200)
        result = r.json()
        self.assertEqual(result["route_state"], "HELD_UNAUTHORIZED")
        self.assertEqual(permissions(result)["Q01"][1], "UNAUTHORIZED")
        self.assert_no_authority(result)

    def test_18_cross_tenant_denied(self):
        client = TestClient(allowed_app(tenant_id="OTHER-TENANT"))
        result = client.post(
            "/api/v1/customer/questionnaires/SYN-ASSESSMENT/route-preview", json=body()
        ).json()
        self.assertEqual(result["route_state"], "HELD_UNAUTHORIZED")
        self.assertEqual(permissions(result)["Q01"][1], "CROSS_TENANT_DENIED")
        self.assert_no_authority(result)

    def test_19_consent_missing_and_withdrawal(self):
        from sitewise.cq_successor.app import create_successor_app
        good_principal = StaticPrincipalPort(
            Principal("SYN-ACTOR", "SYN-TENANT", True, ("RESEARCHER",), "JOHOR")
        )
        no_consent = TestClient(create_successor_app(principal_port=good_principal))
        r = no_consent.post(
            "/api/v1/customer/questionnaires/SYN-ASSESSMENT/route-preview", json=body()
        ).json()
        self.assertEqual(permissions(r)["Q01"][1], "CONSENT_REQUIRED")

        withdrawn = TestClient(create_successor_app(
            principal_port=good_principal,
            consent_port=StaticConsentPort(ConsentSnapshot(True, True, "SYN-CONSENT-V1")),
        ))
        w = withdrawn.post(
            "/api/v1/customer/questionnaires/SYN-ASSESSMENT/route-preview", json=body()
        ).json()
        self.assertEqual(w["route_state"], "WITHDRAWN")
        self.assertEqual(permissions(w)["Q01"][0], "NOT_SHOWN")
        self.assert_no_authority(r)
        self.assert_no_authority(w)

    def test_20_unsupported_jurisdiction(self):
        from sitewise.cq_successor.app import create_successor_app
        client = TestClient(create_successor_app(
            principal_port=StaticPrincipalPort(
                Principal("SYN-ACTOR", "SYN-TENANT", True, ("RESEARCHER",), "MARS")
            ),
            consent_port=StaticConsentPort(ConsentSnapshot(True, False, "SYN-CONSENT-V1")),
        ))
        result = client.post(
            "/api/v1/customer/questionnaires/SYN-ASSESSMENT/route-preview", json=body()
        ).json()
        self.assertEqual(permissions(result)["Q01"][1], "UNSUPPORTED_JURISDICTION")
        self.assert_no_authority(result)

    # --- authority-leak prevention -----------------------------------------
    def test_21_authority_booleans_rejected_with_422(self):
        for field, value in (
            ("viewer_authorized", True), ("consented", True), ("withdrawn", False),
            ("completed_ids", ["Q01"]), ("concept_approved", True),
            ("production_fielding_authorized", True),
        ):
            with self.subTest(field=field):
                r = self.post(body(**{field: value}))
                self.assertEqual(r.status_code, 422, r.text)

    def test_22_unknown_field_rejected(self):
        r = self.post(body(unexpected_field="x"))
        self.assertEqual(r.status_code, 422)

    # --- idempotency ---------------------------------------------------------
    def test_23_route_preview_is_idempotent(self):
        first = self.ok(body())
        second = self.client.get(
            "/api/v1/customer/questionnaires/SYN-ASSESSMENT/route-preview"
        ).json()
        self.assertEqual(first, second)
        self.assertEqual(first["packet_digest"], second["packet_digest"])
        self.assert_no_authority(first)

    def test_24_get_without_post_is_404(self):
        fresh = TestClient(allowed_app())
        r = fresh.get("/api/v1/customer/questionnaires/NEVER-SEEN/route-preview")
        self.assertEqual(r.status_code, 404)

    def test_25_health_declares_unregistered(self):
        h = TestClient(allowed_app()).get("/health").json()
        self.assertEqual(h["mode"], "SYNTHETIC_ONLY")
        self.assertFalse(h["registered_in_live_app"])
        self.assertFalse(h["production_fielding_authorized"])

    def test_26_no_connection_without_approved_concept_still_continues(self):
        from sitewise.cq_successor.app import create_successor_app
        client = TestClient(create_successor_app(
            principal_port=StaticPrincipalPort(
                Principal("SYN-ACTOR", "SYN-TENANT", True, ("RESEARCHER",), "JOHOR")
            ),
            consent_port=StaticConsentPort(ConsentSnapshot(True, False, "SYN-CONSENT-V1")),
            authority=SyntheticAuthority(approved_concept_stimulus=False, concept_exposed=False),
        ))
        result = client.post(
            "/api/v1/customer/questionnaires/SYN-ASSESSMENT/route-preview",
            json=body(q01_codes=[Q01_SUCCESSOR_NO_CONNECTION], q02_code="NONE", q04_code="ZERO"),
        ).json()
        p = permissions(result)
        self.assertEqual(result["connection_group"], "NO_CURRENT_CONNECTION")
        self.assertNotEqual(result["route_state"], "SCREENED_OUT")
        self.assertEqual(p["Q05"][0], "NOT_SHOWN")
        self.assertEqual(p["Q08"], ("NOT_SHOWN", "Q04_NOT_SUBSTANTIVE_NONZERO"))
        self.assert_no_authority(result)


if __name__ == "__main__":
    unittest.main()
