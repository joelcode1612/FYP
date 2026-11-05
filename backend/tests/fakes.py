"""Hermetic fakes for Supabase admin operations.

Strategy (matching ``conftest.py``): Supabase is NEVER contacted in tests.
The staff router resolves its admin adapter through
``sitewise.api.v1.staff._admin_service``, which the tests monkeypatch to
return a :class:`FakeSupabaseAdmin`. The fake records every privileged write
(invites, identity upserts, invitations, audit rows) so tests can assert the
exact side effects the real adapter must produce.
"""

from __future__ import annotations

import uuid


class FakeSupabaseAdmin:
    """In-memory stand-in for :class:`SupabaseAdminService`."""

    def __init__(self):
        self.auth_users: dict[str, dict] = {}  # email -> {id, email}
        self.identity: dict[str, dict] = {}  # user_id -> public.users row
        self.invitations: list[dict] = []
        self.audit: list[dict] = []
        self.agents: list[dict] = []
        self.listings: dict[int, dict] = {}
        self.verifications: list[dict] = []
        self.companies: dict[str, int] = {}
        self.removed_factors: list[tuple[str, str]] = []
        self.factors: dict[str, list[dict]] = {}  # auth_user_id -> factors
        self.invite_calls: list[str] = []
        self._next_agent_id = 1
        self._next_company_id = 1

    # -- auth (GoTrue) ------------------------------------------------------

    def find_auth_user_by_email(self, email: str) -> dict | None:
        user = self.auth_users.get(email.lower())
        return dict(user) if user else None

    def invite_agent(self, *, email: str, full_name: str, phone_number: str | None = None) -> dict:
        uid = str(uuid.uuid4())
        self.auth_users[email.lower()] = {"id": uid, "email": email.lower()}
        self.invite_calls.append(email.lower())
        return {"id": uid, "email": email.lower()}

    def admin_list_factors(self, auth_user_id: str) -> list[dict]:
        return list(self.factors.get(auth_user_id, []))

    def admin_delete_factor(self, auth_user_id: str, factor_id: str) -> None:
        self.removed_factors.append((auth_user_id, factor_id))
        self.factors[auth_user_id] = [
            f for f in self.factors.get(auth_user_id, []) if f.get("id") != factor_id
        ]

    # -- identity rows (public.users) ----------------------------------------

    def upsert_identity_profile(
        self,
        *,
        user_id,
        email: str,
        full_name: str | None = None,
        phone_number: str | None = None,
        role: str,
        account_status: str,
    ) -> dict:
        row = {"user_id": str(user_id), "email": email, "role": role,
               "account_status": account_status}
        self.identity[str(user_id)] = row
        return dict(row)

    def update_identity_profile(self, user_id, data: dict) -> None:
        self.identity.setdefault(str(user_id), {"user_id": str(user_id)}).update(data)

    # -- invitations + audit --------------------------------------------------

    def insert_invitation(self, *, invited_user_id, invited_email, invited_by_user_id,
                          status: str = "sent", expires_at: str | None = None) -> dict:
        row = {
            "invitation_id": str(uuid.uuid4()),
            "invited_user_id": None if invited_user_id is None else str(invited_user_id),
            "invited_email": invited_email,
            "invited_by_user_id": str(invited_by_user_id),
            "invitation_status": status,
        }
        self.invitations.append(row)
        return dict(row)

    def list_invitations(self, email: str | None = None) -> list[dict]:
        if email:
            return [i for i in self.invitations if i["invited_email"] == email]
        return list(self.invitations)

    def insert_role_audit(self, *, affected_user_id, affected_email=None, performed_by_user_id,
                          performed_by_email, action: str, previous_role=None, new_role=None,
                          previous_status=None, new_status=None, details=None) -> dict:
        row = {
            "audit_id": str(uuid.uuid4()),
            "affected_user_id": None if affected_user_id is None else str(affected_user_id),
            "affected_email": affected_email,
            "performed_by_user_id": str(performed_by_user_id),
            "performed_by_email": performed_by_email,
            "action": action,
            "previous_role": previous_role,
            "new_role": new_role,
            "previous_status": previous_status,
            "new_status": new_status,
            "details": details,
        }
        self.audit.append(row)
        return dict(row)

    def list_role_audit(self, affected_user_id=None) -> list[dict]:
        if affected_user_id is not None:
            return [a for a in self.audit if a["affected_user_id"] == str(affected_user_id)]
        return list(self.audit)

    # -- agent profiles / listings / verification -----------------------------

    def resolve_company(self, company_name: str | None) -> int | None:
        if not company_name:
            return None
        if company_name not in self.companies:
            self.companies[company_name] = self._next_company_id
            self._next_company_id += 1
        return self.companies[company_name]

    def create_agent_profile(self, *, user_id, agent_name: str, company_id: int | None = None) -> dict:
        row = {"agent_id": self._next_agent_id, "agent_name": agent_name,
               "user_id": str(user_id), "company_id": company_id}
        self._next_agent_id += 1
        self.agents.append(row)
        return dict(row)

    def get_agent_profile(self, user_id) -> dict | None:
        for row in self.agents:
            if row.get("user_id") == str(user_id):
                return dict(row)
        return None

    def list_agent_profiles(self) -> list[dict]:
        return [dict(row) for row in self.agents if row.get("user_id")]

    def seed_listing(self, listing_id: int, agent_id: int | None) -> dict:
        row = {"listing_id": listing_id, "agent_id": agent_id, "original_title": f"L{listing_id}"}
        self.listings[listing_id] = row
        return dict(row)

    def get_listing(self, listing_id: int) -> dict | None:
        row = self.listings.get(listing_id)
        return dict(row) if row else None

    def list_assigned_listings(self, agent_id: int) -> list[dict]:
        return [dict(r) for r in self.listings.values() if r.get("agent_id") == agent_id]

    def assign_listing(self, listing_id: int, agent_id: int) -> dict:
        row = self.listings.get(listing_id)
        if row is None:
            from sitewise.core.exceptions import NotFoundError

            raise NotFoundError("Listing not found.")
        row["agent_id"] = agent_id
        return dict(row)

    def insert_listing_verification(self, *, listing_id: int, verified_by_user_id,
                                    property_authenticity_status: str,
                                    commercial_classification_status: str,
                                    verification_reason: str,
                                    evidence_url: str | None = None) -> dict:
        row = {
            "verification_id": str(uuid.uuid4()),
            "listing_id": listing_id,
            "verified_by_user_id": str(verified_by_user_id),
            "property_authenticity_status": property_authenticity_status,
            "commercial_classification_status": commercial_classification_status,
            "verification_reason": verification_reason,
            "evidence_url": evidence_url,
        }
        self.verifications.append(row)
        return dict(row)

    def list_listing_verifications(self, listing_id: int) -> list[dict]:
        return [dict(v) for v in self.verifications if v["listing_id"] == listing_id]
