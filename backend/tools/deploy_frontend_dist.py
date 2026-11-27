"""Deploy the built Jaspr bundle to the dist directory the server actually reads.

Why this exists
---------------
The served application was once one build behind the build directory because the
deployment step copied to a *profile* dist (`frontend_demo`) while the launcher
loaded a different profile (`app_pg18.env` -> `frontend`). Nothing failed; the
copy simply landed somewhere the server never looked.

So this tool does not trust a directory name. It:

1. reads the env file the launcher itself reads (``ENV_FILE`` below, kept in step
   with ``tools/pg18_serve_8093.py``) and resolves ``SITEWISE_FRONTEND_DIST``
   from it;
2. copies ``fyp_jaspr_web/build/jaspr`` into that directory;
3. fetches ``/main.client.dart.js`` **over HTTP from the running server** and
   compares its SHA-256 with the build's. A copy that has not reached the socket
   is not a deployment, so the check is on the response body, not on the file.

Exit code is non-zero when the served bytes differ from the build. Nothing is
reported as deployed on the strength of the build directory alone.

Usage
-----
    backend/.venv/Scripts/python.exe tools/deploy_frontend_dist.py
    backend/.venv/Scripts/python.exe tools/deploy_frontend_dist.py --check-only
"""
from __future__ import annotations

import argparse
import hashlib
import re
import shutil
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BACKEND = REPO / 'backend'
BUILD = REPO / 'fyp_jaspr_web' / 'build' / 'jaspr'

#: The env file ``tools/pg18_serve_8093.py`` loads. If that launcher ever reads a
#: different profile, this constant must change with it -- resolving the dist
#: from anywhere else is how the two copies diverged in the first place.
ENV_FILE = BACKEND / 'var' / 'e2e' / 'pg18' / 'app_pg18.env'

#: Every profile env, so a divergence between profiles is reported rather than
#: discovered later by comparing byte counts.
PROFILE_DIR = BACKEND / 'var' / 'e2e' / 'pg18'

BUNDLE = 'main.client.dart.js'


def read_dist(path: Path) -> str | None:
    if not path.is_file():
        return None
    for raw in path.read_text(encoding='utf-8', errors='replace').splitlines():
        line = raw.strip()
        if line.startswith('SITEWISE_FRONTEND_DIST='):
            return line.split('=', 1)[1].strip().strip('"').strip("'")
    return None


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_served(base: str) -> tuple[str | None, str]:
    url = f'{base.rstrip("/")}/{BUNDLE}'
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            body = response.read()
            return hashlib.sha256(body).hexdigest(), f'{len(body)} B'
    except (urllib.error.URLError, OSError) as exc:
        return None, f'unreachable ({exc})'


#: References in ``index.html`` that are answered by a FastAPI route, not by a
#: file in the dist directory. Everything else that starts with "/" must exist.
ROUTE_OWNED_PATHS = {'/auth-config.json'}

_LOCAL_REF = re.compile(r'(?:src|href)="(/[^"]*)"')


def check_index_assets(dist: Path) -> list[str]:
    """Report files ``index.html`` references that are not in the dist.

    A build can be byte-identical for the JS bundle and still be unusable: the
    shell references ``/map-config.js``, which ``jaspr build`` does not emit
    (it is generated into ``fyp_jaspr_web/web/`` by ``npm run gen-map-config``
    and is absent when no basemap key is configured). A stale copy in an
    existing dist hides this; a clean deploy exposes it as a 404 the browser
    never reports. Checking the references catches the class, not one filename.
    """
    index = dist / 'index.html'
    if not index.is_file():
        return ['index.html']
    missing: list[str] = []
    seen: set[str] = set()
    for ref in _LOCAL_REF.findall(index.read_text(encoding='utf-8', errors='replace')):
        # A cache-busting suffix is part of the URL, not the filename:
        # "/admin_accessibility.css?v=1" is served from admin_accessibility.css.
        # Resolving the raw reference looked for a file literally named
        # "...css?v=1", so every correctly versioned asset was reported missing.
        path_part = ref.split('?', 1)[0].split('#', 1)[0]
        if not path_part or path_part.endswith('/'):
            continue
        if path_part in seen:
            continue
        seen.add(path_part)
        if path_part.startswith('/api/') or path_part in ROUTE_OWNED_PATHS:
            continue
        target = (dist / path_part.lstrip('/')).resolve()
        try:
            target.relative_to(dist)
        except ValueError:
            continue
        if not target.exists():
            missing.append(path_part)
    return sorted(missing)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-only', action='store_true',
                        help='verify the served bundle without copying')
    parser.add_argument('--base', default='http://127.0.0.1:8093',
                        help='running server base URL')
    parser.add_argument('--env-file', default=None,
                        help='profile environment file to read SITEWISE_FRONTEND_DIST from '
                             '(default: the file pg18_serve_8093.py loads)')
    parser.add_argument('--no-http', action='store_true',
                        help='skip the socket check (for a pre-start verification)')
    args = parser.parse_args()

    env_file = Path(args.env_file).resolve() if args.env_file else ENV_FILE

    if not BUILD.is_dir():
        print(f'REFUSED: build not found: {BUILD}', file=sys.stderr)
        return 2
    built = BUILD / BUNDLE
    if not built.is_file():
        print(f'REFUSED: {built} missing', file=sys.stderr)
        return 2

    declared = read_dist(env_file)
    if not declared:
        print(f'REFUSED: SITEWISE_FRONTEND_DIST not found in {env_file}',
              file=sys.stderr)
        return 2
    dist = Path(declared)

    print(f'[deploy] build   : {BUILD}')
    print(f'[deploy] env     : {env_file.name}')
    print(f'[deploy] dist    : {dist}')

    # Report every profile so a divergent copy is visible, not silent.
    for profile in sorted(PROFILE_DIR.glob('*.env')):
        value = read_dist(profile)
        if value is None:
            continue
        marker = 'live' if profile.name == env_file.name else '    '
        same = 'same dist' if Path(value) == dist else 'DIFFERENT DIST'
        print(f'[deploy] {marker}  {profile.name:<28} {same}')

    build_hash = sha256_file(built)
    print(f'[deploy] build sha256 {build_hash[:16]}… ({built.stat().st_size:,} B)')

    if not args.check_only:
        dist.mkdir(parents=True, exist_ok=True)
        shutil.copytree(BUILD, dist, dirs_exist_ok=True)
        print(f'[deploy] copied {sum(1 for _ in BUILD.rglob("*"))} entries')
        on_disk = dist / BUNDLE
        disk_hash = sha256_file(on_disk)
        if disk_hash != build_hash:
            print(f'FAIL: on-disk copy differs: {disk_hash[:16]}…', file=sys.stderr)
            return 1
        print(f'[deploy] on-disk sha256 matches build')

    # Asset resolution: a correct bundle inside an incomplete shell is still a
    # broken page. Checked after any copy so it describes what will be served.
    missing_assets = check_index_assets(dist)
    if missing_assets:
        print('FAIL: index.html references files that are not in the dist: '
              + ', '.join(missing_assets), file=sys.stderr)
        print('      Generate them before deploying (for /map-config.js: '
              'npm run gen-map-config in fyp_jaspr_web/tool, then rebuild).',
              file=sys.stderr)
        return 1
    print('[deploy] index.html asset references all resolve')

    if args.no_http:
        print('SKIPPED: socket check (--no-http)')
        return 0

    served_hash, detail = sha256_served(args.base)
    if served_hash is None:
        print(f'BLOCKED: served bundle {detail} at {args.base}', file=sys.stderr)
        return 1
    print(f'[deploy] served sha256 {served_hash[:16]}… ({detail})')

    if served_hash != build_hash:
        print('FAIL: the served bundle is NOT the build. The deployment did not '
              'reach the socket that the browser reads.', file=sys.stderr)
        return 1

    print('PASS: served bundle == build (byte-identical)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
