#!/usr/bin/env python3
"""Project1 CP-04B: source/registered-route/DI/guarded negative-auth verification.

Default operation is PURE STATIC analysis. Optional registered-route probe imports the
app in a separate Python process with database connections and network disabled.
Never performs normal lifespan startup or calls business POST/PUT/PATCH/DELETE.
Nothing in this program is a production DB migration or positive-auth test.
"""
from __future__ import annotations

import argparse
import ast
import csv
import datetime as dt
import hashlib
import inspect
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import zipfile

METHODS = {"get", "post", "put", "patch", "delete", "options", "head", "trace"}
DEPENDENCY_NAMES = {
    "get_db", "get_current_user", "get_active_user", "require_entrepreneur",
    "get_m2_service", "get_bdj_service", "get_confirmation_service",
    "require_admin_mfa", "get_staff_user", "configuration_gate",
}
PROTECTED_DEPENDENCIES = {"get_current_user", "get_active_user", "require_entrepreneur", "require_admin_mfa", "get_staff_user"}
SAFE_FAKE_URL = "postgresql+psycopg2://cp04b_disabled:cp04b_disabled@127.0.0.1:1/project1_cp04b_test"
FLAG_OFF = ("PROJECT1_CP07_ENABLED", "PROJECT1_WORKFLOW_ENABLED", "PROJECT1_AI_ENABLED", "M2_UPSTREAM_ENABLED",
            "PROJECT1_QG_ENABLED", "PROJECT1_BDJ_MODEL_ENABLED", "PROJECT1_LLM_ENABLED")


def date_stamp():
    return dt.datetime.now().strftime("%Y%m%d_%H%M%S")


def relpath(path: Path, backend: Path) -> str:
    try:
        return path.resolve().relative_to(backend.resolve()).as_posix()
    except ValueError:
        return path.name


def expr_name(node):
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        root = expr_name(node.value)
        return root + "." + node.attr if root else node.attr
    if isinstance(node, ast.Subscript):
        return expr_name(node.value)
    return ""


def depends_from_node(node):
    result = []
    for n in ast.walk(node):
        if isinstance(n, ast.Call) and expr_name(n.func).split(".")[-1] in {"Depends", "Security"}:
            if n.args:
                result.append(expr_name(n.args[0]))
    return sorted(set(x for x in result if x))


def walk_source(backend: Path):
    root = backend / "src" / "sitewise"
    if not root.is_dir():
        raise RuntimeError("backend/src/sitewise not present")
    routes, providers, include_calls, boundary_candidates = [], [], [], []
    parse_errors, hashes = [], []
    for path in sorted(root.rglob("*.py")):
        relative = relpath(path, backend)
        try:
            raw = path.read_bytes()
            source = raw.decode("utf-8-sig")
            tree = ast.parse(source, filename=relative)
        except (SyntaxError, UnicodeError, OSError) as ex:
            parse_errors.append({"path": relative, "error_type": type(ex).__name__})
            continue
        hashes.append({"path": relative, "sha256": hashlib.sha256(raw).hexdigest()})
        module = relative.replace("src/", "").replace("/", ".").removesuffix(".py")
        for node in ast.walk(tree):
            if isinstance(node, (ast.Import, ast.ImportFrom)):
                imports = ([x.name for x in node.names] if isinstance(node, ast.Import)
                           else [node.module or ""])
                if "/domain/" in relative and any(x.startswith(("sitewise.api", "sitewise.db", "sitewise.repositories", "sqlalchemy", "fastapi")) for x in imports):
                    boundary_candidates.append({"file": relative, "line": node.lineno,
                                               "reason": "domain_depends_on_outer_layer", "imports": imports})
                if relative.endswith("api/v1/project1_workflow.py") and any(x.startswith("sitewise.repositories") for x in imports):
                    boundary_candidates.append({"file": relative, "line": node.lineno,
                                               "reason": "api_imports_concrete_repository", "imports": imports})
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                deps = []
                for arg in node.args.args + node.args.kwonlyargs:
                    if arg.annotation is not None:
                        deps.extend(depends_from_node(arg.annotation))
                for default in node.args.defaults + node.args.kw_defaults:
                    if default is not None:
                        deps.extend(depends_from_node(default))
                if node.name in DEPENDENCY_NAMES or node.name.startswith("get_"):
                    providers.append({"file": relative, "module": module, "function": node.name,
                                      "line": node.lineno, "depends_on": sorted(set(deps))})
                for decorator in node.decorator_list:
                    if not isinstance(decorator, ast.Call):
                        continue
                    dec = expr_name(decorator.func)
                    if dec.split(".")[-1] not in METHODS:
                        continue
                    method = dec.split(".")[-1].upper()
                    first = decorator.args[0] if decorator.args else None
                    path_value = first.value if isinstance(first, ast.Constant) and isinstance(first.value, str) else None
                    routes.append({"module": module, "file": relative, "function": node.name,
                                   "method": method, "path_fragment": path_value,
                                   "decorator": dec, "line": decorator.lineno,
                                   "depends_direct": sorted(set(deps))})
            if isinstance(node, ast.Call) and expr_name(node.func).endswith(".include_router"):
                include_calls.append({"file": relative, "line": node.lineno,
                                      "router_ref": expr_name(node.args[0]) if node.args else None,
                                      "prefix_literal": next((kw.value.value for kw in node.keywords
                                          if kw.arg == "prefix" and isinstance(kw.value, ast.Constant) and isinstance(kw.value.value, str)), None)})
    return {"routes": routes, "dependency_providers": providers,
            "include_router_calls": include_calls, "boundary_review_candidates": boundary_candidates,
            "parse_errors": parse_errors, "source_hashes": hashes,
            "files_scanned": len(hashes)}


def verify_from_previous(archive_path: Path | None):
    if not archive_path:
        return {"status": "NOT_PROVIDED"}
    try:
        with zipfile.ZipFile(archive_path) as z:
            names = set(z.namelist())
            result = {"status": "PRIOR_REPORT_READ", "archive_file": archive_path.name,
                      "contains_route_inventory": "ROUTE_INVENTORY.json" in names,
                      "contains_prepared_test_matrix": "PREPARED_API_TEST_MATRIX.csv" in names}
            if "ROUTE_INVENTORY.json" in names:
                result["prior_declared_routes"] = len(json.loads(z.read("ROUTE_INVENTORY.json")))
            return result
    except (OSError, zipfile.BadZipFile, ValueError):
        return {"status": "PRIOR_REPORT_UNREADABLE"}


def registered_api_routes(routes):
    """Yield endpoint, effective path and DI for eager and deferred FastAPI routers.

    FastAPI 0.162 defers include_router: inspecting APIRoute objects only at
    app.routes silently misses the whole v1 API. Effective contexts preserve
    prefix and inherited dependencies without mounting or invoking anything.
    """
    from fastapi.routing import APIRoute

    for route in routes:
        if isinstance(route, APIRoute):
            yield route, route.path, route.dependant
        elif callable(getattr(route, "effective_route_contexts", None)):
            for context in route.effective_route_contexts():
                original = context.original_route
                if isinstance(original, APIRoute):
                    yield original, context.path, context.dependant


def worker():
    stage = "INSTALL_NETWORK_AND_DB_GUARDS"
    # Called ONLY in an isolated child process with fake port-1 database URLs.
    # Fail closed for external network and database sessions. Do not run lifespan startup.
    import socket

    # Windows asyncio creates a loopback socketpair for its self-pipe. Prepare
    # those pairs before the guards so in-process ASGI requests can run while
    # every subsequent connect (including all application SQL) remains denied.
    if os.environ.get("CP04B_NEGATIVE_AUTH", "0") == "1":
        self_pipes = [socket.socketpair() for _ in range(16)]
        socket.socketpair = lambda *args, **kwargs: self_pipes.pop()

    def block_network(*args, **kwargs):
        raise RuntimeError("CP04B_NETWORK_CONNECTION_REFUSED")

    socket.socket.connect = block_network
    socket.socket.connect_ex = block_network
    socket.create_connection = block_network
    try:
        from sqlalchemy.engine import Engine
        Engine.connect = block_network
        Engine.begin = block_network
    except ImportError:
        pass
    for driver in ("psycopg", "psycopg2"):
        try:
            obj = __import__(driver)
            obj.connect = block_network
        except ImportError:
            pass
    # Disable arbitrary process spawning during import. Do not affect parent runner.
    subprocess.Popen = block_network
    os.system = block_network
    stage = "IMPORT_FASTAPI_APP"
    try:
        import sitewise.main as main
        stage = "READ_APP_OBJECT"
        app = getattr(main, "app", None)
        if app is None:
            return {"status": "BLOCKED", "reason": "NO_APP_OBJECT"}
        registered, executable = [], []
        stage = "READ_ROUTE_REGISTRY_AND_DEPENDENCIES"
        for route, effective_path, dependant in registered_api_routes(app.routes):
            endpoint = route.endpoint
            try:
                origin_file = inspect.getsourcefile(endpoint) or ""
                origin = str(Path(origin_file).resolve().relative_to(Path(os.environ["CP04B_BACKEND"]).resolve())).replace("\\", "/")
            except (TypeError, ValueError, OSError):
                origin = None
            deps = []
            seen = set()
            def deps_collect(item):
                for dep in getattr(item, "dependencies", []):
                    call = getattr(dep, "call", None)
                    label = getattr(call, "__name__", type(call).__name__)
                    if (label, id(call)) not in seen:
                        seen.add((label, id(call)))
                        deps.append(label)
                    deps_collect(dep)
            deps_collect(dependant)
            methods = sorted((set(route.methods or set()) - {"HEAD", "OPTIONS"}))
            for method in methods:
                registered.append({"method": method, "path": effective_path,
                                   "function": getattr(endpoint, "__name__", "<unknown>"),
                                   "file": origin, "dependencies": sorted(set(deps)),
                                   "protected_guard": bool(set(deps) & PROTECTED_DEPENDENCIES)})
            if "GET" in methods and set(deps) & PROTECTED_DEPENDENCIES:
                executable.append({"route": effective_path, "guards": sorted(set(deps) & PROTECTED_DEPENDENCIES)})
        result = {"status": "REGISTERED_ROUTE_READ", "registered_routes": registered,
                  "unauthed_checks": [], "registration_count": len(registered)}
        if os.environ.get("CP04B_NEGATIVE_AUTH", "0") == "1":
            stage = "NEGATIVE_AUTH_PROBES"
            try:
                from fastapi.testclient import TestClient
                client = TestClient(app, raise_server_exceptions=False)
                checked = set()
                # Prefer M2 routes over unrelated property endpoints.
                ordered = sorted(executable, key=lambda x: ("/assessments/" not in x["route"], x["route"]))
                for item in ordered:
                    if len(checked) >= 4:
                        break
                    path = item["route"]
                    if path in checked:
                        continue
                    checked.add(path)
                    target = re.sub(r"\{[^}]+\}", "00000000-0000-4000-8000-000000000001", path)
                    for variant, headers in (("NO_TOKEN", {}), ("MALFORMED_TOKEN", {"Authorization": "Bearer cp04b.invalid.token"})):
                        try:
                            resp = client.get(target, headers=headers, follow_redirects=False)
                            status = resp.status_code
                            verdict = ("DENIED" if status in (401, 403) else
                                       "FAIL_UNAUTHORIZED_SUCCESS" if status in (200, 201, 202, 204) else
                                       "BLOCKED_OR_INCONCLUSIVE")
                            result["unauthed_checks"].append({"path": path, "variant": variant,
                                      "http_status": status, "verdict": verdict})
                        except Exception as ex:
                            import traceback
                            result["unauthed_checks"].append({"path": path, "variant": variant,
                                     "verdict": "BLOCKED", "error_type": type(ex).__name__,
                                     "failure_frames": [f"{Path(f.filename).name}:{f.name}"
                                         for f in traceback.extract_tb(ex.__traceback__)[-6:]]})
            except Exception as ex:
                result["negative_auth_probe"] = {
                    "status": "BLOCKED", "error_type": type(ex).__name__,
                    "missing_module": ex.name if isinstance(ex, ModuleNotFoundError) else None,
                }
        return result
    except BaseException as ex:
        # Only low-risk, structured diagnostics. Never serialize exception text,
        # tracebacks, locals, environment settings, DB URLs, or token values.
        return {
            "status": "BLOCKED",
            "reason": ("APP_IMPORT_FAILED" if stage == "IMPORT_FASTAPI_APP"
                       else "ROUTE_OR_DEPENDENCY_INSPECTION_FAILED"),
            "failure_phase": stage,
            "error_type": type(ex).__name__,
            "missing_module": ex.name if isinstance(ex, ModuleNotFoundError) else None,
        }


def subprocess_registered(backend: Path, negative_auth: bool, timeout_sec: int):
    env = dict(os.environ)
    env.update({"PYTHONDONTWRITEBYTECODE": "1", "CP04B_BACKEND": str(backend),
                "CP04B_NEGATIVE_AUTH": "1" if negative_auth else "0",
                "DATABASE_URL": SAFE_FAKE_URL, "ANALYTICS_DATABASE_URL": SAFE_FAKE_URL,
                "DATABASE_TEST_URL": SAFE_FAKE_URL, "M2_DATABASE_URL": SAFE_FAKE_URL,
                "PROJECT1_AUDIT_DATABASE_URL": SAFE_FAKE_URL,
                "PYTHONPATH": str(backend / "src")})
    env.update({k: "false" for k in FLAG_OFF})
    try:
        proc = subprocess.run([sys.executable, "-B", str(Path(__file__).resolve()), "--worker"],
                cwd=str(backend), env=env, capture_output=True, text=True,
                timeout=max(5, min(timeout_sec, 90)))
        # Ignore all stdout except our machine-framed JSON. Ignore potentially sensitive logs.
        marker = "CP04B_RESULT_JSON:"
        candidates = [line[len(marker):] for line in proc.stdout.splitlines() if line.startswith(marker)]
        if not candidates:
            return {"status": "BLOCKED", "reason": "NO_MACHINE_RESULT", "exit_code": proc.returncode}
        value = json.loads(candidates[-1])
        return value
    except subprocess.TimeoutExpired:
        return {"status": "BLOCKED", "reason": "TIMEOUT"}
    except (ValueError, OSError) as ex:
        return {"status": "BLOCKED", "reason": "CHILD_EXECUTION_FAILED", "error_type": type(ex).__name__}


def match_registered(static_routes: list, runtime: dict):
    dynamic = runtime.get("registered_routes", []) if runtime.get("status") == "REGISTERED_ROUTE_READ" else []
    mapped, unregistered = [], []
    for route in static_routes:
        candidates = [r for r in dynamic if r.get("method") == route["method"]
             and r.get("function") == route["function"]
             and r.get("file") == route["file"]]
        out = dict(route)
        if candidates:
            out["status"] = "REGISTERED"
            out["public_paths"] = sorted(set(c["path"] for c in candidates))
            out["actual_dependency_names"] = candidates[0]["dependencies"]
            mapped.append(out)
        elif runtime.get("status") == "REGISTERED_ROUTE_READ":
            out["status"] = "DECLARED_NOT_REGISTERED_OR_WRAPPED"
            unregistered.append(out)
        else:
            out["status"] = "NOT_VERIFIED_RUNTIME_BLOCKED"
            unregistered.append(out)
    return mapped + unregistered


def classify_route(row: dict, kind: str):
    # Strong hints only; property evidence and property documents are not research-PDF APIs.
    f = (row.get("file") or "").lower()
    p = (row.get("path") or row.get("path_fragment") or "").lower()
    name = (row.get("function") or "").lower()
    text = f + " " + p + " " + name
    research = ("research" in text or "literature" in text)
    not_property = ("property_verification" not in f and "properties.py" not in f and
                    "/property/" not in p and "/properties/" not in p and "verification/documents" not in p)
    if kind == "source": return research and not_property and ("source" in text or "literature" in text)
    if kind == "passage": return research and not_property and ("passage" in text or "fact" in text or "evidence" in text)
    if kind == "claim": return ("claim" in text or "admission" in text) and not_property
    if kind == "measurement": return ("ee01" in text or "aggregate" in text or "measurement" in text) and not_property
    # The existing reports and assessment-explanation handlers serve property
    # ML/SHAP, not café EE-01/A10 or R01-R12 research snapshots.
    research_surface = not f.endswith(("/reports.py", "/assessments.py"))
    if kind == "explanation": return "explanation" in text and not_property and research_surface
    if kind == "report": return "report" in text and not_property and research_surface
    if kind == "m2": return f.endswith("/m2.py") and "assessment" in p
    if kind == "auth": return (f.endswith("/auth.py") or f.endswith("/users.py")) and "me" in p
    if kind == "upload": return research and not_property and row.get("method") == "POST" and ("upload" in text or "document" in text)
    if kind == "cq": return "customer" in f or "questionnaire" in p or "campaign" in p
    return False


def requirement_kind(test_id):
    if test_id in ("API-01", "API-04", "EV-01-01"): return "source"
    if test_id == "API-02": return "passage"
    if test_id in ("API-03", "API-05", "EV-02-01"): return "claim"
    if test_id in ("API-06", "API-07"): return "measurement"
    if test_id == "API-08": return "explanation"
    if test_id in ("API-09", "API-10", "API-11", "API-12"): return "report"
    if test_id.startswith("AUTH-"): return "auth"
    if test_id == "M2-DB-01": return "m2"
    if test_id == "RESEARCH-UPLOAD-01": return "upload"
    if test_id == "CQ-01": return "cq"
    return None


def make_di_evidence(runtime: dict, providers: list):
    """Structural route -> Depends -> provider evidence, not use-case execution."""
    provider_index = {p["function"]: p for p in providers}
    records = []
    for route in runtime.get("registered_routes", []):
        deps = route.get("dependencies", [])
        if not (set(deps) & (DEPENDENCY_NAMES | {"get_db"})):
            continue
        records.append({
            "method": route["method"], "path": route["path"],
            "handler": route["function"],
            "registered_dependency_names": deps,
            "resolved_provider_sources": [provider_index[x]["file"] for x in deps if x in provider_index],
            "m2_service_from_shared_get_db": ("get_m2_service" in deps and "get_db" in deps),
            "status": "DI_STRUCTURE_ONLY_NO_USECASE_EXECUTION",
        })
    return records


def make_matrix(requirements: list, matched_routes: list, runtime: dict, providers: list):
    matrix = []
    for r in requirements:
        id_ = r["test_id"]
        kind = requirement_kind(id_)
        candidates = [x for x in matched_routes if kind and classify_route(x, kind)]
        registered = [x for x in candidates if x["status"] == "REGISTERED"]
        if id_ == "ROUTE-01":
            route_status = "REGISTERED_CATALOG_OBSERVED" if runtime.get("status") == "REGISTERED_ROUTE_READ" else "BLOCKED_REGISTRATION"
        elif id_ == "DI-01":
            ms = [p for p in providers if p["function"] == "get_m2_service"]
            route_status = "STATIC_GET_M2_SERVICE_FOUND" if ms else "NOT_MAPPED"
        else:
            route_status = ("REGISTERED_POTENTIAL_MATCH" if registered else
                            "DECLARED_ONLY_POTENTIAL_MATCH" if candidates else
                            "NO_MATCH_DISCOVERED")
        matrix.append({"test_id": id_, "intent": r["intent"], "expected": r["expected"],
           "route_mapping_status": route_status,
           "candidate_routes": "; ".join(sorted(set(
               f"{x['method']} {', '.join(x.get('public_paths') or [x['path_fragment'] or '?'])}"
               for x in (registered or candidates)
           )))[:750],
           "usecase_execution": "NOT_EXECUTED", "data_fixture": "NOT_CONFIGURED",
           "verified_result": "NOT_TESTED", "notes": "Heuristic candidate mapping only; not evidence of endpoint coverage or scientific authorization."})
    return matrix


def write_json(path: Path, obj):
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False), encoding="utf-8")


def write_csv(path: Path, records: list):
    if not records:
        path.write_text("", encoding="utf-8")
        return
    keys = list(records[0])
    with path.open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(records)


def report_md(backend: Path, evidence: dict, routes: list, runtime: dict, matrix: list, prior: dict):
    status = runtime.get("status", "NOT_REQUESTED")
    nreg = sum(x["status"] == "REGISTERED" for x in routes)
    missing = sum(x["status"] == "DECLARED_NOT_REGISTERED_OR_WRAPPED" for x in routes)
    auth = runtime.get("unauthed_checks", [])
    denials = sum(x.get("verdict") == "DENIED" for x in auth)
    suspect = sum(x.get("verdict") == "FAIL_UNAUTHORIZED_SUCCESS" for x in auth)
    p = ["# PROJECT1 — CP-04B Registered Routes, DI and API Coverage Verification", "",
         "**Status: PARTIAL — static inspection plus optional guarded runtime probe.**", "",
         "- No production database mutation or migrations performed by this verifier.",
         "- The runtime probe blocks application SQLAlchemy connection attempts and outbound network.",
         "- Runtime import is not a positive authenticated API test or full application startup test.",
         f"- Source Python files parsed: **{evidence['files_scanned']}**; parse errors: **{len(evidence['parse_errors'])}**.",
         f"- Declared routes: **{len(evidence['routes'])}**.",
         f"- Registered-route probe: **{status}**.",
         f"- Blocker reason: **{runtime.get('reason', 'none')}**; "
         f"phase: **{runtime.get('failure_phase', 'none')}**; "
         f"exception: **{runtime.get('error_type', 'none')}**; "
         f"missing module: **{runtime.get('missing_module', 'none')}**.",
         f"- Source declarations matched to registered endpoints: **{nreg}**; unmatched/unregistered: **{missing}**.",
         f"- Guarded negative-auth requests: **{len(auth)}**, rejected with 401/403: **{denials}**, unexpected successes: **{suspect}**.",
         "", "## Required checkpoint decisions", "",
         "| Checkpoint | Actual verification | Remaining work |",
         "|---|---|---|",
         "| Route registration | Only PASS when runtime app.routes was inspected successfully | Missing default-off routers are not automatically defects |",
         "| DI/use-case wiring | Registered route dependency graph is checked where available | Actual use-case call and database ownership need isolated integration fixtures |",
         "| Authenticated execution | No positive real JWT or Supabase login is performed | Isolated test user, verified JWT and safe clone required |",
         "| Research/evidence coverage | Heuristic mapping to actual route names | Research registry, PDF bytes, provenance, A10/EE01 execution remain unverified |",
         "| M2 target database | Earlier preflight found M2 tables in Dss and default DATABASE_URL in Final_Location_Analysis | Validate cutover on clone after merge, not now |",
         "| Restricted RLS | Earlier audit found M2 RLS enabled, zero policies | Execute least-privilege tests on clone |",
         "| Migration | No application or database migration performed | Rehearsal after main merge |", "",
         "## Risk classification", "",
         "- `NO_MATCH_DISCOVERED` is not proof that a capability is absent: it may be internal service-only.",
         "- `REGISTERED_POTENTIAL_MATCH` is not proof the route meets the requirement.",
         "- `DENIED` only proves the no/invalid token request was rejected under isolated conditions.",
         "- An import failure is `BLOCKED`, not PASS or evidence of a missing production endpoint.",
         "- Importing a live app may have import-time side effects; run guarded probing only in development/test checkout.",
         "", "## Artifacts", "",
         "`REGISTERED_ENDPOINTS.json`, `DECLARED_ENDPOINTS.json`, `REGISTRATION_COMPARISON.json`,",
         "`DEPENDENCY_PROVIDERS.json`, `USECASE_WIRING_MATRIX.json`, `ARCHITECTURE_REVIEW.json`,",
         "`API_REQUIREMENT_MATRIX.csv`, `NEGATIVE_AUTH_RESULTS.json`, `SOURCE_SHA256_MANIFEST.json`.",
         "", "## Owner actions", "",
         "1. Review actual registered routes and candidate/unmapped requirements.",
         "2. Identify authoritative research storage; do not substitute property verification documents for research PDFs.",
         "3. Confirm and reconcile existing M2/BCB/CQ and research use-case ownership.",
         "4. Prepare isolated clone with non-superuser roles for positive authenticated HTTP and evidence integrity tests.",
         "5. Preserve current feature branch; defer migration to post-merge rehearsal.", ""]
    if prior.get("status") == "PRIOR_REPORT_READ":
        p.append("Previous static inventory imported for comparison; it is not runtime evidence.")
    return "\n".join(p)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--backend", type=Path)
    ap.add_argument("--output", type=Path)
    ap.add_argument("--requirements", type=Path, default=Path(__file__).resolve().parent / "CP04B_REQUIREMENTS.json")
    ap.add_argument("--previous-report", type=Path, default=None)
    ap.add_argument("--probe-registration", action="store_true")
    ap.add_argument("--probe-negative-auth", action="store_true")
    ap.add_argument("--timeout-sec", type=int, default=40)
    ap.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = ap.parse_args(argv)
    if args.worker:
        # Fail closed unless our parent constructed the fake isolated environment.
        if os.getenv("DATABASE_URL") != SAFE_FAKE_URL or os.getenv("CP04B_BACKEND") is None:
            print("CP04B_RESULT_JSON:" + json.dumps({"status": "BLOCKED", "reason": "MISSING_FAKE_DB_GUARD"}))
            return 3
        print("CP04B_RESULT_JSON:" + json.dumps(worker(), separators=(",", ":")))
        return 0
    if args.backend is None:
        ap.error("--backend required")
    backend = args.backend.resolve()
    if not (backend / "src" / "sitewise").is_dir():
        ap.error("backend path must contain src/sitewise")
    output = (args.output or (Path.home() / "Documents" / "Project1_Verification" / ("CP04B_" + date_stamp()))).resolve()
    if output == backend or backend in output.parents:
        ap.error("Output must be outside the backend repository")
    output.mkdir(parents=True, exist_ok=False)
    requirements = json.loads(args.requirements.read_text(encoding="utf-8"))["requirements"]
    evidence = walk_source(backend)
    runtime = ({"status": "NOT_REQUESTED"} if not args.probe_registration else
               subprocess_registered(backend, args.probe_negative_auth, args.timeout_sec))
    prior = verify_from_previous(args.previous_report)
    routes = match_registered(evidence["routes"], runtime)
    matrix = make_matrix(requirements, routes, runtime, evidence["dependency_providers"])
    di = make_di_evidence(runtime, evidence["dependency_providers"])
    write_json(output / "DECLARED_ENDPOINTS.json", evidence["routes"])
    write_json(output / "REGISTERED_ENDPOINTS.json", runtime)
    write_json(output / "REGISTRATION_COMPARISON.json", routes)
    write_json(output / "DEPENDENCY_PROVIDERS.json", evidence["dependency_providers"])
    write_json(output / "USECASE_WIRING_MATRIX.json", di)
    write_json(output / "INCLUDE_ROUTER_LOCATIONS.json", evidence["include_router_calls"])
    write_json(output / "ARCHITECTURE_REVIEW.json", evidence["boundary_review_candidates"])
    write_json(output / "SOURCE_SHA256_MANIFEST.json", evidence["source_hashes"])
    write_json(output / "SOURCE_PARSE_ERRORS.json", evidence["parse_errors"])
    write_json(output / "NEGATIVE_AUTH_RESULTS.json", runtime.get("unauthed_checks", []))
    write_json(output / "PREVIOUS_REPORT_INPUT.json", prior)
    write_csv(output / "API_REQUIREMENT_MATRIX.csv", matrix)
    (output / "CP04B_CHECKPOINT_REPORT.md").write_text(
        report_md(backend,evidence,routes,runtime,matrix,prior),encoding="utf-8")
    output_zip = output.with_suffix(".zip")
    with zipfile.ZipFile(output_zip, "w", compression=zipfile.ZIP_DEFLATED) as z:
        for f in sorted(output.iterdir()):
            z.write(f,arcname=f.name)
    print("PROJECT1 CP04B SOURCE AND REGISTRATION VERIFICATION")
    print("Python files:", evidence["files_scanned"], "Declared routes:",len(evidence["routes"]))
    print("Registered route probe:",runtime.get("status", "NOT_RUN"),
          "Actual route entries:",runtime.get("registration_count", "UNKNOWN"))
    if runtime.get("status") == "BLOCKED":
        print("Guarded diagnostic:",
              "reason=", runtime.get("reason", "unknown"),
              "phase=", runtime.get("failure_phase", "unknown"),
              "type=", runtime.get("error_type", "unknown"),
              "missing_module=", runtime.get("missing_module", "none"))
    print("Requirement cases prepared:", len(matrix), "Executed positive authenticated cases: 0")
    print("No database migration performed. Positive authenticated integration is not established.")
    print("UPLOAD THIS ZIP:",output_zip)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
