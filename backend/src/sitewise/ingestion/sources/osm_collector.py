"""Bounded OpenStreetMap collector.

Three ingestion routes, in order of preference:

1. A regional Geofabrik PBF extract parsed with ``pyosmium`` (recurring bulk
   updates). A hard size cap prevents an accidental global download.
2. ONE politely-formed Overpass query per refresh (never one per property),
   covering all F&B categories at once with ``out center`` for ways/relations.
3. A local GeoJSON/JSON fixture for offline verification.

OSM element ids, versions, timestamps and tags are preserved verbatim in the
normalized record. Absence from a partial extract is never treated as closure.
"""

from __future__ import annotations

import json
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import httpx

from sitewise.ingestion.config import OSM_LICENCE, RefreshConfig
from sitewise.ingestion.normalizer import normalize_osm
from sitewise.ingestion.records import CollectorBlocked, IngestionStats, SourceRecord
from sitewise.ingestion.sources.overture_collector import CollectionResult

_OVERPASS_TAGS = (
    ('["amenity"~"^(restaurant|cafe|fast_food|food_court|bar|pub|ice_cream|canteen)$"]',),
    ('["shop"~"^(bakery|pastry|ice_cream)$"]',),
)


def _now_iso() -> str:
    return datetime.now(UTC).isoformat()


class OSMCollector:
    source_name = "openstreetmap"

    def __init__(self, config: RefreshConfig | None = None, client: Any = None):
        self.config = config or RefreshConfig()
        self._client = client

    def _http(self) -> httpx.Client:
        return self._client or httpx.Client(
            timeout=self.config.request_timeout_s,
            # Geofabrik answers 307 to the dated extract; the final URL IS
            # the release identifier (e.g. ...-261109.osm.pbf).
            follow_redirects=True,
            headers={"User-Agent": "SiteWise-FYP/1.0 (research data refresh)"},
        )

    def extract_metadata(self) -> dict[str, str]:
        """HEAD the regional extract: its ETag / Last-Modified IS the release."""
        if self.config.offline:
            raise CollectorBlocked(self.source_name, "offline mode: no HEAD request")
        try:
            with self._http() as client:
                response = client.head(self.config.osm_extract_url)
                response.raise_for_status()
        except Exception as exc:
            raise CollectorBlocked(
                self.source_name, f"extract metadata unavailable: {type(exc).__name__}: {exc}"
            ) from exc
        final_url = str(response.url)
        dated = final_url.rsplit("/", 1)[-1].replace(".osm.pbf", "")
        return {
            "release": (
                response.headers.get("etag")
                or response.headers.get("last-modified")
                or dated
                or _now_iso()
            ).strip('"'),
            "last_modified": response.headers.get("last-modified", ""),
            "content_length": response.headers.get("content-length", ""),
            "extract_url": final_url,
        }

    def collect(self, release: str | None = None) -> CollectionResult:
        stats = IngestionStats(source_name=self.source_name, source_release=release or "")
        elements, metadata = self._read(release)
        release = release or metadata.get("release") or metadata.get("source", "local")
        snapshot_at = metadata.get("snapshot_at") or _now_iso()
        stats.source_release = release
        records: list[SourceRecord] = []
        for raw in elements:
            stats.records_downloaded += 1
            record, reason = normalize_osm(
                raw, release=release, snapshot_at=snapshot_at, config=self.config
            )
            if record is None:
                stats.reject(reason or "invalid_record")
            else:
                records.append(record)
            if len(records) >= self.config.max_records_per_source:
                break
        stats.records_accepted = len(records)
        import hashlib

        checksum = hashlib.sha256(
            "|".join(sorted(f"{r.natural_key}:{r.fingerprint()}" for r in records)).encode()
        ).hexdigest()
        return CollectionResult(
            source_name=self.source_name,
            release=release,
            snapshot_at=snapshot_at,
            licence=OSM_LICENCE,
            records=records,
            checksum=checksum,
            stats=stats,
            full_snapshot=metadata.get("full_snapshot", False),
            source_metadata=metadata,
        )

    # ------------------------------------------------------------------

    def _read(self, release: str | None) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        if self.config.fixture_dir:
            return self._read_fixture()
        if self.config.offline:
            raise CollectorBlocked(
                self.source_name, "offline mode and no SITEWISE_REFRESH_FIXTURE_DIR"
            )
        # Route 1: regional PBF + pyosmium. pyosmium has no Python 3.13
        # Windows wheel in this environment; the route is preserved for
        # production Linux workers.
        meta = self.extract_metadata()
        length = meta.get("content_length", "")
        if length.isdigit() and int(length) <= self.config.max_download_mb * 1024 * 1024:
            try:
                return self._read_pbf(meta)
            except CollectorBlocked as pbf_error:
                last_error = pbf_error
        else:
            last_error = CollectorBlocked(
                self.source_name,
                f"regional extract is {length or 'unknown'} bytes "
                f"(cap {self.config.max_download_mb} MB) — skipped",
            )
        # Route 2: one Overpass query per refresh, never per property.
        try:
            return self._read_overpass(meta)
        except CollectorBlocked as overpass_error:
            raise CollectorBlocked(
                self.source_name,
                f"{last_error.reason}; overpass: {overpass_error.reason}",
            ) from overpass_error

    def _read_fixture(self) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        root = Path(self.config.fixture_dir)
        files = sorted(root.glob("osm*.json")) + sorted(root.glob("osm*.geojson"))
        if not files:
            raise CollectorBlocked(
                self.source_name, f"no osm*.json/geojson fixture in {root}"
            )
        elements: list[dict[str, Any]] = []
        for path in files:
            payload = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(payload, dict) and "elements" in payload:
                elements.extend(payload["elements"])
            elif isinstance(payload, dict) and "features" in payload:
                elements.extend(
                    {
                        "type": f.get("geometry", {}).get("type", "node").lower(),
                        "id": f.get("id") or (f.get("properties") or {}).get("osm_id"),
                        "properties": f.get("properties") or {},
                        "geometry": f.get("geometry") or {},
                    }
                    for f in payload["features"]
                )
            elif isinstance(payload, list):
                elements.extend(payload)
        return elements, {
            "snapshot_at": datetime.fromtimestamp(
                max(p.stat().st_mtime for p in files), UTC
            ).isoformat(),
            "source": "local_fixture",
            "files": [p.name for p in files],
            "full_snapshot": False,
            "release": "local-fixture",
        }

    def _read_pbf(self, meta: dict[str, str]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        try:
            import osmium  # type: ignore
        except ImportError as exc:
            raise CollectorBlocked(self.source_name, "pyosmium not installed") from exc
        import tempfile

        with self._http() as client, tempfile.NamedTemporaryFile(suffix=".osm.pbf") as tmp:
            with client.stream("GET", self.config.osm_extract_url) as response:
                response.raise_for_status()
                downloaded = 0
                cap = self.config.max_download_mb * 1024 * 1024
                for chunk in response.iter_bytes():
                    downloaded += len(chunk)
                    if downloaded > cap:
                        raise CollectorBlocked(
                            self.source_name, "regional extract exceeded the size cap"
                        )
                    tmp.write(chunk)
            tmp.flush()

            class _Handler(osmium.SimpleHandler):  # type: ignore[misc]
                """Node POIs only for the bulk PBF route; ways/relations are
                covered by the Overpass ``out center`` route below."""

                def __init__(self):
                    super().__init__()
                    self.elements: list[dict[str, Any]] = []

                def node(self, n: Any) -> None:
                    tags = {t.k: t.v for t in n.tags}
                    if not tags.get("name"):
                        return
                    self.elements.append({
                        "type": "node",
                        "id": n.id,
                        "version": n.version,
                        "timestamp": str(n.timestamp),
                        "tags": tags,
                        "lat": n.location.lat,
                        "lon": n.location.lon,
                    })

            handler = _Handler()
            handler.apply_file(tmp.name)
        return handler.elements, {
            "snapshot_at": meta.get("last_modified") or _now_iso(),
            "release": meta["release"],
            "source": self.config.osm_extract_url,
            "full_snapshot": False,
        }

    def _read_overpass(self, meta: dict[str, str]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        if not self.config.overpass_enabled:
            raise CollectorBlocked(self.source_name, "Overpass disabled by configuration")
        min_lon, min_lat, max_lon, max_lat = self.config.bbox
        bbox = f"{min_lat},{min_lon},{max_lat},{max_lon}"
        selectors = "".join(
            f"node{sel}({bbox});way{sel}({bbox});relation{sel}({bbox});"
            for (sel,) in _OVERPASS_TAGS
        )
        query = f"[out:json][timeout:120];({selectors});out center;"
        try:
            with self._http() as client:
                response = client.post(
                    self.config.overpass_url, data={"data": query}, timeout=120
                )
                response.raise_for_status()
                payload = response.json()
        except Exception as exc:
            raise CollectorBlocked(
                self.source_name, f"Overpass query failed: {type(exc).__name__}: {exc}"
            ) from exc
        return payload.get("elements", []), {
            "snapshot_at": _now_iso(),
            "release": meta.get("release", "overpass"),
            "source": self.config.overpass_url,
            "full_snapshot": False,
        }
