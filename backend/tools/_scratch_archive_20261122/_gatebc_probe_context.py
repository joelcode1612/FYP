"""Probe: build a second persisted BCB context through the real service.

Used only to determine whether a genuinely fresh Gate B/C execution is
available on a second confirmed synthetic assessment. Read/write goes through
``PersistedBusinessContextService`` exactly as the application does.
"""
import os
import sys
from datetime import timedelta
from pathlib import Path
from uuid import UUID

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND / "src"))

from sqlalchemy.engine import make_url  # noqa: E402

TARGET_DB = "project1_workflow_tests"
PORT = 5433
ASSESSMENT = UUID("e0124bfd-e54b-4d57-bc19-2023c8e7a5e6")
CONFIRMATION = UUID("b73d9297-ac39-42f4-9213-4fdd5254af28")
OWNER = UUID("b9e62014-b7bc-426e-a950-a95b25965639")
REVISION = 11

lines = (BACKEND / ".env").read_text(encoding="utf-8", errors="ignore").splitlines()
raw = next(l.split("=", 1)[1].strip() for l in lines if l.startswith("DATABASE_URL="))
base = make_url(raw).set(host="127.0.0.1", port=PORT, database=TARGET_DB)
m2 = base.set(username="p1_m2_runtime", password="m2_runtime_dev_only").render_as_string(hide_password=False)
eng = base.set(username="p1ai_engine", password="p1ai_engine_dev_only").render_as_string(hide_password=False)
os.environ.update({
    "DATABASE_URL": m2, "M2_DATABASE_URL": m2,
    "M2_EXPECTED_DATABASE": TARGET_DB,
    "PROJECT1_RUNTIME_DATABASE_URL": eng,
    "PROJECT1_ISOLATED_DATABASE_NAME": TARGET_DB,
    "PROJECT1_ISOLATED_DATABASE_PORT": str(PORT),
    "PROJECT1_WORKFLOW_ENABLED": "true", "M2_BCB_PERSISTENCE_ENABLED": "true",
    "PROJECT1_BDJ_CONTRACT": "objective",
    "PROJECT1_BCB_CONFIRMATION_VALIDITY_DAYS": "1",
    "M2_PROTECTED_IDENTITY_ENABLED": "false", "TOKENHARBOR_ENABLED": "false",
})

from sitewise.core.config import settings  # noqa: E402
from sitewise.db.m2_session import get_bcb_engine  # noqa: E402
from sitewise.domain import rbac  # noqa: E402
from sitewise.repositories.business_context_repository import SqlBusinessContextStore  # noqa: E402
from sitewise.repositories.m2_context_bindings import M2ContextBindings  # noqa: E402
from sitewise.services.persisted_business_context_service import (  # noqa: E402
    PersistedBusinessContextService)
from sitewise.services.ports.business_context_store_port import (  # noqa: E402
    ContextActor, ContextSelection)

validity = timedelta(days=settings.project1_bcb_confirmation_validity_days)
store = SqlBusinessContextStore(
    get_bcb_engine(),
    lambda repository: M2ContextBindings(repository, validity=validity))
service = PersistedBusinessContextService(store)
actor = ContextActor(OWNER, rbac.canonical_role("ENTREPRENEUR"))
selection = ContextSelection(assessment_id=ASSESSMENT, confirmation_id=CONFIRMATION,
                             revision=REVISION)

try:
    row = service.construct_and_save(selection, actor)
    print("OK context_id:", row.get("context_id"))
    print("   packet_hash:", str(row.get("packet_hash"))[:16], "...")
    print("   contract:", row.get("contract_version"), "lifecycle:", row.get("lifecycle_status"))
except Exception as exc:
    print("FAILED", type(exc).__name__, str(exc)[:300])
    import traceback
    traceback.print_exc()
