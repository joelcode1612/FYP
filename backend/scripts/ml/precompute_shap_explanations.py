"""Controlled, resumable precomputation of genuine SHAP explanations.

Populates the persistent validated-explanation cache
(``ml_explanation_cache``) for the research catalogue properties whose
complete feature vectors and licensed background data are available, using
the ACTIVE PU variant and its own verified background.

Guarantees (performance brief §4):

* the actual deployed artifact, its exact feature order and its verified
  background — the same computation the request path performs;
* every stored explanation passed the additivity check AND the
  score-identity check, otherwise it is recorded as failed with its reason;
* already-valid explanations are skipped (idempotent — re-running resumes);
* failures are tracked with truthful reasons and never retried forever;
* nothing here runs automatically at FastAPI startup.

Usage (from ``backend/``):
    .venv/Scripts/python scripts/ml/precompute_shap_explanations.py [--limit N]
        [--property MD-00510] [--retry-failed] [--dry-run]
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SRC = REPO / "backend" / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from sqlmodel import Session, select  # noqa: E402

from sitewise.core.logging import configure_logging, logger  # noqa: E402
from sitewise.db.analytics_session import analytics_engine  # noqa: E402
from sitewise.db.session import engine as operational_engine  # noqa: E402
from sitewise.ml import shap_explainer  # noqa: E402
from sitewise.ml.feature_bridge import merge_bridge_features  # noqa: E402
from sitewise.ml.model_loader import ModelLoader  # noqa: E402
from sitewise.ml.property_features import PropertyFeatureRepository  # noqa: E402
from sitewise.ml.pu_variant import resolve_variant  # noqa: E402
from sitewise.services import explanation_cache  # noqa: E402
from sitewise.services.property_insights_service import (  # noqa: E402
    PropertyInsightsService,
    _background_path,
    _reference_background_rows,
)


def catalogue_property_ids(session: Session) -> list[str]:
    """Every catalogue id, in stable order (the 955 research rows)."""
    from sqlalchemy import text

    rows = session.execute(
        text("SELECT id FROM fyp.catalogue_properties ORDER BY id")
    ).scalars().all()
    return [str(row) for row in rows]


def precompute_one(
    analytics: Session, operational: Session, property_id: str
) -> tuple[str, str, str]:
    """Compute and store one explanation. Returns (property, outcome, detail)."""
    variant = resolve_variant()
    loaded = ModelLoader().load_cached(variant.layer1_model)
    background_file = _background_path(variant.key)
    background = _reference_background_rows(loaded.feature_names, background_file)
    if not background:
        return property_id, "failed", "no verified background rows for the active variant"

    try:
        bundle = PropertyFeatureRepository(analytics).get(
            property_id, loaded.feature_names, source="catalog"
        )
        coverage = merge_bridge_features(bundle, expected_features=loaded.feature_names)
        if variant.key == "expanded64":
            from sitewise.ml.pu_expanded import merge_expanded_bridge_features

            coverage = merge_expanded_bridge_features(
                coverage, expected_features=loaded.feature_names
            )
    except Exception as exc:  # noqa: BLE001 - tracked failure, not a crash
        return property_id, "failed", f"feature resolution failed: {type(exc).__name__}: {exc}"

    values = dict(coverage.values)
    if coverage.missing_features and variant.key != "expanded64":
        return (
            property_id,
            "incomplete",
            f"{len(coverage.missing_features)} feature(s) missing: "
            + ", ".join(list(coverage.missing_features)[:6]),
        )

    identity = explanation_cache.ExplanationIdentity(
        property_id=property_id,
        model_name=variant.layer1_model,
        model_version=variant.version,
        artifact_sha256=explanation_cache.cached_file_sha256(
            Path(ModelLoader().artifacts_dir) / str(loaded.meta.get("artifact_filename"))
        ),
        feature_digest=explanation_cache.feature_digest(values),
        background_sha256=PropertyInsightsService._reference_background_sha256(background_file),
        background_size=len(background),
    )

    # Skip already-valid explanations: resumable + idempotent by construction.
    if explanation_cache.get_ready_raw(operational, identity.cache_key()) is not None:
        return property_id, "skipped", "already valid"

    service = PropertyInsightsService(
        session=analytics, analytics_session=analytics, cache_session=None
    )
    merged, payload, derived_key = service._insights_full(property_id)
    if payload is None:
        reason = (merged.get("reason") or {}).get("detail") or (
            merged.get("reason") or {}
        ).get("message") or "no explanation payload"
        explanation_cache.mark_failed(operational, identity.cache_key(), str(reason))
        return property_id, "failed", str(reason)[:300]

    # The derived identity reflects what was ACTUALLY computed; store under it
    # and close any stale row this run may have created for a different one.
    derived_identity = explanation_cache.ExplanationIdentity(
        property_id=property_id,
        model_name=variant.layer1_model,
        model_version=variant.version,
        artifact_sha256=explanation_cache.cached_file_sha256(
            Path(ModelLoader().artifacts_dir) / str(loaded.meta.get("artifact_filename"))
        ),
        feature_digest=explanation_cache.feature_digest(
            {k: v for k, v in (coverage.values or {}).items()}
        ),
        background_sha256=PropertyInsightsService._reference_background_sha256(background_file),
        background_size=int(
            (payload.get("explanation") or {}).get("background_size") or len(background)
        ),
    )
    explanation_cache.store_ready(operational, derived_identity, payload)
    if derived_identity.cache_key() != identity.cache_key():
        explanation_cache.close_superseded(
            operational, identity.cache_key(), derived_identity.cache_key()
        )
    explanation = payload.get("explanation") or {}
    detail = (
        f"output={explanation.get('output')}, additivity_error="
        f"{explanation.get('additivity_error')}, background={explanation.get('background_size')}"
    )
    return property_id, "ready", detail


def main() -> int:
    configure_logging()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limit", type=int, default=None, help="stop after N properties")
    parser.add_argument(
        "--property", action="append", default=[],
        help="precompute only these catalogue ids (repeatable)",
    )
    parser.add_argument(
        "--retry-failed", action="store_true",
        help="recompute properties whose previous attempt failed",
    )
    parser.add_argument("--dry-run", action="store_true", help="report, do not write")
    args = parser.parse_args()

    if not shap_explainer.process_warm():
        # The CLI process pays the one-off compilation up front so the batch
        # itself runs at full speed.
        logger.info("Warming SHAP for this process (one-off)...")
        shap_explainer.mark_warm()  # CLI context: latency is not user-facing

    started = time.perf_counter()
    counts = {"ready": 0, "skipped": 0, "failed": 0, "incomplete": 0}
    examples: dict[str, list[str]] = {k: [] for k in counts}

    with Session(analytics_engine) as analytics, Session(operational_engine) as operational:
        if args.property:
            targets = [p.strip() for p in args.property]
        else:
            targets = catalogue_property_ids(analytics)
        if args.limit:
            targets = targets[: args.limit]
        logger.info("Precomputing explanations for %d properties (variant=%s)",
                    len(targets), resolve_variant().key)

        done = 0
        for property_id in targets:
            if args.dry_run:
                logger.info("[dry-run] would precompute %s", property_id)
                done += 1
                continue
            if not args.retry_failed:
                pass  # get_ready_raw skip happens inside precompute_one
            try:
                _, outcome, detail = precompute_one(analytics, operational, property_id)
            except Exception as exc:  # noqa: BLE001 - a bad row never stops the batch
                outcome, detail = "failed", f"{type(exc).__name__}: {exc}"
            counts[outcome] = counts.get(outcome, 0) + 1
            if outcome in {"failed", "incomplete"} and len(examples[outcome]) < 8:
                examples[outcome].append(f"{property_id}: {detail}")
            done += 1
            if done % 50 == 0:
                rate = done / max(time.perf_counter() - started, 1e-6)
                logger.info("progress %d/%d (%.1f/s) %s", done, len(targets), rate, counts)

    summary = {
        "targets": len(targets),
        "elapsed_seconds": round(time.perf_counter() - started, 1),
        "outcomes": counts,
        "examples": {k: v for k, v in examples.items() if v},
        "dry_run": args.dry_run,
    }
    logger.info("Precompute summary: %s", json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    return 0 if counts["failed"] == 0 or args.dry_run else 1


if __name__ == "__main__":
    raise SystemExit(main())
