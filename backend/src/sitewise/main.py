from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from sitewise.api.v1.router import router as v1_router
from sitewise.core.config import settings
from sitewise.core.exceptions import (
    AuthError,
    ForbiddenError,
    NotFoundError,
    SiteWiseError,
)
from sitewise.core.logging import configure_logging, logger
from sitewise.db.session import create_db_and_tables

configure_logging()


@asynccontextmanager
async def lifespan(app: FastAPI):
    try:
        create_db_and_tables()
    except Exception:
        pass
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
async def auth_error_handler(request: Request, exc: SiteWiseError):
    """Map authentication / authorization errors to their mandated statuses.

    AuthError -> 401, AuthUnavailableError -> 503 (it subclasses AuthError),
    ForbiddenError -> 403, NotFoundError -> 404. The messages are written for
    clients and carry no token or secret material.
    """
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
