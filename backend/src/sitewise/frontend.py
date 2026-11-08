"""Static frontend hosting for the unified Sitewise application server.

The Jaspr web app is compiled to plain static assets (`jaspr build` in client
mode writes them to `fyp_jaspr_web/build/jaspr/`). FastAPI serves them on the
same origin as the REST API, with a SPA fallback for client-side routes:

* a file that exists under the dist directory is served as-is;
* an extension-less path (e.g. ``/entrepreneur/explore``) falls back to
  ``index.html`` so nested routes survive a hard refresh;
* a missing path WITH an extension (``/assets/nope.png``) answers 404 — the
  fallback never fabricates JavaScript, CSS or media responses;
* ``/api/*`` paths are guarded here as a backstop: the real API routes are
  matched earlier in the route table, but an unknown API path (``/api/v2/x``,
  ``/api/v1/nope``) must never receive an HTML document.

Only file serving lives in this module — no business logic.
"""

import os
from mimetypes import guess_type
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import FileResponse, JSONResponse, Response

# Same directory as this file's package: backend/src/sitewise/frontend.py
# -> backend/src/sitewise -> backend/src -> backend -> FYP repository root.
_REPO_ROOT = Path(__file__).resolve().parents[3]

# The compiled client frontend produced by `jaspr build` (client mode).
DEFAULT_DIST_DIR = _REPO_ROOT / "fyp_jaspr_web" / "build" / "jaspr"

DIST_DIR_ENV = "SITEWISE_FRONTEND_DIST"

# Windows registry MIME guesses can disagree with what browsers require for
# scripts; pin the types that matter for the Jaspr build output.
_MEDIA_TYPES = {
    ".js": "text/javascript",
    ".mjs": "text/javascript",
    ".css": "text/css",
    ".html": "text/html; charset=utf-8",
    ".json": "application/json",
    ".map": "application/json",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
    ".ico": "image/x-icon",
    ".woff": "font/woff",
    ".woff2": "font/woff2",
    ".ttf": "font/ttf",
    ".wasm": "application/wasm",
    ".webmanifest": "application/manifest+json",
}


def _not_found() -> Response:
    return JSONResponse({"detail": "Not Found"}, status_code=404)


def mount_frontend(app: FastAPI, dist_dir: Path | None = None) -> bool:
    """Serve the compiled Jaspr frontend alongside the API.

    Must be called AFTER ``app.include_router(...)`` so the catch-all route is
    registered last and never shadows ``/api/v1/*``, ``/health``, ``/docs`` or
    ``/openapi.json``. Returns True when the frontend is mounted; a missing
    build output keeps the API usable (API-only deployments) after logging —
    the run launcher reports the missing assets as a hard startup error.
    """
    dist = dist_dir or Path(
        os.environ.get(DIST_DIR_ENV) or DEFAULT_DIST_DIR
    ).resolve()
    index = dist / "index.html"
    if not index.is_file():
        return False

    def serve(full_path: str) -> Response:
        # Backstop for unmatched API-shaped paths (real /api/v1 routes are
        # matched before this handler runs).
        if full_path == "api" or full_path.startswith("api/"):
            return _not_found()

        candidate = (dist / full_path).resolve() if full_path else dist
        try:
            candidate.relative_to(dist)
        except ValueError:
            # Path traversal outside the dist directory (e.g. /../.env).
            return _not_found()

        if full_path and candidate.is_file():
            media_type = _MEDIA_TYPES.get(
                candidate.suffix.lower(),
                guess_type(str(candidate))[0] or "application/octet-stream",
            )
            return FileResponse(candidate, media_type=media_type)

        # Extension-less navigation paths fall back to the SPA shell. Missing
        # assets (which always carry an extension) answer 404 instead.
        if not full_path or not Path(full_path).suffix:
            return FileResponse(index, media_type=_MEDIA_TYPES[".html"], headers={"Cache-Control": "no-store"})
        return _not_found()

    @app.get("/{full_path:path}", include_in_schema=False)
    async def frontend(full_path: str) -> Response:
        return serve(full_path)

    return True
