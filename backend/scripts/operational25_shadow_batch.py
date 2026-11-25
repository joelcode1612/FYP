#!/usr/bin/env python
"""Shadow-only Operational25 coverage/scoring over canonical properties.

Queues every property with verified coordinates through the existing durable
category table and runs parallel claim workers. It NEVER writes Expanded64 or
deployed recommendation scores. Usage:

    .venv/Scripts/python.exe scripts/operational25_shadow_batch.py --workers 6
"""
from __future__ import annotations

import argparse
import concurrent.futures
import os
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND / "src"))
os.chdir(BACKEND)

from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine
from sitewise.services.operational25_enrichment import CATEGORY, VERSION, enqueue, run_next


def worker(index: int) -> int:
    done = 0
    while True:
        with Session(engine) as session:
            if not run_next(session):
                break
        done += 1
        if done % 10 == 0:
            print(f"worker {index}: {done} jobs", flush=True)
    return done


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args()
    with Session(engine) as session:
        ids = session.execute(text(
            "SELECT id FROM fyp.rental_properties "
            "WHERE latitude IS NOT NULL AND longitude IS NOT NULL ORDER BY id"
        )).scalars().all()
        if args.limit:
            ids = ids[: args.limit]
        queued = sum(bool(enqueue(session, int(pid), force=True)) for pid in ids)
        session.commit()
    print(f"queued={queued} eligible={len(ids)} version={VERSION}", flush=True)
    with concurrent.futures.ProcessPoolExecutor(max_workers=max(1, args.workers)) as pool:
        counts = list(pool.map(worker, range(max(1, args.workers))))
    print(f"claimed_jobs={sum(counts)}", flush=True)
    with Session(engine) as session:
        rows = session.execute(text("""
            SELECT q.status, count(*) FROM fyp.property_enrichment_category q
            WHERE q.category=:category GROUP BY 1 ORDER BY 1
        """), {"category": CATEGORY}).all()
        print("queue_status=" + str(rows), flush=True)
        scores = session.execute(text("""
            SELECT count(*), min((pu_inference_snapshot -> :key ->> 'score_0_100')::numeric),
                   avg((pu_inference_snapshot -> :key ->> 'score_0_100')::numeric),
                   max((pu_inference_snapshot -> :key ->> 'score_0_100')::numeric),
                   count(*) FILTER (WHERE (pu_inference_snapshot -> :key ->> 'score_0_100')::numeric > 50)
              FROM fyp.property_geospatial_features
             WHERE pu_inference_snapshot ? :key
        """), {"key": CATEGORY}).one()
        print(f"shadow_scores_total_above50={tuple(scores)}", flush=True)


if __name__ == "__main__":
    main()
