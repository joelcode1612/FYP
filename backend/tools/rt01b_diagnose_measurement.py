"""Diagnose why the report resolver cannot read the EE-01 binding.

Loads the same env file the PG18 server loads, then calls the same dependency
the report route calls, and prints whatever it raises. The resolver swallows
exceptions by design, so this is the only place the cause is visible.

    backend/.venv/Scripts/python.exe tools/rt01b_diagnose_measurement.py
"""
from __future__ import annotations

import os
import sys
import traceback
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
ENV_FILE = BACKEND / 'var' / 'e2e' / 'pg18' / 'app_pg18.env'

for line in ENV_FILE.read_text(encoding='utf-8').splitlines():
    line = line.strip()
    if not line or line.startswith('#') or '=' not in line:
        continue
    key, value = line.split('=', 1)
    os.environ[key.strip()] = value.strip().strip('"').strip("'")

sys.path.insert(0, str(BACKEND / 'src'))
sys.path.insert(0, str(BACKEND))

from sitewise.core.config import settings  # noqa: E402

print('EE01_DATABASE_URL present :', bool(settings.ee01_database_url.get_secret_value()))
print('EE01_EXPECTED_DATABASE env:', os.environ.get('EE01_EXPECTED_DATABASE'))
print('has attr ee01_expected_database:',
      hasattr(settings, 'ee01_expected_database'))

raw = settings.ee01_database_url.get_secret_value()
if raw:
    from sqlalchemy.engine import make_url
    url = make_url(raw)
    print('dsn driver/database/user  :', url.drivername, url.database, url.username)

print('--- calling get_ee01_service() ---')
try:
    from sitewise.api.v1.customer_questionnaire import get_ee01_service
    service = get_ee01_service()
    print('service built OK:', type(service).__name__)
except Exception as exc:  # noqa: BLE001 - this is a diagnostic
    print('RAISED:', type(exc).__name__, '->', exc)
    traceback.print_exc()
