r"""Run CP07 against a NEW private PostgreSQL 18 cluster, never an existing DB.

Run from backend: .venv\Scripts\python.exe tests\cp07\run_isolated.py
Requires installed PostgreSQL 18 binaries and a free loopback port 55437.
Leaves stopped data/logs in a new temp directory for inspection; no recursive delete.
"""
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    binaries = Path(os.environ.get("CP07_PG_BIN", r"C:\Program Files\PostgreSQL\18\bin"))
    for name in ("initdb.exe", "pg_ctl.exe", "psql.exe"):
        if not (binaries / name).is_file():
            raise SystemExit(f"Required PostgreSQL binary absent: {name}")
    # Never commandeer an existing listener/cluster, including UC B4 staging.
    with socket.socket() as check:
        check.bind(("127.0.0.1", 55437))
    lab = Path(tempfile.mkdtemp(prefix="project1_cp07_"))
    print(f"Private CP07 lab: {lab}", flush=True)
    data = lab / "data"
    password = secrets.token_urlsafe(32)
    pwfile = lab / "init_password"
    pwfile.write_text(password, encoding="ascii")
    env = os.environ.copy()
    env["PGPASSWORD"] = password
    env["PGHOST"] = "127.0.0.1"
    env["PGPORT"] = "55437"
    env["PGUSER"] = "postgres"
    env["PGDATABASE"] = "project1_cp07_tests"
    started = False
    with (lab / "cluster_setup.log").open("w", encoding="utf-8") as log:
        def run(args):
            subprocess.run(args, env=env, cwd=root, stdout=log, stderr=log, check=True)
        try:
            run([str(binaries / "initdb.exe"), "-D", str(data), "-U", "postgres",
                 "--encoding=UTF8", "--locale=C", "-A", "scram-sha-256", f"--pwfile={pwfile}"])
            pwfile.unlink()
            run([str(binaries / "pg_ctl.exe"), "-D", str(data), "-l", str(lab / "postgres.log"),
                 "-o", '-h 127.0.0.1 -p 55437', "-w", "start"])
            started = True
            env["PGDATABASE"] = "postgres"
            run([str(binaries / "psql.exe"), "-v", "ON_ERROR_STOP=1", "-c",
                 "CREATE DATABASE project1_cp07_tests"])
            env["PGDATABASE"] = "project1_cp07_tests"
            # Existing restricted role names/ACLs are required by the schema dump.
            run([str(binaries / "psql.exe"), "-v", "ON_ERROR_STOP=1", "-c",
                 "CREATE ROLE p1uc_stage_human NOLOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS; "
                 "CREATE ROLE p1uc_stage_llm NOLOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS; "
                 "CREATE ROLE p1uc_stage_qj NOLOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS;"])
            # The recorded M2 dump already includes the existing users table.
            env["DATABASE_URL"] = f"postgresql+psycopg2://postgres:{password}@127.0.0.1:55437/project1_cp07_tests"
            env["ANALYTICS_DATABASE_URL"] = env["DATABASE_URL"]
            env["PYTHONPATH"] = str(root / "src")
            env["M2_UPSTREAM_ENABLED"] = "false"
            env["PROJECT1_CP07_ENABLED"] = "true"
            for filename in ("stage_m2_schema.sql", "stage_uc_schema.sql"):
                run([str(binaries / "psql.exe"), "-v", "ON_ERROR_STOP=1", "-f",
                     str(root / "tests" / "cp07" / "fixtures" / filename)])
            env["CP07_PRIVATE_CLUSTER_VERIFIED"] = str(lab)
            env["CP07_EVIDENCE_DIR"] = str(lab / "evidence")
            outcome = subprocess.run([sys.executable, "-m", "pytest", "tests/cp07/test_http_postgres.py",
                                      "--confcutdir=tests/cp07", "-q",
                                      f"--junitxml={lab / 'pytest.xml'}"], env=env, cwd=root,
                                     capture_output=True, text=True)
            test_log = outcome.stdout + outcome.stderr
            (lab / "pytest.log").write_text(test_log, encoding="utf-8")
            print(test_log, flush=True)
            (lab / "run.json").write_text(json.dumps({
                "exit_code": outcome.returncode, "cluster": str(lab), "port": 55437,
                "database": "project1_cp07_tests", "main_Dss_accessed": False,
                "restore": "schema-only recorded stage snapshots; no production migration",
            }, indent=2), encoding="utf-8")
            print(f"CP07 evidence directory: {lab}")
            return outcome.returncode
        finally:
            if pwfile.exists():
                pwfile.unlink()
            if started:
                run([str(binaries / "pg_ctl.exe"), "-D", str(data), "-m", "fast", "-w", "stop"])


if __name__ == "__main__":
    raise SystemExit(main())
