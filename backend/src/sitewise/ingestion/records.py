"""Typed records and measured counters for the ingestion pipeline."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any


@dataclass(frozen=True)
class SourceRecord:
    """One normalized, validated outlet observation.

    ``source_record_id`` is the provider's ORIGINAL identifier (never erased):
    OSM ``node/123`` / ``way/123`` or the Overture ``id`` (GERS-style). The
    natural key for synchronization is ``(source_name, source_record_id)``.
    """

    source_name: str  # "openstreetmap" | "overture"
    source_record_id: str
    source_release: str
    source_snapshot_at: str
    source_licence: str
    name: str
    normalized_name: str
    category: str
    category_raw: str
    latitude: float
    longitude: float
    operating_status: str | None = None
    address: str | None = None
    postcode: str | None = None
    city: str | None = None
    phone: str | None = None
    website: str | None = None
    source_updated_at: str | None = None
    source_version: int | None = None
    source_tags: dict[str, Any] = field(default_factory=dict)
    explicit_cross_refs: tuple[str, ...] = ()
    geometry_type: str = "point"

    @property
    def natural_key(self) -> tuple[str, str]:
        return (self.source_name, self.source_record_id)

    def fingerprint(self) -> str:
        """Content hash used to detect a CHANGED record between releases.

        Only business-visible fields participate; source harvest timestamps
        that change on every download do NOT create a spurious update.
        """
        import hashlib
        import json

        payload = {
            "name": self.name,
            "category": self.category,
            "lat": round(self.latitude, 7),
            "lon": round(self.longitude, 7),
            "status": self.operating_status,
            "address": self.address,
            "postcode": self.postcode,
            "city": self.city,
            "phone": self.phone,
            "website": self.website,
        }
        return hashlib.sha256(
            json.dumps(payload, sort_keys=True, ensure_ascii=False).encode("utf-8")
        ).hexdigest()


@dataclass
class IngestionStats:
    """Measurable execution results. Only real events increment a counter."""

    source_name: str = ""
    source_release: str = ""
    records_downloaded: int = 0
    records_accepted: int = 0
    records_rejected: int = 0
    duplicates_detected: int = 0
    ambiguous_matches: int = 0
    records_inserted: int = 0
    records_updated: int = 0
    records_unchanged: int = 0
    records_absent_unproven: int = 0
    properties_affected: int = 0
    properties_recalculated: int = 0
    successful_computations: int = 0
    failed_computations: int = 0
    duration_seconds: float = 0.0
    last_successful_snapshot: str | None = None
    status: str = "pending"
    errors: list[str] = field(default_factory=list)
    rejection_reasons: dict[str, int] = field(default_factory=dict)

    def reject(self, reason: str) -> None:
        self.records_rejected += 1
        self.rejection_reasons[reason] = self.rejection_reasons.get(reason, 0) + 1

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)


class CollectorBlocked(RuntimeError):
    """External source unavailable. Carries the precise reason, never a fake 0."""

    def __init__(self, source: str, reason: str):
        super().__init__(f"{source}: {reason}")
        self.source = source
        self.reason = reason
