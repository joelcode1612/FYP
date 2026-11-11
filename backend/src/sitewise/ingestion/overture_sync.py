"""Incremental Overture synchronization into its DEDICATED research table.

``fnb_a.overture_places`` is the Overture source in
``FypPropertyRepository.COMPETITOR_SOURCES``; writing Overture rows into
``fnb_a.fnb_outlet`` would silently change the OSM source, so this module
never does that. A confirmed MATCH against an OSM outlet is recorded in
``fnb_a.overture_match`` (the exact table the canonical merged view consults),
which suppresses the duplicate business in ``source='merged'`` queries.
"""

from __future__ import annotations

import json
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any

from sqlalchemy import text
from sqlmodel import Session

from sitewise.ingestion.config import RefreshConfig
from sitewise.ingestion.deduplicator import AMBIGUOUS, MATCH, classify_match, merged_provenance
from sitewise.ingestion.normalizer import normalize_name
from sitewise.ingestion.records import IngestionStats, SourceRecord
from sitewise.ingestion.state import RefreshState


@dataclass
class OvertureSyncResult:
    stats: IngestionStats
    changed_points: list[tuple[float, float]]


class OvertureSynchronizer:
    def __init__(self, session: Session, config: RefreshConfig | None = None):
        self.session = session
        self.config = config or RefreshConfig()
        self.state = RefreshState(session)

    @staticmethod
    def _overture_id(record: SourceRecord) -> str:
        return record.source_record_id.split("overture/", 1)[-1]

    def _existing(self, records: Sequence[SourceRecord]) -> dict[str, dict[str, Any]]:
        ids = [self._overture_id(r) for r in records]
        if not ids:
            return {}
        rows = self.session.execute(
            text(
                "SELECT overture_id, name_primary, basic_category, latitude, "
                "longitude, operating_status, overture_release "
                "FROM fnb_a.overture_places "
                "WHERE overture_id = ANY(CAST(:ids AS text[]))"
            ),
            {"ids": ids},
        ).mappings().all()
        return {str(r["overture_id"]): dict(r) for r in rows}

    def _candidates(self, record: SourceRecord) -> list[SourceRecord]:
        """Nearby OSM rows within the dedup radius (GIST + geography)."""
        pad = self.config.dedup_distance_m * 1.05 / 111_320.0
        rows = self.session.execute(
            text(
                """
                SELECT outlet_key, source_record_id, outlet_name, outlet_category,
                       latitude, longitude, addr_street
                FROM fnb_a.fnb_outlet
                WHERE geom IS NOT NULL
                  AND geom && ST_Expand(
                      ST_SetSRID(ST_MakePoint(:lon, :lat), 4326), :pad)
                  AND ST_DWithin(
                      geom::geography,
                      ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,
                      :radius)
                LIMIT 25
                """
            ),
            {
                "lon": record.longitude,
                "lat": record.latitude,
                "pad": pad,
                "radius": self.config.dedup_distance_m,
            },
        ).mappings().all()
        return [
            SourceRecord(
                source_name="openstreetmap",
                source_record_id=str(row["source_record_id"]),
                source_release="stored",
                source_snapshot_at="",
                source_licence="ODbL 1.0",
                name=str(row["outlet_name"] or ""),
                normalized_name=normalize_name(str(row["outlet_name"] or "")),
                category=str(row["outlet_category"] or ""),
                category_raw="",
                latitude=float(row["latitude"]),
                longitude=float(row["longitude"]),
                address=row["addr_street"],
            )
            for row in rows
            if row["latitude"] is not None and row["longitude"] is not None
        ]

    def _verified_ids(self) -> frozenset[str]:
        rows = self.session.execute(
            text(
                "SELECT source_provider || '/' || source_record_id "
                "FROM fnb_a.outlet_source_ids WHERE confirmed_at IS NOT NULL LIMIT 10000"
            )
        ).scalars().all()
        return frozenset(str(r) for r in rows)

    def sync(self, records: Sequence[SourceRecord], stats: IngestionStats) -> OvertureSyncResult:
        verified = self._verified_ids()
        existing = self._existing(records)
        changed: list[tuple[float, float]] = []
        for record in records:
            oid = self._overture_id(record)
            decision = classify_match(
                record, self._candidates(record), self.config, verified
            )
            independent: bool | None = True
            if decision.decision == MATCH:
                independent = False
                stats.duplicates_detected += 1
                self._record_match(record, decision)
                self._record_provenance(record, decision.evidence, "MATCH")
            elif decision.decision == AMBIGUOUS:
                independent = None  # UNKNOWN: never guessed as independent
                stats.ambiguous_matches += 1
                self.state.record_ambiguous(decision)
            old = existing.get(oid)
            changed_now = old is None or (
                (old.get("name_primary") or "") != record.name
                or (old.get("basic_category") or "") != record.category
                or abs(float(old.get("latitude") or 0) - record.latitude) > 1e-7
                or abs(float(old.get("longitude") or 0) - record.longitude) > 1e-7
                or (old.get("operating_status") or None) != record.operating_status
                or (old.get("overture_release") or "") != record.source_release
            )
            self._upsert_place(record, independent)
            if old is None:
                stats.records_inserted += 1
            elif changed_now:
                stats.records_updated += 1
            else:
                stats.records_unchanged += 1
            if changed_now:
                changed.append((record.latitude, record.longitude))
        self.session.commit()
        return OvertureSyncResult(stats=stats, changed_points=changed)

    def _record_match(self, record: SourceRecord, decision: Any) -> None:
        """Insert the MATCH row the merged competitor view reads."""
        if decision.matched_record_id is None:
            return
        key = self.session.execute(
            text(
                "SELECT outlet_key FROM fnb_a.fnb_outlet "
                "WHERE source_record_id = :rid ORDER BY outlet_key LIMIT 1"
            ),
            {"rid": decision.matched_record_id},
        ).scalar()
        if key is None:
            return
        self.session.execute(
            text(
                """
                INSERT INTO fnb_a.overture_match (
                    outlet_key, overture_id, dist_m, name_sim, decision, rule,
                    outlet_name, overture_name, overture_category,
                    overture_operating_status, overture_source_dataset
                ) VALUES (
                    :key, :oid, 0, :score, 'MATCH', 'geo_refresh_evidence_match',
                    NULL, :name, :category, :status, :release
                )
                ON CONFLICT (outlet_key, overture_id) DO NOTHING
                """
            ),
            {
                "key": key,
                "oid": self._overture_id(record),
                "score": decision.score,
                "name": record.name,
                "category": record.category,
                "status": record.operating_status,
                "release": record.source_release,
            },
        )

    def _record_provenance(self, record: SourceRecord, evidence: str, decision: str) -> None:
        provenance = merged_provenance(record, record)
        self.session.execute(
            text(
                "INSERT INTO fnb_a.duplicate_review "
                "(incoming_source_name, incoming_record_id, decision, evidence, "
                "score, resolution) "
                "VALUES ('overture', :rid, :decision, :evidence, 0, :provenance)"
            ),
            {
                "rid": record.source_record_id,
                "decision": decision,
                "evidence": evidence[:1000],
                "provenance": json.dumps(provenance)[:500],
            },
        )

    def _upsert_place(self, record: SourceRecord, independent: bool | None) -> None:
        self.session.execute(
            text(
                """
                INSERT INTO fnb_a.overture_places (
                    overture_id, name_primary, taxonomy_primary, basic_category,
                    confidence, operating_status, longitude, latitude,
                    fnb_category_normalized, independent_of_osm, retrieved_at,
                    overture_release, overture_licence, in_study_area
                ) VALUES (
                    :oid, :name, :category_raw, :category,
                    NULL, :status, :lon, :lat,
                    :category, :independent, CAST(:snapshot AS timestamptz),
                    :release, :licence, true
                )
                ON CONFLICT (overture_id) DO UPDATE SET
                    name_primary = EXCLUDED.name_primary,
                    taxonomy_primary = EXCLUDED.taxonomy_primary,
                    basic_category = EXCLUDED.basic_category,
                    operating_status = EXCLUDED.operating_status,
                    longitude = EXCLUDED.longitude,
                    latitude = EXCLUDED.latitude,
                    fnb_category_normalized = EXCLUDED.fnb_category_normalized,
                    independent_of_osm = EXCLUDED.independent_of_osm,
                    retrieved_at = EXCLUDED.retrieved_at,
                    overture_release = EXCLUDED.overture_release,
                    overture_licence = EXCLUDED.overture_licence,
                    in_study_area = true
                """
            ),
            {
                "oid": self._overture_id(record),
                "name": record.name,
                "category_raw": record.category_raw,
                "category": record.category,
                "status": record.operating_status,
                "lon": record.longitude,
                "lat": record.latitude,
                "independent": independent,
                "snapshot": record.source_snapshot_at,
                "release": record.source_release,
                "licence": record.source_licence,
            },
        )
