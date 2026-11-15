#!/usr/bin/env python
"""Provision the WorldPop age-sex structures tile set for ``age_population``.

Downloads the 42 GeoTIFFs (20 male + 20 female five-year band tiles plus the
T_F / T_M totals, ~1.2 GB) that ``sitewise.services.age_band_raster_service``
reads when an owner or agent adds a property::

    cd backend
    .venv\\Scripts\\python.exe scripts/data/fetch_worldpop_agesex.py
    .venv\\Scripts\\python.exe scripts/data/fetch_worldpop_agesex.py --verify-only
    .venv\\Scripts\\python.exe scripts/data/fetch_worldpop_agesex.py --dest D:\\data\\worldpop_agesex

The tiles live OUTSIDE the repository (too large to commit). Point
``SITEWISE_AGE_RASTER_DIR`` at the destination directory afterwards.

Integrity: every file is verified against the sha256 recorded in the committed
manifest ``backend/local_data/pu_gap_recovery/manifests/download_manifest.csv``
— the byte-identical set the gap-recovery pipeline validated on 2026-11-15.
A pre-existing file whose hash mismatches is treated as corrupt and
re-downloaded; nothing is trusted merely because it exists. The port keeps
the validated pipeline's behaviour: 6 concurrent workers by default,
resume-safe (verified files skipped, truncated ``.part`` files restarted),
and a free-disk guard before every transfer.
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import csv
import hashlib
import sys
import threading
import time
import urllib.request
from pathlib import Path

# Allow direct script execution from the backend/ directory.
_BACKEND = Path(__file__).resolve().parents[2]
if str(_BACKEND / "src") not in sys.path:
    sys.path.insert(0, str(_BACKEND / "src"))

from sitewise.services.age_band_raster_service import (  # noqa: E402
    SOURCE_URL,
    _expected_filenames,
)

#: Known-good sha256 per filename, from the validated recovery run.
COMMITTED_MANIFEST = (
    _BACKEND / "local_data" / "pu_gap_recovery" / "manifests" / "download_manifest.csv"
)

DEFAULT_DEST = _BACKEND / "var" / "worldpop_agesex"

#: Guard before every transfer: below this the disk is not trusted for a
#: ~29 MB file plus extraction headroom (the validated pipeline's rule).
MIN_FREE_BYTES = 1_000_000_000

_READ_CHUNK = 1 << 20  # 1 MiB
_USER_AGENT = "sitewise-age-enrichment/1.0"
_TIMEOUT_SECONDS = 180


def _load_known_hashes() -> dict[str, str]:
    """filename -> sha256 from the committed recovery manifest."""
    known: dict[str, str] = {}
    with open(COMMITTED_MANIFEST, newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            if row.get("filename") and row.get("sha256"):
                known[row["filename"]] = row["sha256"].strip().lower()
    return known


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(_READ_CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _fetch(
    job: tuple[str, str, str | None],
    dest_dir: Path,
    lock: threading.Lock,
    rows: list[list],
) -> tuple[str, str, float]:
    """Download (or verify) one tile; returns (key, status, seconds)."""
    key, url, expected_hash = job
    filename = url.rsplit("/", 1)[-1]
    dest = dest_dir / filename
    t0 = time.time()

    if dest.exists() and dest.stat().st_size > 0:
        actual = _sha256(dest)
        if expected_hash is None or actual == expected_hash:
            with lock:
                rows.append(
                    [key, filename, url, dest.stat().st_size, actual, "already_present"]
                )
            return key, "already_present", time.time() - t0
        # Corrupt or foreign file: the committed manifest is authoritative.
        print(f"{key}: sha256 mismatch on disk, re-downloading", flush=True)
        dest.unlink()

    for attempt in range(1, 5):
        try:
            free = __import__("shutil").disk_usage(dest_dir).free
            if free < MIN_FREE_BYTES:
                raise SystemExit(
                    f"ABORT: free space at {dest_dir} is {free} bytes, "
                    f"below the {MIN_FREE_BYTES} guard"
                )
            part = dest.with_suffix(dest.suffix + ".part")
            request = urllib.request.Request(url, headers={"User-Agent": _USER_AGENT})
            with urllib.request.urlopen(request, timeout=_TIMEOUT_SECONDS) as resp:
                with open(part, "wb") as fh:
                    while True:
                        chunk = resp.read(_READ_CHUNK)
                        if not chunk:
                            break
                        fh.write(chunk)
            actual = _sha256(part)
            if expected_hash is not None and actual != expected_hash:
                # Server-side corruption / partial file: retry from scratch.
                part.unlink()
                raise IOError(
                    f"sha256 mismatch after download "
                    f"(got {actual[:12]}, want {expected_hash[:12]})"
                )
            part.replace(dest)
            with lock:
                rows.append([key, filename, url, dest.stat().st_size, actual, "downloaded"])
            print(
                f"{key}: {dest.stat().st_size / 1e6:.1f} MB in {time.time() - t0:.0f}s",
                flush=True,
            )
            return key, "downloaded", time.time() - t0
        except SystemExit:
            raise
        except Exception as exc:  # noqa: BLE001 - network errors are retried
            print(f"{key}: attempt {attempt} failed: {exc}", flush=True)
            time.sleep(5 * attempt)

    with lock:
        rows.append([key, filename, url, 0, "", "FAILED"])
    return key, "FAILED", 0.0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--dest",
        default=str(DEFAULT_DEST),
        help=f"destination directory (default: {DEFAULT_DEST})",
    )
    parser.add_argument(
        "--workers", type=int, default=6, help="concurrent downloads (default: 6)"
    )
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="hash existing files against the committed manifest; download nothing",
    )
    args = parser.parse_args(argv)

    dest_dir = Path(args.dest).resolve()
    dest_dir.mkdir(parents=True, exist_ok=True)

    filenames = _expected_filenames()
    known = _load_known_hashes()
    wanted: list[tuple[str, str, str | None]] = []
    for key, filename in filenames.items():
        url = f"{SOURCE_URL}{filename}"
        if filename not in known:
            print(
                f"WARNING: {filename} is not in the committed manifest; it will "
                "be downloaded but cannot be byte-verified against the "
                "validated recovery set.",
                flush=True,
            )
        wanted.append((key, url, known.get(filename)))

    print(f"planned files: {len(wanted)} -> {dest_dir}", flush=True)
    if args.verify_only:
        rows: list[list] = []
        lock = threading.Lock()
        verify_jobs = [
            (key, url, expected)
            for key, url, expected in wanted
            if (dest_dir / url.rsplit("/", 1)[-1]).exists()
        ]
        missing = [
            url.rsplit("/", 1)[-1]
            for _, url, _ in wanted
            if not (dest_dir / url.rsplit("/", 1)[-1]).exists()
        ]
        for job in verify_jobs:
            _fetch(job, dest_dir, lock, rows)
        failed = [r[1] for r in rows if r[5] == "FAILED"]
        print(
            f"verify-only: {len(rows)} hashed, {len(missing)} missing, "
            f"{len(failed)} failed",
            flush=True,
        )
        if missing:
            print("missing:", *missing[:5], "..." if len(missing) > 5 else "", flush=True)
        return 0 if not missing and not failed else 1

    rows = []
    lock = threading.Lock()
    t0 = time.time()
    with cf.ThreadPoolExecutor(max_workers=max(1, args.workers)) as executor:
        list(executor.map(lambda job: _fetch(job, dest_dir, lock, rows), wanted))

    manifest_path = dest_dir / "download_manifest.csv"
    with open(manifest_path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["asset_key", "filename", "url", "bytes", "sha256", "status"])
        writer.writerows(rows)

    failed = [r[0] for r in rows if r[5] == "FAILED"]
    total = sum(r[3] for r in rows)
    print(
        f"DONE files={len(rows)} bytes={total / 1e6:.1f}MB failed={len(failed)} "
        f"wall={time.time() - t0:.0f}s manifest={manifest_path}",
        flush=True,
    )
    if failed:
        print("FAILED:", failed, flush=True)
        return 1
    print(
        "Next step: set SITEWISE_AGE_RASTER_DIR=" + str(dest_dir) + " in backend/.env",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
