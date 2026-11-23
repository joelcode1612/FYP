"""Audit which configuration keys were ever committed, without printing values.

Deliverable for Priority 1 (P0-R2). Answers three questions with evidence:

1. Which keys have ever appeared in a tracked ``.env`` file, and in how many
   distinct commits?
2. How many DISTINCT values has each key carried in history? A key that was
   rotated is a different exposure from a key that never changed.
3. Which keys are secrets (must be rotated) versus ordinary configuration?

Values are never printed and never written. Each value is represented only by
the first 12 hex characters of its SHA-256 digest, so two appearances can be
compared for equality without revealing either.

Usage::

    python tools/p1_config_secret_audit_20261122.py [--json OUT]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

#: Keys whose value is a credential. Rotation is required if any of these ever
#: appeared in a tracked file, regardless of whether the value is still current.
SECRET_KEYS = {
    'DATABASE_URL',
    'ANALYTICS_DATABASE_URL',
    'SECRET_KEY',
    'SUPABASE_SECRET_KEY',
    'CARTO_BASEMAPS_KEY',
    'GOOGLE_API_KEY',
    'GOOGLE_MAPS_API_KEY',
    'TOKENHARBOR_API_KEY',
    'PGPASSWORD',
    'M2_DATABASE_URL',
    'PROJECT1_RUNTIME_DATABASE_URL',
    'CP13_TEST_DATABASE_URL',
    'CP13_BEARER_TOKEN',
}

#: Explicitly NOT secrets: safe to keep in history.
NON_SECRET_KEYS = {
    'LOG_LEVEL',
    'CORS_ORIGINS',
    'SUPABASE_URL',
    'SUPABASE_PUBLISHABLE_KEY',
    'SUPABASE_JWT_AUDIENCES',
    'SUPABASE_INVITE_REDIRECT_URL',
    'SUPABASE_STAFF_INVITE_REDIRECT_URL',
    'SUPABASE_ADMIN_TIMEOUT_SECONDS',
    # A JWKS endpoint is a PUBLIC key set by definition. Committing the URL
    # leaks nothing; the private key never leaves the identity provider.
    'SUPABASE_JWKS_URL',
    'SITEWISE_DEV_AUTH_BYPASS',
    'SITEWISE_API_BASE_URL',
}

#: Anything in a tracked .env whose name looks like a credential.
SUSPICIOUS = re.compile(r'(KEY|SECRET|TOKEN|PASSWORD|PASSWD|DSN|URL)$', re.I)


def _git(*args: str) -> str:
    proc = subprocess.run(['git', *args], cwd=str(REPO), capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f'git {" ".join(args)} failed: {proc.stderr.strip()}')
    return proc.stdout


def _tracked_env_paths() -> list[str]:
    out = _git('log', '--all', '--pretty=format:', '--name-only', '--diff-filter=A')
    paths = {
        line.strip()
        for line in out.splitlines()
        if line.strip() and re.search(r'(^|/)\.env(\.[\w-]+)?$', line.strip())
    }
    return sorted(paths)


def _history(path: str) -> list[dict]:
    """Every commit that touched ``path``, newest first."""
    out = _git('log', '--all', '--format=%H%x00%ci%x00%s', '--', path)
    commits = []
    for line in out.splitlines():
        if not line.strip():
            continue
        sha, date, subject = line.split('\x00', 2)
        commits.append({'sha': sha, 'date': date, 'subject': subject})
    return commits


def _parse(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith('#') or '=' not in stripped:
            continue
        key, _, value = stripped.partition('=')
        values[key.strip()] = value.strip()
    return values


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode('utf-8')).hexdigest()[:12]


def audit() -> dict:
    paths = _tracked_env_paths()
    per_path = {}
    global_keys: dict[str, dict] = {}

    for path in paths:
        commits = _history(path)
        distinct: dict[str, set[str]] = {}
        commits_with_key: dict[str, int] = {}
        for commit in commits:
            try:
                blob = _git('show', f'{commit["sha"]}:{path}')
            except RuntimeError:
                continue
            parsed = _parse(blob)
            for key, value in parsed.items():
                distinct.setdefault(key, set()).add(_digest(value))
                commits_with_key[key] = commits_with_key.get(key, 0) + 1
                entry = global_keys.setdefault(
                    key,
                    {'paths': set(), 'digests': set(), 'commits': 0, 'non_empty': 0},
                )
                entry['paths'].add(path)
                entry['digests'].add(_digest(value))
                entry['commits'] += 1
                if value.strip():
                    entry['non_empty'] += 1
        per_path[path] = {
            'commit_count': len(commits),
            'first_commit': commits[-1]['date'] if commits else None,
            'last_commit': commits[0]['date'] if commits else None,
            'keys': {
                key: {
                    'distinct_values': len(distinct[key]),
                    'commits_with_key': commits_with_key[key],
                }
                for key in sorted(distinct)
            },
        }

    key_table = {}
    for key, entry in sorted(global_keys.items()):
        key_table[key] = {
            'secret': key in SECRET_KEYS,
            'classified': 'secret' if key in SECRET_KEYS else (
                'non-secret' if key in NON_SECRET_KEYS else (
                    'unclassified-suspicious' if SUSPICIOUS.search(key) else 'unclassified'
                )
            ),
            'paths': sorted(entry['paths']),
            'commits_with_key': entry['commits'],
            'commits_with_non_empty_value': entry['non_empty'],
            'distinct_values': len(entry['digests']),
            'rotation_required': key in SECRET_KEYS and entry['non_empty'] > 0,
        }

    return {
        'checkpoint': 'P1_CONFIG_SECRET_AUDIT',
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'method': (
            'git log --all over every tracked .env path; values hashed with '
            'sha256 and truncated to 12 hex chars. No value is printed or written.'
        ),
        'tracked_env_paths': paths,
        'per_path': per_path,
        'keys': key_table,
        'totals': {
            'tracked_env_paths': len(paths),
            'distinct_keys_ever_committed': len(key_table),
            'secret_keys_ever_committed': sum(
                1 for v in key_table.values() if v['secret']
            ),
            'keys_requiring_rotation': sum(
                1 for v in key_table.values() if v['rotation_required']
            ),
            'secret_keys_never_committed_with_a_value': sorted(
                key
                for key in SECRET_KEYS
                if key_table.get(key, {}).get('commits_with_non_empty_value', 0) == 0
            ),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--json', default=None)
    args = parser.parse_args()

    result = audit()
    text = json.dumps(result, indent=2, sort_keys=False)
    print(text)
    if args.json:
        out = Path(args.json)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text, encoding='utf-8')
    return 0


if __name__ == '__main__':
    sys.exit(main())
