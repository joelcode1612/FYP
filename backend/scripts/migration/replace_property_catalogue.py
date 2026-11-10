"""Replace the SiteWise research-property catalogue with the 955-property workbook.

Source : SiteWise_PU_Property_Image_Scores_Merged (1).xlsx
Target : Final_Location_Analysis (localhost:5432)

Design notes
------------
* Single transaction. Any failed assertion rolls the whole migration back.
* Internal numeric ids in ``fyp.rental_properties`` are preserved: rows are
  matched on ``listing_id`` == ``canonical_property_id`` and updated in place.
* Owner-submitted listings (``owner_id IS NOT NULL``) are never touched.
* ``sitewise_analytics.subject_features`` is read-only here: all 1,849 PU rows
  (955 U + 894 P) must survive unchanged.
* The research score is stored raw in ``source_data`` and scaled to the
  catalogue's 0-100 ranking column; it is never labelled a success probability.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import openpyxl
import psycopg2
from psycopg2.extras import execute_values

WORKBOOK = Path(
    r"C:/Users/Lenovo/Downloads/Telegram Desktop/"
    r"SiteWise_PU_Property_Image_Scores_Merged (1).xlsx"
)
DSN = dict(
    host="localhost", port=5432, dbname="Final_Location_Analysis",
    user="postgres", password="123456",
)

EXPECTED_PROPERTIES = 955
EXPECTED_WITH_IMAGES = 911
EXPECTED_WITHOUT_IMAGES = 44
EXPECTED_IMAGE_URLS = 5979
EXPECTED_PU_ROWS = 1849
EXPECTED_P_CLASS = 894
EXPECTED_U_CLASS = 955

DATASET_VALIDATION = "UNVERIFIED_RESEARCH_DATASET"
SOURCE_SHEET = "PU Properties + Images"

# Research fields carried into sitewise_app.properties.source_data.
SOURCE_DATA_KEYS = (
    "canonical_property_id", "subject_id", "sample_class", "district",
    "state_dosm", "data_completeness_pct", "coordinate_source",
    "coordinate_quality", "image_status", "valid_image_count",
    "research_p_association_score", "score_type", "model_feature_set",
    "model_method", "prediction_match_status", "property_availability_status",
    "analysis_status", "reference_coverage", "self_exclusion_status",
    "fnb_competitors_500m", "fnb_competitors_1000m", "nearest_transit_walk_m",
    "nearest_major_road_m", "district_income_median_myr",
)


def num(value):
    """Float or None. Blank strings and non-numerics become None, never 0."""
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def txt(value):
    if value is None:
        return None
    value = str(value).strip()
    return value or None


def load_workbook_rows():
    wb = openpyxl.load_workbook(WORKBOOK, read_only=True, data_only=True)

    ws = wb[SOURCE_SHEET]
    it = ws.iter_rows(values_only=True)
    header = list(next(it))
    properties = []
    for offset, raw in enumerate(it, start=2):
        if not raw or all(v in (None, "") for v in raw):
            continue
        row = dict(zip(header, raw))
        row["_source_row"] = offset
        properties.append(row)

    ws = wb["Image Gallery Details"]
    it = ws.iter_rows(values_only=True)
    header = list(next(it))
    images = []
    for raw in it:
        if not raw or all(v in (None, "") for v in raw):
            continue
        row = dict(zip(header, raw))
        url = txt(row.get("image_url"))
        if url:
            images.append(
                {
                    "canonical_property_id": txt(row["canonical_property_id"]),
                    "url": url,
                    "rank": int(num(row.get("image_rank")) or 0),
                    "is_primary": str(row.get("image_is_primary") or "").strip().upper()
                    in {"TRUE", "1", "YES"},
                    "source": txt(row.get("image_source")),
                }
            )

    return properties, images


def assert_workbook(properties, images):
    ids = [txt(p["canonical_property_id"]) for p in properties]
    assert len(properties) == EXPECTED_PROPERTIES, f"properties={len(properties)}"
    assert len(set(ids)) == EXPECTED_PROPERTIES, "canonical ids are not unique"
    assert all(ids), "blank canonical_property_id"

    with_images = sum(1 for p in properties if txt(p.get("primary_image_url")))
    assert with_images == EXPECTED_WITH_IMAGES, f"with_images={with_images}"
    assert EXPECTED_PROPERTIES - with_images == EXPECTED_WITHOUT_IMAGES
    assert len(images) == EXPECTED_IMAGE_URLS, f"image urls={len(images)}"

    image_ids = {i["canonical_property_id"] for i in images}
    assert image_ids <= set(ids), "image rows reference unknown properties"
    assert len(image_ids) == EXPECTED_WITH_IMAGES, f"image-bearing ids={len(image_ids)}"

    for p in properties:
        assert p["sample_class"] == "U", f"{p['canonical_property_id']} is not U-class"
        assert p["property_availability_status"] == "UNKNOWN_NOT_VERIFIED"
        assert num(p["latitude"]) is not None and num(p["longitude"]) is not None
        assert num(p["property_monthly_rental_myr"]) is not None
        assert num(p["property_built_up_sqft"]) and num(p["property_built_up_sqft"]) > 0
        assert num(p["research_p_association_score"]) is not None
        assert txt(p["subject_name"]), "missing property name"
        assert txt(p["property_property_address"]), "missing address"
        assert txt(p["property_source_listing_url"]), "missing source url"
        lat, lon = num(p["latitude"]), num(p["longitude"])
        assert 0.5 < lat < 8.0 and 99.0 < lon < 120.0, f"coords out of Malaysia: {lat},{lon}"


def main() -> int:
    properties, images = load_workbook_rows()
    assert_workbook(properties, images)
    print(f"[read] {len(properties)} properties, {len(images)} image urls")

    conn = psycopg2.connect(**DSN)
    conn.autocommit = False
    cur = conn.cursor()

    try:
        cur.execute("SELECT current_database()")
        db = cur.fetchone()[0]
        assert db == "Final_Location_Analysis", f"connected to {db}"

        # ---- pre-flight: what exists now -------------------------------
        cur.execute(
            "SELECT count(*) FROM fyp.rental_properties WHERE owner_id IS NULL"
        )
        imported_before = cur.fetchone()[0]
        cur.execute(
            "SELECT count(*) FROM fyp.rental_properties WHERE owner_id IS NOT NULL"
        )
        owner_before = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM sitewise_app.properties")
        catalogue_before = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM sitewise_analytics.subject_features")
        features_before = cur.fetchone()[0]
        print(
            f"[state] imported={imported_before} owner={owner_before} "
            f"catalogue={catalogue_before} features={features_before}"
        )
        assert features_before == EXPECTED_PU_ROWS, "PU feature rows already wrong"

        # ---- staging ---------------------------------------------------
        cur.execute("DROP SCHEMA IF EXISTS mig_stage CASCADE")
        cur.execute("CREATE SCHEMA mig_stage")
        cur.execute(
            """
            CREATE TABLE mig_stage.props (
                canonical_property_id text PRIMARY KEY,
                subject_id            text,
                name                  text,
                address               text,
                state                 text,
                district              text,
                property_type         text,
                rental_price          double precision,
                size_sqft             double precision,
                psf                   double precision,
                latitude              double precision,
                longitude             double precision,
                floor_level           double precision,
                unit_position         text,
                frontage_ft           double precision,
                depth_ft              double precision,
                land_area_sqft        double precision,
                tenure                text,
                facing_direction      text,
                availability          text,
                source_platform       text,
                source_listing_id     text,
                source_url            text,
                primary_image_url     text,
                image_status          text,
                valid_image_count     integer,
                research_score        double precision,
                score_type            text,
                source_row            integer,
                source_data           jsonb
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE mig_stage.images (
                canonical_property_id text NOT NULL,
                url                   text NOT NULL,
                image_rank            integer,
                is_primary            boolean,
                image_source          text
            )
            """
        )

        prop_rows = []
        for p in properties:
            cid = txt(p["canonical_property_id"])
            source_data = {k: p.get(k) for k in SOURCE_DATA_KEYS if k in p}
            prop_rows.append(
                (
                    cid,
                    txt(p.get("subject_id")),
                    txt(p["subject_name"]),
                    txt(p["property_property_address"]),
                    txt(p["state_dosm"]),
                    txt(p.get("district")),
                    txt(p["property_type"]),
                    num(p["property_monthly_rental_myr"]),
                    num(p["property_built_up_sqft"]),
                    num(p["property_rental_psf_myr_per_sqft_month"]),
                    num(p["latitude"]),
                    num(p["longitude"]),
                    num(p.get("property_floor_level")),
                    txt(p.get("property_unit_position")),
                    num(p.get("property_frontage_ft")),
                    num(p.get("property_depth_ft")),
                    num(p.get("property_land_area_sqft")),
                    txt(p.get("property_tenure")),
                    txt(p.get("property_facing_direction")),
                    txt(p["property_availability_status"]),
                    txt(p.get("property_source_platform")),
                    txt(p.get("property_source_listing_id")),
                    txt(p["property_source_listing_url"]),
                    txt(p.get("primary_image_url")),
                    txt(p.get("image_status")),
                    int(num(p.get("valid_image_count")) or 0),
                    num(p["research_p_association_score"]),
                    txt(p.get("score_type")),
                    p["_source_row"],
                    json.dumps(source_data, default=str),
                )
            )

        execute_values(
            cur,
            """
            INSERT INTO mig_stage.props VALUES %s
            """,
            prop_rows,
            page_size=500,
        )

        execute_values(
            cur,
            "INSERT INTO mig_stage.images "
            "(canonical_property_id, url, image_rank, is_primary, image_source) VALUES %s",
            [
                (i["canonical_property_id"], i["url"], i["rank"], i["is_primary"], i["source"])
                for i in images
            ],
            page_size=500,
        )
        print("[stage] rows loaded")

        # ---- 1. fyp.rental_properties : update the 955 imported rows ----
        cur.execute(
            """
            UPDATE fyp.rental_properties r SET
                name             = s.name,
                property_type    = s.property_type,
                address          = s.address,
                state            = s.state,
                latitude         = s.latitude,
                longitude        = s.longitude,
                rental_price     = s.rental_price,
                size_sqft        = s.size_sqft,
                psf              = s.psf,
                built_up_sqft    = s.size_sqft,
                land_area_sqft   = s.land_area_sqft,
                floor_level      = s.floor_level,
                unit_position    = s.unit_position,
                frontage_ft      = s.frontage_ft,
                depth_ft         = s.depth_ft,
                tenure           = s.tenure,
                facing_direction = s.facing_direction,
                availability     = s.availability,
                updated_at       = now()
            FROM mig_stage.props s
            WHERE r.listing_id = s.canonical_property_id
              AND r.owner_id IS NULL
            """
        )
        rp_updated = cur.rowcount
        print(f"[rental_properties] updated {rp_updated}")

        # Insert any workbook property that has no operational row yet.
        cur.execute(
            """
            INSERT INTO fyp.rental_properties
                (listing_id, name, property_type, address, state, latitude, longitude,
                 rental_price, size_sqft, psf, built_up_sqft, land_area_sqft,
                 floor_level, unit_position, frontage_ft, depth_ft, tenure,
                 facing_direction, availability, verification_status, is_published,
                 created_at, updated_at)
            SELECT s.canonical_property_id, s.name, s.property_type, s.address, s.state,
                   s.latitude, s.longitude, s.rental_price, s.size_sqft, s.psf,
                   s.size_sqft, s.land_area_sqft, s.floor_level, s.unit_position,
                   s.frontage_ft, s.depth_ft, s.tenure, s.facing_direction, s.availability,
                   'pending', false, now(), now()
            FROM mig_stage.props s
            WHERE NOT EXISTS (
                SELECT 1 FROM fyp.rental_properties r
                WHERE r.listing_id = s.canonical_property_id
            )
            """
        )
        rp_inserted = cur.rowcount
        print(f"[rental_properties] inserted {rp_inserted}")

        # ---- 2. fyp.property_photos : rebuild images for the 955 --------
        cur.execute(
            """
            DELETE FROM fyp.property_photos p
            USING fyp.rental_properties r
            WHERE p.property_id = r.id AND r.owner_id IS NULL
            """
        )
        photos_deleted = cur.rowcount
        cur.execute(
            """
            INSERT INTO fyp.property_photos (property_id, url, caption, is_primary, created_at)
            SELECT r.id, i.url,
                   CASE WHEN i.is_primary THEN 'Primary listing image'
                        ELSE 'Listing image ' || i.image_rank END,
                   i.is_primary, now()
            FROM mig_stage.images i
            JOIN fyp.rental_properties r
              ON r.listing_id = i.canonical_property_id AND r.owner_id IS NULL
            """
        )
        photos_inserted = cur.rowcount
        print(f"[property_photos] deleted {photos_deleted}, inserted {photos_inserted}")
        assert photos_inserted == EXPECTED_IMAGE_URLS

        # ---- 3. fyp.property_listing_sources ---------------------------
        cur.execute(
            """
            UPDATE fyp.property_listing_sources l SET
                source_platform   = s.source_platform,
                source_listing_id = s.source_listing_id,
                source_url        = s.source_url,
                source_availability = s.availability
            FROM mig_stage.props s
            JOIN fyp.rental_properties r
              ON r.listing_id = s.canonical_property_id AND r.owner_id IS NULL
            WHERE l.property_id = r.id
            """
        )
        sources_updated = cur.rowcount
        print(f"[property_listing_sources] updated {sources_updated}")

        cur.execute(
            """
            INSERT INTO fyp.property_listing_sources
                (property_id, source_platform, source_listing_id, source_url,
                 source_availability, usage_rights_note)
            SELECT r.id, s.source_platform, s.source_listing_id, s.source_url,
                   s.availability,
                   'Imported from the SiteWise PU research workbook; platform '
                   'reuse and current availability must be verified before display.'
            FROM mig_stage.props s
            JOIN fyp.rental_properties r
              ON r.listing_id = s.canonical_property_id AND r.owner_id IS NULL
            WHERE NOT EXISTS (
                SELECT 1 FROM fyp.property_listing_sources l WHERE l.property_id = r.id
            )
            """
        )
        sources_inserted = cur.rowcount
        print(f"[property_listing_sources] inserted {sources_inserted}")

        # ---- 4. fyp.property_subject_links -----------------------------
        cur.execute(
            """
            UPDATE fyp.property_subject_links l SET
                subject_id           = s.subject_id,
                sitewise_property_id = s.canonical_property_id,
                match_method         = 'WORKBOOK_EXACT_CANONICAL_ID',
                match_evidence       = 'canonical_property_id == subject_id in '
                                       'SiteWise_PU_Property_Image_Scores_Merged (1).xlsx',
                match_verified       = true,
                verified_at          = COALESCE(l.verified_at, now())
            FROM mig_stage.props s
            JOIN fyp.rental_properties r
              ON r.listing_id = s.canonical_property_id AND r.owner_id IS NULL
            WHERE l.property_id = r.id
            """
        )
        links_updated = cur.rowcount
        print(f"[property_subject_links] updated {links_updated}")

        cur.execute(
            """
            INSERT INTO fyp.property_subject_links
                (property_id, subject_id, sitewise_property_id, match_method,
                 match_evidence, match_verified, linked_at, verified_at)
            SELECT r.id, s.subject_id, s.canonical_property_id,
                   'WORKBOOK_EXACT_CANONICAL_ID',
                   'canonical_property_id == subject_id in '
                   'SiteWise_PU_Property_Image_Scores_Merged (1).xlsx',
                   true, now(), now()
            FROM mig_stage.props s
            JOIN fyp.rental_properties r
              ON r.listing_id = s.canonical_property_id AND r.owner_id IS NULL
            WHERE NOT EXISTS (
                SELECT 1 FROM fyp.property_subject_links l WHERE l.property_id = r.id
            )
            """
        )
        links_inserted = cur.rowcount
        print(f"[property_subject_links] inserted {links_inserted}")

        # ---- 5. sitewise_app.properties : replace the catalogue --------
        cur.execute(
            """
            INSERT INTO sitewise_app.properties
                (id, title, address, city, state, postcode, rental_rm, size_sqft,
                 latitude, longitude, property_type, image_url, source_url,
                 suitability_score, dataset_validation, source_workbook,
                 source_sheet, source_row, source_data, imported_at)
            SELECT s.canonical_property_id, s.name, s.address, '', s.state, '',
                   s.rental_price, s.size_sqft, s.latitude, s.longitude,
                   s.property_type, s.primary_image_url, s.source_url,
                   s.research_score * 100, %s, %s, %s, s.source_row,
                   s.source_data, now()
            FROM mig_stage.props s
            ON CONFLICT (id) DO UPDATE SET
                title              = EXCLUDED.title,
                address            = EXCLUDED.address,
                city               = EXCLUDED.city,
                state              = EXCLUDED.state,
                postcode           = EXCLUDED.postcode,
                rental_rm          = EXCLUDED.rental_rm,
                size_sqft          = EXCLUDED.size_sqft,
                latitude           = EXCLUDED.latitude,
                longitude          = EXCLUDED.longitude,
                property_type      = EXCLUDED.property_type,
                image_url          = EXCLUDED.image_url,
                source_url         = EXCLUDED.source_url,
                suitability_score  = EXCLUDED.suitability_score,
                dataset_validation = EXCLUDED.dataset_validation,
                source_workbook    = EXCLUDED.source_workbook,
                source_sheet       = EXCLUDED.source_sheet,
                source_row         = EXCLUDED.source_row,
                source_data        = EXCLUDED.source_data,
                imported_at        = now()
            """,
            (DATASET_VALIDATION, WORKBOOK.name, SOURCE_SHEET),
        )
        catalogue_upserted = cur.rowcount
        print(f"[sitewise_app.properties] upserted {catalogue_upserted}")

        cur.execute(
            """
            DELETE FROM sitewise_app.properties p
            WHERE NOT EXISTS (
                SELECT 1 FROM mig_stage.props s WHERE s.canonical_property_id = p.id
            )
            """
        )
        catalogue_deleted = cur.rowcount
        print(f"[sitewise_app.properties] removed {catalogue_deleted} obsolete rows")

        # ---- 6. in-transaction verification ----------------------------
        checks = {}

        cur.execute(
            "SELECT count(*) FROM sitewise_app.properties WHERE id IN "
            "(SELECT canonical_property_id FROM mig_stage.props)"
        )
        checks["catalogue_matches_workbook"] = (cur.fetchone()[0], EXPECTED_PROPERTIES)

        cur.execute("SELECT count(*) FROM sitewise_app.properties")
        checks["catalogue_total"] = (cur.fetchone()[0], EXPECTED_PROPERTIES)

        cur.execute(
            "SELECT count(*) FROM fyp.rental_properties WHERE owner_id IS NULL"
        )
        checks["imported_rows"] = (cur.fetchone()[0], EXPECTED_PROPERTIES)

        cur.execute(
            "SELECT count(*) FROM fyp.rental_properties WHERE owner_id IS NOT NULL"
        )
        checks["owner_rows_preserved"] = (cur.fetchone()[0], owner_before)

        cur.execute(
            "SELECT count(*) FROM fyp.property_photos p "
            "JOIN fyp.rental_properties r ON r.id = p.property_id "
            "WHERE r.owner_id IS NULL"
        )
        checks["photos"] = (cur.fetchone()[0], EXPECTED_IMAGE_URLS)

        cur.execute(
            "SELECT count(DISTINCT r.listing_id) FROM fyp.property_photos p "
            "JOIN fyp.rental_properties r ON r.id = p.property_id "
            "WHERE r.owner_id IS NULL"
        )
        checks["properties_with_photos"] = (cur.fetchone()[0], EXPECTED_WITH_IMAGES)

        cur.execute("SELECT count(*) FROM fyp.property_subject_links")
        checks["subject_links"] = (cur.fetchone()[0], EXPECTED_PROPERTIES)

        cur.execute(
            "SELECT count(*) FROM fyp.property_subject_links l "
            "JOIN sitewise_app.properties p ON p.id = l.sitewise_property_id"
        )
        checks["links_resolve_to_catalogue"] = (cur.fetchone()[0], EXPECTED_PROPERTIES)

        cur.execute("SELECT count(*) FROM sitewise_analytics.subject_features")
        checks["pu_features"] = (cur.fetchone()[0], EXPECTED_PU_ROWS)

        cur.execute(
            "SELECT count(*) FROM sitewise_analytics.subject_features "
            "WHERE sample_class = 'P'"
        )
        checks["p_class"] = (cur.fetchone()[0], EXPECTED_P_CLASS)

        cur.execute(
            "SELECT count(*) FROM sitewise_analytics.subject_features "
            "WHERE sample_class = 'U' AND canonical_property_id IS NOT NULL"
        )
        checks["u_class"] = (cur.fetchone()[0], EXPECTED_U_CLASS)

        cur.execute(
            "SELECT count(*) FROM sitewise_analytics.subject_features f "
            "WHERE f.canonical_property_id IS NOT NULL AND NOT EXISTS ("
            "  SELECT 1 FROM mig_stage.props s "
            "  WHERE s.canonical_property_id = f.canonical_property_id)"
        )
        checks["orphan_features"] = (cur.fetchone()[0], 0)

        cur.execute(
            "SELECT count(*) FROM fyp.property_listing_sources"
        )
        checks["listing_sources"] = (cur.fetchone()[0], EXPECTED_PROPERTIES)

        cur.execute(
            "SELECT count(*) FROM sitewise_app.properties WHERE image_url IS NOT NULL"
        )
        checks["catalogue_with_image"] = (cur.fetchone()[0], EXPECTED_WITH_IMAGES)

        cur.execute(
            "SELECT count(*) FROM sitewise_app.properties "
            "WHERE suitability_score < 0 OR suitability_score > 100"
        )
        checks["score_in_range"] = (cur.fetchone()[0], 0)

        failed = False
        for name, (actual, expected) in checks.items():
            ok = actual == expected
            failed |= not ok
            print(f"  [{'ok ' if ok else 'FAIL'}] {name}: {actual} (expected {expected})")

        if failed:
            raise RuntimeError("in-transaction verification failed")

        conn.commit()
        print("[commit] migration committed")
        print(
            json.dumps(
                {
                    "catalogue_before": catalogue_before,
                    "catalogue_after": checks["catalogue_total"][0],
                    "obsolete_removed": catalogue_deleted,
                    "photos": photos_inserted,
                    "rental_updated": rp_updated,
                    "rental_inserted": rp_inserted,
                    "sources_updated": sources_updated,
                    "links_updated": links_updated,
                },
                indent=2,
            )
        )
        return 0

    except Exception:
        conn.rollback()
        print("[rollback] migration rolled back", file=sys.stderr)
        raise
    finally:
        try:
            cur.execute("DROP SCHEMA IF EXISTS mig_stage CASCADE")
            conn.commit()
        except Exception:
            pass
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
