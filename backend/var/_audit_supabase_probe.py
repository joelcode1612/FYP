"""Read-only Supabase identity resolution via direct PostgREST/GoTrue GETs.

Same authorized mechanism as SupabaseAdminService (service-role key from the
active backend settings), but using urllib so a malformed proxy env pattern
cannot break client construction. GETs only; no writes.
"""
from __future__ import annotations

import json
import urllib.error
import urllib.request
from pathlib import Path

from sitewise.core.config import settings

OUT = Path(__file__).parent / "_audit_supabase.json"
BRIEF_UUIDS = [
    "8de9ed3b-1431-4603-b680-731e40f53628",
    "dcbc87df-0911-49ed-806c-02305441439f",
]

_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def get(path: str):
    url = settings.supabase_url.rstrip("/") + path
    req = urllib.request.Request(url, headers={
        "apikey": settings.supabase_secret_key,
        "Authorization": f"Bearer {settings.supabase_secret_key}",
        "Accept": "application/json",
    })
    try:
        with _opener.open(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8")), None
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")[:300]
        return None, f"HTTP {exc.code}: {body}"
    except Exception as exc:
        return None, str(exc)[:200]


def main() -> None:
    data = {}

    profiles, err = get("/rest/v1/agent?select=*&order=agent_id")
    data["agent_profiles"] = profiles or []
    data["agent_profiles_error"] = err
    print(f"public.agent rows: {len(profiles or [])} err={err}")
    for p in profiles or []:
        print("  ", {k: p.get(k) for k in ("agent_id", "user_id", "agent_name", "company_id")})

    users, err = get("/rest/v1/users?select=user_id,email,full_name,role,account_status")
    data["identity_users"] = users or []
    data["identity_users_error"] = err
    print(f"supabase public.users rows: {len(users or [])} err={err}")
    for u in users or []:
        if u.get("role") in ("agent", "admin"):
            print("  staff:", u)

    auth = {}
    targets = {str(p.get("user_id")) for p in (profiles or []) if p.get("user_id")} | set(BRIEF_UUIDS)
    for uid in sorted(targets):
        a, err = get(f"/auth/v1/admin/users/{uid}")
        if a is None:
            auth[uid] = {"error": err}
        else:
            auth[uid] = {k: a.get(k) for k in (
                "id", "email", "email_confirmed_at", "confirmed_at",
                "banned_until", "created_at", "last_sign_in_at")}
    data["auth_users"] = auth
    print("auth state:")
    for uid, a in auth.items():
        print("  ", uid, a)

    listing, err = get("/rest/v1/listing?select=listing_id&limit=1")
    data["supabase_listing_table"] = {"rows": listing, "error": err}
    print("supabase listing table probe:", data["supabase_listing_table"])

    OUT.write_text(json.dumps(data, indent=2, default=str), encoding="utf-8")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()