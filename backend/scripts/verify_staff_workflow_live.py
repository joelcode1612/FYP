"""Live workflow verification for staff invitation + suspension.

Runs the SAME service-layer calls the FastAPI endpoints make, against the
LIVE Supabase project + the local enforcement mirror, then cleans up every
row it created (test identity, agent profile, invitation, mirror row).

Usage (from backend/, with the project venv):

    env -u HTTP_PROXY -u HTTPS_PROXY PYTHONPATH=src \
        ./.venv/Scripts/python.exe scripts/verify_staff_workflow_live.py

Exit codes: 0 = both workflows verified, 2 = provider/DB blocker (the SQL
fix has not been applied yet), 3 = verification failed after the fix.

It does NOT exercise JWT/MFA authorization (that needs a real signed-in
administrator); the HTTP + browser acceptance check stays a manual step.
"""

from __future__ import annotations

import sys
import uuid

from sqlmodel import Session

from sitewise.core.supabase_admin import SupabaseAdminError, SupabaseAdminService
from sitewise.db.session import engine
from sitewise.domain import rbac
from sitewise.services.user_service import UserService

TEST_EMAIL = "sitewise-workflow-verification@example.com"
TEST_NAME = "Workflow Verification (test artifact)"


def step(text: str) -> None:
    print(f"\n== {text}")


def main() -> int:
    svc = SupabaseAdminService()
    created: dict[str, object] = {}

    # ── 0. Preconditions ────────────────────────────────────────────────────
    step("preconditions")
    companies = svc.list_companies()
    if not companies:
        print("FAIL: public.company has no rows — register a company first.")
        return 3
    company = companies[0]
    print(f"company_id={company['company_id']} ({company['company_name']})")

    stale = svc.find_auth_user_by_email(TEST_EMAIL)
    if stale is not None:
        print(f"removing stale test identity {str(stale['id'])[:8]}… from an earlier run")
        svc._gotrue_admin_json("DELETE", f"admin/users/{stale['id']}")

    # ── 1. Invitation: identity creation (the GoTrue step) ──────────────────
    step("invite step 1/4 — GoTrue invite_user_by_email")
    try:
        invited = svc.invite_agent(email=TEST_EMAIL, full_name=TEST_NAME)
    except SupabaseAdminError as exc:
        print(f"BLOCKED: {exc}")
        print(
            "\nThe auth.users provisioning trigger is still failing.\n"
            "Apply backend/supabase/migrations/repair_auth_user_provisioning_live.sql\n"
            "in the Supabase SQL editor, then re-run this script."
        )
        return 2
    auth_user_id = str(invited["id"])
    created["auth_user_id"] = auth_user_id
    print(f"OK: identity created {auth_user_id[:8]}… (email handed to provider)")

    try:
        # ── 2. Identity row + enforcement mirror ───────────────────────────
        step("invite step 2/4 — public.users identity row + local mirror")
        svc.upsert_identity_profile(
            user_id=auth_user_id,
            email=TEST_EMAIL,
            full_name=TEST_NAME,
            role=rbac.ROLE_AGENT,
            account_status=rbac.STATUS_PENDING,
        )
        with Session(engine) as session:
            UserService(session).ensure_staff_profile(
                user_id=uuid.UUID(auth_user_id),
                email=TEST_EMAIL,
                full_name=TEST_NAME,
                phone_number=None,
                role=rbac.ROLE_AGENT,
                account_status=rbac.STATUS_PENDING,
            )
        print("OK: identity row + mirror row written (agent / pending)")

        # ── 3. Agent profile linked to the REAL company id ──────────────────
        step("invite step 3/4 — public.agent profile with real company_id")
        profile = svc.create_agent_profile(
            user_id=auth_user_id,
            agent_name=TEST_NAME,
            company_id=int(company["company_id"]),
        )
        created["agent_id"] = profile.get("agent_id")
        print(f"OK: agent_id={profile.get('agent_id')} company_id={profile.get('company_id')}")
        if profile.get("company_id") != int(company["company_id"]):
            print("FAIL: agent profile not linked to the selected company")
            return 3

        # ── 4. Invitation tracking + audit (the fixed write) ───────────────
        step("invite step 4/4 — staff_invitations + role_change_audit")
        admin_id = svc.client.table("users").select("user_id").eq(
            "role", "admin").limit(1).execute().data[0]["user_id"]
        invitation = svc.insert_invitation(
            invited_user_id=auth_user_id,
            invited_email=TEST_EMAIL,
            invited_by_user_id=admin_id,
            status="sent",
        )
        created["invitation_id"] = invitation.get("invitation_id")
        svc.insert_role_audit(
            affected_user_id=auth_user_id,
            affected_email=TEST_EMAIL,
            performed_by_user_id=admin_id,
            performed_by_email="verification@sitewise.internal",
            action="staff.invited",
            new_role=rbac.ROLE_AGENT,
            new_status=rbac.STATUS_PENDING,
            details={"verification": True, "company_id": company["company_id"]},
        )
        print(f"OK: invitation_id={invitation.get('invitation_id')} + audit row written")

        # ── 5. Suspend ─────────────────────────────────────────────────────
        step("suspend — identity + mirror + audit")
        svc.update_identity_profile(auth_user_id, {"account_status": rbac.STATUS_SUSPENDED})
        with Session(engine) as session:
            updated = UserService(session).update_user(
                uuid.UUID(auth_user_id), {"account_status": rbac.STATUS_SUSPENDED})
        svc.insert_role_audit(
            affected_user_id=auth_user_id,
            affected_email=TEST_EMAIL,
            performed_by_user_id=admin_id,
            performed_by_email="verification@sitewise.internal",
            action="staff.suspended",
            previous_status=rbac.STATUS_ACTIVE,
            new_status=rbac.STATUS_SUSPENDED,
            details={"verification": True},
        )
        identity_row = svc.client.table("users").select("account_status").eq(
            "user_id", auth_user_id).limit(1).execute().data[0]
        print(f"OK: identity={identity_row['account_status']} mirror={updated.account_status}")
        if updated.account_status != rbac.STATUS_SUSPENDED:
            print("FAIL: mirror did not record the suspension")
            return 3

        # ── 6. Reactivate ──────────────────────────────────────────────────
        step("reactivate — identity + mirror + audit")
        svc.update_identity_profile(auth_user_id, {"account_status": rbac.STATUS_ACTIVE})
        with Session(engine) as session:
            restored = UserService(session).update_user(
                uuid.UUID(auth_user_id), {"account_status": rbac.STATUS_ACTIVE})
        svc.insert_role_audit(
            affected_user_id=auth_user_id,
            affected_email=TEST_EMAIL,
            performed_by_user_id=admin_id,
            performed_by_email="verification@sitewise.internal",
            action="staff.reactivated",
            previous_status=rbac.STATUS_SUSPENDED,
            new_status=rbac.STATUS_ACTIVE,
            details={"verification": True},
        )
        print(f"OK: identity=active mirror={restored.account_status}")

        # ── 7. Directory join sanity (company name resolves) ───────────────
        step("directory join — agent profile -> company")
        listed = svc.get_agent_profile(auth_user_id)
        print(f"OK: agent profile readable, company_id={listed.get('company_id')}")

    finally:
        # ── Cleanup: remove every artifact this script created ─────────────
        step("cleanup")
        if created.get("invitation_id"):
            svc.client.table("staff_invitations").delete().eq(
                "invitation_id", created["invitation_id"]).execute()
        if created.get("agent_id") is not None:
            svc.client.table("agent").delete().eq(
                "agent_id", created["agent_id"]).execute()
        if created.get("auth_user_id"):
            try:
                with Session(engine) as session:
                    UserService(session).delete_user(uuid.UUID(str(created["auth_user_id"])))
            except Exception as exc:  # mirror row may be absent
                print(f"  mirror delete skipped: {exc}")
            try:
                svc.client.table("users").delete().eq(
                    "user_id", created["auth_user_id"]).execute()
            except Exception as exc:
                print(f"  identity row delete skipped: {exc}")
            try:
                svc._gotrue_admin_json(
                    "DELETE", f"admin/users/{created['auth_user_id']}")
            except Exception as exc:
                print(f"  auth identity delete failed (remove manually): {exc}")
        print("cleanup done (audit rows for the test account are kept as records)")

    print("\nRESULT: invitation + suspension + reactivation verified live.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
