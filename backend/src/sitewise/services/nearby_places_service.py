"""Individual verified nearby locations behind the property map's markers.

The insights endpoint reports *how many* competitors, nearby places, transit
stops and parking facilities fall inside each catchment radius, but until now
the map could only show those totals, so the Property Detail page rendered
"totals only" chips. The individual coordinates were never missing — the four
source tables this service reads are the same tables the feature measurements
themselves are built from:

* ``fnb_a.fnb_outlet`` joined with ``fnb_a.outlet_labels_v2`` — F&B outlets
  whose coordinates passed the outlet pipeline, with per-outlet operating
  status and the evidence behind it;
* ``demand_gen.pois_master`` — the deduplicated POI table
  (``active_for_analysis``) covering schools, universities, malls,
  supermarkets, retail, offices and hospitals;
* ``fyp_features.gtfs_stops`` — GTFS transit stops joined with
  ``gtfs_stop_modes`` for bus/rail mode;
* ``public.psense_parking`` (``kept IS TRUE``) — parking facilities.

What this endpoint adds is the "where exactly" half. It deliberately does NOT
recompute the recorded radius counts: those stay owned by the insights
payload, so the map can show recorded totals and mapped locations side by
side. The two may legitimately differ (deduplication, status filtering,
coordinate gates), and the UI says so instead of pretending they match.

Straight-line distances are computed with ``ST_DistanceSphere`` from the
catalogue's own coordinate — the same origin the insights score describes.
Read-only, no new tables, no new data pipeline, no scoring.
"""

from __future__ import annotations

from typing import Any

from sqlalchemy import text
from sqlmodel import Session

# Per-category cap on returned locations. A 3 km catchment in central Kuala
# Lumpur holds ~2,500 POIs and ~1,900 F&B outlets; the map clusters markers
# but a multi-megabyte payload hurts more than it helps, so the nearest N are
# returned and `truncated` says so honestly.
_CAP_PER_CATEGORY = 800

_CATEGORY_SOURCES = {
    "competitors": "fnb_a.fnb_outlet joined with fnb_a.outlet_labels_v2",
    "demand_generators": "demand_gen.pois_master (active_for_analysis)",
    "accessibility": "fyp_features.gtfs_stops (GTFS feeds)",
    "parking": "public.psense_parking (kept IS TRUE)",
}

# One bbox prefilter keeps the exact distance check cheap; 1 degree of
# latitude is ~111.32 km, and longitude degrees only shrink from there.
_DEG_PER_METRE = 1.0 / 111_320.0

_COMPETITOR_SQL = """
SELECT 'fnb:' || o.outlet_id AS id,
       COALESCE(NULLIF(btrim(l.outlet_name), ''), 'Unnamed F&B outlet') AS name,
       o.outlet_category AS subtype,
       NULL AS detail,
       l.latitude AS lat,
       l.longitude AS lng,
       'osm' AS source,
       COALESCE(o.source_osm_id::text, o.source_record_id) AS source_id,
       CASE
         WHEN l.operating_status = 'LIKELY_OPEN' THEN 'likely_open'
         WHEN l.indep_closed_n > 0 THEN 'possibly_closed'
         ELSE 'unknown'
       END AS operating_status,
       l.operating_status_evidence AS status_evidence,
       (l.coordinate_validation_status = 'PASS') AS coords_verified,
       round(ST_DistanceSphere(
           ST_SetSRID(ST_MakePoint(l.longitude, l.latitude), 4326),
           ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)))::int AS distance_m,
       COALESCE(o.check_date::text, o.source_collection_timestamp::text) AS observed_at,
       count(*) OVER () AS total
FROM fnb_a.fnb_outlet o
JOIN fnb_a.outlet_labels_v2 l USING (outlet_key)
WHERE l.latitude IS NOT NULL
  AND l.longitude IS NOT NULL
  AND o.duplicate_resolution_status <> 'UNRESOLVED_AMBIGUOUS'
  AND l.latitude BETWEEN :lat - :pad AND :lat + :pad
  AND l.longitude BETWEEN :lon - :pad AND :lon + :pad
  AND ST_DistanceSphere(
      ST_SetSRID(ST_MakePoint(l.longitude, l.latitude), 4326),
      ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)) <= :radius_m
ORDER BY distance_m
LIMIT :cap
"""

_POI_SQL = """
SELECT 'osm:' || p.poi_pk AS id,
       COALESCE(NULLIF(btrim(p.name), ''), initcap(p.poi_category)) AS name,
       p.poi_category AS subtype,
       NULLIF(btrim(p.poi_subcategory), '') AS detail,
       p.latitude AS lat,
       p.longitude AS lng,
       p.source_platform AS source,
       p.src_id AS source_id,
       'open' AS operating_status,
       NULL AS status_evidence,
       NULL AS coords_verified,
       round(ST_DistanceSphere(
           ST_SetSRID(ST_MakePoint(p.longitude, p.latitude), 4326),
           ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)))::int AS distance_m,
       p.collected_at AS observed_at,
       count(*) OVER () AS total
FROM demand_gen.pois_master p
WHERE p.active_for_analysis
  AND p.latitude IS NOT NULL
  AND p.longitude IS NOT NULL
  AND p.latitude BETWEEN :lat - :pad AND :lat + :pad
  AND p.longitude BETWEEN :lon - :pad AND :lon + :pad
  AND ST_DistanceSphere(
      ST_SetSRID(ST_MakePoint(p.longitude, p.latitude), 4326),
      ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)) <= :radius_m
ORDER BY distance_m
LIMIT :cap
"""

# psense_parking carries two rows for some facilities (naming variance around
# the same OSM element), so markers are deduplicated on the OSM element and
# the nearest representative wins. `total` counts the deduplicated set.
_PARKING_SQL = """
SELECT id, name, subtype, detail, lat, lng, source, source_id,
       operating_status, status_evidence, coords_verified, distance_m, observed_at,
       count(*) OVER () AS total
FROM (
    SELECT 'park:' || p.facility_id AS id,
           COALESCE(NULLIF(btrim(p.name), ''), 'Parking facility') AS name,
           'parking' AS subtype,
           p.parking_kind AS detail,
           p.lat AS lat,
           p.lon AS lng,
           CASE WHEN p.source_kind LIKE 'OSM%' THEN 'osm' ELSE p.source_kind END AS source,
           COALESCE(p.osm_type || '/' || p.osm_id::text, p.facility_id) AS source_id,
           NULL AS operating_status,
           NULL AS status_evidence,
           NULL AS coords_verified,
           round(ST_DistanceSphere(
               ST_SetSRID(ST_MakePoint(p.lon, p.lat), 4326),
               ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)))::int AS distance_m,
           NULL AS observed_at,
           row_number() OVER (
               PARTITION BY COALESCE(p.osm_type || '/' || p.osm_id::text, p.facility_id)
               ORDER BY ST_DistanceSphere(
                   ST_SetSRID(ST_MakePoint(p.lon, p.lat), 4326),
                   ST_SetSRID(ST_MakePoint(:lon, :lat), 4326))
           ) AS rn
    FROM public.psense_parking p
    WHERE p.kept IS TRUE
      AND p.lat IS NOT NULL
      AND p.lon IS NOT NULL
      AND p.lat BETWEEN :lat - :pad AND :lat + :pad
      AND p.lon BETWEEN :lon - :pad AND :lon + :pad
      AND ST_DistanceSphere(
          ST_SetSRID(ST_MakePoint(p.lon, p.lat), 4326),
          ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)) <= :radius_m
) ranked
WHERE rn = 1
ORDER BY distance_m
LIMIT :cap
"""

_TRANSIT_SQL = """
SELECT 'gtfs:' || s.stop_uid AS id,
       COALESCE(NULLIF(btrim(s.name), ''), 'Transit stop') AS name,
       m.mode AS subtype,
       NULL AS detail,
       s.lat AS lat,
       s.lon AS lng,
       'gtfs:' || s.feed AS source,
       s.stop_id AS source_id,
       NULL AS operating_status,
       NULL AS status_evidence,
       NULL AS coords_verified,
       round(ST_DistanceSphere(
           ST_SetSRID(ST_MakePoint(s.lon, s.lat), 4326),
           ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)))::int AS distance_m,
       NULL AS observed_at,
       count(*) OVER () AS total
FROM fyp_features.gtfs_stops s
LEFT JOIN fyp_features.gtfs_stop_modes m USING (stop_uid)
WHERE s.lat IS NOT NULL
  AND s.lon IS NOT NULL
  AND s.lat BETWEEN :lat - :pad AND :lat + :pad
  AND s.lon BETWEEN :lon - :pad AND :lon + :pad
  AND ST_DistanceSphere(
      ST_SetSRID(ST_MakePoint(s.lon, s.lat), 4326),
      ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)) <= :radius_m
ORDER BY distance_m
LIMIT :cap
"""

_QUERIES = (
    ("competitors", _COMPETITOR_SQL),
    ("demand_generators", _POI_SQL),
    ("accessibility", _TRANSIT_SQL),
    ("parking", _PARKING_SQL),
)


class NearbyPlacesService:
    """Reads the individual verified locations around one catalogue origin."""

    def __init__(self, session: Session):
        self.session = session

    def nearby(self, lat: float | None, lon: float | None, radius_m: int) -> dict[str, Any]:
        """Places within ``radius_m`` of ``(lat, lon)``, nearest first.

        A missing origin is not an error: every category reports an honest
        zero and the caller shows its own "no usable coordinates" state. Each
        category carries its own totals so the UI can tell "no records in
        radius" (a measured absence) apart from "this category has no
        individual-coordinate source" (which does not occur here).
        """
        radius = int(radius_m)
        pad = radius * _DEG_PER_METRE
        args = {"lat": lat, "lon": lon, "radius_m": radius, "pad": pad}
        categories: dict[str, Any] = {}
        places: list[dict[str, Any]] = []
        for key, sql in _QUERIES:
            cap = _CAP_PER_CATEGORY
            if lat is None or lon is None:
                categories[key] = {
                    "returned": 0,
                    "total_in_radius": 0,
                    "truncated": False,
                    "source": _CATEGORY_SOURCES[key],
                }
                continue
            rows = self.session.execute(
                text(sql), {**args, "cap": cap + 1}
            ).mappings().all()
            truncated = len(rows) > cap
            rows = rows[:cap]
            total = int(rows[0]["total"]) if rows else 0
            categories[key] = {
                "returned": len(rows),
                "total_in_radius": total,
                "truncated": truncated,
                "source": _CATEGORY_SOURCES[key],
            }
            places.extend(self._place(key, row) for row in rows)
        places.sort(key=lambda place: (place["distance_m"], place["id"]))
        return {"radius_m": radius, "categories": categories, "places": places}

    def _place(self, category: str, row: Any) -> dict[str, Any]:
        return {
            "id": str(row["id"]),
            "name": row["name"],
            "category": category,
            "subtype": row["subtype"],
            "detail": row["detail"],
            "lat": float(row["lat"]),
            "lng": float(row["lng"]),
            "source": row["source"],
            "source_id": row["source_id"],
            "operating_status": row["operating_status"],
            "status_evidence": row["status_evidence"],
            "coords_verified": None if row["coords_verified"] is None else bool(row["coords_verified"]),
            "distance_m": int(row["distance_m"]),
            "observed_at": row["observed_at"],
        }
