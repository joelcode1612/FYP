"""Shared PostgREST client for the standardization scripts (server-only).

Credentials come from the backend environment (``SUPABASE_URL`` +
``SUPABASE_SECRET_KEY``) and are never printed or persisted. The service key
bypasses RLS but the scripts are read-only unless an ``apply`` mode is
explicitly requested.
"""

from __future__ import annotations

from typing import Any

import httpx

from sitewise.core.config import settings


class SupabaseRest:
    def __init__(self, profile: str = "public") -> None:
        if not settings.supabase_url or not settings.supabase_secret_key:
            raise RuntimeError("Supabase REST is not configured (SUPABASE_URL / SUPABASE_SECRET_KEY).")
        self.base = settings.supabase_url.rstrip("/")
        self.profile = profile
        self.headers = {
            "apikey": settings.supabase_secret_key,
            "Authorization": f"Bearer {settings.supabase_secret_key}",
            "Accept-Profile": profile,
            "Content-Profile": profile,
        }

    def get(self, table: str, *, select: str = "*", filters: dict[str, str] | None = None,
            limit: int | None = None, order: str | None = None,
            count: bool = False) -> tuple[list[dict[str, Any]], int | None]:
        params: dict[str, Any] = {"select": select}
        if filters:
            params.update(filters)
        if limit is not None:
            params["limit"] = str(limit)
        if order:
            params["order"] = order
        headers = {**self.headers}
        if count:
            headers["Prefer"] = "count=exact"
        with httpx.Client(timeout=30) as client:
            resp = client.get(f"{self.base}/rest/v1/{table}", headers=headers, params=params)
        if resp.status_code >= 400:
            raise RuntimeError(f"REST GET {table} -> {resp.status_code}: {resp.text[:200]}")
        total = None
        if count:
            cr = resp.headers.get("content-range", "")
            if "/" in cr:
                tail = cr.split("/")[-1]
                total = None if tail == "*" else int(tail)
        return resp.json(), total

    def insert(self, table: str, rows: list[dict[str, Any]], *, upsert_on: str | None = None) -> list[dict[str, Any]]:
        params: dict[str, Any] = {}
        headers = {**self.headers, "Prefer": "return=representation"}
        if upsert_on:
            headers["Prefer"] += ",resolution=merge-duplicates"
            params["on_conflict"] = upsert_on
        with httpx.Client(timeout=30) as client:
            resp = client.post(f"{self.base}/rest/v1/{table}", headers=headers,
                               json=rows, params=params)
        if resp.status_code >= 400:
            raise RuntimeError(f"REST POST {table} -> {resp.status_code}: {resp.text[:200]}")
        return resp.json() if resp.text else []


# Canonical column mapping used by parity checks (Supabase REST name -> local
# canonical name) for the property master.
PROPERTY_COLUMN_MAP = {
    "property_id": "id",
    "title": "name",
    "normalized_address": "address",
    "property_type_normalized": "property_type",
    "price": "rental_price",
    "built_up_area_sqft": "built_up_sqft",
    "bathroom_count": "bathrooms",
    "user_id": "owner_user_id",
    "local_source_data": "catalogue_source_data",
    "verification_status": "verification_status",
    "is_published": "is_published",
    "published_at": "published_at",
    "rejection_reason": "rejection_reason",
    "latitude": "latitude",
    "longitude": "longitude",
    "tenure": "tenure",
    "floor_level": "floor_level",
    "unit_position": "unit_position",
    "facing_direction": "facing_direction",
    "land_area_sqft": "land_area_sqft",
    "frontage_ft": "frontage_ft",
    "depth_ft": "depth_ft",
}
