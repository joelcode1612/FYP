"""Drain the durable Location Intelligence queue with several workers.

The API process already runs one enrichment thread. This is the same code path
(``run_next``), only replicated so a one-off backfill of the existing catalogue
finishes in minutes instead of hours. It is safe to run alongside the API:

* ``run_next`` claims work with ``FOR UPDATE OF p SKIP LOCKED`` and refuses to
  start a category while another category for the same property is running, so
  two workers can never calculate the same property at the same time;
* every write is fenced by the coordinate hash and the attempt token, so a
  claim that goes stale cannot overwrite a newer result.

Usage (from ``backend/``):

    .venv/Scripts/python.exe scripts/drain_location_intelligence.py --workers 6
"""

from __future__ import annotations

import argparse
import sys
import threading
import time

from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine
from sitewise.services.expanded64_enrichment import run_next


def _remaining() -> int:
    with Session(engine) as session:
        return session.execute(text("""
            SELECT count(*) FROM fyp.property_enrichment_category
            WHERE category LIKE 'expanded64\\_%'
              AND status IN ('pending', 'running')
            """)).scalar_one()


def _worker(index: int, stop: threading.Event, counters: list[int]) -> None:
    idle = 0
    while not stop.is_set():
        try:
            with Session(engine) as session:
                if run_next(session):
                    counters[index] += 1
                    idle = 0
                    continue
        except Exception as exc:  # one bad job must not stop the drain
            print(f"worker {index}: {type(exc).__name__}", flush=True)
            stop.wait(5)
            continue
        idle += 1
        if idle >= 6:
            stop.set()
            return
        stop.wait(2)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workers", type=int, default=6)
    args = parser.parse_args(argv)

    before = _remaining()
    print(f"queued categories before: {before}", flush=True)
    if before == 0:
        print("nothing to do.")
        return 0

    stop = threading.Event()
    counters = [0] * args.workers
    threads = [
        threading.Thread(target=_worker, args=(i, stop, counters), daemon=True)
        for i in range(args.workers)
    ]
    started = time.time()
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    after = _remaining()
    print(
        f"processed {sum(counters)} categories in {time.time() - started:.0f}s; "
        f"remaining queued: {after}",
        flush=True,
    )
    with Session(engine) as session:
        states = session.execute(text("""
            SELECT status, count(*) FROM fyp.property_enrichment_category
            WHERE category LIKE 'expanded64\\_%' GROUP BY status ORDER BY status
            """)).all()
    print("category states:", dict(states), flush=True)
    return 0 if after == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
