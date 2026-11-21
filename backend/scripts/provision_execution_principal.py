"""Provision the restricted execution + audit principals (idempotent).

- Applies migrations/project1_ai/20261117_01_execution_principal.sql to Dss.
- Generates passwords for p1ai_engine (execution) and p1ai_auditor (read-only audit).
- Writes PROJECT1_RUNTIME_DATABASE_URL and PROJECT1_AUDIT_DATABASE_URL into .env.
- Verifies SET LOCAL ROLE into p1ai_runtime and p1ai_audit respectively.

Never prints passwords. Backs up .env first.
"""
import secrets
import sys
from pathlib import Path
from urllib.parse import quote_plus

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from sqlalchemy import create_engine, text  # noqa: E402
from sqlalchemy.engine import make_url  # noqa: E402

from sitewise.core.config import settings  # noqa: E402

BACKEND = Path(__file__).resolve().parents[1]
ENV = BACKEND / ".env"
MIGRATION = BACKEND / "migrations" / "project1_ai" / "20261117_01_execution_principal.sql"


def provision(super_url, role, target_role, env_key):
    engine = create_engine(super_url, hide_parameters=True)
    password = secrets.token_urlsafe(36)
    with engine.begin() as c:
        c.execute(text(f"ALTER ROLE {role} PASSWORD :pw"), {"pw": password})
    url = (f"postgresql+psycopg2://{role}:{quote_plus(password)}@"
           f"{super_url.host}:{super_url.port}/Dss")
    lines = [ln for ln in ENV.read_text(encoding="utf-8").splitlines()
             if not ln.strip().startswith(env_key)]
    lines.append(f"{env_key}={url}")
    ENV.write_text("\n".join(lines) + "\n", encoding="utf-8")
    # Verify SET LOCAL ROLE.
    check = create_engine(make_url(url), hide_parameters=True)
    with check.connect() as c:
        su = c.execute(text("SELECT session_user")).scalar()
        c.execute(text(f"SET LOCAL ROLE {target_role}"))
        cu = c.execute(text("SELECT current_user")).scalar()
    ok = su == role and cu == target_role
    print(f"{role}: session_user={su} current_user_after_setrole={cu} {'PASS' if ok else 'FAIL'}")
    return ok


def main() -> int:
    super_url = make_url(settings.database_url).set(database="Dss")
    engine = create_engine(super_url, hide_parameters=True)
    with engine.begin() as c:
        c.exec_driver_sql(MIGRATION.read_text(encoding="utf-8"))
    print("migration=applied")

    backup = ENV.with_suffix(".env.bak.execprincipal")
    backup.write_text(ENV.read_text(encoding="utf-8"), encoding="utf-8")

    ok1 = provision(super_url, "p1ai_engine", "p1ai_runtime", "PROJECT1_RUNTIME_DATABASE_URL")
    ok2 = provision(super_url, "p1ai_auditor", "p1ai_audit", "PROJECT1_AUDIT_DATABASE_URL")
    print(f"env_backup={backup.name}")
    return 0 if (ok1 and ok2) else 1


if __name__ == "__main__":
    raise SystemExit(main())
