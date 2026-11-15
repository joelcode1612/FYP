"""Background explanation worker: computes SHAP off the request path.

Design constraints (performance brief §7):

* Expensive computation never runs inside a user-facing HTTP request.
* Jobs are idempotent: the computation is a pure function of the property's
  resolved feature vector, the deployed artifact and the verified background,
  and the persistent cache identity captures all of them.
* Concurrent requests cannot create duplicate jobs: the persistent cache row
  is the single-flight primitive (unique primary key + lease), and the worker
  processes its in-process queue serially.
* Results are persisted after completion; failures are recorded with a
  truthful reason.
* Processing resumes after application restart: at startup the lifespan
  re-enqueues every unclaimed or lease-expired pending row.
* No Redis/Celery: this deployment runs one uvicorn worker; a daemon thread
  plus the durable pending rows in PostgreSQL satisfy every requirement
  without a new external service.
"""

from __future__ import annotations

import logging
import queue
import threading
import time
from typing import Any

from sitewise.db.analytics_session import analytics_engine
from sitewise.db.session import engine as operational_engine
from sitewise.services import explanation_cache
from sitewise.services.explanation_cache import ExplanationJob

logger = logging.getLogger("sitewise.explanations")


class ExplanationWorker:
    """Single-threaded daemon worker over an in-process FIFO of durable jobs."""

    def __init__(self) -> None:
        self._queue: queue.Queue[ExplanationJob] = queue.Queue()
        self._thread: threading.Thread | None = None
        self._start_lock = threading.Lock()

    # -- lifecycle -----------------------------------------------------------

    def start(self) -> None:
        """Start the daemon thread once per process (idempotent)."""
        with self._start_lock:
            if self._thread is not None and self._thread.is_alive():
                return
            self._thread = threading.Thread(
                target=self._run, name="shap-explanation-worker", daemon=True
            )
            self._thread.start()

    def resume(self, limit: int = 200) -> int:
        """Re-enqueue pending rows left behind by a previous process."""
        from sqlmodel import Session

        try:
            with Session(operational_engine) as session:
                jobs = explanation_cache.pending_jobs(session, limit=limit)
        except Exception:  # noqa: BLE001 - a cache table problem must not stop startup
            logger.warning("Explanation resume scan failed", exc_info=True)
            return 0
        for job in jobs:
            self.enqueue(job)
        if jobs:
            logger.info("Explanation worker resumed %d pending job(s)", len(jobs))
        return len(jobs)

    # -- queue ---------------------------------------------------------------

    def enqueue(self, job: ExplanationJob) -> bool:
        """Queue one job. Returns False only if the worker is not running."""
        if self._thread is None or not self._thread.is_alive():
            return False
        try:
            self._queue.put_nowait(job)
            return True
        except queue.Full:  # pragma: no cover - unbounded queue
            return False

    # -- loop ----------------------------------------------------------------

    def _run(self) -> None:
        while True:
            job = self._queue.get()
            try:
                self._process(job)
            except Exception:  # noqa: BLE001 - one bad job must not kill the worker
                logger.exception("Explanation job %s failed unexpectedly", job.cache_key[:16])
            finally:
                self._queue.task_done()

    def _process(self, job: ExplanationJob) -> None:
        from sqlmodel import Session

        from sitewise.services.property_insights_service import PropertyInsightsService

        started = time.perf_counter()
        try:
            with Session(analytics_engine) as analytics, Session(operational_engine) as operational:
                service = PropertyInsightsService(
                    session=analytics,
                    analytics_session=analytics,
                    # The operational session lets the compute path persist the
                    # validated payload itself; the worker never recurses into
                    # the scheduling branch (that branch only runs on a cold,
                    # unscheduled request).
                    cache_session=operational,
                )
                merged, payload, derived_key = service._insights_full(job.property_id)
                if payload is None:
                    reason = (merged.get("reason") or {}).get("detail") or (
                        merged.get("reason") or {}
                    ).get("message") or "Explanation could not be computed for this property."
                    explanation_cache.mark_failed(
                        operational, job.cache_key, str(reason)
                    )
                elif derived_key is not None and derived_key != job.cache_key:
                    # The stored payload went in under the freshly derived
                    # identity; close the stale pending row truthfully.
                    explanation_cache.close_superseded(
                        operational, job.cache_key, derived_key
                    )
                # derived_key == job.cache_key: the compute path already
                # upserted the row to 'ready'. derived_key is None only when
                # an in-process cache entry served the call, in which case the
                # request that computed it already stored the row.
        except Exception as exc:  # noqa: BLE001 - record, never crash the loop
            logger.warning("Explanation job %s failed: %s", job.cache_key[:16], exc)
            try:
                with Session(operational_engine) as operational:
                    explanation_cache.mark_failed(
                        operational, job.cache_key, f"{type(exc).__name__}: {exc}"
                    )
            except Exception:  # pragma: no cover - DB fully unavailable
                logger.exception("Could not record the failed explanation job")
            return
        logger.info(
            "Explanation job %s finished in %.2fs (status stored)",
            job.cache_key[:16],
            time.perf_counter() - started,
        )


#: Process-wide worker, started by the FastAPI lifespan.
_worker = ExplanationWorker()


def get_explanation_worker() -> ExplanationWorker:
    return _worker


def startup() -> dict[str, Any]:
    """Start the worker thread and resume durable pending jobs."""
    _worker.start()
    resumed = _worker.resume()
    return {"worker_started": True, "resumed_jobs": resumed}
