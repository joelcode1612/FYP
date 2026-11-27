"""Serve the real SiteWise FastAPI application from an explicit runtime profile.

This is a *launcher for the existing* ``sitewise.main:app``. It is not a second
application server: the process, the route table, the workers and the static
frontend mount are exactly the ones ``run-sitewise.ps1`` has always started.

Why a profile registry
----------------------
The application is identical in every environment; only the injected
environment differs. Historically that difference was expressed by *choosing a
different script*, and the two scripts drifted until one of them pointed at a
database that no longer held the tables the code needs. A profile makes the
choice explicit, reviewable in one place, and verifiable before a socket is
bound.

Profiles
--------
========================  ==========================  ======  ==================
Profile                   Environment file            Port    Server major
========================  ==========================  ======  ==================
``pg18`` (default)        ``app_pg18.env``            8093    18
``pg18-demo``             ``app_pg18_demo.env``       8093    18
``pg18-preview``          ``app_pg18_preview.env``    8093    18
``pg18-prod-rt24``        ``app_pg18_prod_rt24.env``  8093    18
``dev``                   ``backend/.env``            8090    any
========================  ==========================  ======  ==================

``dev`` is deliberately **not** usable by default. It reads
``backend/.env`` + ``backend/.env.local``, which name the protected
``Final_Location_Analysis`` database on the legacy PostgreSQL 16 server. That
target is refused outright, so ``-Profile dev`` fails closed instead of
silently starting the legacy environment. Pass ``--allow-legacy-database``
only when ``backend/.env`` has been repointed at a non-protected local
database you own.

Identity discipline
-------------------
``assert_target`` reads the *server's own answer* (``current_database()``,
``inet_server_port()``, ``version()``, the role's ``rolsuper``/``rolbypassrls``)
and refuses to bind when it disagrees with the profile. A URL is a claim;
``current_database()`` is evidence. The same check refuses a protected database
name, a legacy port, a superuser principal, a server major version other than
the profile's, and any required table that is missing.

One authoritative port
-----------------------
``--port`` is resolved once. Everything derived from it is derived here, not
restated in four files:

* the uvicorn bind port;
* ``CORS_ORIGINS`` (first entry also drives the entrepreneur auth redirect);
* ``SUPABASE_STAFF_INVITE_REDIRECT_URL``.

An explicit ``SITEWISE_PUBLIC_ORIGIN`` in the profile overrides the derivation
for the case where the browser reaches the app through a different origin
(reverse proxy, LAN address). The PostgreSQL port is never derived from this
value: changing the application port must not move the database.

Usage
-----
    backend/.venv/Scripts/python.exe tools/serve_profile.py --profile pg18
    backend/.venv/Scripts/python.exe tools/serve_profile.py --profile pg18 --check
    backend/.venv/Scripts/python.exe tools/serve_profile.py --profile pg18 --port 8095

``--check`` performs the full preflight (identity, schema, routes, dependencies,
frontend directory) and prints one JSON object, without binding a socket. The
PowerShell launcher calls it first and prints its own receipt from the result.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
PROFILE_DIR = BACKEND / 'var' / 'e2e' / 'pg18'

# Runnable from any working directory: the application package lives in
# backend/src and the shared proxy guard in backend/tools. The launcher also
# sets PYTHONPATH, but a standalone ``--check`` must not depend on that.
for _entry in (str(BACKEND / 'src'), str(BACKEND / 'tools'), str(BACKEND)):
    if _entry not in sys.path:
        sys.path.insert(0, _entry)

#: Databases the launcher must never bind against, whatever a profile says.
FORBIDDEN_DATABASES = {'Dss', 'Final_Location_Analysis'}
#: Ports belonging to the protected production database or the disposable cluster.
FORBIDDEN_PORTS = {5432, 5433}

#: Tables whose absence means the profile does not describe a migrated database.
#: A schema gap is a refusal, not a warning: every one of these is read by a
#: route the UI calls on first load.
REQUIRED_TABLES = (
    'public.m2_assessments',
    'public.m2_confirmation_snapshots',
    'public.cq_campaigns',
    'public.cq_collection_state',
    'project1_ai.runs',
)

#: Modules the application needs at import time. ``cv2`` is declared by
#: ``pyproject.toml`` for the panorama worker; a venv that predates that line
#: still starts the API, but the worker and the readiness endpoint degrade.
#: Reported, never installed automatically.
CRITICAL_MODULES = ('uvicorn', 'fastapi', 'sqlmodel', 'sqlalchemy', 'psycopg2', 'joblib')
OPTIONAL_MODULES = ('cv2',)

PROFILES = {
    'pg18': {
        'env': 'app_pg18.env',
        'port': 8093,
        'major': 18,
        'legacy': False,
        'label': 'PG18 isolated test (default)',
    },
    'pg18-demo': {
        'env': 'app_pg18_demo.env',
        'port': 8093,
        'major': 18,
        'legacy': False,
        'label': 'PG18 demo',
    },
    'pg18-preview': {
        'env': 'app_pg18_preview.env',
        'port': 8093,
        'major': 18,
        'legacy': False,
        'label': 'PG18 preview (separate frontend directory)',
    },
    'pg18-prod-rt24': {
        'env': 'app_pg18_prod_rt24.env',
        'port': 8093,
        'major': 18,
        'legacy': False,
        'label': 'PG18 rt24 (separate frontend directory)',
    },
    'dev': {
        'env': None,
        'port': 8090,
        'major': None,
        'legacy': True,
        'label': 'Legacy backend/.env (refused: protected database)',
    },
}


def load_environment(path: Path) -> int:
    """Apply ``KEY=VALUE`` lines from ``path`` to this process's environment."""
    if not path.is_file():
        raise SystemExit(f'REFUSED: configuration not found: {path}')
    applied = 0
    for raw in path.read_text(encoding='utf-8', errors='replace').splitlines():
        line = raw.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        key = key.strip()
        # Skip anything that is not a plain environment name, so a stray line in
        # a hand-edited file cannot inject an arbitrary variable.
        if not key or not key.replace('_', '').isalnum() or key[0].isdigit():
            continue
        os.environ[key] = value.strip().strip('"').strip("'")
        applied += 1
    return applied


def _split_origins(raw: str) -> list[str]:
    return [item.strip().rstrip('/') for item in raw.split(',') if item.strip()]


def apply_runtime_origin(port: int, host: str) -> dict:
    """Derive every port-dependent setting from the one resolved port.

    Returns a dict describing what was applied, so the launcher can print it and
    the receipt never states a value that was not actually set.
    """
    explicit = (os.environ.get('SITEWISE_PUBLIC_ORIGIN') or '').strip().rstrip('/')
    if explicit:
        public_origin = explicit
        source = 'SITEWISE_PUBLIC_ORIGIN'
    else:
        # A launcher that binds a wildcard address is still reached at localhost
        # by the browser on this machine, which is what the redirects must name.
        browser_host = 'localhost' if host in {'0.0.0.0', '::', ''} else host
        public_origin = f'http://{browser_host}:{port}'
        source = 'derived from --port'

    loopback = [f'http://127.0.0.1:{port}', f'http://localhost:{port}']
    extra = _split_origins(os.environ.get('SITEWISE_CORS_EXTRA', ''))

    ordered: list[str] = []
    for origin in [public_origin, *loopback, *extra]:
        if origin and origin not in ordered:
            ordered.append(origin)

    cors = ','.join(ordered)
    os.environ['CORS_ORIGINS'] = cors
    # The first CORS entry is what ``Settings._default_auth_redirect`` uses, so
    # the entrepreneur / default callback follows ``public_origin`` above.
    staff_redirect = f'{public_origin}/auth/callback?next=/reset-password'
    os.environ['SUPABASE_STAFF_INVITE_REDIRECT_URL'] = staff_redirect

    return {
        'public_origin': public_origin,
        'origin_source': source,
        'cors_origins': cors,
        'staff_invite_redirect': staff_redirect,
    }


def _server_identity(engine) -> tuple:
    """Ask the server who and where it is. One round trip, read-only."""
    from sqlalchemy import text

    with engine.connect() as conn:
        row = conn.execute(text(
            'select current_database(), current_user, inet_server_port(), '
            "       coalesce(host(inet_server_addr()), '127.0.0.1'), "
            '       (select rolsuper or rolbypassrls from pg_roles '
            '         where rolname = current_user), '
            "       current_setting('server_version_num')::int / 10000"
        )).one()
        conn.rollback()
    return row


def _declared_target(env_key: str) -> tuple[str, int] | None:
    """The database name and port written in a DSN, without connecting.

    Needed because the guard has to refuse a protected *name* before it dials
    it: on a host where that database does not exist, connecting first produces
    a raw ``OperationalError`` ("database does not exist") instead of the
    refusal that explains the policy. ``None`` means the key is unset or
    unparseable, and the caller falls back to the post-connection check.
    """
    raw = (os.environ.get(env_key) or '').strip()
    if not raw:
        return None
    try:
        from sqlalchemy.engine import make_url
        url = make_url(raw)
    except Exception:  # noqa: BLE001 - an unparseable DSN is reported later
        return None
    if not url.database or url.port is None:
        return None
    return url.database, int(url.port)


def _brief_error(exc: BaseException) -> str:
    """First line of a driver error, with any credential-bearing URL removed."""
    text = str(exc).strip().splitlines()[0] if str(exc).strip() else type(exc).__name__
    return re.sub(r'://[^:@/\s]+:[^@\s]+@', '://***:***@', text)[:300]


def assert_target(profile: str, spec: dict) -> dict:
    """Prove the engines resolve to the profile's database before binding.

    The *application* engine is sampled first because it is the connection the
    routes write through; the M2 engine is then required to agree. Reporting a
    receipt from the M2 read-only role alone would name a principal the user
    never sees in an error message.

    Refusals are raised as ``SystemExit`` with an explanatory message, never as
    a driver traceback: a bad target is a configuration state the operator can
    fix, and a traceback hides which key is wrong.
    """
    from sqlalchemy.exc import SQLAlchemyError
    from sitewise.db.m2_session import get_m2_engine
    from sitewise.db.session import engine as app_engine

    # Refuse a protected target by name *before* dialling it. The post-connect
    # checks below stay as the authority on what the server actually reports;
    # this pass only prevents a confusing connection error on the way there.
    for env_key in ('DATABASE_URL', 'M2_DATABASE_URL', 'EE01_DATABASE_URL',
                    'CQ_PUBLICATION_DATABASE_URL'):
        declared = _declared_target(env_key)
        if declared is None:
            continue
        name, declared_port = declared
        if name in FORBIDDEN_DATABASES:
            raise SystemExit(
                f'REFUSED: {env_key} names the protected database {name!r}. '
                f'Repoint the profile environment file; the launcher will not '
                f'start against a protected target.')
        if declared_port in FORBIDDEN_PORTS:
            raise SystemExit(
                f'REFUSED: {env_key} names protected/legacy port {declared_port}.')

    try:
        database, principal, port, address, privileged, major = _server_identity(app_engine)
    except SQLAlchemyError as exc:
        raise SystemExit(
            f'REFUSED: cannot reach the database named by DATABASE_URL. '
            f'The server said: {_brief_error(exc)}') from None

    try:
        m2_database, m2_principal, m2_port, _, m2_privileged, _ = _server_identity(get_m2_engine())
    except SQLAlchemyError as exc:
        raise SystemExit(
            f'REFUSED: cannot reach the database named by M2_DATABASE_URL. '
            f'The server said: {_brief_error(exc)}') from None
    except Exception as exc:  # noqa: BLE001 - AssessmentError carries the code
        code = getattr(exc, 'code', None) or type(exc).__name__
        raise SystemExit(
            f'REFUSED: the M2 engine refused its target ({code}). '
            f'M2_DATABASE_URL must name the same verified database as '
            f'DATABASE_URL; a split profile silently reads one database and '
            f'writes another.') from None

    if database in FORBIDDEN_DATABASES:
        raise SystemExit(
            f'REFUSED: profile {profile!r} resolves to the protected database '
            f'{database!r}. Repoint the profile environment file; the launcher '
            f'will not start against a protected target.')
    if port in FORBIDDEN_PORTS:
        raise SystemExit(
            f'REFUSED: profile {profile!r} resolves to protected/legacy port {port}.')
    if privileged or m2_privileged:
        holder = principal if privileged else m2_principal
        raise SystemExit(
            f'REFUSED: principal {holder!r} holds superuser or BYPASSRLS. '
            f'The profile must name a least-privilege runtime role.')
    if m2_database != database or int(m2_port) != int(port):
        raise SystemExit(
            f'REFUSED: M2_DATABASE_URL resolves to {m2_database}@{m2_port} but '
            f'DATABASE_URL resolves to {database}@{port}. The M2 and application '
            f'engines must name the same database; a split profile silently reads '
            f'one database and writes another.')

    expected_major = spec.get('major')
    if expected_major and int(major) != int(expected_major):
        raise SystemExit(
            f'REFUSED: profile {profile!r} expects PostgreSQL {expected_major}, '
            f'server reports {major}.')

    return {
        'database': database,
        'principal': principal,
        'm2_principal': m2_principal,
        'db_port': int(port),
        'db_host': address,
        'privileged': bool(privileged),
        'server_major': int(major),
    }


def check_schema(identity: dict) -> list[str]:
    """Return the required tables that are absent. Read-only."""
    from sqlalchemy import text
    from sitewise.db.m2_session import get_m2_engine

    missing: list[str] = []
    engine = get_m2_engine()
    with engine.connect() as conn:
        for qualified in REQUIRED_TABLES:
            present = conn.execute(text('select to_regclass(:n)'), {'n': qualified}).scalar()
            if present is None:
                missing.append(qualified)
        conn.rollback()
    return missing


def check_declared_identity() -> list[str]:
    """The profile's own expected-database keys must agree with each other.

    A profile that claims two different expected databases is internally
    inconsistent; refusing is cheaper than discovering it at the first read.
    """
    problems: list[str] = []
    keys = ('M2_EXPECTED_DATABASE', 'EE01_EXPECTED_DATABASE',
            'EXPLANATION_STORE_EXPECTED_DATABASE', 'CQ_PUBLICATION_EXPECTED_DATABASE',
            'PROJECT1_ISOLATED_DATABASE_NAME')
    declared = {}
    for key in keys:
        value = (os.environ.get(key) or '').strip()
        if value:
            declared[key] = value
    distinct = sorted(set(declared.values()))
    if len(distinct) > 1:
        problems.append(
            'expected-database keys disagree: '
            + ', '.join(f'{k}={v}' for k, v in sorted(declared.items())))
    return problems


def check_dependencies() -> dict:
    """Report missing modules. Nothing is installed here."""
    import importlib.util

    missing_critical = [m for m in CRITICAL_MODULES if importlib.util.find_spec(m) is None]
    missing_optional = [m for m in OPTIONAL_MODULES if importlib.util.find_spec(m) is None]
    return {'critical': missing_critical, 'optional': missing_optional}


def _iter_route_paths(routes, prefix: str = ''):
    """Flatten the route table.

    This FastAPI version keeps ``include_router`` calls as lazy
    ``_IncludedRouter`` placeholders instead of copying routes into
    ``app.routes``, so a naive ``[r.path for r in app.routes]`` reports an empty
    API surface. Recursing through ``include_context`` is both accurate and far
    cheaper than building the OpenAPI schema (measured 0.2 s versus 17.9 s).
    """
    for route in routes:
        if type(route).__name__ == '_IncludedRouter':
            context = getattr(route, 'include_context', None)
            sub = getattr(context, 'included_router', None)
            if sub is not None:
                nested = prefix + (getattr(context, 'prefix', '') or '')
                for path in _iter_route_paths(sub.routes, nested):
                    yield path
        else:
            path = getattr(route, 'path', None)
            if path:
                yield prefix + path


def check_routes() -> dict:
    """Prove the gated routers are actually registered on this app object."""
    from sitewise.main import app

    paths = list(_iter_route_paths(app.routes))
    m2 = [p for p in paths if p.startswith('/api/v1/m2')]
    workflow = [p for p in paths if p.startswith('/api/v1/project1-workflow')]
    cq = [p for p in paths if p.startswith('/api/v1/cq')]
    return {
        'm2': bool(m2),
        'workflow': bool(workflow),
        'cq': bool(cq),
        'm2_route_count': len(m2),
        'workflow_route_count': len(workflow),
        'cq_route_count': len(cq),
        'total_route_count': len(paths),
        # A stable, parameter-free route is what the launcher probes over HTTP.
        'm2_probe_path': '/api/v1/m2/instruments' if '/api/v1/m2/instruments' in m2 else None,
    }


def resolve_frontend() -> dict:
    from sitewise.frontend import DEFAULT_DIST_DIR, DIST_DIR_ENV

    raw = os.environ.get(DIST_DIR_ENV)
    dist = Path(raw).resolve() if raw else Path(DEFAULT_DIST_DIR)
    index = dist / 'index.html'
    bundle = dist / 'main.client.dart.js'
    return {
        'dist': str(dist),
        'source': DIST_DIR_ENV if raw else 'DEFAULT_DIST_DIR',
        'index_present': index.is_file(),
        'bundle_present': bundle.is_file(),
    }


def build_report(profile: str, spec: dict, origin: dict, port: int,
                 skip_frontend: bool = False) -> dict:
    report: dict = {
        'ok': False,
        'profile': profile,
        'profile_label': spec['label'],
        'port': port,
        'errors': [],
        'warnings': [],
    }

    deps = check_dependencies()
    report['missing_critical_modules'] = deps['critical']
    report['missing_optional_modules'] = deps['optional']
    if deps['critical']:
        report['errors'].append(
            'missing required Python modules: ' + ', '.join(deps['critical'])
            + '. Install them with: backend\\.venv\\Scripts\\python.exe -m pip install -e backend')
    if deps['optional']:
        report['warnings'].append(
            'missing optional modules: ' + ', '.join(deps['optional'])
            + ' (panorama worker and full readiness will report unavailable)')

    # A refusal here is reported, not raised: in --check mode the launcher wants
    # the whole picture (including the dependency findings above), and an
    # identity failure is one finding among several.
    try:
        identity = assert_target(profile, spec)
    except SystemExit as refusal:
        report['errors'].append(str(refusal))
        identity = None

    if identity is not None:
        report.update(identity)

        missing_tables = check_schema(identity)
        report['missing_tables'] = missing_tables
        if missing_tables:
            report['errors'].append(
                'profile database is missing required tables: ' + ', '.join(missing_tables)
                + '. Apply the reviewed migrations for this profile; the launcher never migrates.')

        identity_problems = check_declared_identity()
        report['identity_problems'] = identity_problems
        report['errors'].extend(identity_problems)

    routes = check_routes()
    report['m2_routes'] = routes['m2']
    report['workflow_routes'] = routes['workflow']
    report['cq_routes'] = routes['cq']
    report['m2_route_count'] = routes['m2_route_count']
    report['workflow_route_count'] = routes['workflow_route_count']
    report['cq_route_count'] = routes['cq_route_count']
    report['total_route_count'] = routes['total_route_count']
    report['m2_probe_path'] = routes['m2_probe_path']
    if not routes['m2']:
        report['warnings'].append(
            'M2 routes are not registered (M2_UPSTREAM_ENABLED is not true in this profile)')
    if not routes['workflow']:
        report['warnings'].append(
            'project1-workflow routes are not registered '
            '(PROJECT1_WORKFLOW_ENABLED is not true in this profile)')

    frontend = resolve_frontend()
    report['frontend'] = frontend
    if skip_frontend:
        report['frontend_checked'] = False
    else:
        report['frontend_checked'] = True
        if not frontend['index_present'] or not frontend['bundle_present']:
            report['errors'].append(
                f'frontend is incomplete at {frontend["dist"]} '
                f'(index.html={frontend["index_present"]}, '
                f'main.client.dart.js={frontend["bundle_present"]}). '
                f'Run the launcher with -Rebuild, or point SITEWISE_FRONTEND_DIST at a deployed build.')

    report['public_origin'] = origin['public_origin']
    report['origin_source'] = origin['origin_source']
    report['cors_origins'] = origin['cors_origins']
    report['staff_invite_redirect'] = origin['staff_invite_redirect']

    # Governance switches: report them, never change them.
    report['cq_runtime_enabled'] = (os.environ.get('CQ_RUNTIME_ENABLED') or 'false').strip().lower() == 'true'
    report['tokenharbor_enabled'] = (os.environ.get('TOKENHARBOR_ENABLED') or 'false').strip().lower() == 'true'

    report['ok'] = not report['errors']
    return report


def main() -> int:
    parser = argparse.ArgumentParser(
        description='Serve sitewise.main:app from an explicit runtime profile.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='Profiles: ' + ', '.join(sorted(PROFILES)))
    parser.add_argument('--profile', default='pg18', choices=sorted(PROFILES))
    parser.add_argument('--port', type=int, default=None,
                        help='application port; defaults to the profile default')
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--env-file', default=None,
                        help='explicit environment file, overriding the profile default')
    parser.add_argument('--allow-legacy-database', action='store_true',
                        help='allow a profile whose target is not a PG18 test database')
    parser.add_argument('--check', action='store_true',
                        help='run preflight and print one JSON object; bind nothing')
    parser.add_argument('--skip-frontend', action='store_true',
                        help='do not fail preflight when the frontend is missing '
                             '(used before -Rebuild)')
    parser.add_argument('--log-level', default=None)
    args = parser.parse_args()

    spec = PROFILES[args.profile]

    if spec['legacy'] and not args.allow_legacy_database:
        print(
            f'REFUSED: profile {args.profile!r} is the legacy environment.\n'
            f'  It reads backend/.env and backend/.env.local, which name the protected\n'
            f'  Final_Location_Analysis database on the legacy PostgreSQL 16 server.\n'
            f'  Use the default profile (-Profile pg18) for the current implementation.\n'
            f'  If backend/.env has been repointed at a local database you own, pass\n'
            f'  -AllowLegacyDatabase explicitly.',
            file=sys.stderr)
        return 2

    # 1. Environment, before anything imports sitewise.core.config.
    if args.env_file:
        env_path = Path(args.env_file).resolve()
        applied = load_environment(env_path)
        env_name = env_path.name
    elif spec['env']:
        env_path = PROFILE_DIR / spec['env']
        applied = load_environment(env_path)
        env_name = env_path.name
    else:
        applied = 0
        env_name = 'backend/.env + backend/.env.local (pydantic)'

    port = args.port if args.port is not None else int(os.environ.get('PORT') or spec['port'])

    # 2. One authoritative port, fanned out.
    origin = apply_runtime_origin(port, args.host)

    if args.log_level:
        os.environ['LOG_LEVEL'] = args.log_level

    # 3. The shared guard, not a private copy.
    from dead_proxy_guard import drop_unreachable_proxies
    dropped = drop_unreachable_proxies(verbose=not args.check)

    try:
        report = build_report(args.profile, spec, origin, port,
                              skip_frontend=args.skip_frontend)
    except SystemExit as refusal:
        if args.check:
            print(json.dumps({'ok': False, 'profile': args.profile, 'port': port,
                              'errors': [str(refusal)], 'warnings': []}))
            return 2
        raise

    report['env_file'] = env_name
    report['env_entries_applied'] = applied
    report['proxies_dropped'] = dropped
    report['host'] = args.host

    if args.check:
        print(json.dumps(report))
        return 0 if report['ok'] else 2

    if not report['ok']:
        print('REFUSED: preflight failed; no socket was bound.', file=sys.stderr)
        for problem in report['errors']:
            print(f'  - {problem}', file=sys.stderr)
        return 2

    for warning in report['warnings']:
        print(f'[serve] WARNING: {warning}', flush=True)

    from sitewise.main import app
    import uvicorn

    print(f'[serve] profile={args.profile} env={env_name} ({applied} entries)', flush=True)
    print(f'[serve] target proved: {report["database"]}@{report["db_port"]} '
          f'as {report["principal"]} (PostgreSQL {report["server_major"]})', flush=True)
    print(f'[serve] frontend: {report["frontend"]["dist"]} ({report["frontend"]["source"]})', flush=True)
    print(f'[serve] public origin: {report["public_origin"]} ({report["origin_source"]})', flush=True)
    print(f'[serve] binding http://{args.host}:{port}', flush=True)

    uvicorn.run(app, host=args.host, port=port,
                log_level=(os.environ.get('LOG_LEVEL', 'info')).lower())
    return 0


if __name__ == '__main__':
    sys.exit(main())
