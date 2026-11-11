"""Bounded Overture Maps ``places`` collector (release-aware GeoParquet).

Public Overture releases are GeoParquet partitions on a public S3 bucket.
A release is identified by its dated prefix; the SAME release is never
imported twice (``source_snapshot`` tracks it). Only the configured study-area
bounding box is read, with column projection and a row cap — never a global
download. When the network or an optional reader is unavailable the collector
reports ``CollectorBlocked`` with the precise reason instead of inventing an
empty successful harvest.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import httpx

from sitewise.ingestion.config import OVERTURE_LICENCE, RefreshConfig
from sitewise.ingestion.normalizer import normalize_overture
from sitewise.ingestion.records import CollectorBlocked, IngestionStats, SourceRecord

_PREFIX_RE = re.compile(r"<Prefix>(release/[^<]+)</Prefix>")


@dataclass
class CollectionResult:
    source_name: str
    release: str
    snapshot_at: str
    licence: str
    records: list[SourceRecord] = field(default_factory=list)
    checksum: str = ""
    stats: IngestionStats = field(default_factory=IngestionStats)
    full_snapshot: bool = False
    source_metadata: dict[str, Any] = field(default_factory=dict)


def _now_iso() -> str:
    return datetime.now(UTC).isoformat()


class OvertureCollector:
    """Release listing + bounded GeoParquet extraction."""

    source_name = "overture"

    def __init__(self, config: RefreshConfig | None = None, client: Any = None):
        self.config = config or RefreshConfig()
        self._client = client

    def _http(self) -> httpx.Client:
        return self._client or httpx.Client(timeout=self.config.request_timeout_s)

    def available_releases(self) -> list[str]:
        """List dated release prefixes from the public bucket (newest last)."""
        if self.config.overture_release:
            return [self.config.overture_release]
        if self.config.offline:
            raise CollectorBlocked(self.source_name, "offline mode: no release check")
        # The public bucket root lists release prefixes (the configured
        # release base points at the same bucket).
        url = "https://overturemaps-us-west-2.s3.amazonaws.com/"
        try:
            with self._http() as client:
                response = client.get(
                    url,
                    params={"list-type": "2", "prefix": "release/", "delimiter": "/"},
                )
                response.raise_for_status()
        except Exception as exc:
            raise CollectorBlocked(
                self.source_name, f"release listing unavailable: {type(exc).__name__}: {exc}"
            ) from exc
        releases = sorted({
            m.group(1).split("/")[1].strip("/")
            for m in _PREFIX_RE.finditer(response.text)
            if m.group(1).strip("/") != "release/"
        })
        if not releases:
            raise CollectorBlocked(self.source_name, "release listing returned no dated release")
        return releases

    def collect(self, release: str | None = None) -> CollectionResult:
        """Return normalized F&B places inside the configured bbox."""
        release = release or self.config.overture_release
        if not release:
            if self.config.fixture_dir:
                # A local fixture is a bounded snapshot, not a live release
                # check — never require network access for it.
                release = "local-fixture"
            else:
                releases = self.available_releases()
                release = releases[-1]
        stats = IngestionStats(source_name=self.source_name, source_release=release)
        raw_rows, metadata = self._read(release)
        snapshot_at = metadata.get("snapshot_at") or _now_iso()
        records: list[SourceRecord] = []
        for raw in raw_rows:
            stats.records_downloaded += 1
            record, reason = normalize_overture(
                raw, release=release, snapshot_at=snapshot_at, config=self.config
            )
            if record is None:
                stats.reject(reason or "invalid_record")
            else:
                records.append(record)
            if len(records) >= self.config.max_records_per_source:
                break
        stats.records_accepted = len(records)
        checksum = hashlib.sha256(
            "|".join(sorted(f"{r.natural_key}:{r.fingerprint()}" for r in records)).encode()
        ).hexdigest()
        return CollectionResult(
            source_name=self.source_name,
            release=release,
            snapshot_at=snapshot_at,
            licence=OVERTURE_LICENCE,
            records=records,
            checksum=checksum,
            stats=stats,
            full_snapshot=metadata.get("full_snapshot", False),
            source_metadata=metadata,
        )

    # ------------------------------------------------------------------

    def _read(self, release: str) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        """Read bounded rows from a local fixture or a remote GeoParquet path."""
        if self.config.fixture_dir:
            return self._read_fixture(release)
        if self.config.offline:
            raise CollectorBlocked(
                self.source_name, "offline mode and no SITEWISE_REFRESH_FIXTURE_DIR"
            )
        return self._read_geoparquet(release)

    def _read_fixture(self, release: str) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        root = Path(self.config.fixture_dir)
        files = sorted(root.glob("overture*.parquet")) + sorted(root.glob("overture*.json"))
        if not files:
            raise CollectorBlocked(
                self.source_name, f"no overture*.parquet/json fixture in {root}"
            )
        rows: list[dict[str, Any]] = []
        for path in files:
            if path.suffix == ".parquet":
                import pyarrow.parquet as pq

                table = pq.read_table(
                    path,
                    columns=[
                        c for c in (
                            "id", "names", "name", "categories", "category",
                            "latitude", "longitude", "bbox", "addresses",
                            "operating_status", "update_time", "version",
                            "phone", "website", "confidence",
                        ) if c in pq.read_schema(path).names
                    ],
                )
                rows.extend(table.to_pylist())
            else:
                payload = json.loads(path.read_text(encoding="utf-8"))
                rows.extend(payload if isinstance(payload, list) else payload.get("records", []))
        return rows, {
            "snapshot_at": datetime.fromtimestamp(
                max(p.stat().st_mtime for p in files), UTC
            ).isoformat(),
            "source": "local_fixture",
            "files": [p.name for p in files],
            "full_snapshot": False,
        }

    def _read_geoparquet(self, release: str) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        """DuckDB column/row pruning over the public HTTPS GeoParquet path.

        ``bbox`` is Overture's own bounding-box struct; pushing the study-area
        predicate into the scan keeps the download bounded. Everything else is
        filtered in :mod:`normalizer`.
        """
        try:
            import duckdb
        except ImportError as exc:  # pragma: no cover
            raise CollectorBlocked(self.source_name, "duckdb not installed") from exc
        min_lon, min_lat, max_lon, max_lat = self.config.bbox
        base = self.config.overture_release_base.rstrip("/")
        prefix = f"release/{release}/theme=places/type=place/"
        # List the concrete part files through the public S3 API: DuckDB's
        # HTTP glob does not expand on this bucket, and an explicit list also
        # bounds exactly which objects are read.
        # Paginate ALL ListObjectsV2 pages. One response can be truncated.
        # An explicit budget is a FAILURE, not a successful partial snapshot.
        try:
            from xml.etree import ElementTree as ET
            parts = []
            token = None
            with self._http() as client:
                while True:
                    params = {"list-type": "2", "prefix": prefix}
                    if token:
                        params["continuation-token"] = token
                    response = client.get(
                        "https://overturemaps-us-west-2.s3.amazonaws.com/",
                        params=params,
                    )
                    response.raise_for_status()
                    root = ET.fromstring(response.content)
                    ns = {"s3": "http://s3.amazonaws.com/doc/2006-03-01/"}
                    for item in root.findall("s3:Contents", ns):
                        key_node = item.find("s3:Key", ns)
                        if key_node is not None and key_node.text and key_node.text.endswith(".parquet"):
                            parts.append(key_node.text)
                    truncated = root.findtext("s3:IsTruncated", default="false", namespaces=ns).lower() == "true"
                    if not truncated:
                        break
                    next_token = root.findtext("s3:NextContinuationToken", namespaces=ns)
                    if not next_token or next_token == token:
                        raise RuntimeError("S3 listing truncated without a new continuation token")
                    token = next_token
        except Exception as exc:
            raise CollectorBlocked(
                self.source_name,
                f"complete release part listing failed: {type(exc).__name__}: {str(exc)[:200]}",
            ) from exc
        parts = sorted(set(parts))
        if not parts:
            raise CollectorBlocked(self.source_name, f"no parquet parts under {prefix}")
        if len(parts) > self.config.max_overture_parts:
            raise CollectorBlocked(self.source_name,
                f"incomplete coverage: {len(parts)} parts found but max_overture_parts="
                f"{self.config.max_overture_parts}. Increase limit or use explicit bounded mode.")
        parts_total = len(parts)
        # ``base`` already ends with /release/, and the listed keys are
        # bucket-relative (release/<id>/...).
        paths = [f"{base}/{release}/theme=places/type=place/{key.rsplit('/', 1)[-1]}" for key in parts]
        con = duckdb.connect()
        try:
            import tempfile
            from pathlib import Path

            ext_dir = Path(tempfile.gettempdir()) / "sitewise_duckdb_ext"
            ext_dir.mkdir(parents=True, exist_ok=True)
            con.execute(f"SET extension_directory = '{ext_dir.as_posix()}'")
            con.execute("INSTALL httpfs; LOAD httpfs;")
            con.execute("SET enable_object_cache = true")
            rows = con.execute(
                """
                SELECT id, names, taxonomy.primary AS taxonomy_primary,
                       basic_category, confidence,
                       (bbox.xmin + bbox.xmax) / 2.0 AS longitude,
                       (bbox.ymin + bbox.ymax) / 2.0 AS latitude,
                       addresses, operating_status, version,
                       phones[1] AS phone, websites[1] AS website
                FROM read_parquet(?)
                WHERE bbox.xmax >= ? AND bbox.xmin <= ?
                  AND bbox.ymax >= ? AND bbox.ymin <= ?
                  AND (
                    lower(coalesce(taxonomy.primary, '')) LIKE '%restaurant%'
                    OR lower(coalesce(taxonomy.primary, '')) LIKE '%cafe%'
                    OR lower(coalesce(taxonomy.primary, '')) LIKE '%fast_food%'
                    OR lower(coalesce(taxonomy.primary, '')) LIKE '%food_court%'
                    OR lower(coalesce(taxonomy.primary, '')) LIKE '%bakery%'
                    OR lower(coalesce(taxonomy.primary, '')) LIKE '%bar%'
                    OR lower(coalesce(taxonomy.primary, '')) LIKE '%ice_cream%'
                    OR lower(coalesce(basic_category, '')) LIKE '%restaurant%'
                    OR lower(coalesce(basic_category, '')) LIKE '%cafe%'
                    OR lower(coalesce(basic_category, '')) LIKE '%bakery%'
                  )
                LIMIT ?
                """,
                [
                    paths,
                    min_lon, max_lon,
                    min_lat, max_lat,
                    self.config.max_records_per_source * 5,
                ],
            ).fetchall()
        except Exception as exc:
            raise CollectorBlocked(
                self.source_name,
                f"bounded GeoParquet read failed: {type(exc).__name__}: {str(exc)[:300]}",
            ) from exc
        finally:
            con.close()
        keys = (
            "id", "names", "taxonomy_primary", "basic_category", "confidence",
            "longitude", "latitude", "addresses", "operating_status",
            "version", "phone", "website",
        )
        return [dict(zip(keys, row)) for row in rows], {
            "snapshot_at": _now_iso(),
            "source": f"{base}/{prefix}",
            "parts_read": len(paths),
            "parts_total": parts_total,
            "all_parts_verified": len(paths) == parts_total,
            "full_snapshot": False,  # bbox-based, not a global snapshot
            "release": release,
        }
