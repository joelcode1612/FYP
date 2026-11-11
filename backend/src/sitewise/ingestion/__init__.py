"""SiteWise automated geospatial ingestion and refresh pipeline.

Public surface used by the CLI and the API integration:

* :mod:`config` — environment-driven settings and category/licence vocabulary
* :mod:`records` — typed source records and measured counters
* :mod:`normalizer` — validation, category mapping, study-area filtering
* :mod:`deduplicator` — evidence-based cross-source match decisions
* :mod:`synchronizer` — staged, incremental, idempotent PostgreSQL writes
* :mod:`state` — snapshots, runs, freshness rows and the cross-process lock
* :mod:`schema` — additive DDL (CREATE IF NOT EXISTS only)
* :mod:`sources` — bounded Overture / OSM collectors
"""

from .config import RefreshConfig
from .records import CollectorBlocked, IngestionStats, SourceRecord
from .schema import ensure_schema
from .state import RefreshAlreadyRunning, RefreshLock, RefreshState

__all__ = [
    "CollectorBlocked",
    "IngestionStats",
    "RefreshAlreadyRunning",
    "RefreshConfig",
    "RefreshLock",
    "RefreshState",
    "SourceRecord",
    "ensure_schema",
]
