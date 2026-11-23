"""Gate 3 — real BCB construction and persistence (disposable target only).

Pinned source: assessment d82b78ff…, confirmation 658dfcc7…, revision 11.
Uses PersistedBusinessContextService + SqlBusinessContextStore + M2ContextBindings.
No fabricated context, no live model call, no `.env` change.

Run:
    PYTHONPATH=src .venv/Scripts/python.exe tools/phase2_gate3_bcb_20261121.py
"""
import json
import os
import uuid
from datetime import timedelta
from pathlib import Path

TARGET_DB = "project1_workflow_tests"
PORT = 5433
BACKEND = Path(__file__).resolve().parents[1]
ASSESSMENT = uuid.UUID("d82b78ff-dad0-41d8-afa4-0205ad199a20")
CONFIRMATION = uuid.UUID("658dfcc7-75e6-4f76-b245-71678459ba60")
REVISION = 11
ROLE = "p1_m2_runtime"
ROLE_PW = os.environ.get("PHASE2_M2_ROLE_PW", "m2_runtime_dev_only")


def install_overrides():
    for line in (BACKEND / ".env").read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.startswith("DATABASE_URL="):
            base = line.split("=", 1)[1].strip()
            break
    app = base.replace(":5432", f":{PORT}").rsplit("/", 1)[0] + "/" + TARGET_DB
    host = app.split("://", 1)[1].split("@", 1)[1]
    scheme = app.split("://", 1)[0]
    os.environ["DATABASE_URL"] = app
    os.environ["M2_DATABASE_URL"] = f"{scheme}://{ROLE}:{ROLE_PW}@{host}"
    os.environ["PROJECT1_BCB_CONFIRMATION_VALIDITY_DAYS"] = "1"
    # get_bcb_engine() refuses unless the expected database matches the URL.
    os.environ["M2_EXPECTED_DATABASE"] = TARGET_DB
    return app, f"{scheme}://{ROLE}:{ROLE_PW}@{host}"


APP_URL, M2_URL = install_overrides()


def libpq(dsn):
    return dsn.replace("postgresql+psycopg2://", "postgresql://")


def main():
    import psycopg2
    from sitewise.core.config import settings
    from sitewise.db.m2_session import get_bcb_engine
    from sitewise.repositories.business_context_repository import SqlBusinessContextStore
    from sitewise.repositories.m2_context_bindings import M2ContextBindings
    from sitewise.services.persisted_business_context_service import PersistedBusinessContextService
    from sitewise.services.ports.business_context_store_port import ContextActor, ContextSelection
    from sitewise.domain import rbac

    checks = []

    def check(label, fn):
        try:
            checks.append({"check": label, "result": "PASS", "detail": str(fn())})
        except Exception as exc:
            checks.append({"check": label, "result": "FAIL",
                           "detail": f"{type(exc).__name__}: {str(exc)[:150]}"})
        print("  %-4s %-46s %s" % (checks[-1]["result"], label, str(checks[-1]["detail"])[:62]))

    admin = psycopg2.connect(libpq(APP_URL))
    admin.autocommit = True
    with admin.cursor() as cur:
        cur.execute("select owner_user_id, revision, confirmed_revision from public.m2_assessments where id=%s",
                    (str(ASSESSMENT),))
        owner, revision, confirmed_revision = cur.fetchone()
        # The authorization port compares UUID to UUID; psycopg2 hands back a
        # str here, which fails the strict comparison as OWNERSHIP_NOT_VERIFIED.
        owner = uuid.UUID(str(owner))
        cur.execute("select snapshot_digest from public.m2_confirmation_snapshots where id=%s",
                    (str(CONFIRMATION),))
        digest = cur.fetchone()[0]
        cur.execute("select md5(string_agg(id::text || ':' || item_version_id::text, ',' order by id)) "
                    "from public.m2_answer_revisions where assessment_id=%s", (str(ASSESSMENT),))
        m2_hash_before = cur.fetchone()[0]

    print("=" * 78)
    print("GATE 3 — real BCB")
    print("=" * 78)
    print("assessment:", ASSESSMENT, "| revision:", revision, "| confirmed:", confirmed_revision)
    print("confirmation:", CONFIRMATION, "| digest:", str(digest)[:12])
    print("validity:", settings.project1_bcb_confirmation_validity_days, "day(s)")

    validity = timedelta(days=settings.project1_bcb_confirmation_validity_days)
    store = SqlBusinessContextStore(get_bcb_engine(),
                                    lambda repository: M2ContextBindings(repository, validity=validity))
    service = PersistedBusinessContextService(store)
    selection = ContextSelection(assessment_id=ASSESSMENT, confirmation_id=CONFIRMATION,
                                 revision=REVISION)

    state = {}

    def construct():
        errors = []
        for role_name in ("ENTREPRENEUR", "OWNER", "ADMIN"):
            actor = ContextActor(owner, rbac.canonical_role(role_name))
            try:
                row = service.construct_and_save(selection, actor)
                state.update(row=row, actor=actor, role=actor.role)
                return f"context {row.get('context_id')} hash {str(row.get('packet_hash'))[:12]} role={actor.role}"
            except Exception as exc:
                errors.append(f"{role_name}:{type(exc).__name__}:{str(exc)[:40]}")
        raise AssertionError(" | ".join(errors))

    def identity():
        row = state["row"]
        if not row.get("context_id") or not row.get("packet", {}).get("packet_hash"):
            raise AssertionError(f"missing identity: {list(row)}")
        return ("context_id + packet.packet_hash present, status="
                f"{row.get('lifecycle_status')}, replayed={row.get('replayed')}")

    def readback():
        # Transaction-local actor binding: autocommit would discard it between
        # statements and produce a false "no rows" result.
        c = psycopg2.connect(libpq(M2_URL))
        c.autocommit = False
        try:
            with c.cursor() as cur:
                cur.execute("select set_config('project1.actor_id', %s, true)", (str(owner),))
                cur.execute("select context_id, confirmation_id, assessment_revision, schema_version, "
                            "packet_hash from public.m2_business_contexts where context_id=%s",
                            (str(state["row"]["context_id"]),))
                got = cur.fetchone()
        finally:
            c.rollback()
            c.close()
        if got is None:
            with admin.cursor() as cur:
                cur.execute("select count(*) from public.m2_business_contexts where context_id=%s",
                            (str(state["row"]["context_id"]),))
                n = cur.fetchone()[0]
            raise AssertionError(f"0 rows as restricted principal; admin sees {n} "
                                 f"(RLS problem if 1, missing persistence if 0)")
        if str(got[1]) != str(CONFIRMATION) or got[2] != REVISION:
            raise AssertionError(f"identity mismatch: {got}")
        if str(got[4]) != str(state["row"]["packet"]["packet_hash"]):
            raise AssertionError("persisted hash differs from returned hash")
        return f"read as p1_m2_runtime: {got[0]} rev={got[2]} v={got[3]}"

    def deterministic():
        actor = state["actor"]
        again = service.construct_and_save(selection, actor)
        if str(again.get("context_id")) != str(state["row"].get("context_id")):
            raise AssertionError("repeat construction produced a different context id")
        if str(again.get("packet", {}).get("packet_hash")) != str(state["row"].get("packet", {}).get("packet_hash")):
            raise AssertionError("repeat construction produced a different hash")
        return "same context_id and packet_hash on re-construction"

    def m2_unchanged():
        c = psycopg2.connect(libpq(APP_URL))
        c.autocommit = True
        with c.cursor() as cur:
            cur.execute("select md5(string_agg(id::text || ':' || item_version_id::text, ',' order by id)) "
                        "from public.m2_answer_revisions where assessment_id=%s", (str(ASSESSMENT),))
            after = cur.fetchone()[0]
            cur.execute("select count(*) from public.m2_answer_revisions where assessment_id=%s",
                        (str(ASSESSMENT),))
            n = cur.fetchone()[0]
        c.close()
        if after != m2_hash_before:
            raise AssertionError("M2 answer revisions changed")
        return f"{n} answer revisions, canonical hash unchanged"

    def cross_owner():
        other = uuid.uuid4()
        try:
            service.construct_and_save(selection, ContextActor(other, rbac.canonical_role("ENTREPRENEUR")))
        except Exception as exc:
            return f"refused: {type(exc).__name__}: {str(exc)[:50]}"
        raise AssertionError("cross-owner construction accepted")

    def missing_validity():
        s2 = SqlBusinessContextStore(get_bcb_engine(),
                                     lambda repository: M2ContextBindings(repository, validity=None))
        try:
            PersistedBusinessContextService(s2).construct_and_save(selection, state["actor"])
        except Exception as exc:
            return f"refused: {type(exc).__name__}: {str(exc)[:50]}"
        raise AssertionError("missing validity accepted")

    def stale_revision():
        bad = ContextSelection(assessment_id=ASSESSMENT, confirmation_id=CONFIRMATION,
                               revision=REVISION - 1)
        try:
            service.construct_and_save(bad, state["actor"])
        except Exception as exc:
            return f"refused: {type(exc).__name__}: {str(exc)[:50]}"
        raise AssertionError("stale revision accepted")

    check("1. construct_and_save returns identity", construct)
    check("2. context identity fields", identity)
    check("3. persisted readback via restricted role", readback)
    check("4. deterministic re-construction", deterministic)
    check("5. M2 answer revisions unchanged", m2_unchanged)
    check("6. cross-owner refused", cross_owner)
    check("7. missing validity refused", missing_validity)
    check("8. stale revision refused", stale_revision)

    passed = sum(1 for c in checks if c["result"] == "PASS")
    row = state.get("row") or {}
    packet = row.get("packet") or {}
    evidence = {"gate": 3, "target": f"{TARGET_DB}@{PORT}",
                "assessment": str(ASSESSMENT), "confirmation": str(CONFIRMATION),
                "revision": REVISION, "actor_role": state.get("role"),
                "context_id": str(row.get("context_id")),
                "packet_hash": packet.get("packet_hash"),
                "schema_version": packet.get("schema_version"),
                "context_version": packet.get("context_version"),
                "lifecycle_status": row.get("lifecycle_status"),
                "replayed": row.get("replayed"),
                "checks": checks, "passed": passed, "total": len(checks),
                "verdict": "PASS" if passed == len(checks) else "FAIL"}
    out = BACKEND.parent / "deliverables/phase2/BDJ_GATE3_BCB_20261121.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(evidence, indent=2, ensure_ascii=False, default=str), encoding="utf-8")
    print("\n  %d/%d checks passed" % (passed, len(checks)))
    print("  evidence:", out)
    print("  VERDICT:", evidence["verdict"])
    return 0 if evidence["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
