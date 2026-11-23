"""Export the complete persisted BCB V1.2 context for one confirmed M2 V2 assessment.

Read-only. Retrieval goes through the authenticated HTTP API only (the local
GoTrue stub plus the app served by ``tools/m2v2_serve_20261122.py``); nothing is
written to the database and no protected cluster is contacted.

The exported file is exactly the ``persisted-business-context/1`` envelope the
API returns, so the traceability that already exists in the contract
(``packet.m2_answers``, ``packet.sections[*].source``, ``packet.provenance``)
travels with the packet instead of being duplicated into a parallel schema.

Verification is independent of the service that produced the packet:

* the packet hash is recomputed from the canonical form defined by
  ``business_context_v1.canonical_bytes`` and compared with the stored value;
* the confirmation digest in the packet is compared with the live
  ``confirmation-current`` record;
* every ``m2_answers`` declaration is checked against the saved M2 answer for
  that item, and every section source reference is checked to resolve.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND / "src"))
DEFAULT_OUT = BACKEND.parent / "deliverables" / "m2v2" / "bcb_v12_current_context.json"

API = "http://127.0.0.1:8091"
GOTRUE = "http://127.0.0.1:54329"
ANON = "sb_publishable_local_e2e"
PASSWORD = "e2e-local-password"
OWNER = "gatebc-e2e-b9e62014@example.invalid"

#: Both sections contracts are valid exports; 1.2.0 is the frozen historical
#: shape and 1.2.1 is current. Hardcoding one made a valid packet look invalid.
from sitewise.services.business_context_v1 import SECTIONS_CONTRACTS as _SECTIONS_CONTRACTS  # noqa: E402


def request(method: str, url: str, body=None, bearer: str | None = None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.load(resp)
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            return exc.code, json.loads(raw)
        except Exception:  # noqa: BLE001
            return exc.code, {"raw": raw[:400].decode("utf-8", "replace")}


def token() -> str:
    status, body = request("POST", f"{GOTRUE}/auth/v1/token?grant_type=password",
                           {"email": OWNER, "password": PASSWORD})
    if status != 200:
        raise SystemExit(f"auth failed: {status} {body}")
    return body["access_token"]


def canonical_bytes(value) -> bytes:
    """Mirror of business_context_v1.canonical_bytes (PYTHON-JSON-SORTED-UTF8-V1)."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False).encode("utf-8")


def recompute_packet_hash(packet: dict) -> str:
    body = {k: v for k, v in packet.items() if k != "packet_hash"}
    return hashlib.sha256(canonical_bytes(body)).hexdigest()


def discover(bearer: str, assessment_id: str | None, context_id: str | None):
    """Find the newest confirmed M2 V2 assessment whose persisted BCB is current."""
    if assessment_id:
        candidates = [assessment_id]
    else:
        status, body = request("GET", f"{API}/api/v1/m2/assessments", bearer=bearer)
        if status != 200:
            raise SystemExit(f"assessment list failed: {status} {body}")
        rows = body if isinstance(body, list) else body.get("items") or body.get("assessments") or []

        # The assessment list exposes ``instrument_id`` only, so the version tag
        # has to be resolved through the instrument catalogue rather than guessed
        # from the row.
        st_i, instruments = request("GET", f"{API}/api/v1/m2/instruments", bearer=bearer)
        tag_by_id = {}
        if st_i == 200:
            for inst in (instruments.get("items") or instruments.get("instruments") or []):
                tag_by_id[str(inst.get("id"))] = inst.get("version_tag")

        candidates = []
        for row in rows:
            instrument_id = str(row.get("instrument_id") or "")
            tag = (tag_by_id.get(instrument_id)
                   or row.get("instrument_version_tag") or row.get("version_tag"))
            if tag and str(tag).startswith("M2V2-"):
                candidates.append(row.get("id") or row.get("assessment_id"))

    found = []
    for aid in filter(None, candidates):
        st, conf = request("GET", f"{API}/api/v1/m2/assessments/{aid}/confirmation-current",
                           bearer=bearer)
        if st != 200:
            continue
        cid = conf.get("id") or conf.get("confirmation_id")
        st2, ctx_status = request(
            "GET",
            f"{API}/api/v1/m2/assessments/{aid}/confirmations/{cid}/business-context-status",
            bearer=bearer)
        if st2 != 200:
            continue
        found.append({
            "assessment_id": str(aid), "confirmation": conf,
            "status": ctx_status,
            "current": ctx_status.get("source_is_current") is True,
            "persisted": ctx_status.get("status") == "PERSISTED",
            "context_id": ctx_status.get("context_id"),
        })

    usable = [f for f in found if f["current"] and f["persisted"] and f["context_id"]]
    if not usable:
        print(json.dumps({"discovered": found}, indent=2, default=str))
        return None
    if context_id:
        usable = [f for f in usable if str(f["context_id"]) == context_id] or usable
    return usable[-1]


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--assessment-id")
    p.add_argument("--context-id")
    p.add_argument("--out", default=str(DEFAULT_OUT))
    args = p.parse_args()

    bearer = token()
    chosen = discover(bearer, args.assessment_id, args.context_id)
    if chosen is None:
        print("NO CURRENT CONFIRMED M2 V2 BCB CONTEXT FOUND")
        return 2

    aid = chosen["assessment_id"]
    cid = chosen["confirmation"]["id"]
    context_id = chosen["context_id"]

    st, envelope = request(
        "GET", f"{API}/api/v1/m2/assessments/{aid}/business-contexts/{context_id}",
        bearer=bearer)
    if st != 200:
        raise SystemExit(f"context read failed: {st} {envelope}")
    packet = envelope["packet"]

    st, assessment = request("GET", f"{API}/api/v1/m2/assessments/{aid}", bearer=bearer)
    saved = (assessment.get("answers") or {}) if st == 200 else {}

    checks = []

    def check(name, ok, evidence):
        checks.append({"check": name, "ok": bool(ok), "evidence": evidence})

    recomputed = recompute_packet_hash(packet)
    check("packet hash recomputes from canonical form",
          recomputed == packet.get("packet_hash"),
          {"stored": packet.get("packet_hash"), "recomputed": recomputed})

    check("confirmation digest matches live confirmation record",
          packet.get("confirmation", {}).get("digest") == chosen["confirmation"].get("snapshot_digest"),
          {"packet": packet.get("confirmation", {}).get("digest"),
           "live": chosen["confirmation"].get("snapshot_digest")})

    check("packet identity matches the assessment",
          packet.get("identity", {}).get("assessment_id") == aid, aid)

    instrument = packet.get("instrument") or {}
    check("instrument is the M2 V2 candidate and not AUTHORIZED",
          str(instrument.get("version_tag", "")).startswith("M2V2-")
          and instrument.get("approval_state") != "AUTHORIZED", instrument)

    check("context version is a business-context-package/1.2 sections contract",
          packet.get("context_version") in _SECTIONS_CONTRACTS
          and packet.get("schema_version") == "business-context-package/1.2",
          {"context_version": packet.get("context_version"),
           "schema_version": packet.get("schema_version")})

    sections = packet.get("sections") or {}
    check("three separable outputs present",
          all(k in sections for k in ("business_description", "research_context",
                                      "questionnaire_stimuli")),
          sorted(sections))

    # Every declared answer must correspond to a saved M2 answer revision.
    declarations = packet.get("m2_answers") or []
    missing = [d.get("item_key") for d in declarations
               if d.get("item_key") not in saved]
    check("every m2_answers declaration has a saved M2 answer",
          not missing, {"declarations": len(declarations), "missing": missing})

    # Every section source reference must resolve to a declaration.
    declared_keys = {d.get("item_key") for d in declarations}

    def walk(node, path, unresolved):
        if isinstance(node, dict):
            key = node.get("item_key")
            if key is not None and key not in declared_keys:
                unresolved.append({"path": path, "item_key": key})
            for k, v in node.items():
                walk(v, f"{path}.{k}", unresolved)
        elif isinstance(node, list):
            for i, v in enumerate(node):
                walk(v, f"{path}[{i}]", unresolved)

    unresolved: list = []
    for name, section in sections.items():
        walk(section, name, unresolved)
    check("every section source reference resolves to a declaration",
          not unresolved, unresolved[:10])

    check("no model was invoked", sections.get("model_invoked") is False,
          sections.get("model_invoked"))
    check("packet grants no execution authority",
          packet.get("permissions") == {"report_admission": False, "report_release": False,
                                        "qj_execution": False, "qg_execution": False},
          packet.get("permissions"))

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(envelope, indent=2, ensure_ascii=False, sort_keys=False),
                   encoding="utf-8")

    print(json.dumps({
        "file": str(out),
        "assessment_id": aid,
        "confirmation_id": str(cid),
        "context_id": str(context_id),
        "assessment_revision": envelope.get("assessment_revision"),
        "instrument_version": instrument.get("version_tag"),
        "schema_version": packet.get("schema_version"),
        "context_version": packet.get("context_version"),
        "snapshot_digest": packet.get("confirmation", {}).get("digest"),
        "packet_hash": packet.get("packet_hash"),
        "checks": checks,
    }, indent=2, default=str))

    failed = [c for c in checks if not c["ok"]]
    print(f"\n{len(checks) - len(failed)}/{len(checks)} verification checks passed")
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
