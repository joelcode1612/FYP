"""Recalculate six Expanded64 inputs for all 1,796 original training subjects.

The calculators are imported from the SiteWise runtime; no parallel
implementation, no model training and no production writes. The database
session is put into a READ ONLY transaction before any calculator runs.

Usage (from package root)::

    DATABASE_URL=postgresql+psycopg2://... python source/extract_expanded64_v2.py \
        --batch-size 50

Progress is appended to ``checkpoints/extraction_progress.jsonl`` one record
per subject, so an interrupted run resumes by skipping completed subject ids.
"""
from __future__ import annotations

import argparse
import csv
import json
import logging
import os
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlmodel import Session

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT.parent / "backend"
sys.path.insert(0, str(BACKEND / "src"))

from sitewise.ml.coordinate_features import (  # noqa: E402
    GROUP_ISO, GROUP_POPULATION, GROUP_ROAD,
)
from sitewise.ml.expanded64_network import Expanded64CoordinateExtractor  # noqa: E402
from sitewise.ml.expanded64_feature_definitions import DEFINITIONS_VERSION  # noqa: E402

TRAINING_CSV = ROOT / "original_training_data" / "SiteWise_PU_1796_Expanded_Observed.csv"
CHECKPOINT = ROOT / "checkpoints" / "extraction_progress.jsonl"
SQL_OUT = ROOT / "sql" / "02_extraction_queries.sql"
LOG = ROOT / "logs" / "extraction.log"
LOG.parent.mkdir(exist_ok=True)
CHECKPOINT.parent.mkdir(exist_ok=True)

logging.basicConfig(
    filename=LOG, filemode="a", level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("extraction")

TARGETS = (
    "road_length_density_500m_km_km2",
    "osm_walkway_length_density_500m_km_km2",
    "pop_2000m",
    "pop_3000m",
    "walk_isochrone_area_10min_km2",
    "worldpop_walk_reachable_10min",
)
GROUP_OF = {
    "road_length_density_500m_km_km2": GROUP_ROAD,
    "osm_walkway_length_density_500m_km_km2": GROUP_ROAD,
    "pop_2000m": GROUP_POPULATION,
    "pop_3000m": GROUP_POPULATION,
    "walk_isochrone_area_10min_km2": GROUP_ISO,
    "worldpop_walk_reachable_10min": GROUP_ISO,
}
SELECTED = {GROUP_ROAD, GROUP_POPULATION, GROUP_ISO}

EXTRACTED_SQL = """-- SQL executed by the SiteWise runtime calculators (verbatim templates).
-- road_geometry / population_rings: backend/src/sitewise/ml/coordinate_features.py
-- isochrone_population: backend/src/sitewise/ml/expanded64_network.py
-- Parameter values are the original subject coordinates; see the handoff document
-- for the fully expanded statements and class lists.
-- Calculator groups selected: road_geometry, population_rings, isochrone_population.
-- Every statement executed inside SET TRANSACTION READ ONLY.
"""


def load_subjects() -> list[dict]:
    with TRAINING_CSV.open(encoding="utf-8-sig", newline="") as fp:
        rows = list(csv.DictReader(fp))
    return [
        {
            "subject_id": row["subject_id"],
            "sample_class": row["sample_class"],
            "latitude": float(row["latitude"]),
            "longitude": float(row["longitude"]),
            "original": {name: row.get(name) or "" for name in TARGETS},
        }
        for row in rows
    ]


def checkpoint_paths() -> list[Path]:
    return sorted(CHECKPOINT.parent.glob("extraction_progress*.jsonl"))


def load_checkpoint() -> dict[str, dict]:
    done: dict[str, dict] = {}
    for path in checkpoint_paths():
        with path.open(encoding="utf-8") as fp:
            for line in fp:
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    log.warning("Skipping malformed checkpoint line in %s", path.name)
                    continue
                done[record["subject_id"]] = record
    return done


def measure(session: Session, subject: dict) -> dict:
    extractor = Expanded64CoordinateExtractor(session)
    groups = extractor.extract(
        subject["latitude"], subject["longitude"], selected=set(SELECTED)
    )
    values: dict[str, float | None] = {name: None for name in TARGETS}
    sources: dict[str, str] = {}
    notes: dict[str, dict] = {}
    statuses: dict[str, str] = {}
    reasons: dict[str, str] = {}
    for group_name, result in groups.items():
        statuses[group_name] = result.status
        if result.reason:
            reasons[group_name] = result.reason[:500]
        notes[group_name] = result.notes
        for name, value in result.values.items():
            if name in values and value is not None:
                values[name] = float(value)
                sources[name] = result.sources.get(name, "")
    return {
        "subject_id": subject["subject_id"],
        "sample_class": subject["sample_class"],
        "latitude": subject["latitude"],
        "longitude": subject["longitude"],
        "values": values,
        "sources": sources,
        "notes": notes,
        "statuses": statuses,
        "reasons": reasons,
        "definition_version": DEFINITIONS_VERSION,
        "measured_at_utc": datetime.now(timezone.utc).isoformat(),
    }


def _run_chunk(engine, subjects: list[dict], worker_id: int, batch_size: int) -> int:
    """Process one disjoint slice with its own session and checkpoint file."""
    path = CHECKPOINT.parent / f"extraction_progress_w{worker_id}.jsonl"
    completed = 0
    with Session(engine) as session:
        session.connection().exec_driver_sql("SET TRANSACTION READ ONLY")
        session.connection().exec_driver_sql("SET LOCAL statement_timeout = '120s'")
        with path.open("a", encoding="utf-8") as fp:
            for start in range(0, len(subjects), batch_size):
                batch = subjects[start : start + batch_size]
                for subject in batch:
                    try:
                        record = measure(session, subject)
                    except Exception as exc:  # noqa: BLE001 - per-subject failure only
                        record = {
                            "subject_id": subject["subject_id"],
                            "sample_class": subject["sample_class"],
                            "latitude": subject["latitude"],
                            "longitude": subject["longitude"],
                            "values": {name: None for name in TARGETS},
                            "sources": {}, "notes": {}, "statuses": {},
                            "reasons": {"extraction": f"{type(exc).__name__}: {exc}"[:500]},
                            "definition_version": DEFINITIONS_VERSION,
                            "measured_at_utc": datetime.now(timezone.utc).isoformat(),
                        }
                        log.warning("Worker %d subject %s failed: %s",
                                    worker_id, subject["subject_id"], type(exc).__name__)
                    fp.write(json.dumps(record, ensure_ascii=False, allow_nan=False) + "\n")
                    fp.flush()
                    completed += 1
                log.info("Worker %d batch %d-%d complete",
                         worker_id, start + 1, start + len(batch))
        session.rollback()
    return completed


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--batch-size", type=int, default=50)
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--limit", type=int, default=0, help="debug only: cap subjects")
    args = parser.parse_args()
    SQL_OUT.write_text(EXTRACTED_SQL, encoding="utf-8")

    subjects = load_subjects()
    if args.limit:
        subjects = subjects[: args.limit]
    done = load_checkpoint()
    pending = [s for s in subjects if s["subject_id"] not in done]
    log.info(
        "Starting extraction: total=%d completed=%d pending=%d batch=%d workers=%d",
        len(subjects), len(done), len(pending), args.batch_size, args.workers,
    )

    url = make_url(os.environ["DATABASE_URL"])
    engine = create_engine(url, pool_pre_ping=True)
    log.info("Database identity: %s@%s:%s/%s", url.username, url.host, url.port, url.database)
    with engine.connect() as conn:
        identity = conn.execute(text(
            "SELECT current_database(), inet_server_port()"
        )).one()
        if (identity[0], identity[1]) != ("Final_Location_Analysis", 5432):
            raise RuntimeError(f"Refusing unexpected database identity: {identity}")
        log.info("Verified read-only source database %s:%s", identity[0], identity[1])

    workers = max(1, args.workers)
    chunks = [pending[i::workers] for i in range(workers)]
    if workers == 1:
        total = _run_chunk(engine, chunks[0], 0, args.batch_size)
    else:
        total = 0
        with ThreadPoolExecutor(max_workers=workers) as pool:
            futures = {
                pool.submit(_run_chunk, engine, chunk, i, args.batch_size): i
                for i, chunk in enumerate(chunks) if chunk
            }
            for future in as_completed(futures):
                total += future.result()
                log.info("Worker %d finished", futures[future])
    log.info("Extraction complete: %d new subject records, %d total", total, len(load_checkpoint()))


if __name__ == "__main__":
    main()
