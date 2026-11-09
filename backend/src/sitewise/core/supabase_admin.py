"""Supabase admin adapter (infrastructure).

Trusted, server-only operations against the Supabase project, executed with
the ``SUPABASE_SECRET_KEY`` (service role). This module is the ONLY place the
secret key is used; it never reaches the frontend or any client bundle.

Responsibilities
----------------
* Agent provisioning: ``auth.admin.invite_user_by_email`` creates the auth
  identity AND emails the native Supabase invite (password-setup) link. No
  custom token, no plaintext password, no secret ever stored or emailed.
* Authoritative identity rows: the ``public.users`` profile in the Supabase
  identity database (role / account status), kept in step with the local
  ``sitesense`` mirror through the calling services.
* ``staff_invitations`` + ``role_change_audit`` bookkeeping (PostgREST).
* Agent profile / listing assignment / verification records, all through the
  EXISTING Supabase ``public`` tables (``agent``, ``listing``,
  ``listing_verification``, ``company``) - no duplicated application tables.
* MFA factor recovery via the documented GoTrue admin REST endpoints. Note:
  supabase-py 2.34.0 does not wrap the admin factor endpoints, so those two
  calls use httpx against the documented API (the same endpoints supabase-js
  wraps as ``auth.admin.mfa.*``). No secret material is logged or stored.

Every method fails closed with :class:`AuthUnavailableError` when the admin
credentials are not configured, and :class:`SupabaseAdminError` carries
PostgREST/GoTrue failures to the presentation layer without leaking keys.
"""

from __future__ import annotations

import uuid
from typing import Any

import httpx
from supabase import Client, create_client
from supabase_auth.types import InviteUserByEmailOptions

from sitewise.core.config import settings
from sitewise.core.exceptions import (
    AuthUnavailableError,
    ConflictError,
    NotFoundError,
    SiteWiseError,
)


class SupabaseAdminError(SiteWiseError):
    """A Supabase admin (GoTrue/PostgREST) operation failed.

    Maps to 502 at the presentation layer: the caller's request and session
    are fine, but the trusted provider operation did not succeed.
    """

    status_code = 502


_client: Client | None = None


def get_supabase_admin_client() -> Client:
    """Build (once) the service-role Supabase client.

    Raises :class:`AuthUnavailableError` (503) when the project URL or the
    secret key is missing - staff administration is simply unavailable in
    that configuration, rather than half-working.
    """
    global _client
    if _client is None:
        if not settings.supabase_url or not settings.supabase_secret_key:
            raise AuthUnavailableError(
                "Staff administration is unavailable: the Supabase project URL "
                "or secret key is not configured on the server."
            )
        _client = create_client(settings.supabase_url, settings.supabase_secret_key)
    return _client


def reset_admin_client() -> None:
    """Drop the cached client (used by tests)."""
    global _client
    _client = None


def _normalize_auth_user(raw: Any) -> dict[str, Any]:
    """Flatten a GoTrue user payload to a dict with a validated UUID ``id``.

    supabase-py returns a ``User`` model (directly from
    ``invite_user_by_email``, or nested under ``user`` depending on the SDK
    version), while the documented admin REST endpoint returns a JSON object.
    The staff API must never index a missing ``id`` off a shape it did not
    expect, so every shape is flattened and validated here; a malformed
    payload fails closed with :class:`SupabaseAdminError` (502) instead of a
    KeyError deep in the router.
    """
    if raw is None:
        raise SupabaseAdminError("Supabase Auth returned no user payload.")
    if hasattr(raw, "model_dump") and callable(raw.model_dump):
        raw = raw.model_dump()
    if isinstance(raw, dict) and isinstance(raw.get("user"), dict):
        raw = raw["user"]
    if not isinstance(raw, dict):
        raise SupabaseAdminError(
            "Supabase Auth returned an unreadable user payload."
        )
    user_id = raw.get("id")
    try:
        uuid.UUID(str(user_id))
    except (TypeError, ValueError) as exc:
        raise SupabaseAdminError(
            "Supabase Auth returned a user payload without a valid identity id."
        ) from exc
    return {**raw, "id": str(user_id)}


def get_admin_service() -> SupabaseAdminService:
    """Seam for building the admin service.

    Routers depend on this factory (not on the class directly) so tests can
    substitute a fake service without any network access, while production
    always gets the real service-role adapter.
    """
    return SupabaseAdminService()


class SupabaseAdminService:
    """High-level trusted operations used by the staff API."""

    def __init__(self, client: Client | None = None):
        self.client = client or get_supabase_admin_client()

    # ------------------------------------------------------------------
    # Auth (GoTrue) administration
    # ------------------------------------------------------------------

    def find_auth_user_by_email(self, email: str) -> dict[str, Any] | None:
        """Return the auth user payload for ``email`` (paginated lookup)."""
        page = 1
        per_page = 200
        while True:
            users = self.client.auth.admin.list_users(page=page, per_page=per_page)
            for user in users or []:
                if (getattr(user, "email", None) or "").lower() == email.lower():
                    to_dict = getattr(user, "model_dump", None)
                    return to_dict() if callable(to_dict) else user
            if not users or len(users) < per_page:
                return None
            page += 1

    def invite_agent(
        self,
        *,
        email: str,
        full_name: str,
        phone_number: str | None = None,
    ) -> dict[str, Any]:
        """Create the auth identity (if new) and email the native invite link.

        The invite email is Supabase's own password-setup flow: the agent
        opens the link, lands on the authorized redirect URL with a valid
        one-time code, and sets a password. No custom token is generated and
        no password is ever created or viewed by an administrator.
        """
        options = InviteUserByEmailOptions(
            data={"full_name": full_name, **({"phone_number": phone_number} if phone_number else {})},
            redirect_to=settings.staff_invite_redirect,
        )
        try:
            invited = self.client.auth.admin.invite_user_by_email(email, options=options)
        except Exception as exc:
            message = str(exc)
            if "422" in message or "already" in message.lower():
                raise ConflictError(
                    "This email is already registered in Supabase Auth. Use the "
                    "explicit existing-account workflow to grant staff access."
                ) from exc
            raise SupabaseAdminError(f"Supabase invite failed: {message}") from exc
        return _normalize_auth_user(invited)

    def get_auth_user(self, auth_user_id: str) -> dict[str, Any] | None:
        """Fetch one Supabase Auth user via the documented admin REST endpoint.

        Returns ``None`` when the identity does not exist. The payload is
        normalized, so ``email_confirmed_at`` / ``confirmed_at`` - the
        authoritative evidence that an invited user actually accepted the
        invitation - is readable without knowing the SDK response shape.
        """
        data = self._gotrue_admin_json(
            "GET", f"admin/users/{auth_user_id}", not_found_ok=True
        )
        return _normalize_auth_user(data) if data else None

    def admin_list_factors(self, auth_user_id: str) -> list[dict[str, Any]]:
        """List MFA factors for a user (documented GoTrue admin endpoint)."""
        data = self._gotrue_admin_json("GET", f"admin/users/{auth_user_id}/factors")
        return list(data.get("factors", []))

    def admin_delete_factor(self, auth_user_id: str, factor_id: str) -> None:
        """Delete an MFA factor (administrator-supervised recovery).

        This is Supabase's documented supported method for lost-device
        recovery: the administrator deletes the factor, the user re-enrolls
        on next sign-in. No factor secret or recovery code is ever exposed.
        """
        self._gotrue_admin_json("DELETE", f"admin/users/{auth_user_id}/factors/{factor_id}")

    def _gotrue_admin_json(
        self,
        method: str,
        path: str,
        *,
        not_found_ok: bool = False,
    ) -> dict[str, Any]:
        url = f"{settings.supabase_url.rstrip('/')}/auth/v1/{path}"
        headers = {
            "apikey": settings.supabase_secret_key,
            "Authorization": f"Bearer {settings.supabase_secret_key}",
        }
        try:
            response = httpx.request(
                method,
                url,
                headers=headers,
                timeout=settings.supabase_admin_timeout_seconds,
            )
        except httpx.HTTPError as exc:
            raise AuthUnavailableError(
                "The authentication service is temporarily unavailable."
            ) from exc
        if response.status_code >= 400:
            if not_found_ok and response.status_code == 404:
                return {}
            raise SupabaseAdminError(
                f"GoTrue admin call failed ({response.status_code})."
            )
        return response.json() if response.content else {}

    # ------------------------------------------------------------------
    # Authoritative identity rows (public.users in the Supabase DB)
    # ------------------------------------------------------------------

    def upsert_identity_profile(
        self,
        *,
        user_id: uuid.UUID | str,
        email: str,
        full_name: str | None = None,
        phone_number: str | None = None,
        role: str,
        account_status: str,
    ) -> dict[str, Any]:
        """Create-or-update the authoritative ``public.users`` row.

        Public registration must never be able to pick the role, so this is
        only callable from trusted backend code with the service key.
        """
        payload: dict[str, Any] = {
            "user_id": str(user_id),
            "email": email,
            "role": role,
            "account_status": account_status,
        }
        if full_name is not None:
            payload["full_name"] = full_name
        if phone_number is not None:
            payload["phone_number"] = phone_number
        try:
            result = (
                self.client.table("users")
                .upsert(payload, on_conflict="user_id")
                .execute()
            )
        except Exception as exc:
            raise SupabaseAdminError(f"Identity profile write failed: {exc}") from exc
        return (result.data or [{}])[0]

    def update_identity_profile(self, user_id: uuid.UUID | str, data: dict[str, Any]) -> None:
        """Partial update of the authoritative identity row (role/status)."""
        try:
            (
                self.client.table("users")
                .update(data)
                .eq("user_id", str(user_id))
                .execute()
            )
        except Exception as exc:
            raise SupabaseAdminError(f"Identity profile update failed: {exc}") from exc

    # ------------------------------------------------------------------
    # Staff invitations
    # ------------------------------------------------------------------

    def insert_invitation(
        self,
        *,
        invited_user_id: uuid.UUID | str | None,
        invited_email: str,
        invited_by_user_id: uuid.UUID | str,
        status: str = "sent",
        expires_at: str | None = None,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "invited_email": invited_email,
            "invited_by_user_id": str(invited_by_user_id),
            "invitation_status": status,
        }
        if invited_user_id is not None:
            payload["invited_user_id"] = str(invited_user_id)
        if expires_at:
            payload["expires_at"] = expires_at
        try:
            result = self.client.table("staff_invitations").insert(payload).execute()
        except Exception as exc:
            raise SupabaseAdminError(f"Invitation write failed: {exc}") from exc
        return (result.data or [{}])[0]

    def update_invitation(self, invitation_id: str, data: dict[str, Any]) -> None:
        try:
            (
                self.client.table("staff_invitations")
                .update(data)
                .eq("invitation_id", invitation_id)
                .execute()
            )
        except Exception as exc:
            raise SupabaseAdminError(f"Invitation update failed: {exc}") from exc

    def list_invitations(self, email: str | None = None) -> list[dict[str, Any]]:
        query = self.client.table("staff_invitations").select("*")
        if email:
            query = query.eq("invited_email", email)
        result = query.order("created_at", desc=True).limit(200).execute()
        return list(result.data or [])

    def get_invitation(self, invitation_id: str) -> dict[str, Any] | None:
        """Read one invitation row before a state-changing admin action."""
        try:
            result = (
                self.client.table("staff_invitations")
                .select("*")
                .eq("invitation_id", str(invitation_id))
                .limit(1)
                .execute()
            )
        except Exception as exc:
            raise SupabaseAdminError(f"Invitation lookup failed: {exc}") from exc
        return (result.data or [None])[0]

    # ------------------------------------------------------------------
    # Role-change audit
    # ------------------------------------------------------------------

    def insert_role_audit(
        self,
        *,
        affected_user_id: uuid.UUID | str | None,
        affected_email: str | None,
        performed_by_user_id: uuid.UUID | str,
        performed_by_email: str | None,
        action: str,
        previous_role: str | None = None,
        new_role: str | None = None,
        previous_status: str | None = None,
        new_status: str | None = None,
        details: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "performed_by_user_id": str(performed_by_user_id),
            "action": action,
        }
        if affected_user_id is not None:
            payload["affected_user_id"] = str(affected_user_id)
        if affected_email:
            payload["affected_email"] = affected_email
        if performed_by_email:
            payload["performed_by_email"] = performed_by_email
        for key, value in (
            ("previous_role", previous_role),
            ("new_role", new_role),
            ("previous_status", previous_status),
            ("new_status", new_status),
        ):
            if value is not None:
                payload[key] = value
        if details:
            payload["details"] = details
        try:
            result = self.client.table("role_change_audit").insert(payload).execute()
        except Exception as exc:
            raise SupabaseAdminError(f"Audit write failed: {exc}") from exc
        return (result.data or [{}])[0]

    def list_role_audit(self, affected_user_id: uuid.UUID | str | None = None) -> list[dict[str, Any]]:
        query = self.client.table("role_change_audit").select("*")
        if affected_user_id is not None:
            query = query.eq("affected_user_id", str(affected_user_id))
        result = query.order("created_at", desc=True).limit(200).execute()
        return list(result.data or [])

    # ------------------------------------------------------------------
    # Agent profiles + listing assignment + verification (existing tables)
    # ------------------------------------------------------------------

    def list_companies(self) -> list[dict[str, Any]]:
        """Return the existing ``public.company`` rows.

        Only the two columns the rest of this codebase already relies on
        (``company_id`` / ``company_name`` from :meth:`resolve_company`) are
        projected into the API. ``select("*")`` is used on the wire so the
        query stays valid if the live table carries additional columns; no
        column is invented here.
        """
        try:
            result = (
                self.client.table("company")
                .select("*")
                .order("company_name")
                .execute()
            )
        except Exception as exc:
            raise SupabaseAdminError(f"Company directory query failed: {exc}") from exc
        companies: list[dict[str, Any]] = []
        for row in result.data or []:
            raw_id = row.get("company_id")
            if raw_id is None:
                continue
            companies.append(
                {
                    "company_id": int(raw_id),
                    "company_name": str(row.get("company_name") or "").strip(),
                }
            )
        return companies

    def get_company(self, company_id: int) -> dict[str, Any] | None:
        """Look up one ``public.company`` row by its primary key."""
        try:
            result = (
                self.client.table("company")
                .select("*")
                .eq("company_id", int(company_id))
                .limit(1)
                .execute()
            )
        except Exception as exc:
            raise SupabaseAdminError(f"Company lookup failed: {exc}") from exc
        for row in result.data or []:
            return {
                "company_id": int(row["company_id"]),
                "company_name": str(row.get("company_name") or "").strip(),
            }
        return None

    def create_company(self, company_name: str) -> dict[str, Any]:
        """Register a company in the existing ``public.company`` table.

        Exact-name duplicates are refused rather than silently creating two
        near-identical rows: the caller can then pick the existing
        ``company_id`` from the directory. No new columns or tables.
        """
        name = company_name.strip()
        if not name:
            raise SupabaseAdminError("A company name is required.")
        try:
            found = (
                self.client.table("company")
                .select("company_id,company_name")
                .eq("company_name", name)
                .limit(1)
                .execute()
            )
            if found.data:
                raise ConflictError(
                    "A company with this name already exists. Select it from "
                    "the existing company directory instead."
                )
            created = (
                self.client.table("company")
                .insert({"company_name": name})
                .execute()
            )
        except ConflictError:
            raise
        except Exception as exc:
            raise SupabaseAdminError(f"Company registration failed: {exc}") from exc
        for row in created.data or []:
            return {
                "company_id": int(row["company_id"]),
                "company_name": str(row.get("company_name") or name).strip(),
            }
        raise SupabaseAdminError("Company registration returned no row.")

    def resolve_company(self, company_name: str | None) -> int | None:
        """Return the ``company`` id for a name, creating the row if new."""
        if not company_name:
            return None
        try:
            found = (
                self.client.table("company")
                .select("company_id")
                .eq("company_name", company_name)
                .limit(1)
                .execute()
            )
            if found.data:
                return int(found.data[0]["company_id"])
            created = (
                self.client.table("company")
                .insert({"company_name": company_name})
                .execute()
            )
            if created.data:
                return int(created.data[0]["company_id"])
        except Exception as exc:
            raise SupabaseAdminError(f"Company lookup failed: {exc}") from exc
        return None

    def create_agent_profile(
        self,
        *,
        user_id: uuid.UUID | str,
        agent_name: str,
        company_id: int | None = None,
    ) -> dict[str, Any]:
        """Create the ``public.agent`` profile linked to the auth identity.

        The existing ``agent`` table (``agent_id`` int64, ``agent_name``,
        ``company_id``) gains the additive ``user_id`` column via the identity
        migration; existing rows and columns are untouched.
        """
        payload: dict[str, Any] = {"agent_name": agent_name, "user_id": str(user_id)}
        if company_id is not None:
            payload["company_id"] = company_id
        try:
            result = self.client.table("agent").insert(payload).execute()
        except Exception as exc:
            raise SupabaseAdminError(f"Agent profile write failed: {exc}") from exc
        return (result.data or [{}])[0]

    def get_agent_profile(self, user_id: uuid.UUID | str) -> dict[str, Any] | None:
        try:
            result = (
                self.client.table("agent")
                .select("*")
                .eq("user_id", str(user_id))
                .limit(1)
                .execute()
            )
        except Exception as exc:
            raise SupabaseAdminError(f"Agent profile lookup failed: {exc}") from exc
        return (result.data or [None])[0]

    def list_agent_profiles(self) -> list[dict[str, Any]]:
        try:
            result = (
                self.client.table("agent")
                .select("*")
                .not_.is_("user_id", "null")
                .order("agent_id")
                .execute()
            )
        except Exception as exc:
            raise SupabaseAdminError(f"Agent profile list failed: {exc}") from exc
        return list(result.data or [])

    def list_assigned_listings(self, agent_id: int) -> list[dict[str, Any]]:
        try:
            result = (
                self.client.table("listing")
                .select("*")
                .eq("agent_id", agent_id)
                .order("listing_id")
                .execute()
            )
        except Exception as exc:
            raise SupabaseAdminError(f"Listing query failed: {exc}") from exc
        return list(result.data or [])

    def get_listing(self, listing_id: int) -> dict[str, Any] | None:
        try:
            result = (
                self.client.table("listing")
                .select("*")
                .eq("listing_id", listing_id)
                .limit(1)
                .execute()
            )
        except Exception as exc:
            raise SupabaseAdminError(f"Listing lookup failed: {exc}") from exc
        return (result.data or [None])[0]

    def assign_listing(self, listing_id: int, agent_id: int) -> dict[str, Any]:
        try:
            result = (
                self.client.table("listing")
                .update({"agent_id": agent_id})
                .eq("listing_id", listing_id)
                .execute()
            )
        except Exception as exc:
            raise SupabaseAdminError(f"Listing assignment failed: {exc}") from exc
        if not result.data:
            raise NotFoundError("Listing not found.")
        return result.data[0]

    def insert_listing_verification(
        self,
        *,
        listing_id: int,
        verified_by_user_id: uuid.UUID | str,
        property_authenticity_status: str,
        commercial_classification_status: str,
        verification_reason: str,
        evidence_url: str | None = None,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "listing_id": listing_id,
            "verified_by_user_id": str(verified_by_user_id),
            "property_authenticity_status": property_authenticity_status,
            "commercial_classification_status": commercial_classification_status,
            "verification_reason": verification_reason,
        }
        if evidence_url:
            payload["evidence_url"] = evidence_url
        try:
            result = (
                self.client.table("listing_verification")
                .insert(payload)
                .execute()
            )
        except Exception as exc:
            raise SupabaseAdminError(f"Verification write failed: {exc}") from exc
        return (result.data or [{}])[0]

    def list_listing_verifications(self, listing_id: int) -> list[dict[str, Any]]:
        try:
            result = (
                self.client.table("listing_verification")
                .select("*")
                .eq("listing_id", listing_id)
                .order("created_at", desc=True)
                .execute()
            )
        except Exception as exc:
            raise SupabaseAdminError(f"Verification query failed: {exc}") from exc
        return list(result.data or [])
