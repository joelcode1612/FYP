#!/usr/bin/env python
"""SiteWise geospatial refresh CLI.

One-shot (cron / Windows Task Scheduler / manual)::

    cd backend
    .venv\\Scripts\\python.exe scripts/run_data_refresh.py --once --source all \
        --local-fixture tests/fixtures/geo --dry-run

Scheduler process (a SINGLE process, never FastAPI startup hooks)::

    .venv\\Scripts\\python.exe scripts/run_data_refresh.py --schedule

The CLI acquires a PostgreSQL advisory lock for the whole run, so a scheduled
job and a manual run can never interleave. Every counter printed is measured
from the actual operation; a blocked download is reported as an error, never
as a successful empty refresh.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

# Allow direct script execution from the backend/ directory.
_BACKEND = Path(__file__).resolve().parents[1]
if str(_BACKEND / "src") not in sys.path:
    sys.path.insert(0, str(_BACKEND / "src"))

from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine
from sitewise.ingestion import (
    CollectorBlocked,
    IngestionStats,
    RefreshAlreadyRunning,
    RefreshConfig,
    RefreshLock,
    RefreshState,
    ensure_schema,
)
from sitewise.ingestion.overture_sync import OvertureSynchronizer
from sitewise.ingestion.sources import OSMCollector, OvertureCollector
from sitewise.ingestion.synchronizer import OutletSynchronizer
from sitewise.services.feature_refresh_service import FeatureRefreshService

WINDOWS_TASK_XML = """<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>2026-11-12T03:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByWeek>
        <DaysOfWeek><Monday /></DaysOfWeek>
        <WeeksInterval>1</WeeksInterval>
      </ScheduleByWeek>
    </CalendarTrigger>
  </Triggers>
  <Principals><Principal id="Author"><LogonType>InteractiveToken</LogonType></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>{python}</Command>
      <Arguments>"{script}" --once --source all --kind all</Arguments>
      <WorkingDirectory>{cwd}</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"""


def build_config(args: argparse.Namespace) -> RefreshConfig:
    config = RefreshConfig()
    overrides: dict[str, Any] = {}
    if args.local_fixture:
        overrides["fixture_dir"] = str(Path(args.local_fixture).resolve())
        overrides["offline"] = True
    if args.offline:
        overrides["offline"] = True
    if overrides:
        config = replace(config, **overrides)
    return config


def _check_only(config: RefreshConfig) -> dict:
    result: dict[str, Any] = {"mode": "check", "status": "available", "sources": {}}
    overture = OvertureCollector(config)
    try:
        releases = overture.available_releases()
        result["sources"]["overture"] = {
            "status": "available",
            "releases": releases[-5:],
            "latest": releases[-1],
        }
    except CollectorBlocked as exc:
        result["status"] = "partial"
        result["sources"]["overture"] = {"status": "blocked", "error": exc.reason}
    osm = OSMCollector(config)
    try:
        result["sources"]["openstreetmap"] = {
            "status": "available",
            **osm.extract_metadata(),
        }
    except CollectorBlocked as exc:
        result["status"] = "partial"
        result["sources"]["openstreetmap"] = {"status": "blocked", "error": exc.reason}
    return result


def _status(config: RefreshConfig, session: Session) -> dict:
    state = RefreshState(session)
    counts = session.execute(
        text(
            "SELECT refresh_status, count(*) FROM fyp.property_feature_freshness GROUP BY 1"
        )
    ).all()
    runs = session.execute(
        text(
            "SELECT kind, status, started_at, finished_at, metrics "
            "FROM fnb_a.refresh_run ORDER BY started_at DESC LIMIT 3"
        )
    ).mappings().all()
    return {
        "mode": "status",
        "last_successful_snapshot": state.last_successful_snapshot(),
        "provenance": state.provenance_summary(),
        "freshness_counts": {str(k): int(v) for k, v in counts},
        "recent_runs": [
            {
                "kind": r["kind"],
                "status": r["status"],
                "started_at": r["started_at"].isoformat() if r["started_at"] else None,
                "finished_at": r["finished_at"].isoformat() if r["finished_at"] else None,
                "metrics": r["metrics"],
            }
            for r in runs
        ],
    }


def run_once(args: argparse.Namespace, config: RefreshConfig) -> dict:
    """One complete refresh (or a dry-run measurement)."""
    started = time.perf_counter()
    overall = IngestionStats(status="success")
    sources = ("openstreetmap", "overture") if args.source == "all" else (args.source,)
    last_snapshot: dict | None = None
    metrics: dict[str, Any] = {
        "mode": "dry_run" if args.dry_run else "once",
        "kind": args.kind,
        "sources": {},
        "feature_refresh": {},
        "status": "success",
        "errors": [],
    }
    try:
        with RefreshLock(config.advisory_lock_key), Session(engine) as session:
            if not args.dry_run:
                ensure_schema(session)
            state = RefreshState(session)
            run_id = state.start_run(args.kind) if not args.dry_run else None
            changed_points: list[tuple[float, float]] = []
            for source in sources:
                source_metrics = _refresh_source(
                    source, args, config, session, state, changed_points
                )
                metrics["sources"][source] = source_metrics
                if source_metrics.get("status") == "blocked":
                    overall.status = "partial"
                    overall.errors.append(
                        f"{source}: {source_metrics.get('error', 'blocked')}"
                    )
            if args.kind in {"competitors", "all"} and changed_points:
                if args.dry_run:
                    affected = FeatureRefreshService(session, config).affected_property_ids(
                        changed_points
                    )
                    metrics["feature_refresh"] = {
                        "properties_affected": len(affected),
                        "properties_recalculated": 0,
                        "dry_run": True,
                    }
                else:
                    metrics["feature_refresh"] = FeatureRefreshService(
                        session, config
                    ).refresh_for_changed_outlets(changed_points)
                    overall.properties_affected = metrics["feature_refresh"][
                        "properties_affected"
                    ]
                    overall.properties_recalculated = metrics["feature_refresh"][
                        "properties_recalculated"
                    ]
                    overall.successful_computations = metrics["feature_refresh"][
                        "successful_computations"
                    ]
                    overall.failed_computations = metrics["feature_refresh"][
                        "failed_computations"
                    ]
            elif args.kind in {"roads", "demographics"} and not args.dry_run:
                pending = FeatureRefreshService(session, config).stale_property_ids()
                metrics["feature_refresh"] = FeatureRefreshService(
                    session, config
                ).refresh_population_only(pending)
            if not args.dry_run:
                last_snapshot = state.last_successful_snapshot()
                state.finish_run(
                    run_id,
                    overall.status if overall.status != "success" else "success",
                    {"sources": metrics["sources"], "feature_refresh": metrics["feature_refresh"]},
                    "; ".join(overall.errors)[:1000] or None,
                )
    except RefreshAlreadyRunning as exc:
        metrics["status"] = "skipped"
        metrics["errors"].append(str(exc))
        return metrics

    overall.duration_seconds = round(time.perf_counter() - started, 3)
    metrics["status"] = overall.status
    metrics["execution"] = {
        "duration_seconds": overall.duration_seconds,
        "errors": overall.errors,
        "last_successful_snapshot": last_snapshot,
    }
    return metrics


def _refresh_source(
    source: str,
    args: argparse.Namespace,
    config: RefreshConfig,
    session: Session,
    state: RefreshState,
    changed_points: list[tuple[float, float]],
) -> dict:
    """Collect → validate → deduplicate → incrementally synchronize ONE source."""
    collector = OSMCollector(config) if source == "openstreetmap" else OvertureCollector(config)
    try:
        release: str | None = args.release or None
        result = collector.collect(release)
    except CollectorBlocked as exc:
        if not args.dry_run:
            state.record_snapshot(
                source_name=source,
                release=release or "unresolved",
                snapshot_at=datetime.now(UTC).isoformat(),
                licence="",
                checksum="",
                stats={},
                status="failed",
                error=exc.reason,
            )
        return {"status": "blocked", "error": exc.reason, "source": source}

    stats = result.stats
    snapshot_entry: dict[str, Any] = {
        "release": result.release,
        "snapshot_at": result.snapshot_at,
        "checksum": result.checksum,
        "licence": result.licence,
        "records_downloaded": stats.records_downloaded,
        "records_accepted": stats.records_accepted,
        "records_rejected": stats.records_rejected,
        "rejection_reasons": stats.rejection_reasons,
        "full_snapshot": result.full_snapshot,
    }
    if not args.dry_run and not args.force and state.snapshot_processed(source, result.release):
        snapshot_entry["status"] = "skipped_unchanged_release"
        snapshot_entry["records_inserted"] = 0
        snapshot_entry["records_updated"] = 0
        snapshot_entry["records_unchanged"] = 0
        return snapshot_entry

    if args.dry_run:
        snapshot_entry.update({
            "status": "dry_run",
            "records_inserted": 0,
            "records_updated": 0,
            "records_unchanged": 0,
            "duplicates_detected": stats.duplicates_detected,
        })
        return snapshot_entry

    if source == "openstreetmap":
        sync = OutletSynchronizer(session, config).sync(
            result.records, stats=stats, full_snapshot=result.full_snapshot
        )
    else:
        sync = OvertureSynchronizer(session, config).sync(result.records, stats)
    changed_points.extend(sync.changed_points)
    state.record_snapshot(
        source_name=source,
        release=result.release,
        snapshot_at=result.snapshot_at,
        licence=result.licence,
        checksum=result.checksum,
        stats=stats.as_dict(),
        status="current",
    )
    snapshot_entry.update({
        "status": "current",
        "records_inserted": stats.records_inserted,
        "records_updated": stats.records_updated,
        "records_unchanged": stats.records_unchanged,
        "duplicates_detected": stats.duplicates_detected,
        "ambiguous_matches": stats.ambiguous_matches,
        "records_absent_unproven": stats.records_absent_unproven,
        "properties_affected_points": len(sync.changed_points),
    })
    return snapshot_entry


def run_scheduler(config: RefreshConfig, args: argparse.Namespace) -> None:
    """A DEDICATED scheduler process (never a FastAPI startup hook)."""
    from apscheduler.schedulers.background import BackgroundScheduler

    scheduler = BackgroundScheduler(timezone="UTC")

    def job(kind: str, source: str) -> None:
        job_args = argparse.Namespace(**vars(args))
        job_args.kind = kind
        job_args.source = source
        job_args.dry_run = False
        job_args.schedule = False
        print(json.dumps(run_once(job_args, config), default=str), flush=True)

    scheduler.add_job(
        job, "interval", args=["competitors", "all"],
        seconds=config.source_check_interval_s,
        id="weekly_sources", max_instances=1, coalesce=True,
    )
    scheduler.add_job(
        job, "interval", args=["roads", "all"],
        seconds=config.roads_refresh_interval_s,
        id="monthly_roads", max_instances=1, coalesce=True,
    )
    scheduler.add_job(
        job, "interval", args=["demographics", "all"],
        seconds=config.demographics_refresh_interval_s,
        id="monthly_demographics", max_instances=1, coalesce=True,
    )
    scheduler.start()
    print("SiteWise refresh scheduler running (Ctrl+C to stop).", flush=True)
    try:
        while True:
            time.sleep(60)
    except (KeyboardInterrupt, SystemExit):
        scheduler.shutdown()


def install_windows_task() -> dict:
    path = Path(__file__).with_name("SiteWiseGeoRefresh.xml")
    path.write_text(
        WINDOWS_TASK_XML.format(
            python=sys.executable,
            script=str(Path(__file__).resolve()),
            cwd=str(_BACKEND),
        ),
        encoding="utf-16",
    )
    return {
        "xml": str(path),
        "command": f'schtasks /Create /TN "SiteWiseGeoRefresh" /XML "{path}" /F',
        "note": "Registration is NOT performed automatically; run the command as administrator.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="SiteWise geospatial refresh")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--once", action="store_true", help="single bounded refresh (default)")
    mode.add_argument("--check", action="store_true", help="check source releases only")
    mode.add_argument("--status", action="store_true", help="show freshness/provenance state")
    mode.add_argument("--schedule", action="store_true", help="run as a dedicated scheduler")
    mode.add_argument("--install-windows-task", action="store_true", help="write Task Scheduler XML")
    parser.add_argument("--source", choices=["osm", "overture", "all"], default="all")
    parser.add_argument("--kind", choices=["competitors", "roads", "demographics", "all"],
                        default="competitors")
    parser.add_argument("--release", default="", help="pin a source release id")
    parser.add_argument("--local-fixture", default="", help="offline fixture directory")
    parser.add_argument("--offline", action="store_true", help="no network calls")
    parser.add_argument("--dry-run", action="store_true", help="measure, do not write")
    parser.add_argument("--force", action="store_true", help="reprocess an already-current release")
    parser.add_argument("--ensure-schema", action="store_true", help="create additive tables, then exit")
    args = parser.parse_args()

    # Normalize the CLI source names to the stored provider names.
    args.source = {"osm": "openstreetmap", "overture": "overture", "all": "all"}[args.source]
    config = build_config(args)

    try:
        if args.install_windows_task:
            output = install_windows_task()
        elif args.ensure_schema:
            with Session(engine) as session:
                ensure_schema(session)
            output = {"mode": "ensure_schema", "status": "success"}
        elif args.status:
            with Session(engine) as session:
                output = _status(config, session)
        elif args.check:
            output = _check_only(config)
        elif args.schedule:
            run_scheduler(config, args)
            return 0
        else:
            output = run_once(args, config)
    except Exception as exc:  # noqa: BLE001 - exact reason is reported
        output = {"status": "failed", "error": f"{type(exc).__name__}: {exc}"}
    print(json.dumps(output, indent=2, default=str))
    return 0 if output.get("status") in {"success", "partial", "skipped", "available"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
