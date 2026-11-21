"""Read-only inspection of project1_ai roles/grants/membership. No writes, no secrets."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from sqlalchemy import create_engine, text  # noqa: E402

from sitewise.core.config import settings  # noqa: E402


def run(label, url):
    if not url:
        print(f"[{label}] no url")
        return
    try:
        engine = create_engine(url, hide_parameters=True, pool_pre_ping=True)
        with engine.connect() as c:
            db, cu, su = c.execute(text(
                "SELECT current_database(), current_user, session_user")).one()
            print(f"[{label}] db={db} current_user={cu} session_user={su}")
            roles = c.execute(text(
                "SELECT rolname, rolcanlogin, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb "
                "FROM pg_roles WHERE rolname IN "
                "('p1ai_runtime','p1ai_owner','p1ai_audit','p1_m2_runtime','p1_ee01_runtime','postgres') "
                "ORDER BY rolname")).all()
            for r in roles:
                print(f"  role={r[0]} login={r[1]} super={r[2]} bypassrls={r[3]} createrole={r[4]} createdb={r[5]}")
            try:
                members = c.execute(text(
                    "SELECT r.rolname AS role, m.rolname AS member "
                    "FROM pg_auth_members am "
                    "JOIN pg_roles r ON r.oid=am.roleid "
                    "JOIN pg_roles m ON m.oid=am.member "
                    "WHERE r.rolname IN ('p1ai_runtime','p1ai_audit')")).all()
                print(f"  memberships_of_p1ai_runtime/audit={members}")
            except Exception as exc:  # noqa: BLE001
                print(f"  membership_read_error={type(exc).__name__}")
            try:
                n = c.execute(text("SELECT count(*) FROM project1_ai.runs")).scalar()
                print(f"  project1_ai.runs_count={n}")
            except Exception as exc:  # noqa: BLE001
                print(f"  project1_ai_read={type(exc).__name__}")
    except Exception as exc:  # noqa: BLE001
        print(f"[{label}] CONNECT_FAIL {type(exc).__name__}: {str(exc)[:160]}")


run("m2", settings.m2_database_url.get_secret_value())
run("app", settings.database_url)
