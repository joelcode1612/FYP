from contextlib import asynccontextmanager

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
    try:
        create_db_and_tables()
    except Exception:
        # Fail fast: without the schema every data route would 500 while
        # /health still answered "ok". The traceback stays server-side.
        logger.exception("Database startup failed; the API will not start.")
        raise
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
    return {"status": "ok" if db_ok else "degraded", "database": "ok" if db_ok else "error"}


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
