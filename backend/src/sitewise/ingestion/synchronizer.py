"""Staged, incremental, idempotent synchronization into fnb_a.fnb_outlet.

Design rules:
* A controlled staging table is loaded first (batched, parameterized).
* Natural key = (source_provider, source_record_id); provider ids are never
  rewritten. The three pre-existing duplicate keys are updated in place,
  never duplicated further.
* Only genuine field changes produce an UPDATE; unchanged rows are preserved
  byte-for-byte. Running the same snapshot twice produces 0 inserts / 0
  updates.
* Absence from a partial download NEVER proves closure. Even for a complete
  snapshot, absence is recorded in ``source_absence`` as UNPROVEN. Only an
  explicit ``operating_status='closed'`` from the source sets
  ``in_main_scope=false`` (the existing competitor predicate honours it).
* New rows are classified with ``fnb_a.study_area_states`` via ST_Intersects,
  preserving the documented target-region semantics.
"""

from __future__ import annotations

import hashlib
import json
from collections.abc import Iterable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import text
from sqlmodel import Session

from sitewise.ingestion.config import RefreshConfig
from sitewise.ingestion.deduplicator import within_source_duplicates
from sitewise.ingestion.normalizer import in_main_scope
from sitewise.ingestion.records import IngestionStats, SourceRecord

#: Columns read from live rows to decide whether a record changed.
_COMPARE_COLUMNS = """
    source_record_id, outlet_name, outlet_category, latitude, longitude,
    addr_street, addr_postcode, addr_city, phone, website, in_main_scope,
    source_tags
"""


@dataclass
class SyncResult:
    stats: IngestionStats
    changed_points: list[tuple[float, float]] = field(default_factory=list)
    inserted_keys: list[str] = field(default_factory=list)


def _row_payload(record: SourceRecord, config: RefreshConfig) -> dict[str, Any]:
    import json as _json

    tags = dict(record.source_tags)
    if record.operating_status:
        tags["operating_status"] = record.operating_status
    tags["source_licence"] = record.source_licence
    tags["source_release"] = record.source_release
    return {
        "source_name": record.source_name,
        "source_record_id": record.source_record_id,
        "name": record.name,
        "category": record.category,
        "category_raw": record.category_raw,
        "latitude": record.latitude,
        "longitude": record.longitude,
        "operating_status": record.operating_status,
        "address": record.address,
        "postcode": record.postcode,
        "city": record.city,
        "phone": record.phone,
        "website": record.website,
        "source_release": record.source_release,
        "source_snapshot_at": record.source_snapshot_at,
        "source_updated_at": record.source_updated_at,
        "source_licence": record.source_licence,
        "payload": _json.dumps(
            {
                "source_tags": tags,
                "geometry_type": record.geometry_type,
                "explicit_cross_refs": list(record.explicit_cross_refs),
                "source_version": record.source_version,
                "source_licence": record.source_licence,
                "calculation_version": config.calculation_version,
            },
            ensure_ascii=False,
        ),
    }


def plan_changes(
    incoming: Iterable[SourceRecord],
    existing: dict[str, dict[str, Any]],
) -> tuple[list[SourceRecord], list[SourceRecord], list[str]]:
    """Pure comparison: (to_insert, to_update, unchanged_keys).

    Kept separate from SQL so the idempotency and change-detection rules are
    unit-testable without a database.
    """
    inserts: list[SourceRecord] = []
    updates: list[SourceRecord] = []
    unchanged: list[str] = []
    for record in incoming:
        old = existing.get(record.source_record_id)
        if old is None:
            inserts.append(record)
            continue
        changed = (
            (old.get("outlet_name") or "") != record.name
            or (old.get("outlet_category") or "") != record.category
            or _coord_differs(old.get("latitude"), record.latitude)
            or _coord_differs(old.get("longitude"), record.longitude)
            or (old.get("addr_street") or None) != (record.address or None)
            or (old.get("addr_postcode") or None) != (record.postcode or None)
            or (old.get("addr_city") or None) != (record.city or None)
            or (old.get("phone") or None) != (record.phone or None)
            or (old.get("website") or None) != (record.website or None)
            or _status_differs(old, record)
        )
        if changed:
            updates.append(record)
        else:
            unchanged.append(record.source_record_id)
    return inserts, updates, unchanged


def _coord_differs(old: Any, new: float) -> bool:
    if old is None:
        return True
    try:
        return abs(float(old) - float(new)) > 1e-7
    except (TypeError, ValueError):
        return True


def _status_differs(old: dict[str, Any], record: SourceRecord) -> bool:
    tags = old.get("source_tags")
    if isinstance(tags, str):
        try:
            tags = json.loads(tags)
        except ValueError:
            tags = {}
    tags = tags if isinstance(tags, dict) else {}
    old_status = tags.get("operating_status")
    if record.operating_status == "closed" and old_status != "closed":
        return True
    if record.operating_status == "open" and old_status == "closed":
        return True
    expected_scope = in_main_scope(record.category) and record.operating_status != "closed"
    return bool(old.get("in_main_scope")) != expected_scope and old_status is not None


class OutletSynchronizer:
    def __init__(
        self,
        session: Session,
        config: RefreshConfig | None = None,
        *,
        target: str = "fnb_a.fnb_outlet",
        stage: str = "fnb_a.fnb_outlet_stage",
    ):
        self.session = session
        self.config = config or RefreshConfig()
        # Identifiers are internal constants, never client input.
        if not all(part.replace("_", "").isalnum() for part in (target + stage).split(".")):
            raise ValueError("invalid table identifier")
        self.target = target
        self.stage = stage

    def load_stage(self, records: list[SourceRecord]) -> None:
        """Replace the controlled staging contents in batches."""
        self.session.execute(text(f"TRUNCATE TABLE {self.stage}"))
        if not records:
            self.session.commit()
            return
        stmt = text(
            f"""
            INSERT INTO {self.stage} (
                source_name, source_record_id, name, category, category_raw,
                latitude, longitude, operating_status, address, postcode, city,
                phone, website, source_release, source_snapshot_at,
                source_updated_at, source_licence, payload
            ) VALUES (
                :source_name, :source_record_id, :name, :category, :category_raw,
                :latitude, :longitude, :operating_status, :address, :postcode,
                :city, :phone, :website, :source_release,
                CAST(:source_snapshot_at AS timestamptz), :source_updated_at,
                :source_licence, CAST(:payload AS jsonb)
            )
            ON CONFLICT (source_name, source_record_id) DO NOTHING
            """
        )
        payloads = [_row_payload(r, self.config) for r in records]
        for start in range(0, len(payloads), self.config.batch_size):
            self.session.execute(stmt, payloads[start : start + self.config.batch_size])
        self.session.commit()

    def existing_rows(self, source_name: str, keys: list[str]) -> dict[str, dict[str, Any]]:
        """Load only the live rows whose natural keys appear in this snapshot."""
        if not keys:
            return {}
        rows = self.session.execute(
            text(
                f"SELECT {_COMPARE_COLUMNS} FROM {self.target} "
                "WHERE source_provider = :name "
                "AND source_record_id = ANY(CAST(:keys AS text[]))"
            ),
            {"name": source_name, "keys": keys},
        ).mappings().all()
        return {str(r["source_record_id"]): dict(r) for r in rows}

    def sync(
        self,
        records: list[SourceRecord],
        *,
        stats: IngestionStats | None = None,
        full_snapshot: bool = False,
    ) -> SyncResult:
        """Insert new, update changed, preserve unchanged, record absence."""
        started = datetime.now(UTC)
        stats = stats or IngestionStats()
        survivors, duplicates = within_source_duplicates(records)
        stats.duplicates_detected += duplicates
        stats.records_accepted = len(survivors)
        self.load_stage(survivors)
        source_name = survivors[0].source_name if survivors else ""
        existing = self.existing_rows(source_name, [r.source_record_id for r in survivors])
        inserts, updates, unchanged = plan_changes(survivors, existing)
        stats.records_inserted = len(inserts)
        stats.records_updated = len(updates)
        stats.records_unchanged = len(unchanged)

        changed_points: list[tuple[float, float]] = []
        for record in updates:
            old = existing.get(record.source_record_id, {})
            if old.get("latitude") is not None and old.get("longitude") is not None:
                changed_points.append((float(old["latitude"]), float(old["longitude"])))
            changed_points.append((record.latitude, record.longitude))
        for record in inserts:
            changed_points.append((record.latitude, record.longitude))

        if inserts:
            self._insert_batch(inserts)
        if updates:
            self._update_batch(updates)

        if full_snapshot and survivors:
            self._record_absence(survivors, stats)
        self.session.commit()
        stats.duration_seconds = (datetime.now(UTC) - started).total_seconds()
        return SyncResult(
            stats=stats,
            changed_points=changed_points,
            inserted_keys=[r.source_record_id for r in inserts],
        )

    def _insert_batch(self, records: list[SourceRecord]) -> None:
        stmt = text(
            f"""
            INSERT INTO {self.target} (
                outlet_id, outlet_key, source_provider, source_licence,
                usage_class, permitted_for_ml_dataset, source_table,
                source_osm_id, source_record_id, outlet_name, outlet_category,
                source_category_raw, latitude, longitude, geom,
                coordinate_validation_status, in_target_region,
                study_region, spatial_state, main_category, in_main_scope,
                source_tags, source_snapshot_at, source_provenance_version,
                criteria_version, built_at, addr_street, addr_postcode,
                addr_city, phone, website
            )
            SELECT
                -- The live table enforces outlet_id = 'FNB-' || lpad(outlet_key,8,'0'),
                -- so BOTH columns must come from ONE sequence value.
                'FNB-' || lpad(seq.k::text, 8, '0'),
                seq.k,
                s.source_name, s.source_licence,
                'PERMITTED', true,
                COALESCE(s.payload->>'geometry_type', 'point'),
                CASE WHEN s.source_name = 'openstreetmap'
                          AND split_part(s.source_record_id, '/', 2) ~ '^[0-9]+$'
                     THEN split_part(s.source_record_id, '/', 2)::bigint END,
                s.source_record_id, s.name, s.category, s.category_raw,
                s.latitude, s.longitude,
                ST_SetSRID(ST_MakePoint(s.longitude, s.latitude), 4326),
                'PASS', (b.name_1 IS NOT NULL), b.name_1, b.name_1,
                s.category,
                ((s.category IN (
                    'restaurant','cafe','fast_food','food_court','bakery_pastry',
                    'bar_pub','ice_cream_dessert','beverage_tea_coffee','canteen'))
                 AND COALESCE(s.operating_status, '') <> 'closed'),
                COALESCE(s.payload->'source_tags', '{{}}'::jsonb),
                s.source_snapshot_at, 'geo-refresh-v1.0',
                :criteria_version, now(), s.address, s.postcode, s.city,
                s.phone, s.website
            FROM {self.stage} s
            CROSS JOIN LATERAL (
                SELECT nextval('fnb_a.fnb_outlet_refresh_key_seq') AS k
            ) seq
            LEFT JOIN LATERAL (
                SELECT b.name_1 FROM fnb_a.study_area_states b
                WHERE ST_Intersects(
                    b.geom,
                    ST_SetSRID(ST_MakePoint(s.longitude, s.latitude), 4326))
                LIMIT 1
            ) b ON true
            WHERE NOT EXISTS (
                SELECT 1 FROM {self.target} o
                WHERE o.source_provider = s.source_name
                  AND o.source_record_id = s.source_record_id
            )
            AND s.source_record_id IN (:keys)
            """
        )
        import sqlalchemy

        stmt = stmt.bindparams(sqlalchemy.bindparam("keys", expanding=True))
        keys = [r.source_record_id for r in records]
        for start in range(0, len(keys), self.config.batch_size):
            self.session.execute(
                stmt,
                {
                    "criteria_version": "fnb-criteria-v1.0",
                    "keys": keys[start : start + self.config.batch_size],
                },
            )

    def _update_batch(self, records: list[SourceRecord]) -> None:
        stmt = text(
            f"""
            UPDATE {self.target} o SET
                outlet_name = s.name,
                outlet_category = s.category,
                source_category_raw = s.category_raw,
                latitude = s.latitude,
                longitude = s.longitude,
                geom = ST_SetSRID(ST_MakePoint(s.longitude, s.latitude), 4326),
                addr_street = s.address,
                addr_postcode = s.postcode,
                addr_city = s.city,
                phone = s.phone,
                website = s.website,
                main_category = s.category,
                in_main_scope =
                    (s.category IN (
                        'restaurant','cafe','fast_food','food_court','bakery_pastry',
                        'bar_pub','ice_cream_dessert','beverage_tea_coffee','canteen'))
                    AND COALESCE(s.operating_status, '') <> 'closed',
                source_tags = COALESCE(s.payload->'source_tags', o.source_tags),
                source_snapshot_at = s.source_snapshot_at,
                source_collection_timestamp = s.source_updated_at,
                built_at = now()
            FROM {self.stage} s
            WHERE o.source_provider = s.source_name
              AND o.source_record_id = s.source_record_id
              AND s.source_record_id IN (:keys)
            """
        )
        import sqlalchemy

        stmt = stmt.bindparams(sqlalchemy.bindparam("keys", expanding=True))
        keys = [r.source_record_id for r in records]
        for start in range(0, len(keys), self.config.batch_size):
            self.session.execute(
                stmt, {"keys": keys[start : start + self.config.batch_size]}
            )

    def _record_absence(self, survivors: list[SourceRecord], stats: IngestionStats) -> None:
        """Absence is recorded, never used as proof of closure."""
        source_name = survivors[0].source_name
        release = survivors[0].source_release
        seen = {r.source_record_id for r in survivors}
        live = self.session.execute(
            text(
                f"SELECT source_record_id FROM {self.target} "
                "WHERE source_provider = :name AND source_record_id IS NOT NULL"
            ),
            {"name": source_name},
        ).scalars().all()
        absent = [key for key in live if key not in seen]
        if not absent:
            return
        stmt = text(
            "INSERT INTO fnb_a.source_absence "
            "(source_name, source_record_id, source_release, evidence, closure_confirmed) "
            "VALUES (:name, :key, :release, 'absent_from_full_snapshot', false) "
            "ON CONFLICT DO NOTHING"
        )
        for start in range(0, len(absent), self.config.batch_size):
            self.session.execute(
                stmt,
                [
                    {"name": source_name, "key": key, "release": release}
                    for key in absent[start : start + self.config.batch_size]
                ],
            )
        stats.records_absent_unproven = len(absent)


def snapshot_checksum(records: Iterable[SourceRecord]) -> str:
    """Stable digest of a source snapshot, used to skip unchanged releases."""
    digest = hashlib.sha256()
    for record in sorted(records, key=lambda r: r.natural_key):
        digest.update(f"{record.natural_key}|{record.fingerprint()}\n".encode())
    return digest.hexdigest()
