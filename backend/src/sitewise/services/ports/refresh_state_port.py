"""Contract for calculated-feature freshness and ingestion provenance.

Shared by the Explore and geospatial read models: both expose the same additive
status block, and ``sitewise.ingestion.state.RefreshState`` is the live
implementation. Declared once so neither service imports the ingestion package.
"""

from __future__ import annotations

from typing import Protocol


class RefreshStatePort(Protocol):
    def freshness_payload(self, property_id: int | None) -> dict: ...

    def provenance_summary(self, source_name: str | None = None) -> dict: ...
