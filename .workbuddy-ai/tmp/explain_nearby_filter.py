"""EXPLAIN ANALYZE probe for the 500 m nearby-property filter.

Runs the repository's real list SQL twice over the full published dataset:
  A. baseline  (no nearby filter)      -> timing reference ("before")
  B. nearby ON (min_nearby_properties=3, nearby_radius_m=500, LIMIT 24)
and prints the EXPLAIN (ANALYZE, BUFFERS) plan of B so the index usage is
visible. Read-only: no rows are written.
"""

from __future__ import annotations

import time

from sqlalchemy import create_engine, text

from sitewise.core.config import settings

engine = create_engine(settings.database_url, pool_pre_ping=True)

PAD = 500 * 1.02 / 111320

SELECT_WITH = """
SELECT p.id,
       nearby.nearby_count AS nearby_property_count
FROM fyp.rental_properties p
LEFT JOIN LATERAL (
    SELECT count(*)::int AS nearby_count
    FROM fyp.rental_properties o
    WHERE o.id <> p.id
      AND o.is_published AND o.verification_status = 'approved'
      AND o.geom IS NOT NULL
      AND o.geom && ST_Expand(p.geom, :nearby_pad)
      AND ST_DWithin(o.geom::geography, p.geom::geography, :nearby_radius_m)
) nearby ON TRUE
WHERE p.is_published AND p.verification_status = 'approved'
  AND nearby.nearby_count >= :min_nearby_properties
ORDER BY p.created_at DESC NULLS LAST, p.id DESC
LIMIT 24 OFFSET 0
"""

SELECT_WITHOUT = SELECT_WITH.replace(
    "  AND nearby.nearby_count >= :min_nearby_properties\n", ""
).replace(
    "       nearby.nearby_count AS nearby_property_count\n",
    "       1 AS one\n",
)

args = {"nearby_pad": PAD, "nearby_radius_m": 500, "min_nearby_properties": 3}

with engine.connect() as conn:
    conn.execute(text("SET max_parallel_workers_per_gather = 2"))

    # Warm the page cache once so both timings describe steady state.
    conn.execute(text(SELECT_WITHOUT), args).fetchall()

    for label, sql in (("B  nearby ON ", SELECT_WITH), ("A  nearby OFF", SELECT_WITHOUT)):
        t0 = time.perf_counter()
        rows = conn.execute(text(sql), args).fetchall()
        wall = (time.perf_counter() - t0) * 1000
        print(f"{label}: {len(rows)} rows, wall {wall:.1f} ms")

    plan = conn.execute(
        text("EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) " + SELECT_WITH), args
    ).fetchall()
    print("\n--- EXPLAIN (ANALYZE, BUFFERS) nearby ON ---")
    for (line,) in plan:
        print(line)
