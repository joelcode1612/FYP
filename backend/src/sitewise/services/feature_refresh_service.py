"""SiteWise P1: full-study-property coverage + real population recomputation.

Drop-in replacement for backend/src/sitewise/services/feature_refresh_service.py.

Scope:
* Existing 500m/1km competitor contract, SQL tables and public methods preserved.
* Overture is ingested REGION BY REGION using the existing collector/synchronizer.
  Its collector MUST be patched to page the S3 listing and fail on truncation
  (see accompanying overture_collector_p1_patch.py).
* WorldPop population is recomputed from a **verified, local, population-per-
  pixel GeoTIFF**; it is never fabricated from DOSM district totals.
* Official DOSM district estimates can separately be synchronised from DOSM.
* Geographic coverage is audited for every state containing rental properties.

This module does NOT automatically claim full statewide polygon coverage: the
calculated bounding boxes cover the known rental properties and their catchments.
Use an authoritative study-area polygon when state-wide completeness is required.
"""
from __future__ import annotations

import csv
import hashlib
import io
import logging
import math
import urllib.request
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from sqlalchemy import text
from sqlmodel import Session

from sitewise.ingestion.config import RefreshConfig
from sitewise.ingestion.state import RefreshState
from sitewise.repositories.fyp_property_repository import FypPropertyRepository

logger = logging.getLogger("sitewise.feature_refresh")
DOSM_URL = "https://storage.dosm.gov.my/population/population_district.csv"
STUDY_STATES = frozenset({"Selangor", "Johor", "Pulau Pinang", "W.P. Kuala Lumpur"})


def _valid_coordinates(lat: Any, lon: Any) -> bool:
    try:
        return all(math.isfinite(float(x)) for x in (lat, lon)) and -90 <= float(lat) <= 90 and -180 <= float(lon) <= 180
    except (TypeError, ValueError):
        return False


def _normalized_state(state: str | None) -> str:
    s = " ".join((state or "").strip().split())
    key = s.casefold().replace("wilayah persekutuan", "w.p.")
    if key in {"kuala lumpur", "w.p. kuala lumpur", "wp kuala lumpur", "w.p. wilayah kuala lumpur"}:
        return "W.P. Kuala Lumpur"
    if key in {"penang", "pulau pinang"}:
        return "Pulau Pinang"
    if key == "johor":
        return "Johor"
    if key == "selangor":
        return "Selangor"
    return s or "UNKNOWN"


class FeatureRefreshService:
    def __init__(self, session: Session, config: RefreshConfig | None = None):
        self.session = session
        self.config = config or RefreshConfig()
        self.repo = FypPropertyRepository(session)
        self.state = RefreshState(session)

    # ------------------------------------------------------------------
    # Existing affected-property and competitor/demand refresh interface
    # ------------------------------------------------------------------
    def affected_property_ids(
        self, points: Sequence[tuple[float, float]], radius_m: int | None = None
    ) -> list[int]:
        radius = int(radius_m or self.config.influence_radius_m)
        if radius <= 0:
            raise ValueError("radius_m must be positive")
        unique = sorted({(round(lat, 7), round(lon, 7)) for lat, lon in points
                         if _valid_coordinates(lat, lon)})
        found: set[int] = set()
        for start in range(0, len(unique), 400):
            chunk = unique[start:start + 400]
            rows = self.session.execute(text("""
                SELECT DISTINCT p.id FROM fyp.rental_properties p
                JOIN unnest(CAST(:lats AS double precision[]),
                            CAST(:lons AS double precision[])) AS c(lat,lon) ON true
                WHERE p.geom IS NOT NULL
                  AND p.geom && ST_Expand(
                    ST_SetSRID(ST_MakePoint(c.lon,c.lat),4326),:pad)
                  AND ST_DWithin(p.geom::geography,
                    ST_SetSRID(ST_MakePoint(c.lon,c.lat),4326)::geography,:radius)
            """), {
                "lats": [x[0] for x in chunk], "lons": [x[1] for x in chunk],
                # Longitude degree width expands toward the poles; do not use a
                # too-small bbox predicate that misses valid geodesic matches.
                "pad": radius * 1.05 / (111_320 * min(
                    max(abs(math.cos(math.radians(lat))), 0.1) for lat, _ in chunk)),
                "radius": float(radius),
            }).scalars().all()
            found.update(int(r) for r in rows)
        return sorted(found)

    def recalculate(self, property_ids: Iterable[int], *,
                    reason: str = "source_change", source_release: str | None = None) -> dict:
        ids = list(dict.fromkeys(int(i) for i in property_ids))
        result = {"properties_affected": len(ids), "properties_recalculated": 0,
                  "successful_computations": 0, "failed_computations": 0, "errors": []}
        for property_id in ids:
            try:
                self.state.set_freshness(property_id, status="pending",
                    version=self.config.calculation_version, source_release=source_release)
                row = self.session.execute(text("""
                    SELECT id,latitude,longitude FROM fyp.rental_properties WHERE id=:pid
                """), {"pid": property_id}).mappings().first()
                if row is None or not _valid_coordinates(row["latitude"], row["longitude"]):
                    self.state.set_freshness(property_id, status="unavailable",
                        version=self.config.calculation_version,
                        error="property_or_coordinates_missing")
                    result["failed_computations"] += 1
                    result["errors"].append(f"{property_id}: coordinates unavailable")
                    continue
                snapshot = self.repo.enrichment_snapshot(
                    float(row["latitude"]), float(row["longitude"]))
                if snapshot.get("competitor_status") != "ok":
                    raise RuntimeError("competitor computation reported unavailable")
                previous = self.session.execute(text("""
                    SELECT population_500m,population_1km
                    FROM fyp.property_geospatial_features
                    WHERE property_id=:pid ORDER BY id DESC LIMIT 1
                """), {"pid": property_id}).first()
                if previous is not None:
                    for ix, field in enumerate(("population_500m", "population_1km")):
                        if snapshot.get(field) is None and previous[ix] is not None:
                            snapshot[field] = previous[ix]
                            snapshot["population_status"] = "preserved"
                self.repo.upsert_geospatial_features(property_id, snapshot)
                self.state.set_freshness(property_id, status="current",
                    version=self.config.calculation_version,
                    source_release=source_release, success=True)
                result["properties_recalculated"] += 1
                result["successful_computations"] += 1
            except Exception as exc:
                self.session.rollback()
                logger.exception("feature calculation failed for %s", property_id)
                message = f"{property_id}: {type(exc).__name__}: {str(exc)[:200]}"
                self.state.set_freshness(property_id, status="failed",
                    version=self.config.calculation_version, error=message)
                result["failed_computations"] += 1
                result["errors"].append(message)
        logger.info("feature refresh (%s): %d successful, %d failed", reason,
                    result["successful_computations"], result["failed_computations"])
        return result

    def recalculate_new_property(self, property_id: int,
                                 source_release: str | None = None) -> dict:
        return self.recalculate([property_id], reason="new_property",
                                source_release=source_release)

    def refresh_for_changed_outlets(self, points: Sequence[tuple[float, float]],
                                    source_release: str | None = None) -> dict:
        affected = self.affected_property_ids(points)
        return self.recalculate(affected, reason="outlet_change", source_release=source_release)

    def stale_property_ids(self, older_than_hours: int = 24 * 7) -> list[int]:
        rows = self.session.execute(text("""
            SELECT property_id FROM fyp.property_feature_freshness
            WHERE refresh_status IN ('pending','failed')
               OR (refresh_status='stale'
                   AND updated_at < now() - (:hours || ' hours')::interval)
            ORDER BY updated_at ASC LIMIT 500
        """), {"hours": str(int(older_than_hours))}).scalars().all()
        return [int(r) for r in rows]

    def mark_stale_for_source_change(self, points: Sequence[tuple[float, float]]) -> int:
        affected = self.affected_property_ids(points)
        for pid in affected:
            self.session.execute(text("""
                INSERT INTO fyp.property_feature_freshness
                    (property_id,refresh_status,calculation_version,last_refresh_attempt_at)
                VALUES (:pid,'stale',:version,now())
                ON CONFLICT (property_id) DO UPDATE SET
                    refresh_status=CASE WHEN
                    fyp.property_feature_freshness.refresh_status IN ('failed','unavailable')
                    THEN fyp.property_feature_freshness.refresh_status ELSE 'stale' END,
                    updated_at=now()
            """), {"pid": pid, "version": self.config.calculation_version})
        self.session.commit()
        return len(affected)

    @staticmethod
    def attempted_at() -> str:
        return datetime.now(UTC).isoformat()

    # ------------------------------------------------------------------
    # Coverage: all states in the operational property corpus, not just
    # the previously tested box. No empty-data-is-success assumptions.
    # ------------------------------------------------------------------
    def study_region_bboxes(self, *, buffer_m: float = 1500,
                            states: Iterable[str] | None = None) -> dict[str, tuple]:
        """Return property-extents + buffer, NOT authoritative state boundaries."""
        wanted = {_normalized_state(x) for x in (states or STUDY_STATES)}
        rows = self.session.execute(text("""
            SELECT state, latitude, longitude FROM fyp.rental_properties
            WHERE latitude IS NOT NULL AND longitude IS NOT NULL
        """)).mappings().all()
        grouped: dict[str, list[tuple[float, float]]] = {}
        for row in rows:
            state = _normalized_state(row["state"])
            if state in wanted and _valid_coordinates(row["latitude"], row["longitude"]):
                grouped.setdefault(state, []).append(
                    (float(row["latitude"]), float(row["longitude"])))
        missing = wanted - grouped.keys()
        if missing:
            raise ValueError(f"Study regions lack valid property coordinates: {sorted(missing)}")
        result = {}
        for state, coords in grouped.items():
            min_lat = min(lat for lat, _ in coords)
            max_lat = max(lat for lat, _ in coords)
            min_lon = min(lon for _, lon in coords)
            max_lon = max(lon for _, lon in coords)
            pad_lat = buffer_m / 110_574
            pad_lon = buffer_m / (111_320 * max(.1, math.cos(math.radians(max(abs(min_lat), abs(max_lat))))))
            result[state] = (min_lon - pad_lon, min_lat - pad_lat,
                             max_lon + pad_lon, max_lat + pad_lat)
        return result

    def coverage_audit(self, *, expected_states: Iterable[str] | None = None) -> dict:
        """Database counts by study state. Counts are NOT proof of area completeness."""
        wanted = {_normalized_state(s) for s in (expected_states or STUDY_STATES)}
        rows = self.session.execute(text("""
            SELECT p.id, p.state, p.latitude, p.longitude,
                   g.population_500m, g.population_1km,
                   g.competitor_count_500m, g.competitor_count_1km,
                   f.refresh_status
            FROM fyp.rental_properties p
            LEFT JOIN LATERAL (
                SELECT population_500m,population_1km,
                       competitor_count_500m,competitor_count_1km
                FROM fyp.property_geospatial_features
                WHERE property_id=p.id ORDER BY id DESC LIMIT 1
            ) g ON true
            LEFT JOIN fyp.property_feature_freshness f ON f.property_id=p.id
        """)).mappings().all()
        summary: dict[str, dict] = {}
        for row in rows:
            name = _normalized_state(row["state"])
            if name not in wanted:
                continue
            stat = summary.setdefault(name, {"properties": 0, "valid_coordinates": 0,
                "both_population_radii": 0, "both_competitor_radii": 0,
                "freshness_current": 0, "incomplete_ids": []})
            stat["properties"] += 1
            stat["valid_coordinates"] += int(_valid_coordinates(row["latitude"], row["longitude"]))
            has_pop = row["population_500m"] is not None and row["population_1km"] is not None
            has_comp = row["competitor_count_500m"] is not None and row["competitor_count_1km"] is not None
            stat["both_population_radii"] += int(has_pop)
            stat["both_competitor_radii"] += int(has_comp)
            stat["freshness_current"] += int(row["refresh_status"] == "current")
            if not has_pop or not has_comp:
                stat["incomplete_ids"].append(int(row["id"]))
        missing = sorted(wanted - summary.keys())
        return {"scope": "operational_property_coverage_not_full_state", "states": summary,
                "missing_states": missing,
                "all_property_features_present": bool(summary) and not missing and all(
                    s["properties"] > 0 and not s["incomplete_ids"] and
                    s["valid_coordinates"] == s["properties"] for s in summary.values()),
                "generated_at": self.attempted_at()}

    # ------------------------------------------------------------------
    # Overture full-part ingestion, using the SAME existing normalizer and
    # synchronizer. The companion collector patch makes truncation explicit.
    # ------------------------------------------------------------------
    def refresh_overture_regions(self, region_bboxes: Mapping[str, tuple] | None = None,
                                 *, release: str | None = None, dry_run: bool = True,
                                 max_records_per_region: int = 1_000_000) -> dict:
        from sitewise.ingestion.sources import OvertureCollector
        from sitewise.ingestion.overture_sync import OvertureSynchronizer
        from sitewise.ingestion.records import CollectorBlocked

        boxes = dict(region_bboxes or self.study_region_bboxes())
        if not boxes:
            raise ValueError("No study regions available")
        # Resolve ONE release for every state, preventing mixed-release data.
        master = OvertureCollector(self.config)
        resolved = release or self.config.overture_release
        if not resolved:
            resolved = master.available_releases()[-1]
        output = {"release": resolved, "dry_run": dry_run, "regions": {},
                  "status": "complete", "changed_points": 0,
                  "coverage_scope": "study_property_extents_plus_buffer"}
        for region, bbox in boxes.items():
            cfg = replace(self.config, bbox=tuple(bbox), overture_release=resolved,
                          max_overture_parts=1_000_000,
                          max_records_per_source=max_records_per_region)
            try:
                result = OvertureCollector(cfg).collect(resolved)
                if result.stats.records_accepted >= max_records_per_region:
                    raise RuntimeError("record limit reached; coverage incomplete")
                # Empty rows are NOT evidence that all Overture partitions were read.
                if not result.source_metadata.get("all_parts_verified", False):
                    raise RuntimeError(
                        "Overture collector did not verify the complete paginated "
                        "part listing. Apply overture_collector_p1_patch.py first.")
                stats = {"status": "collected", "bbox": list(bbox),
                         "records_downloaded": result.stats.records_downloaded,
                         "records_accepted": result.stats.records_accepted,
                         "parts_read": result.source_metadata.get("parts_read", 0),
                         "parts_total": result.source_metadata.get("parts_total", 0)}
                if not dry_run:
                    sync = OvertureSynchronizer(self.session, cfg).sync(
                        result.records, result.stats)
                    self.state.record_snapshot(source_name=f"overture:{region}",
                        release=resolved, snapshot_at=result.snapshot_at,
                        licence=result.licence, checksum=result.checksum,
                        stats=result.stats.as_dict(), status="current")
                    stats["status"] = "synchronized"
                    stats["records_inserted"] = result.stats.records_inserted
                    stats["records_updated"] = result.stats.records_updated
                    stats["changed_points"] = len(sync.changed_points)
                    output["changed_points"] += len(sync.changed_points)
                    if sync.changed_points:
                        self.mark_stale_for_source_change(sync.changed_points)
                output["regions"][region] = stats
            except Exception as exc:
                self.session.rollback()
                output["regions"][region] = {"status": "failed", "bbox": list(bbox),
                    "error": f"{type(exc).__name__}: {str(exc)[:300]}"}
                output["status"] = "partial_failed"
                logger.exception("Overture region failed: %s", region)
        return output

    # ------------------------------------------------------------------
    # Real population refresh. Only a raster whose pixels represent PERSONS
    # (not density/persons-per-km2) is valid here.
    # ------------------------------------------------------------------
    @staticmethod
    def _population_at_radius(raster: Any, lat: float, lon: float,
                              radius_m: int) -> tuple[float, float]:
        import numpy as np
        from pyproj import Geod
        from rasterio.features import geometry_mask
        from rasterio.mask import mask
        from rasterio.warp import transform_geom
        from rasterio.errors import WindowError

        geod = Geod(ellps="WGS84")
        azimuths = [i * 360.0 / 144 for i in range(144)]
        lons, lats, _ = geod.fwd([lon] * 144, [lat] * 144,
                                azimuths, [radius_m] * 144)
        ring = list(zip(lons, lats))
        ring.append(ring[0])
        geom = {"type": "Polygon", "coordinates": [ring]}
        if raster.crs.to_epsg() != 4326:
            geom = transform_geom("EPSG:4326", raster.crs, geom)
        # mask(...filled=False) excludes nodata but doesn't expose the number
        # of pixels inside the catchment. Use an independent geometry mask for QC.
        try:
            image, tr = mask(raster, [geom], indexes=[1], crop=True,
                             all_touched=False, filled=False)
        except (ValueError, WindowError) as exc:
            raise ValueError("population raster does not cover this catchment") from exc
        inside = geometry_mask([geom], out_shape=image.shape[-2:],
                               transform=tr, invert=True, all_touched=False)
        pixels = image[0]
        valid = inside & ~np.ma.getmaskarray(pixels) & np.isfinite(pixels.data)
        total = int(np.count_nonzero(inside))
        covered = int(np.count_nonzero(valid))
        if not total or not covered:
            raise ValueError("no valid population pixels in catchment")
        population = float(np.sum(pixels.data[valid], dtype=np.float64))
        if not math.isfinite(population) or population < 0:
            raise ValueError("population pixel values invalid")
        return population, covered / total

    def refresh_population_only(self, property_ids: Iterable[int], *,
                                raster_path: str | Path | None = None,
                                source_release: str | None = None,
                                min_coverage: float = .98) -> dict:
        """Recalculate WorldPop 500m & 1km when raster supplied.

        Backwards-compatible: without a raster, retain old mark-stale behavior,
        but explicitly say no population values were computed.
        """
        ids = list(dict.fromkeys(int(i) for i in property_ids))
        if not raster_path:
            for pid in ids:
                self.session.execute(text("""
                    UPDATE fyp.property_feature_freshness SET
                    source_release=COALESCE(:release,source_release),
                    refresh_status=CASE WHEN refresh_status='failed' THEN 'failed'
                                        ELSE 'stale' END,
                    updated_at=now() WHERE property_id=:pid
                """), {"pid": pid, "release": "population-dataset"})
            self.session.commit()
            return {"population_properties_flagged": len(ids),
                    "population_properties_recomputed": 0,
                    "competitor_recomputations": 0,
                    "status": "stale_only_no_raster_supplied"}
        if not source_release or not source_release.strip():
            raise ValueError("source_release is required for a population recomputation")
        if not 0 < min_coverage <= 1:
            raise ValueError("min_coverage must be in (0,1]")
        source = Path(raster_path).resolve()
        if not source.is_file():
            raise FileNotFoundError(source)
        import rasterio
        totals: dict[str, Any] = {"status": "completed", "source": str(source),
                                  "source_release": source_release,
                                  "population_properties_requested": len(ids),
                                  "population_properties_recomputed": 0,
                                  "population_properties_failed": 0,
                                  "competitor_recomputations": 0, "errors": []}
        # Population provenance is independent from the combined competitor
        # freshness state; a population refresh must not mark all features current.
        self.session.execute(text("""
            CREATE TABLE IF NOT EXISTS fyp_features.property_population_refresh (
                property_id bigint PRIMARY KEY,
                population_source text NOT NULL,
                source_release text NOT NULL,
                coverage_500m double precision,
                coverage_1km double precision,
                status text NOT NULL,
                error text,
                refreshed_at timestamptz NOT NULL DEFAULT now()
            )
        """))
        self.session.commit()
        with rasterio.open(source) as raster:
            if not raster.crs or raster.count < 1:
                raise ValueError("population raster requires CRS and at least one band")
            for pid in ids:
                try:
                    row = self.session.execute(text("""
                        SELECT latitude, longitude FROM fyp.rental_properties WHERE id=:pid
                    """), {"pid": pid}).mappings().first()
                    if row is None or not _valid_coordinates(row["latitude"], row["longitude"]):
                        raise ValueError("missing or invalid property coordinates")
                    lat, lon = float(row["latitude"]), float(row["longitude"])
                    p500, c500 = self._population_at_radius(raster, lat, lon, 500)
                    p1000, c1000 = self._population_at_radius(raster, lat, lon, 1000)
                    if min(c500, c1000) < min_coverage:
                        raise ValueError(
                            f"insufficient raster coverage: 500m={c500:.1%}, "
                            f"1km={c1000:.1%} (minimum {min_coverage:.1%})")
                    # Population-only update: leave all competitor and demand
                    # generator fields EXACTLY as they are.
                    updated = self.session.execute(text("""
                        UPDATE fyp.property_geospatial_features SET
                            population_500m=:p500, population_1km=:p1000,
                            last_calculated_at=now()
                        WHERE property_id=:pid
                    """), {"pid": pid, "p500": p500, "p1000": p1000}).rowcount
                    if not updated:
                        self.session.execute(text("""
                            INSERT INTO fyp.property_geospatial_features
                                (property_id,population_500m,population_1km,last_calculated_at)
                            VALUES (:pid,:p500,:p1000,now())
                        """), {"pid": pid, "p500": p500, "p1000": p1000})
                    # One atomic commit for population values and their own
                    # provenance; do not mark competitor/demand features current.
                    self.session.execute(text("""
                        INSERT INTO fyp_features.property_population_refresh
                            (property_id,population_source,source_release,
                             coverage_500m,coverage_1km,status,error,refreshed_at)
                        VALUES (:pid,'WorldPop',:release,:c500,:c1000,'current',NULL,now())
                        ON CONFLICT (property_id) DO UPDATE SET
                            population_source=EXCLUDED.population_source,
                            source_release=EXCLUDED.source_release,
                            coverage_500m=EXCLUDED.coverage_500m,
                            coverage_1km=EXCLUDED.coverage_1km,
                            status='current',error=NULL,refreshed_at=now()
                    """), {"pid": pid, "release": source_release,
                           "c500": c500, "c1000": c1000})
                    self.session.commit()
                    totals["population_properties_recomputed"] += 1
                except Exception as exc:
                    self.session.rollback()
                    logger.warning("population refresh failed for %s: %s", pid, exc)
                    totals["population_properties_failed"] += 1
                    totals["errors"].append(f"{pid}: {type(exc).__name__}: {str(exc)[:180]}")
                    # Preserve previously valid values and the combined
                    # feature status; only population source status fails.
                    self.session.execute(text("""
                        INSERT INTO fyp_features.property_population_refresh
                            (property_id,population_source,source_release,status,error)
                        VALUES (:pid,'WorldPop',:release,'failed',:error)
                        ON CONFLICT (property_id) DO UPDATE SET
                            status='failed', error=EXCLUDED.error,
                            refreshed_at=now()
                    """), {"pid": pid, "release": source_release,
                           "error": str(exc)[:160]})
                    self.session.commit()
        if totals["population_properties_failed"]:
            totals["status"] = "partial_failed"
        return totals

    # ------------------------------------------------------------------
    # Official government population (district totals, different resolution).
    # Never overwrite 500m/1km WorldPop values with district totals.
    # ------------------------------------------------------------------
    def refresh_official_dosm_districts(self, *, http_timeout: int = 40,
                                        dry_run: bool = True) -> dict:
        """Download/validate fresh official DOSM annual district data.

        When dry_run=False, write to a SEPARATE auditable reference table. The
        district figures are thousands in the source and converted to persons.
        """
        req = urllib.request.Request(DOSM_URL, headers={
            "User-Agent": "SiteWise-geospatial-refresh/1.0 (academic open-data use)"})
        with urllib.request.urlopen(req, timeout=http_timeout) as response:
            content = response.read(30_000_001)
        if len(content) > 30_000_000:
            raise RuntimeError("DOSM response exceeded 30MB guard")
        checksum = hashlib.sha256(content).hexdigest()
        reader = csv.DictReader(io.StringIO(content.decode("utf-8-sig")))
        if not {"date", "state", "district", "sex", "age", "ethnicity", "population"}.issubset(reader.fieldnames or []):
            raise ValueError("DOSM district population CSV schema changed")
        parsed = []
        for row in reader:
            if (row["sex"].strip().casefold() != "both" or
                row["age"].strip().casefold() != "overall" or
                row["ethnicity"].strip().casefold() != "overall"):
                continue
            year = int(row["date"][:4])
            value = float(row["population"]) * 1000  # DOSM unit is '000 persons
            if not math.isfinite(value) or value < 0:
                raise ValueError("Invalid DOSM population figure")
            parsed.append({"year": year, "state": row["state"].strip(),
                "district": row["district"].strip(), "persons": value})
        if not parsed:
            raise ValueError("No overall population rows returned by DOSM")
        latest = max(r["year"] for r in parsed)
        current = [r for r in parsed if r["year"] == latest]
        if len({(r["state"], r["district"]) for r in current}) != len(current):
            raise ValueError("Duplicate DOSM state/district/year rows")
        output = {"status": "validated_only" if dry_run else "synchronized",
                  "source": DOSM_URL, "year": latest, "district_rows": len(current),
                  "sha256": checksum, "written": 0,
                  "important": "District totals are NOT 500m/1km catchment estimates"}
        if dry_run:
            return output
        self.session.execute(text("""
            CREATE TABLE IF NOT EXISTS fyp_features.dosm_population_district (
                year integer NOT NULL, state text NOT NULL, district text NOT NULL,
                population_persons double precision NOT NULL,
                source_url text NOT NULL, source_sha256 text NOT NULL,
                retrieved_at timestamptz NOT NULL DEFAULT now(),
                PRIMARY KEY (year, state, district)
            )
        """))
        for row in current:
            self.session.execute(text("""
                INSERT INTO fyp_features.dosm_population_district (
                    year,state,district,population_persons,source_url,source_sha256)
                VALUES (:year,:state,:district,:persons,:url,:sha256)
                ON CONFLICT (year,state,district) DO UPDATE SET
                    population_persons=EXCLUDED.population_persons,
                    source_url=EXCLUDED.source_url,
                    source_sha256=EXCLUDED.source_sha256,
                    retrieved_at=now()
            """), {**row, "url": DOSM_URL, "sha256": checksum})
            output["written"] += 1
        self.session.commit()
        return output
