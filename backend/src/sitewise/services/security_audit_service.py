"""Security & activity audit retrieval (service layer).

Coordinates the two audit sources behind the admin "System activity" page
(`/admin/activity`) into one normalized, server-filtered response.

Sources
-------
1. ``public.role_change_audit`` (Supabase PostgREST via the service-role
   adapter) — the EXISTING administrative feed. Unchanged: the legacy
   ``GET /api/v1/staff/audit`` endpoint still serves the same rows to its
   existing consumers; this service adds filtering/pagination on top.
2. ``auth.audit_log_entries`` (GoTrue) — the authentication/MFA event
   history, READ ONLY IF the Supabase project exposes the ``auth`` schema
   through its PostgREST API. Hosted projects do not expose it by default
   (``db-schemas`` defaults to ``public, storage``), and this deployment has
   no direct database connection to Supabase, so the probe below detects the
   real capability and the page renders the honest status. If the project is
   later configured to expose the schema, the same code path picks the
   events up with no further change.

Verified GoTrue behaviour (supabase/auth ``internal/models/audit_log_entry.go``
and ``internal/api/mfa.go``, project master):

* Audit entries are written inside the SUCCESS transaction only. Failed
  sign-ins and failed MFA verifications are NOT recorded anywhere in
  ``auth.audit_log_entries`` — this service reports that limitation rather
  than inventing failure events.
* Action strings are stable names (``login``, ``user_signedup``,
  ``verification_attempted``, ``factor_unenrolled``, ...) and each payload
  carries GoTrue's own classification in ``log_type`` (``account`` /
  ``token`` / ``user`` / ``factor``), which is used for category mapping —
  no invented event-type codes.

Security properties
-------------------
* Read-only: nothing in this module writes to either audit source.
* Auth payloads are reduced to a safe allow-list (action, actor id/email,
  log type, SSO flag); traits and every other payload key are dropped.
  Tokens, OTPs, recovery codes and TOTP secrets never appear in GoTrue
  audit rows, and no credential material is produced here either.
* Every query is executed with the service-role key from the backend only.
"""

from __future__ import annotations

import logging
import time
import uuid
from typing import Any

from sitewise.core.supabase_admin import (
    SupabaseAdminError,
    SupabaseAdminService,
)
from sitewise.domain import rbac

logger = logging.getLogger("sitewise.security_audit")

ADMIN_SOURCE = "SiteWise staff audit"
AUTH_SOURCE = "Supabase Auth"

#: Upper bound on rows pulled per source when the "All activity" tab merges
#: two sources in memory. Documented in the response notes when truncation
#: actually happens — never silently.
_MERGE_WINDOW = 500

#: Auth-source availability probe cache (seconds). A failed PostgREST read is
#: retried after this window so a project that later exposes the schema is
#: picked up without a restart, while a search does not hammer the API.
_PROBE_TTL_SECONDS = 120.0

_probe_cache: dict[str, tuple[float, bool, str]] = {}

# ---------------------------------------------------------------------------
# GoTrue action vocabulary (verified against supabase/auth master)
# ---------------------------------------------------------------------------

#: Actions whose payload ``log_type`` is ``factor`` — the MFA category.
AUTH_MFA_ACTIONS = frozenset(
    {
        "factor_in_progress",
        "factor_unenrolled",
        "factor_deleted",
        "factor_updated",
        "challenge_created",
        "verification_attempted",
        "recovery_codes_generated",
        "recovery_codes_verified",
        "recovery_codes_regenerated",
        "recovery_codes_deleted",
    }
)

#: Actions that complete something (green "Successful" in the table).
AUTH_SUCCESS_ACTIONS = frozenset(
    {
        "login",
        "user_signedup",
        "invite_accepted",
        "user_updated_password",
        "user_reauthenticate_requested",
        "verification_attempted",
        "factor_unenrolled",
        "factor_deleted",
        "recovery_codes_verified",
        "identity_linked",
        "identity_unlinked",
    }
)

#: Safe, human labels per known GoTrue action. Unknown actions render their
#: raw action name with a neutral tone — nothing is invented.
AUTH_LABELS: dict[str, str] = {
    "login": "Sign-in successful",
    "logout": "Sign-out",
    "user_signedup": "Account registered",
    "user_repeated_signup": "Repeat registration attempt",
    "user_invited": "Account invitation sent",
    "invite_accepted": "Invitation accepted",
    "user_deleted": "Account deleted",
    "user_modified": "Account details updated",
    "user_recovery_requested": "Password recovery requested",
    "user_reauthenticate_requested": "Re-authentication completed",
    "user_confirmation_requested": "Confirmation email sent",
    "user_updated_password": "Password updated",
    "token_revoked": "Session token revoked",
    "token_refreshed": "Session token refreshed",
    "factor_in_progress": "MFA factor enrollment completed",
    "factor_unenrolled": "MFA factor removed",
    "factor_deleted": "MFA factor deleted",
    "factor_updated": "MFA factor updated",
    "challenge_created": "MFA challenge created",
    "verification_attempted": "MFA verification successful",
    "identity_linked": "Identity linked",
    "identity_unlinked": "Identity unlinked",
    "passkey_created": "Passkey created",
    "passkey_updated": "Passkey updated",
    "passkey_deleted": "Passkey deleted",
    "recovery_codes_generated": "MFA recovery codes generated",
    "recovery_codes_verified": "MFA recovery code used",
    "recovery_codes_regenerated": "MFA recovery codes regenerated",
    "recovery_codes_deleted": "MFA recovery codes deleted",
}

#: The existing administrative actions written by staff.py operations.
ADMIN_LABELS: dict[str, str] = {
    "staff.invited": "Agent invitation sent",
    "staff.role_granted": "Staff role granted",
    "staff.activated": "Account activated",
    "staff.suspended": "Account suspended",
    "staff.reactivated": "Account reactivated",
    "staff.status_changed": "Account status changed",
    "staff.onboarding_completed": "Agent onboarding completed",
    "staff.mfa_factor_reset": "MFA factor reset (administrator)",
    "staff.invitation_revoked": "Invitation revoked",
    "company.registered": "Company registered",
    "listing.assigned": "Listing assigned to agent",
}


def _admin_label(action: str) -> str:
    if action in ADMIN_LABELS:
        return ADMIN_LABELS[action]
    if not action:
        return "Administrative action"
    # Generic fallback: 'staff.invitation_revoked' -> 'Invitation revoked'.
    tail = action.rsplit(".", 1)[-1].replace("_", " ").strip()
    return tail[:1].upper() + tail[1:] if tail else action


def _auth_label(action: str) -> str:
    if action in AUTH_LABELS:
        return AUTH_LABELS[action]
    return f"Auth event: {action}" if action else "Auth event"


def _prettify_role(role: str | None) -> str | None:
    """``admin`` -> ``Administrator`` etc. Legacy aliases first."""
    if not role:
        return None
    canonical = rbac.canonical_role(role)
    return {
        rbac.ROLE_ADMIN: "Administrator",
        rbac.ROLE_OWNER: "Property Owner",
        rbac.ROLE_AGENT: "Agent",
        rbac.ROLE_ENTREPRENEUR: "Entrepreneur",
    }.get(canonical)


# ---------------------------------------------------------------------------
# Source availability probe
# ---------------------------------------------------------------------------


def _auth_source_status(service: SupabaseAdminService) -> tuple[bool, str]:
    """Can this backend read ``auth.audit_log_entries`` right now?

    Cached for a short window: a search must not hammer the API with a
    doomed probe on every request, but a project that later exposes the
    ``auth`` schema is picked up without a redeploy.
    """
    cached = _probe_cache.get("auth")
    now = time.monotonic()
    if cached and now - cached[0] < _PROBE_TTL_SECONDS:
        return cached[1], cached[2]
    try:
        (
            service.client.schema("auth")
            .table("audit_log_entries")
            .select("id", count="exact")
            .limit(1)
            .execute()
        )
    except Exception as exc:  # noqa: BLE001 — any failure = honestly unavailable
        raw = str(getattr(exc, "message", None) or exc)
        lowered = raw.lower()
        if "api key" in lowered or "unregistered" in lowered or "invalid key" in lowered:
            detail = (
                "auth.audit_log_entries cannot be read: the backend's service "
                "key was rejected by the Supabase project (key rotated or "
                "misconfigured SUPABASE_SECRET_KEY). This also affects the "
                "administrative feed. Sign-in / registration / MFA events are "
                "therefore not shown."
            )
        elif "not found" in lowered or "schema" in lowered or "pgrst" in lowered:
            detail = (
                "auth.audit_log_entries is not reachable through this backend: "
                "the Supabase PostgREST API does not expose the auth schema "
                "(default db-schemas are public + storage) and no direct "
                "database connection is configured. Sign-in / registration / "
                "MFA events from Supabase are therefore not shown. Expose the "
                "auth schema to the service key or configure a direct "
                "connection to enable it."
            )
        else:
            detail = (
                "auth.audit_log_entries cannot be read right now "
                f"({type(exc).__name__}). Sign-in / registration / MFA events "
                "from Supabase are therefore not shown."
            )
        logger.info("auth audit source probe failed: %s", type(exc).__name__)
        _probe_cache["auth"] = (now, False, detail)
        return False, detail
    detail = (
        "auth.audit_log_entries read via the backend service connection. "
        "Note: GoTrue writes audit entries on success only — failed sign-ins "
        "and failed MFA verifications are not recorded by this source."
    )
    _probe_cache["auth"] = (now, True, detail)
    return True, detail


# ---------------------------------------------------------------------------
# Query construction (server-side filtering + pagination)
# ---------------------------------------------------------------------------


def _sanitize_search(raw: str | None) -> str:
    """Strip PostgREST logical-operator syntax so a search term cannot inject
    extra ``or=`` clauses. What remains is matched as a literal fragment."""
    cleaned = (raw or "").strip()[:120]
    return "".join(c for c in cleaned if c not in "(),\"'\\")


def _maybe_uuid(search: str) -> str | None:
    try:
        return str(uuid.UUID(search))
    except (ValueError, AttributeError, TypeError):
        return None


def _admin_count_mfa(service: SupabaseAdminService) -> bool:
    """Does the administrative feed carry any MFA action at all? Used only to
    state the MFA source strip accurately."""
    try:
        result = (
            service.client.table("role_change_audit")
            .select("action", count="exact")
            .filter("action", "like", "*mfa*")
            .limit(1)
            .execute()
        )
    except Exception:  # noqa: BLE001 — status information must never 500 the page
        return False
    return bool((result.count or 0) > 0 or result.data)


def _admin_query(
    service: SupabaseAdminService,
    *,
    category: str,
    result: str,
    search: str,
    role_ids: list[str] | None,
    date_from: str | None,
    date_to: str | None,
    offset: int,
    limit: int,
    want_count: bool,
):
    query = service.client.table("role_change_audit").select(
        "*", count="exact" if want_count else None
    )
    if category == "admin":
        query = query.filter("action", "nlike", "*mfa*")
    elif category == "mfa":
        query = query.filter("action", "like", "*mfa*")
    if result == "success":
        query = query.eq("action_status", "success")
    elif result == "failed":
        # Rows are written after successful operations, so anything other
        # than 'success' is the honest "failed" bucket (e.g. a manually
        # corrected row); 'info' has no administrative counterpart.
        query = query.neq("action_status", "success")
    if date_from:
        query = query.gte("changed_at", date_from)
    if date_to:
        query = query.lte("changed_at", date_to)
    if role_ids is not None:
        if not role_ids:
            # No account carries this role: a deterministic empty result is
            # the correct answer, not an unfiltered fallback.
            query = query.filter("user_id_affected", "is", None)
        else:
            query = query.in_("user_id_affected", role_ids)
    if search:
        terms = [f"action.ilike.*{search}*"]
        if "@" in search or len(search) >= 3:
            terms.append(f"affected_email_snapshot.ilike.*{search}*")
        terms.append(f"details->>performed_by_email.ilike.*{search}*")
        as_uuid = _maybe_uuid(search)
        if as_uuid:
            terms.insert(0, f"user_id_affected.eq.{as_uuid}")
            terms.append(f"entity_id.eq.{as_uuid}")
        query = query.or_(",".join(terms))
    return query.order("changed_at", desc=True).range(offset, offset + limit - 1)


def _auth_query(
    service: SupabaseAdminService,
    *,
    category: str,
    result: str,
    search: str,
    date_from: str | None,
    date_to: str | None,
    offset: int,
    limit: int,
    want_count: bool,
):
    query = (
        service.client.schema("auth")
        .table("audit_log_entries")
        .select("*", count="exact" if want_count else None)
    )
    if category == "auth":
        # log_type is GoTrue's own classification of the action.
        query = query.filter("payload->>log_type", "neq", "factor")
    elif category == "mfa":
        query = query.filter("payload->>log_type", "eq", "factor")
    if result in ("success", "info"):
        actions = AUTH_SUCCESS_ACTIONS if result == "success" else set()
        if result == "info":
            # Everything known-but-not-successful; unknown actions stay
            # visible under 'all' rather than being guessed into a bucket.
            actions = set(AUTH_LABELS) - AUTH_SUCCESS_ACTIONS
        if actions:
            query = query.in_(
                "payload->>action", f"({','.join(sorted(actions))})"
            )
        else:
            query = query.filter("payload->>action", "is", None)
    elif result == "failed":
        # Honest empty result: GoTrue does not record failures.
        query = query.filter("payload->>action", "is", None)
    if date_from:
        query = query.gte("created_at", date_from)
    if date_to:
        query = query.lte("created_at", date_to)
    if search:
        terms = [f"payload->>action.ilike.*{search}*"]
        if "@" in search or len(search) >= 3:
            terms.append(f"payload->>actor_username.ilike.*{search}*")
        as_uuid = _maybe_uuid(search)
        if as_uuid:
            terms.insert(0, f"payload->>actor_id.eq.{as_uuid}")
            terms.append(f"id.eq.{as_uuid}")
        query = query.or_(",".join(terms))
    return query.order("created_at", desc=True).range(offset, offset + limit - 1)


# ---------------------------------------------------------------------------
# Normalization
# ---------------------------------------------------------------------------


def _admin_event(row: dict[str, Any], roles: dict[str, str]) -> dict[str, Any]:
    action = str(row.get("action") or "")
    details = row.get("details") if isinstance(row.get("details"), dict) else {}
    affected_id = str(row.get("user_id_affected") or "")
    affected_role = roles.get(affected_id) or _prettify_role(
        row.get("new_role") or row.get("old_role")
    )
    return {
        "id": f"admin:{row.get('entity_id') or affected_id}:{row.get('changed_at') or ''}",
        "category": "mfa" if "mfa" in action else "admin",
        "action": action,
        "title": _admin_label(action),
        "summary": "Administrative action recorded by the SiteWise staff "
        "audit feed when the operation completed.",
        "affected_email": str(row.get("affected_email_snapshot") or ""),
        "affected_user_id": affected_id,
        "performed_by_email": str(
            (details or {}).get("performed_by_email")
            or row.get("performed_by_email")
            or ""
        ),
        "performed_by_user_id": str(row.get("changed_by_user_id") or ""),
        "role": affected_role,
        "created_at": str(row.get("changed_at") or ""),
        "result": "success" if row.get("action_status") == "success" else "failed",
        "source": ADMIN_SOURCE,
        "details": {
            "entity_type": str(row.get("entity_type") or ""),
            "entity_id": str(row.get("entity_id") or ""),
            "previous_role": _prettify_role(row.get("old_role")),
            "new_role": _prettify_role(row.get("new_role")),
            "previous_status": row.get("old_account_status"),
            "new_status": row.get("new_account_status"),
        },
    }


def _auth_event(row: dict[str, Any], roles: dict[str, str]) -> dict[str, Any]:
    payload = row.get("payload") if isinstance(row.get("payload"), dict) else {}
    action = str(payload.get("action") or "")
    log_type = str(payload.get("log_type") or "")
    actor_id = str(payload.get("actor_id") or "")
    category = "mfa" if (log_type == "factor" or action in AUTH_MFA_ACTIONS) else "auth"
    result = "success" if action in AUTH_SUCCESS_ACTIONS else "info"
    label = _auth_label(action)
    # Safe allow-list ONLY: action, actor id/email, log type, SSO flag, ip.
    # Traits and any other payload keys are dropped, never forwarded.
    details: dict[str, Any] = {"log_type": log_type or None}
    if payload.get("actor_via_sso") is not None:
        details["sign_in_method"] = (
            "SSO" if payload.get("actor_via_sso") else "Direct"
        )
    ip = str(row.get("ip_address") or "")
    if ip:
        details["ip_address"] = ip
    return {
        "id": f"auth:{row.get('id') or ''}",
        "category": category,
        "action": action,
        "title": label,
        "summary": "Authentication event recorded by Supabase Auth when the "
        "action completed successfully.",
        "affected_email": str(payload.get("actor_username") or ""),
        "affected_user_id": actor_id,
        "performed_by_email": "",  # self-service: the actor is the account
        "performed_by_user_id": actor_id,
        "role": roles.get(actor_id),
        "created_at": str(row.get("created_at") or ""),
        "result": result,
        "source": AUTH_SOURCE,
        "details": details,
    }


def _roles_for(service: SupabaseAdminService, ids: list[str]) -> dict[str, str]:
    """Resolve affected-account roles from the authoritative ``public.users``
    profile. Best-effort: a role the identity DB does not carry stays ``None``
    and the UI renders it as unknown — never a guess."""
    clean = [i for i in ids if i]
    if not clean:
        return {}
    try:
        result = (
            service.client.table("users")
            .select("user_id,role")
            .in_("user_id", clean)
            .execute()
        )
    except Exception as exc:  # noqa: BLE001 — enrichment failure must not fail the page
        logger.warning("role resolution failed: %s", type(exc).__name__)
        return {}
    roles: dict[str, str] = {}
    for row in result.data or []:
        pretty = _prettify_role(str(row.get("role") or ""))
        if row.get("user_id") and pretty:
            roles[str(row["user_id"])] = pretty
    return roles


def _role_ids_for(service: SupabaseAdminService, role_value: str) -> list[str] | None:
    """Ids of accounts carrying the requested role (server-side role filter).

    ``None`` means "no role filter". ``[]`` means the role genuinely has no
    accounts, which must produce an empty page rather than unfiltered rows.
    """
    canonical = rbac.LEGACY_ROLE_ALIASES.get(role_value, role_value)
    if canonical not in rbac.ALL_ROLES:
        return None
    try:
        result = (
            service.client.table("users")
            .select("user_id")
            .eq("role", canonical)
            .limit(_MERGE_WINDOW)
            .execute()
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("role filter resolution failed: %s", type(exc).__name__)
        return None
    return [str(r["user_id"]) for r in (result.data or []) if r.get("user_id")]


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------


def list_security_audit(
    service: SupabaseAdminService,
    *,
    page: int = 1,
    page_size: int = 25,
    category: str = "all",
    search: str = "",
    result: str = "all",
    role: str = "all",
    date_from: str | None = None,
    date_to: str | None = None,
) -> dict[str, Any]:
    """Normalized read for the System activity page.

    Keeps ``GET /api/v1/staff/audit`` untouched; this is the additive,
    filterable, paginated read the page uses. All filters are applied
    SERVER-SIDE (PostgREST), so a search never downloads the whole history.
    """
    offset = (page - 1) * page_size
    auth_available, auth_detail = _auth_source_status(service)
    search = _sanitize_search(search)
    role_ids = _role_ids_for(service, role) if role not in ("", "all") else None

    notes: list[str] = []
    events: list[dict[str, Any]] = []
    total = 0
    auth_total = 0
    admin_total = 0
    truncated_merge = False

    need_admin = category in ("all", "admin", "mfa")
    need_auth = category in ("all", "auth", "mfa") and auth_available

    if category == "auth" and not auth_available:
        # The tab exists but its only source is unavailable: say so instead
        # of showing admin rows under an Authentication tab.
        notes.append(
            "Authentication events are not available on this deployment — "
            "see the sign-in source status above."
        )

    admin_rows: list[dict[str, Any]] = []
    auth_rows: list[dict[str, Any]] = []

    if need_admin:
        try:
            response = _admin_query(
                service,
                category=category,
                result=result,
                search=search,
                role_ids=role_ids,
                date_from=date_from,
                date_to=date_to,
                offset=offset,
                limit=page_size,
                want_count=True,
            ).execute()
        except SupabaseAdminError:
            raise
        except Exception as exc:  # noqa: BLE001
            raise SupabaseAdminError(f"Audit read failed: {exc}") from exc
        admin_rows = list(response.data or [])
        admin_total = int(response.count or 0)

    if need_auth:
        # Two-source categories merge bounded windows in memory. The auth
        # window is capped at _MERGE_WINDOW rows; anything older is reached
        # through the Authentication / MFA tab, which paginates its source
        # directly. State it — never silently.
        merge_cap = _MERGE_WINDOW
        try:
            response = _auth_query(
                service,
                category=category,
                result=result,
                search=search,
                date_from=date_from,
                date_to=date_to,
                offset=offset if category != "all" else 0,
                limit=page_size if category != "all" else merge_cap,
                want_count=True,
            ).execute()
        except SupabaseAdminError:
            raise
        except Exception as exc:  # noqa: BLE001
            raise SupabaseAdminError(f"Auth audit read failed: {exc}") from exc
        auth_rows = list(response.data or [])
        auth_total = int(response.count or 0)
        if category == "all" and auth_total > len(auth_rows):
            truncated_merge = True

    if category == "all":
        total = admin_total + auth_total
        ids = [
            *(r.get("user_id_affected") or "" for r in admin_rows),
            *(str((r.get("payload") or {}).get("actor_id") or "") for r in auth_rows),
        ]
        roles = _roles_for(service, ids)
        events = [
            *(_admin_event(r, roles) for r in admin_rows),
            *(_auth_event(r, roles) for r in auth_rows),
        ]
        events.sort(key=lambda e: e["created_at"] or "", reverse=True)
        events = events[offset : offset + page_size]
        if truncated_merge:
            notes.append(
                "The merged All-activity view includes the most recent "
                f"{_MERGE_WINDOW} authentication events; use the "
                "Authentication tab for full pagination of that source."
            )
    elif category == "auth":
        total = auth_total
        ids = [str((r.get("payload") or {}).get("actor_id") or "") for r in auth_rows]
        roles = _roles_for(service, ids)
        events = [_auth_event(r, roles) for r in auth_rows]
    elif category == "mfa":
        total = admin_total + auth_total
        ids = [
            *(r.get("user_id_affected") or "" for r in admin_rows),
            *(str((r.get("payload") or {}).get("actor_id") or "") for r in auth_rows),
        ]
        roles = _roles_for(service, ids)
        events = [
            *(_admin_event(r, roles) for r in admin_rows),
            *(_auth_event(r, roles) for r in auth_rows),
        ]
        events.sort(key=lambda e: e["created_at"] or "", reverse=True)
        events = events[offset : offset + page_size]
    else:  # admin
        total = admin_total
        ids = [r.get("user_id_affected") or "" for r in admin_rows]
        roles = _roles_for(service, ids)
        events = [_admin_event(r, roles) for r in admin_rows]

    if result == "failed" and category in ("auth", "all"):
        notes.append(
            "No failed authentication events are shown: GoTrue writes audit "
            "entries on success only, so failed sign-ins and failed MFA "
            "verifications are not recorded by the auth source."
        )

    admin_mfa_rows = _admin_count_mfa(service) if category != "auth" else False

    sources = {
        "administrative": {
            "available": True,
            "detail": "Existing public.role_change_audit feed — agent "
            "invitations, suspensions, role changes, MFA factor resets, "
            "listing assignments — with the performing administrator.",
        },
        "authentication": {
            "available": auth_available,
            "detail": auth_detail,
        },
        "mfa": {
            "available": auth_available or admin_mfa_rows,
            "detail": (
                auth_detail
                if not auth_available and not admin_mfa_rows
                else (
                    "Supabase MFA events (enrollment, verification success, "
                    "factor removal) are available from auth.audit_log_entries."
                    if auth_available
                    else "Administrator MFA actions (factor resets) come from "
                    "the existing staff audit feed; Supabase-side MFA "
                    "verification events are not available on this deployment."
                )
            ),
        },
    }

    return {
        "sources": sources,
        "events": events,
        "total": total,
        "page": page,
        "page_size": page_size,
        "notes": notes,
    }
