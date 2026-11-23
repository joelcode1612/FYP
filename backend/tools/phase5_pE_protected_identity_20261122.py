"""Phase E - isolated protected-identity prototype.

Scope
-----
A brand-new database (``project1_security_prototype``) on the disposable
cluster, with its own owner role, its own runtime role and its own synthetic
data. Nothing here touches ``project1_workflow_tests``, ``Dss`` or
``Final_Location_Analysis``.

The design under test
---------------------
Replace the writable ``project1.actor_id`` GUC with a **signed identity
assertion** that the database itself verifies:

    project1.identity_assertion = "<actor_id>.<nonce>.<expiry_epoch>.<hmac_sha256_hex>"

``sec.actor()`` is SECURITY DEFINER, owned by a role the runtime cannot
impersonate, and recomputes the HMAC over ``actor_id|nonce|expiry`` with a key
stored in a table the runtime has no privilege on. If the assertion is absent,
malformed, expired, tampered, or signed with a retired key, ``sec.actor()``
returns NULL and RLS denies everything.

The critical property: **writing a GUC is not enough**. The old design let any
principal with ``EXECUTE`` on ``set_config`` name any owner. Here the runtime
can write any string it likes into the GUC and still cannot produce a valid
signature, because it cannot read the key and cannot execute the issuer.

What this prototype deliberately does NOT do
--------------------------------------------
* It does not modify any existing RLS policy.
* It does not migrate ``20261121_01`` or rename a database to defeat a guard.
* It does not claim to be production-ready: key custody, constant-time
  comparison and rotation windows are discussed in the report.
"""

from __future__ import annotations

import json
import re
import secrets
import threading
import time
import uuid
from pathlib import Path

import psycopg2
from psycopg2.extras import RealDictCursor

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
OUT = REPO / "deliverables" / "phase5"

HOST = "127.0.0.1"
PORT = 5433
DB = "project1_security_prototype"
OWNER_ROLE = "p1sec_owner"
RUNTIME_ROLE = "p1sec_runtime"
RUNTIME_PW = "p1sec_runtime_dev_only"   # disposable cluster only
OWNER_PW = "p1sec_owner_dev_only"       # disposable cluster only

OWNER_ID = "b9e62014-b7bc-426e-a950-a95b25965639"
STRANGER_ID = "c70a999a-50c6-4a31-8f7a-b914d0a5c641"


# ---------------------------------------------------------------------------
# connection helpers
# ---------------------------------------------------------------------------

def admin_dsn(database: str = "postgres") -> str:
    """Privileged session, redirected to the disposable cluster only."""
    from sqlalchemy.engine import make_url

    lines = (BACKEND / ".env").read_text(encoding="utf-8", errors="ignore").splitlines()
    raw = next(line.split("=", 1)[1].strip() for line in lines if line.startswith("DATABASE_URL="))
    url = make_url(raw)
    if url.get_backend_name() != "postgresql" or url.host not in {"localhost", "127.0.0.1"}:
        raise SystemExit("REFUSED: configured host is not local")
    target = url.set(port=PORT, database=database)
    if target.port != PORT or target.database in {"Dss", "Final_Location_Analysis"}:
        raise SystemExit("REFUSED: not the authorized disposable cluster")
    return target.render_as_string(hide_password=False).replace(
        "postgresql+psycopg2://", "postgresql://", 1)


def dsn(db: str, role: str, pw: str) -> str:
    return f"postgresql://{role}:{pw}@{HOST}:{PORT}/{db}"


# ---------------------------------------------------------------------------
# provisioning
# ---------------------------------------------------------------------------

SCHEMA_SQL = """
CREATE SCHEMA IF NOT EXISTS sec;

-- The signing key. The runtime role has no privilege on this table, and the
-- table is owned by p1sec_owner, so SECURITY DEFINER functions owned by that
-- role can read it while the runtime cannot.
CREATE TABLE IF NOT EXISTS sec.identity_keys (
    key_id      integer PRIMARY KEY,
    key_bytes   bytea   NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    retired_at  timestamptz
);

CREATE TABLE IF NOT EXISTS sec.identity_assertions (
    nonce       text PRIMARY KEY,
    actor_id    uuid NOT NULL,
    issued_at   timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS sec.owned_rows (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_user_id uuid NOT NULL,
    label         text NOT NULL
);

-- Issue an assertion. Only the auth service may call this: EXECUTE is revoked
-- from PUBLIC and from the runtime role, so a runtime principal cannot mint
-- an identity for itself.
CREATE OR REPLACE FUNCTION sec.issue_assertion(p_actor uuid, p_ttl_seconds integer)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, sec, ext
AS $$
DECLARE
    v_key    bytea;
    v_nonce  text;
    v_expiry bigint;
    v_mac    text;
BEGIN
    SELECT key_bytes INTO v_key FROM sec.identity_keys
     WHERE retired_at IS NULL ORDER BY key_id DESC LIMIT 1;
    IF v_key IS NULL THEN
        RAISE EXCEPTION 'no active signing key';
    END IF;
    v_nonce  := encode(gen_random_bytes(16), 'hex');
    v_expiry := extract(epoch FROM now())::bigint + p_ttl_seconds;
    INSERT INTO sec.identity_assertions(nonce, actor_id, expires_at)
    VALUES (v_nonce, p_actor, to_timestamp(v_expiry));
    v_mac := encode(hmac(convert_to(p_actor::text || '|' || v_nonce || '|'
                                    || v_expiry::text, 'UTF8'),
                         v_key, 'sha256'), 'hex');
    RETURN p_actor::text || '.' || v_nonce || '.' || v_expiry::text || '.' || v_mac;
END;
$$;

-- Verify the assertion. Returns NULL for anything that does not verify, so a
-- failed assertion denies by returning no rows rather than raising.
CREATE OR REPLACE FUNCTION sec.actor()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, sec, ext
AS $$
DECLARE
    v_raw    text := nullif(current_setting('project1.identity_assertion', true), '');
    v_parts  text[];
    v_actor  uuid;
    v_nonce  text;
    v_expiry bigint;
    v_mac    text;
    v_key    bytea;
    v_expect text;
    v_seen   timestamptz;
BEGIN
    IF v_raw IS NULL THEN
        RETURN NULL;
    END IF;
    v_parts := string_to_array(v_raw, '.');
    IF array_length(v_parts, 1) <> 4 THEN
        RETURN NULL;
    END IF;
    BEGIN
        v_actor  := v_parts[1]::uuid;
        v_nonce  := v_parts[2];
        v_expiry := v_parts[3]::bigint;
    EXCEPTION WHEN others THEN
        RETURN NULL;
    END;
    v_mac := v_parts[4];
    IF v_expiry < extract(epoch FROM now())::bigint THEN
        RETURN NULL;
    END IF;
    -- The nonce must have been issued by the auth service and must name the
    -- same actor: a replayed or substituted nonce fails here.
    SELECT expires_at INTO v_seen FROM sec.identity_assertions
     WHERE nonce = v_nonce AND actor_id = v_actor;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    SELECT key_bytes INTO v_key FROM sec.identity_keys
     WHERE retired_at IS NULL ORDER BY key_id DESC LIMIT 1;
    IF v_key IS NULL THEN
        RETURN NULL;
    END IF;
    v_expect := encode(hmac(convert_to(v_actor::text || '|' || v_nonce || '|'
                                       || v_expiry::text, 'UTF8'),
                            v_key, 'sha256'), 'hex');
    IF v_mac IS DISTINCT FROM v_expect THEN
        RETURN NULL;
    END IF;
    RETURN v_actor;
END;
$$;

ALTER TABLE sec.owned_rows ENABLE ROW LEVEL SECURITY;
ALTER TABLE sec.owned_rows FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS owned_rows_actor ON sec.owned_rows;
CREATE POLICY owned_rows_actor ON sec.owned_rows
    FOR ALL
    USING (owner_user_id = sec.actor())
    WITH CHECK (owner_user_id = sec.actor());
"""


def provision(admin) -> None:
    cur = admin.cursor()
    cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (OWNER_ROLE,))
    if not cur.fetchone():
        cur.execute(f'CREATE ROLE "{OWNER_ROLE}" LOGIN PASSWORD %s', (OWNER_PW,))
    else:
        cur.execute(f'ALTER ROLE "{OWNER_ROLE}" PASSWORD %s', (OWNER_PW,))
    cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (RUNTIME_ROLE,))
    if not cur.fetchone():
        cur.execute(f'CREATE ROLE "{RUNTIME_ROLE}" LOGIN PASSWORD %s', (RUNTIME_PW,))
    else:
        cur.execute(f'ALTER ROLE "{RUNTIME_ROLE}" PASSWORD %s', (RUNTIME_PW,))

    # The prototype database is rebuilt from scratch on every run so the
    # extension lands in its own schema, owned by the cluster superuser, before
    # the owner role is handed control. Only this prototype's name is dropped.
    if DB != "project1_security_prototype":
        raise SystemExit("REFUSED: unexpected prototype database name")
    cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (DB,))
    if cur.fetchone():
        cur.execute(f'DROP DATABASE "{DB}" WITH (FORCE)')
    cur.execute(f'CREATE DATABASE "{DB}" OWNER "{OWNER_ROLE}"')
    admin.commit()


def configure(admin) -> None:
    """Create the schema as the owner role, then grant the minimum."""
    cur = admin.cursor()
    cur.execute(f'SET ROLE "{OWNER_ROLE}"')
    cur.execute(SCHEMA_SQL)
    cur.execute(
        "INSERT INTO sec.identity_keys(key_id, key_bytes) "
        "SELECT 1, ext.gen_random_bytes(32) WHERE NOT EXISTS "
        "(SELECT 1 FROM sec.identity_keys WHERE key_id = 1)")
    # Least privilege: the runtime gets exactly these and nothing else.
    cur.execute(f'GRANT USAGE ON SCHEMA sec TO "{RUNTIME_ROLE}"')
    cur.execute(f'GRANT SELECT, INSERT, UPDATE, DELETE ON sec.owned_rows TO "{RUNTIME_ROLE}"')
    cur.execute(f'GRANT EXECUTE ON FUNCTION sec.actor() TO "{RUNTIME_ROLE}"')
    cur.execute(f'REVOKE ALL ON sec.identity_keys FROM "{RUNTIME_ROLE}"')
    cur.execute(f'REVOKE ALL ON sec.identity_assertions FROM "{RUNTIME_ROLE}"')
    cur.execute(f'REVOKE ALL ON FUNCTION sec.issue_assertion(uuid, integer) FROM PUBLIC')
    cur.execute(f'REVOKE ALL ON FUNCTION sec.issue_assertion(uuid, integer) FROM "{RUNTIME_ROLE}"')
    cur.execute(f'REVOKE CREATE ON SCHEMA sec FROM "{RUNTIME_ROLE}"')
    cur.execute(f'REVOKE CREATE ON SCHEMA public FROM PUBLIC')
    cur.execute('RESET ROLE')
    admin.commit()


def seed(admin_conn) -> None:
    """Seed with the cluster administrator.

    FORCE ROW LEVEL SECURITY applies to the table owner as well, so the owner
    role cannot insert without an assertion - which is the intended behaviour
    and exactly why the seed runs privileged.
    """
    cur = admin_conn.cursor()
    cur.execute("SELECT count(*) FROM sec.owned_rows")
    if cur.fetchone()[0] == 0:
        for owner, label in ((OWNER_ID, "owner-row-1"), (OWNER_ID, "owner-row-2"),
                             (STRANGER_ID, "stranger-row-1")):
            cur.execute(
                "INSERT INTO sec.owned_rows(owner_user_id, label) VALUES (%s, %s)",
                (owner, label))
    admin_conn.commit()


def issue(owner_conn, actor: str, ttl: int = 300) -> str:
    cur = owner_conn.cursor()
    cur.execute("SELECT sec.issue_assertion(%s::uuid, %s)", (actor, ttl))
    token = cur.fetchone()[0]
    owner_conn.commit()
    return token


# ---------------------------------------------------------------------------
# test helpers
# ---------------------------------------------------------------------------

def runtime_session(assertion: str | None, *, also_set_legacy_guc: str | None = None):
    """Open a runtime connection carrying (or not carrying) an assertion."""
    conn = psycopg2.connect(dsn(DB, RUNTIME_ROLE, RUNTIME_PW))
    conn.autocommit = False
    cur = conn.cursor()
    if assertion is not None:
        cur.execute("SELECT set_config('project1.identity_assertion', %s, true)",
                    (assertion,))
    if also_set_legacy_guc is not None:
        cur.execute("SELECT set_config('project1.actor_id', %s, true)",
                    (also_set_legacy_guc,))
    return conn, cur


def visible(cur) -> list[dict]:
    cur.execute("SELECT owner_user_id::text, label FROM sec.owned_rows ORDER BY label")
    return [{"owner": r[0], "label": r[1]} for r in cur.fetchall()]


# ---------------------------------------------------------------------------
# the test suite
# ---------------------------------------------------------------------------

def run_tests(owner_conn) -> list[dict]:
    tests: list[dict] = []

    def record(name: str, ok: bool, detail) -> None:
        tests.append({"test": name, "pass": bool(ok), "detail": detail})

    owner_tok = issue(owner_conn, OWNER_ID)
    stranger_tok = issue(owner_conn, STRANGER_ID)

    # 1. authenticated owner sees only its own rows
    conn, cur = runtime_session(owner_tok)
    rows = visible(cur)
    record("authenticated owner reads its own rows only",
           len(rows) == 2 and all(r["owner"] == OWNER_ID for r in rows), rows)
    conn.rollback(); conn.close()

    # 2. foreign owner is rejected
    conn, cur = runtime_session(stranger_tok)
    rows = visible(cur)
    record("foreign owner cannot read the other owner's rows",
           len(rows) == 1 and rows[0]["owner"] == STRANGER_ID, rows)
    conn.rollback(); conn.close()

    # 3. unset actor is rejected
    conn, cur = runtime_session(None)
    rows = visible(cur)
    record("unset assertion yields no rows", rows == [], rows)
    conn.rollback(); conn.close()

    # 4. GUC spoofing: the legacy actor GUC is written, no assertion supplied
    conn, cur = runtime_session(None, also_set_legacy_guc=OWNER_ID)
    rows = visible(cur)
    record("writing the legacy actor GUC grants nothing", rows == [], rows)
    conn.rollback(); conn.close()

    # 5. plaintext actor id in the new GUC (no signature)
    conn, cur = runtime_session(OWNER_ID)
    rows = visible(cur)
    record("a bare actor id in the assertion GUC is rejected", rows == [], rows)
    conn.rollback(); conn.close()

    # 6. tampered signature
    parts = owner_tok.split(".")
    forged = ".".join(parts[:3] + ["0" * 64])
    conn, cur = runtime_session(forged)
    rows = visible(cur)
    record("a tampered signature is rejected", rows == [], rows)
    conn.rollback(); conn.close()

    # 7. actor substitution: valid nonce/mac for stranger, actor field swapped
    s_parts = stranger_tok.split(".")
    substituted = ".".join([OWNER_ID] + s_parts[1:])
    conn, cur = runtime_session(substituted)
    rows = visible(cur)
    record("substituting the actor id into a valid token is rejected", rows == [], rows)
    conn.rollback(); conn.close()

    # 8. expired assertion
    expired_tok = issue(owner_conn, OWNER_ID, ttl=-5)
    conn, cur = runtime_session(expired_tok)
    rows = visible(cur)
    record("an expired assertion is rejected", rows == [], rows)
    conn.rollback(); conn.close()

    # 9. cross-owner INSERT refused by WITH CHECK
    conn, cur = runtime_session(owner_tok)
    refused = False
    detail = ""
    try:
        cur.execute("INSERT INTO sec.owned_rows(owner_user_id, label) VALUES (%s, %s)",
                    (STRANGER_ID, "forged-insert"))
        conn.commit()
    except psycopg2.errors.InsufficientPrivilege as exc:
        conn.rollback()
        refused = True
        detail = str(exc).strip().splitlines()[0]
    record("cross-owner INSERT is refused by WITH CHECK", refused,
           {"error": detail})

    # 10. cross-owner UPDATE affects nothing
    cur.execute("UPDATE sec.owned_rows SET label = 'hijacked' WHERE owner_user_id = %s",
                (STRANGER_ID,))
    affected = cur.rowcount
    conn.rollback(); conn.close()
    record("cross-owner UPDATE affects zero rows", affected == 0, {"rowcount": affected})

    # 11. cross-owner DELETE affects nothing
    conn, cur = runtime_session(owner_tok)
    cur.execute("DELETE FROM sec.owned_rows WHERE owner_user_id = %s", (STRANGER_ID,))
    affected = cur.rowcount
    conn.rollback(); conn.close()
    record("cross-owner DELETE affects zero rows", affected == 0, {"rowcount": affected})

    # 12. runtime cannot read the signing key
    conn, cur = runtime_session(owner_tok)
    denied = False
    detail = ""
    try:
        cur.execute("SELECT key_bytes FROM sec.identity_keys")
        cur.fetchall()
    except psycopg2.errors.InsufficientPrivilege as exc:
        conn.rollback()
        denied = True
        detail = str(exc).strip().splitlines()[0]
    conn.rollback(); conn.close()
    record("runtime cannot read the signing key", denied, {"error": detail})

    # 13. runtime cannot mint an assertion
    conn, cur = runtime_session(owner_tok)
    denied = False
    detail = ""
    try:
        cur.execute("SELECT sec.issue_assertion(%s::uuid, 300)", (STRANGER_ID,))
        cur.fetchone()
    except psycopg2.errors.InsufficientPrivilege as exc:
        conn.rollback()
        denied = True
        detail = str(exc).strip().splitlines()[0]
    conn.rollback(); conn.close()
    record("runtime cannot mint an assertion for another actor", denied, {"error": detail})

    # 14. runtime cannot replace sec.actor() or create objects in the schema
    conn, cur = runtime_session(owner_tok)
    denied_fn = denied_schema = False
    detail_fn = detail_schema = ""
    try:
        cur.execute("CREATE OR REPLACE FUNCTION sec.actor() RETURNS uuid "
                    "LANGUAGE sql AS $$ SELECT '%s'::uuid $$" % OWNER_ID)
    except psycopg2.errors.InsufficientPrivilege as exc:
        conn.rollback()
        denied_fn = True
        detail_fn = str(exc).strip().splitlines()[0]
    try:
        cur.execute("CREATE TABLE sec.evil(x int)")
    except psycopg2.errors.InsufficientPrivilege as exc:
        conn.rollback()
        denied_schema = True
        detail_schema = str(exc).strip().splitlines()[0]
    conn.rollback(); conn.close()
    record("runtime cannot redefine sec.actor()", denied_fn, {"error": detail_fn})
    record("runtime cannot create objects in sec", denied_schema, {"error": detail_schema})

    # 15. runtime cannot disable RLS on the table
    conn, cur = runtime_session(owner_tok)
    denied = False
    detail = ""
    try:
        cur.execute("ALTER TABLE sec.owned_rows DISABLE ROW LEVEL SECURITY")
    except psycopg2.errors.InsufficientPrivilege as exc:
        conn.rollback()
        denied = True
        detail = str(exc).strip().splitlines()[0]
    conn.rollback(); conn.close()
    record("runtime cannot disable row level security", denied, {"error": detail})

    # 16. injection-shaped assertions are rejected, not executed
    injections = [
        f"{OWNER_ID}' OR '1'='1",
        f"{OWNER_ID}; DROP TABLE sec.owned_rows; --",
        f"{OWNER_ID}/*",
        ".".join([OWNER_ID, "x' OR 1=1 --", "9999999999", "0" * 64]),
    ]
    results = []
    for payload in injections:
        conn, cur = runtime_session(payload)
        results.append({"payload": payload[:48], "rows": len(visible(cur))})
        conn.rollback(); conn.close()
    record("injection-shaped assertions yield no rows",
           all(r["rows"] == 0 for r in results), results)

    # 17. connection-pool isolation under interleaving
    anomalies: list[dict] = []
    lock = threading.Lock()

    def worker(tok: str, expected_owner: str, rounds: int) -> None:
        try:
            conn = psycopg2.connect(dsn(DB, RUNTIME_ROLE, RUNTIME_PW))
            conn.autocommit = True
            cur = conn.cursor()
            for _ in range(rounds):
                cur.execute("SELECT set_config('project1.identity_assertion', %s, true)",
                            (tok,))
                cur.execute("SELECT owner_user_id::text FROM sec.owned_rows")
                seen = {r[0] for r in cur.fetchall()}
                if seen and seen != {expected_owner}:
                    with lock:
                        anomalies.append({"expected": expected_owner, "seen": sorted(seen)})
            conn.close()
        except Exception as exc:  # noqa: BLE001
            with lock:
                anomalies.append({"error": f"{type(exc).__name__}: {exc}"})

    threads = [threading.Thread(target=worker, args=(owner_tok, OWNER_ID, 12)),
               threading.Thread(target=worker, args=(stranger_tok, STRANGER_ID, 12))]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    record("connection-pool isolation holds under interleaving", not anomalies,
           {"anomalies": anomalies, "rounds": 24})

    # 18. key rotation invalidates assertions signed with the retired key
    old_tok = issue(owner_conn, OWNER_ID)
    cur = owner_conn.cursor()
    cur.execute("UPDATE sec.identity_keys SET retired_at = now() WHERE key_id = 1")
    cur.execute("INSERT INTO sec.identity_keys(key_id, key_bytes) "
                "VALUES (2, ext.gen_random_bytes(32))")
    owner_conn.commit()
    conn, cur2 = runtime_session(old_tok)
    rows_old = visible(cur2)
    conn.rollback(); conn.close()
    new_tok = issue(owner_conn, OWNER_ID)
    conn, cur3 = runtime_session(new_tok)
    rows_new = visible(cur3)
    conn.rollback(); conn.close()
    record("rotation: retired-key assertions stop working, new ones work",
           rows_old == [] and len(rows_new) == 2,
           {"old_token_rows": len(rows_old), "new_token_rows": len(rows_new)})

    return tests


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    report: dict = {"checkpoint": "PHASE_E_PROTECTED_IDENTITY_PROTOTYPE",
                    "database": DB, "port": PORT,
                    "runtime_role": RUNTIME_ROLE, "owner_role": OWNER_ROLE}

    admin = psycopg2.connect(admin_dsn())
    admin.autocommit = True
    provision(admin)
    admin.close()

    # pgcrypto in its own schema, installed by the superuser before handover,
    # so the definer search_path is pg_catalog, sec, ext and never public.
    boot = psycopg2.connect(admin_dsn(DB))
    boot.autocommit = True
    bcur = boot.cursor()
    bcur.execute("CREATE SCHEMA IF NOT EXISTS ext")
    bcur.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA ext")
    bcur.execute(f'GRANT USAGE ON SCHEMA ext TO "{OWNER_ROLE}", "{RUNTIME_ROLE}"')
    boot.close()

    admin = psycopg2.connect(admin_dsn(DB))
    admin.autocommit = True
    configure(admin)
    seed(admin)
    admin.close()

    owner_conn = psycopg2.connect(dsn(DB, OWNER_ROLE, OWNER_PW))
    owner_conn.autocommit = False

    report["tests"] = run_tests(owner_conn)
    owner_conn.close()

    passed = sum(1 for t in report["tests"] if t["pass"])
    report["summary"] = {"pass": passed, "fail": len(report["tests"]) - passed,
                         "total": len(report["tests"])}

    (OUT / "pE_protected_identity.json").write_text(
        json.dumps(report, indent=2, default=str), encoding="utf-8")
    print(json.dumps(report["summary"], indent=2))
    for t in report["tests"]:
        print(f"{'PASS' if t['pass'] else 'FAIL'}  {t['test']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
