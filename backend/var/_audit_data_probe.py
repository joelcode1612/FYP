"""Read-only data audit: properties, owners, assignments, verification, links.

SELECT-only; session forced READ ONLY. Dumps JSON for report building.
"""
from __future__ import annotations

import json
from pathlib import Path

from sqlalchemy import create_engine, text

from sitewise.core.config import settings

OUT = Path(__file__).parent / "_audit_data.json"


def rows(conn, sql, **params):
    return [dict(r) for r in conn.execute(text(sql), params).mappings().all()]


def scalar(conn, sql, **params):
    return conn.execute(text(sql), params).scalar()


def main() -> None:
    engine = create_engine(settings.database_url)
    data = {}
    with engine.connect() as conn:
        conn.execute(text("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY"))
        conn.execute(text("BEGIN"))

        # --- operational properties -------------------------------------
        data["property_count"] = scalar(conn, "SELECT count(*) FROM fyp.rental_properties")
        data["by_verification_status"] = rows(conn,
            "SELECT verification_status, count(*) AS n, "
            "count(*) FILTER (WHERE is_published) AS published "
            "FROM fyp.rental_properties GROUP BY verification_status ORDER BY n DESC")
        data["owner_coverage"] = rows(conn,
            "SELECT count(*) AS total, "
            "count(owner_user_id) AS with_owner_uuid, "
            "count(owner_id) AS with_legacy_owner_id, "
            "count(*) FILTER (WHERE owner_user_id IS NULL AND owner_id IS NULL) AS no_owner_at_all, "
            "count(*) FILTER (WHERE owner_user_id IS NOT NULL AND owner_id IS NOT NULL) AS both_owner_fields, "
            "count(listing_id) AS with_catalogue_ref "
            "FROM fyp.rental_properties")
        data["properties"] = rows(conn,
            "SELECT id, name, city, state, property_type, rental_price, size_sqft, "
            "availability, verification_status, is_published, owner_user_id, owner_id, "
            "listing_id, created_at, updated_at, published_at "
            "FROM fyp.rental_properties ORDER BY id")

        # --- assignments --------------------------------------------------
        data["assignment_count"] = scalar(conn, "SELECT count(*) FROM public.agent_listing_assignment")
        data["assignments"] = rows(conn,
            "SELECT a.listing_id, a.agent_id, a.assigned_by_user_id, a.created_at, a.updated_at, "
            "p.name, p.verification_status, p.is_published, p.owner_user_id, p.owner_id, "
            "(p.id IS NOT NULL) AS property_exists "
            "FROM public.agent_listing_assignment a "
            "LEFT JOIN fyp.rental_properties p ON p.id = a.listing_id ORDER BY a.listing_id")
        data["assignments_per_listing"] = rows(conn,
            "SELECT listing_id, count(*) AS n FROM public.agent_listing_assignment "
            "GROUP BY listing_id HAVING count(*) > 1")
        data["agent_workload_local"] = rows(conn,
            "SELECT agent_id, count(*) AS assigned, "
            "count(*) FILTER (WHERE p.id IS NULL) AS orphaned "
            "FROM public.agent_listing_assignment a "
            "LEFT JOIN fyp.rental_properties p ON p.id = a.listing_id "
            "GROUP BY agent_id ORDER BY agent_id")

        # --- identity mirrors ---------------------------------------------
        data["public_users_count"] = scalar(conn, "SELECT count(*) FROM public.users")
        data["public_users"] = rows(conn,
            "SELECT user_id, email, full_name, role, account_status, email_verified, created_at "
            "FROM public.users ORDER BY created_at")
        data["fyp_users_count"] = scalar(conn, "SELECT count(*) FROM fyp.users")
        data["fyp_users"] = rows(conn,
            "SELECT id, email, full_name, role, is_active FROM fyp.users ORDER BY id")
        data["brief_agent_uuids_in_mirror"] = rows(conn,
            "SELECT user_id, email, full_name, role, account_status FROM public.users "
            "WHERE user_id IN ('8de9ed3b-1431-4603-b680-731e40f53628',"
            "'dcbc87df-0911-49ed-806c-02305441439f')")

        # owner UUID resolution against the mirror
        data["owner_resolution"] = rows(conn,
            "SELECT p.owner_user_id, count(*) AS properties, "
            "u.email, u.full_name, u.role, u.account_status "
            "FROM fyp.rental_properties p "
            "LEFT JOIN public.users u ON u.user_id = p.owner_user_id "
            "WHERE p.owner_user_id IS NOT NULL "
            "GROUP BY p.owner_user_id, u.email, u.full_name, u.role, u.account_status "
            "ORDER BY properties DESC")
        data["legacy_owner_resolution"] = rows(conn,
            "SELECT p.owner_id, count(*) AS properties, u.email, u.full_name, u.role, u.is_active "
            "FROM fyp.rental_properties p LEFT JOIN fyp.users u ON u.id = p.owner_id "
            "WHERE p.owner_id IS NOT NULL GROUP BY p.owner_id, u.email, u.full_name, u.role, u.is_active")
        data["assigned_by_resolution"] = rows(conn,
            "SELECT a.assigned_by_user_id, count(*) AS n, u.email, u.role "
            "FROM public.agent_listing_assignment a "
            "LEFT JOIN public.users u ON u.user_id = a.assigned_by_user_id "
            "GROUP BY a.assigned_by_user_id, u.email, u.role")

        # --- verification workflow ----------------------------------------
        data["verification_count"] = scalar(conn, "SELECT count(*) FROM public.property_verification")
        data["verification_states"] = rows(conn,
            "SELECT listing_status, ownership_status, count(*) AS n "
            "FROM public.property_verification GROUP BY listing_status, ownership_status ORDER BY n DESC")
        data["verification_orphans"] = rows(conn,
            "SELECT v.property_id FROM public.property_verification v "
            "LEFT JOIN fyp.rental_properties p ON p.id = v.property_id WHERE p.id IS NULL")

        # --- research links ------------------------------------------------
        data["subject_links_count"] = scalar(conn, "SELECT count(*) FROM fyp.property_subject_links")
        data["subject_links_verified"] = rows(conn,
            "SELECT match_verified, count(*) AS n FROM fyp.property_subject_links GROUP BY match_verified")
        data["subject_links_sample"] = rows(conn,
            "SELECT property_id, subject_id, sitewise_property_id, match_method, match_verified "
            "FROM fyp.property_subject_links ORDER BY property_id LIMIT 15")
        data["brief_research_ids"] = rows(conn,
            "SELECT property_id, subject_id, sitewise_property_id, match_verified "
            "FROM fyp.property_subject_links WHERE subject_id IN ('MD-00510','MD-01755') "
            "OR sitewise_property_id IN ('MD-00510','MD-01755')")

        # --- catalogue (sitewise_app.properties) ---------------------------
        data["catalogue_columns"] = rows(conn,
            "SELECT column_name, data_type FROM information_schema.columns "
            "WHERE table_schema='sitewise_app' AND table_name='properties' ORDER BY ordinal_position")
        data["catalogue_count"] = scalar(conn, "SELECT count(*) FROM sitewise_app.properties")

        conn.execute(text("ROLLBACK"))

    OUT.write_text(json.dumps(data, indent=2, default=str), encoding="utf-8")
    print(f"wrote {OUT}")
    print(f"properties={data['property_count']} assignments={data['assignment_count']} "
          f"public_users={data['public_users_count']} fyp_users={data['fyp_users_count']} "
          f"verifications={data['verification_count']} subject_links={data['subject_links_count']} "
          f"catalogue={data['catalogue_count']}")
    print("owner_coverage:", data["owner_coverage"])
    print("by_status:", data["by_verification_status"])
    print("agent_workload_local:", data["agent_workload_local"])
    print("brief_agent_uuids_in_mirror:", data["brief_agent_uuids_in_mirror"])
    print("brief_research_ids:", data["brief_research_ids"])
    print("assignments_per_listing (>1):", data["assignments_per_listing"])
    print("verification_orphans:", data["verification_orphans"])


if __name__ == "__main__":
    main()