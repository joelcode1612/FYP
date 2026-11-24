"""Prove every database URL in the PG18 test environment targets 127.0.0.1:5544.

Owner Decision 2 requires: "Before connecting the application, prove that every
database URL targets the intended test environment." A URL string is not proof —
it is a claim. This tool checks the claim twice:

  1. **Statically** — parse each ``*_DATABASE_URL`` and refuse a host, port or
     database name that is not the isolated PG18 target. Catches a typo or a
     copy-pasted 5433 line before a socket is opened.
  2. **Dynamically** — connect as that URL's own principal and read back
     ``current_database()``, ``inet_server_port()`` and the principal's
     ``rolsuper`` / ``rolbypassrls`` flags. The server's answer is the evidence.

A URL that passes step 1 and fails step 2 means the configuration lies about
where it points, which is exactly the failure this environment must not have.

Read-only: it issues no DDL, no DML, no SET beyond a transaction-local
read-only guard.

Usage
-----
    backend/.venv/Scripts/python.exe tools/pg18_verify_targets.py \
        --env var/e2e/pg18/app_pg18.env --receipt var/e2e/pg18/targets_receipt.json
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote, urlparse

BACKEND = Path(__file__).resolve().parents[1]

EXPECTED_HOST = '127.0.0.1'
EXPECTED_PORT = 5544
EXPECTED_PREFIX = 'project1_pg18_'
PROTECTED = {'Dss', 'Final_Location_Analysis'}
FORBIDDEN_PORTS = {5432, 5433}


def parse_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding='utf-8', errors='replace').splitlines():
        line = raw.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def split_sqlalchemy_url(url: str):
    """Normalise ``postgresql+psycopg2://`` into something urlparse understands."""
    return urlparse(url.replace('postgresql+psycopg2://', 'postgresql://', 1))


def check_static(name: str, url: str) -> dict:
    parsed = split_sqlalchemy_url(url)
    database = (parsed.path or '').lstrip('/')
    port = parsed.port
    problems = []
    if parsed.hostname != EXPECTED_HOST:
        problems.append(f'host={parsed.hostname!r}')
    if port != EXPECTED_PORT:
        problems.append(f'port={port!r}')
    if port in FORBIDDEN_PORTS:
        problems.append('port is a protected/legacy cluster')
    if database in PROTECTED:
        problems.append(f'database {database!r} is protected')
    if not database.startswith(EXPECTED_PREFIX):
        problems.append(f'database {database!r} lacks prefix {EXPECTED_PREFIX!r}')
    return {
        'variable': name,
        'host': parsed.hostname,
        'port': port,
        'database': database,
        'principal': unquote(parsed.username or ''),
        'static': 'PASS' if not problems else 'FAIL',
        'problems': problems,
    }


def check_dynamic(entry: dict, url: str) -> dict:
    """Connect as the URL's own principal and read the server's answer."""
    import psycopg2

    parsed = split_sqlalchemy_url(url)
    try:
        conn = psycopg2.connect(
            host=parsed.hostname, port=parsed.port,
            dbname=(parsed.path or '').lstrip('/'),
            user=unquote(parsed.username or ''),
            password=unquote(parsed.password or ''),
            connect_timeout=8,
        )
    except Exception as exc:  # noqa: BLE001 - the failure text is the evidence
        entry['dynamic'] = 'FAIL'
        entry['error'] = f'{type(exc).__name__}: {exc}'.strip()
        return entry

    try:
        with conn.cursor() as cur:
            cur.execute("set local statement_timeout = '5s'")
            cur.execute(
                'select current_database(), current_user, inet_server_port(), '
                '       coalesce(host(inet_server_addr()), %s), '
                '       (select rolsuper or rolbypassrls from pg_roles '
                '         where rolname = current_user)',
                (EXPECTED_HOST,),
            )
            database, principal, port, address, privileged = cur.fetchone()
        conn.rollback()
    finally:
        conn.close()

    entry.update({
        'server_database': database,
        'server_principal': principal,
        'server_port': port,
        'server_address': address,
        'principal_privileged': bool(privileged),
    })
    agrees = (
        database == entry['database']
        and port == entry['port']
        and address == EXPECTED_HOST
    )
    entry['dynamic'] = 'PASS' if agrees and not privileged else 'FAIL'
    if not agrees:
        entry['error'] = 'server identity disagrees with the configured URL'
    if privileged:
        entry['error'] = 'principal holds superuser or BYPASSRLS'
    return entry


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--env', type=Path,
                        default=BACKEND / 'var' / 'e2e' / 'pg18' / 'app_pg18.env')
    parser.add_argument('--receipt', type=Path, default=None)
    args = parser.parse_args()

    if not args.env.is_file():
        raise SystemExit(f'REFUSED: env file not found: {args.env}')
    env = parse_env(args.env)

    # `DATABASE_URL` has no leading underscore, so a plain suffix test silently
    # skips the most important URL in the file. Match it explicitly.
    urls = {k: v for k, v in env.items()
            if k == 'DATABASE_URL' or k.endswith('_DATABASE_URL')}
    if not urls:
        raise SystemExit('REFUSED: no *_DATABASE_URL entries found')

    results = []
    for name, url in sorted(urls.items()):
        entry = check_static(name, url)
        if entry['static'] == 'PASS':
            entry = check_dynamic(entry, url)
        results.append(entry)

    # Environment-level expectations that must agree with the URLs.
    expected_name = env.get('M2_EXPECTED_DATABASE', '')
    expected_port = env.get('PROJECT1_ISOLATED_DATABASE_PORT', '')
    cross = {
        'M2_EXPECTED_DATABASE': expected_name,
        'PROJECT1_ISOLATED_DATABASE_NAME': env.get('PROJECT1_ISOLATED_DATABASE_NAME', ''),
        'PROJECT1_ISOLATED_DATABASE_PORT': expected_port,
        'DB_AUTO_CREATE': env.get('DB_AUTO_CREATE', ''),
        'TOKENHARBOR_ENABLED': env.get('TOKENHARBOR_ENABLED', ''),
        'M2_SYNTHETIC_INSTRUMENT_SCOPE': env.get('M2_SYNTHETIC_INSTRUMENT_SCOPE', '<unset>'),
    }
    cross_ok = (
        expected_name.startswith(EXPECTED_PREFIX)
        and str(expected_port) == str(EXPECTED_PORT)
        and cross['DB_AUTO_CREATE'] == 'false'
        and cross['TOKENHARBOR_ENABLED'] == 'false'
        and cross['M2_SYNTHETIC_INSTRUMENT_SCOPE'] == '<unset>'
    )

    failed = [r for r in results if r['static'] != 'PASS' or r.get('dynamic') != 'PASS']
    verdict = 'ALL_URLS_TARGET_PG18_5544' if not failed and cross_ok else 'TARGET_PROOF_FAILED'

    receipt = {
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'env_file': str(args.env),
        'expected': {'host': EXPECTED_HOST, 'port': EXPECTED_PORT,
                     'database_prefix': EXPECTED_PREFIX},
        'urls_checked': len(results),
        'results': results,
        'cross_checks': cross,
        'cross_checks_pass': cross_ok,
        'failures': [r['variable'] for r in failed],
        'verdict': verdict,
    }

    for r in results:
        line = f"  {r['static']:4} {r.get('dynamic','-'):4} {r['variable']:34} {r['database']}"
        if r.get('error'):
            line += f"  <- {r['error']}"
        print(line, flush=True)
    print(f"  cross-checks: {'PASS' if cross_ok else 'FAIL'}  {cross}", flush=True)
    print(f"\n  VERDICT: {verdict}", flush=True)

    if args.receipt:
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(receipt, indent=2), encoding='utf-8')
        print(f'  receipt: {args.receipt}', flush=True)

    return 0 if verdict == 'ALL_URLS_TARGET_PG18_5544' else 1


if __name__ == '__main__':
    sys.exit(main())
