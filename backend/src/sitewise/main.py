from contextlib import asynccontextmanager
import re

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from sitewise.api.v1.router import router as v1_router
from sitewise.core.config import settings
from sitewise.core.exceptions import (
    AssessmentError,
    AuthError,
    ConflictError,
    ForbiddenError,
    NotFoundError,
    SiteWiseError,
    ValidationError,
)
from sitewise.core.supabase_admin import SupabaseAdminError
from sitewise.core.logging import configure_logging, logger
from sitewise.db.session import create_db_and_tables
from sitewise.frontend import DEFAULT_DIST_DIR, mount_frontend
from sitewise.project1.contracts import WorkflowHeld

configure_logging()


def _warm_explainers() -> None:
    """Pre-import SHAP and compile its numba paths off the request path.

    ``import shap`` costs seconds on this deployment and the first permutation
    explainer evaluation compiles its numba kernels (measured 13-35 s). Paying
    that inside a user request would miss the 3-second explanation target by
    an order of magnitude, so it is done once per worker in a daemon thread:
    the PU explainer path with the ACTIVE variant's own artifact and verified
    background (the kernels are dtype-keyed, so this readies every later
    explanation). A failure is logged
    and ignored: explanations then degrade to their documented "pending"/
    "unavailable" states instead of preventing startup. On completion the
    process is marked warm, which re-enables synchronous explanation
    computation for cache misses.
    """
    import threading

    def run() -> None:
        try:
            from sitewise.ml import shap_explainer

            pu_result = shap_explainer.warm_up_pu()
            logger.info("PU SHAP warm-up finished: %s", pu_result)
        except Exception:  # noqa: BLE001 - warm-up must never break the app
            logger.warning("PU SHAP warm-up failed; explanations stay lazy", exc_info=True)

    threading.Thread(target=run, name="shap-warmup", daemon=True).start()


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Schema creation is OFF by default: the application must not create or
    # migrate tables on startup. Enable SITEWISE_DB_AUTO_CREATE only for a
    # disposable local database.
    if settings.db_auto_create:
        try:
            create_db_and_tables()
        except Exception:
            # Fail fast: without the schema every data route would 500 while
            # /health still answered "ok". The traceback stays server-side.
            logger.exception("Database startup failed; the API will not start.")
            raise
    else:
        logger.info("Startup schema creation disabled (db_auto_create=false).")
    try:
        from sqlmodel import Session
        from sitewise.db.session import engine
        from sitewise.services.enrichment_schema import schema_gaps

        with Session(engine) as session:
            missing_schema = schema_gaps(session)
        if missing_schema:
            logger.warning("Enrichment schema requires migration: %s", ", ".join(missing_schema))
    except Exception as exc:
        logger.warning("Enrichment schema could not be checked: %s", type(exc).__name__)
    _warm_explainers()
    # Background explanation worker: computes SHAP off the request path and
    # resumes any pending durable jobs left by a previous process. Startup
    # never runs the full precompute (that is the controlled CLI's job).
    try:
        from sitewise.services import explanation_worker

        worker_status = explanation_worker.startup()
        logger.info("Explanation worker: %s", worker_status)
    except Exception:  # noqa: BLE001 - the API must start even if the worker cannot
        logger.exception("Explanation worker could not start; explanations degrade to pending")
    # Durable panorama stitching worker: claims fyp.panorama_jobs rows with
    # FOR UPDATE SKIP LOCKED; a job stalled by a crash or restart is
    # reclaimed after its claim goes stale, so no stitch is ever stranded.
    try:
        from sitewise.services import panorama_worker

        stitcher_status = panorama_worker.startup()
        logger.info("Panorama worker: %s", stitcher_status)
    except Exception:  # noqa: BLE001 - the API must start even if the worker cannot
        logger.exception("Panorama worker could not start; queued jobs wait for the next start")
    # Assignments are consolidated into local fyp.agent_listing_assignment.
    # The Supabase mirror/outbox worker has been retired; no runtime replication.
    yield


app = FastAPI(title="SiteWise API", version="0.1.0", lifespan=lifespan)

origins = [o.strip() for o in settings.cors_origins.split(",") if o.strip()]
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.exception_handler(AuthError)
@app.exception_handler(ForbiddenError)
@app.exception_handler(NotFoundError)
@app.exception_handler(ConflictError)
@app.exception_handler(ValidationError)
async def auth_error_handler(request: Request, exc: SiteWiseError):
    """Map authentication / authorization errors to their mandated statuses.

    AuthError -> 401, AuthUnavailableError -> 503 (it subclasses AuthError),
    ForbiddenError -> 403, NotFoundError -> 404, ConflictError -> 409,
    ValidationError -> 422. The failure classes are declared with the status
    they mean, so a business-rule rejection (a too-short enquiry message, an
    unparseable contact number) never surfaces as a 500. The messages are
    written for clients and carry no token or secret material.
    """
    return JSONResponse(status_code=exc.status_code, content={"detail": str(exc)})


@app.exception_handler(AssessmentError)
async def assessment_error_handler(request: Request, exc: AssessmentError):
    """Structured assessment failures: the browser bridge reads detail.code."""
    return JSONResponse(
        status_code=exc.status_code,
        content={"detail": {"code": exc.code, "message": str(exc)}},
    )


@app.exception_handler(SupabaseAdminError)
async def supabase_admin_error_handler(request: Request, exc: SupabaseAdminError):
    """A trusted provider operation failed (GoTrue/PostgREST). 502, no keys."""
    logger.error("Supabase admin operation failed on %s %s", request.method, request.url.path)
    return JSONResponse(status_code=exc.status_code, content={"detail": str(exc)})


# WorkflowHeld carries a fixed reason code and nothing else. The message is
# chosen from this static table; provider text, prompts and answer content are
# never interpolated. Unknown codes get a generic message plus the code.
_WORKFLOW_HELD_MESSAGES = {
    'DISCLOSURE_REAL_DATA_NOT_AUTHORIZED':
        'Real business data cannot be sent to the review provider until disclosure '
        'terms are authorized.',
    'DISCLOSURE_PURPOSE_MISMATCH':
        'This review purpose is not authorized for the provider.',
    'DISCLOSURE_SOURCE_MISMATCH':
        'The business details changed before the review could be sent.',
    'RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED':
        'The review service is waiting for its required database authorization.',
    'WORKFLOW_RUN_REVISION_MISMATCH':
        'The saved business details changed. Reload before requesting a review.',
    'WORKFLOW_RUN_NOT_FOUND':
        'The review record could not be found. Reload before trying again.',
    'WORKFLOW_STORAGE_UNAVAILABLE':
        'The review record could not be stored. Try again later.',
    'MODEL_STAGE_ALREADY_RESERVED':
        'A review attempt is already recorded for this version. Reload before trying again.',
    'MODEL_ATTEMPT_BUDGET_EXHAUSTED':
        'This review version has used its allowed attempts. Reload before trying again.',
    'MODEL_RECEIPT_OUTCOME_INVALID':
        'The review attempt could not be reconciled and was not stored.',
    'E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN':
        'The review provider did not respond in time. The attempt was recorded and '
        'will not be retried automatically.',
    'PROVIDER_NOT_CONFIGURED':
        'Model-assisted review is waiting for its required setup.',
    'PROVIDER_CREDENTIALS_REJECTED':
        'The review provider rejected its configured credentials.',
    'PROVIDER_RATE_LIMITED':
        'The review provider is busy. Try again later.',
    'PROVIDER_TEMPORARILY_UNAVAILABLE':
        'The review provider is temporarily unavailable. Try again later.',
    'PROVIDER_MODEL_MISMATCH':
        'The review provider returned a different model than the one authorized.',
    'BDJ_RULE_ADOPTION_REQUIRED':
        'Model-assisted review is waiting for its required setup.',
    'BDJ_RULE_FINGERPRINT_MISMATCH':
        'The adopted review rules could not be verified.',
    'RESULT_OUTCOME_UNCLASSIFIED':
        'The review result could not be classified and was not stored.',
    'BDJ_RESULT_NOT_FOUND':
        'The review result was not found.',
}
_INFRASTRUCTURE_HELD_CODES = frozenset({
    'RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED',
    'WORKFLOW_STORAGE_UNAVAILABLE',
    'WORKFLOW_RUN_NOT_FOUND',
    'MODEL_RECEIPT_OUTCOME_INVALID',
    'E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN',
    'PROVIDER_NOT_CONFIGURED',
    'PROVIDER_CREDENTIALS_REJECTED',
    'PROVIDER_RATE_LIMITED',
    'PROVIDER_TEMPORARILY_UNAVAILABLE',
    'PROVIDER_HTTP_REJECTED',
})
_WORKFLOW_CODE = re.compile(r'[A-Z][A-Z0-9_]{0,63}')


@app.exception_handler(WorkflowHeld)
async def workflow_held_handler(request: Request, exc: WorkflowHeld):
    """409 for a judged refusal, 503 for an infrastructure-class hold.

    The body is ``{'detail': {'code', 'message'}}`` with a static message. The
    code is validated against a fixed shape so an arbitrary exception string
    cannot become client-visible text.
    """
    code = str(exc)
    if not _WORKFLOW_CODE.fullmatch(code):
        code = 'WORKFLOW_HELD'
    message = _WORKFLOW_HELD_MESSAGES.get(
        code, 'The workflow could not complete this request.')
    status = 503 if code in _INFRASTRUCTURE_HELD_CODES else 409
    return JSONResponse(status_code=status,
                        content={'detail': {'code': code, 'message': message}})


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception):
    # Never leak internal exception text to clients; log it server-side.
    logger.exception("Unhandled error on %s %s", request.method, request.url.path)
    return JSONResponse(status_code=500, content={"detail": "Internal server error."})


app.include_router(v1_router, prefix="/api/v1")


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/api/v1/health")
def health_v1() -> dict:
    from sqlalchemy import text
    from sqlmodel import Session
    from sitewise.db.session import engine

    db_ok = True
    try:
        with Session(engine) as session:
            session.execute(text("SELECT 1"))
    except Exception:
        db_ok = False
    from sitewise.services import explanation_worker, panorama_worker

    panorama_ok = panorama_worker.is_running()
    explanation_ok = explanation_worker.is_running()
    return {
        "status": "ok" if db_ok and panorama_ok and explanation_ok else "degraded",
        "database": "ok" if db_ok else "error",
        "panorama_worker": "running" if panorama_ok else "unavailable",
        "explanation_worker": "running" if explanation_ok else "unavailable",
    }


# Serve the compiled Jaspr frontend (static assets + SPA fallback) on this
# same origin. Registered LAST so every explicit route above (/api/v1/*,
# /health, /docs, /openapi.json) is matched first; a missing build output
# keeps the API usable (the run launcher reports that as a startup error).
if not mount_frontend(app):
    logger.warning(
        "Compiled frontend not found at %s; starting as API-only. "
        "Run 'jaspr build' in fyp_jaspr_web first.",
        DEFAULT_DIST_DIR,
    )
