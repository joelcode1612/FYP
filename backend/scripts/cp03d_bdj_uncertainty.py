"""CP-03D(b): verify BDJ actually detects a planted, genuine contradiction.

The CP-03D run returned ``issues=[]`` on a consistent packet. That exercises the
happy path only; it does NOT demonstrate uncertainty detection. This probe plants
two genuine internal contradictions into a *derived* synthetic packet and checks
that BDJ flags them, with version-bound source references and verbatim quotes.

Honesty constraints:
  * The derived packet is NOT a persisted assessment revision. It is a synthetic
    test fixture derived from the synthetic assessment, and is labelled as such
    in the operator receipt and in the evidence file.
  * Exactly one additional bounded attempt, its own run_id, its own authorization.
  * Still synthetic-only, still TokenHarbor-only, still no retry.
"""
import copy
import json
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from sqlalchemy import create_engine, text  # noqa: E402
from sqlmodel import Session  # noqa: E402

from sitewise.core.config import settings  # noqa: E402
from sitewise.project1.contracts import BDJOutput, WorkflowHeld, digest  # noqa: E402
from sitewise.project1.disclosure import SyntheticBdjAuthorization, SyntheticBdjDisclosure  # noqa: E402
from sitewise.project1.ledger import PostgresAttemptLedger  # noqa: E402
from sitewise.project1.prompts import PROMPTS  # noqa: E402
from sitewise.project1.projection import M2SourceProjection, verify_projection  # noqa: E402
from sitewise.project1.provider import ENDPOINT, MODEL, ModelRunner, TokenHarbor  # noqa: E402
from sitewise.repositories.m2_repository import SqlModelM2Repository  # noqa: E402

ACTOR = uuid.UUID("11111111-1111-4111-8111-111111111111")
ASSESSMENT = uuid.UUID("da90aa4a-f9cf-4145-9acf-7de36c9d6fad")
REV = 12

# Planted contradictions (each is a genuine logical conflict in the packet):
#   1. primary customer group is not one of the selected customer groups
#   2. first investigation topic is not one of the selected topics
PLANTED = {
    'M2V1-05': 'FAMILIES',              # selected groups are STUDENTS + OFFICE_WORKERS
    'M2V1-09': ['PRICE_ACCEPTABILITY'],  # first topic is CONCEPT_INTEREST
}

results = {}


def check(name, ok, detail=""):
    results[name] = (ok, detail)
    print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}")


def build_packet():
    engine = create_engine(settings.m2_database_url.get_secret_value(), hide_parameters=True)
    with Session(engine) as s:
        s.execute(text("SELECT set_config('project1.actor_id', :a, true)"), {"a": str(ACTOR)})
        return M2SourceProjection(SqlModelM2Repository(s)).read(ASSESSMENT, ACTOR, REV)


def derive_contradictory(packet: dict) -> tuple[dict, list[dict]]:
    derived = copy.deepcopy(packet)
    derived.pop('source_fingerprint', None)
    mutations = []
    for decl in derived['declarations']:
        if decl['item_key'] in PLANTED:
            before = copy.deepcopy(decl['value'])
            decl['value'] = copy.deepcopy(PLANTED[decl['item_key']])
            mutations.append({'item_key': decl['item_key'], 'from': before,
                              'to': decl['value']})
    derived['source_fingerprint'] = digest(derived)
    return derived, mutations


def contradiction_is_real(packet: dict) -> tuple[bool, str]:
    by_key = {d['item_key']: d for d in packet['declarations']}
    groups = set(by_key['M2V1-04']['value'])
    primary = by_key['M2V1-05']['value']
    topics = set(by_key['M2V1-09']['value'])
    first = by_key['M2V1-10']['value']
    ok = primary not in groups and first not in topics
    return ok, f"primary={primary} in groups={sorted(groups)}: {primary in groups}; " \
               f"first={first} in topics={sorted(topics)}: {first in topics}"


def provision_run(engine, run_id, source_fp, policy_fp, work_id):
    with engine.connect() as c:
        c.execute(text("SET LOCAL ROLE p1ai_runtime"))
        c.execute(text("SELECT set_config('project1.actor_id', :a, true)"), {"a": str(ACTOR)})
        c.execute(text(
            "INSERT INTO project1_ai.runs(id,owner_user_id,assessment_id,assessment_revision,"
            "source_fingerprint,policy_fingerprint,work_identity) VALUES (:r,:o,:a,:rev,:s,:p,:w)"),
            {"r": run_id, "o": ACTOR, "a": ASSESSMENT, "rev": REV,
             "s": source_fp, "p": policy_fp, "w": work_id})
        c.commit()


def audit_readback(run_id):
    url = settings.project1_audit_database_url.get_secret_value()
    if not url:
        return None
    engine = create_engine(url, hide_parameters=True)
    with engine.connect() as c:
        c.execute(text("SET LOCAL ROLE p1ai_audit"))
        cu = c.execute(text("SELECT current_user")).scalar()
        rows = c.execute(text(
            "SELECT a.attempt_no,a.stage,a.prompt_version,a.prompt_hash,a.request_hash,"
            "r.outcome,r.output_digest FROM project1_ai.attempts a "
            "LEFT JOIN project1_ai.attempt_receipts r ON r.run_id=a.run_id AND r.attempt_no=a.attempt_no "
            "WHERE a.run_id=:id ORDER BY a.attempt_no"), {"id": run_id}).mappings().all()
    return cu, [dict(x) for x in rows]


def quote_fidelity(output: dict, packet: dict) -> tuple[int, int]:
    """How many supplied quotes are exact substrings of the cited declaration text."""
    haystack = {}
    for d in packet['declarations']:
        haystack[(d['item_key'], d['answer_revision_id'], d['item_version_id'])] = (
            d['question'] + ' ' + json.dumps(d['value'], ensure_ascii=False)).casefold()
    exact = total = 0
    for issue in output.get('issues', []):
        for ref in issue.get('source_refs', []):
            total += 1
            text_ = haystack.get((ref['item_key'], ref['answer_revision_id'], ref['item_version_id']), '')
            if ref['quote'].strip().casefold() in text_:
                exact += 1
    return exact, total


def main() -> int:
    packet = build_packet()
    check("packet_built", len(packet["declarations"]) > 0,
          f"declarations={len(packet['declarations'])} fp={packet['source_fingerprint'][:12]}")

    derived, mutations = derive_contradictory(packet)
    real, why = contradiction_is_real(derived)
    check("contradiction_planted", real and len(mutations) == 2, why)
    check("derived_fingerprint_changed",
          derived['source_fingerprint'] != packet['source_fingerprint'],
          f"{packet['source_fingerprint'][:12]} -> {derived['source_fingerprint'][:12]}")
    try:
        verify_projection(derived)
        check("derived_packet_self_consistent", True, "fingerprint + membership verified")
    except Exception as exc:  # noqa: BLE001
        check("derived_packet_self_consistent", False, f"{type(exc).__name__}: {exc}")

    runtime_engine = create_engine(settings.project1_runtime_database_url.get_secret_value(),
                                   hide_parameters=True)
    policy_fp = PROMPTS["BDJ"].fingerprint
    run_id = uuid.uuid4()
    work_id = uuid.uuid4().hex + uuid.uuid4().hex[:32]
    provision_run(runtime_engine, run_id, derived["source_fingerprint"], policy_fp, work_id)
    check("run_provisioned", True, f"run_id={run_id}")

    auth = SyntheticBdjAuthorization(
        run_id=str(run_id), source_fingerprint=derived["source_fingerprint"],
        operator_receipt=("CP-03D(b) synthetic contradiction probe; derived non-persisted packet; "
                          "planted M2V1-05=FAMILIES and M2V1-09=[PRICE_ACCEPTABILITY]; "
                          "one attempt; TokenHarbor only."))
    disclosure = SyntheticBdjDisclosure(auth)

    provider = TokenHarbor(settings.tokenharbor_api_key, enabled=True,
                           structured_mode=settings.tokenharbor_structured_mode, timeout=45)
    ledger = PostgresAttemptLedger(runtime_engine, ACTOR, run_id)
    runner = ModelRunner(provider, ledger, PROMPTS, disclosure=disclosure)

    output = None
    try:
        output = runner("BDJ", derived, BDJOutput)
        check("model_runner_returned", True, f"issues={len(output.get('issues', []))}")
    except WorkflowHeld as exc:
        check("model_runner_returned", False, f"held code={exc}")

    if output is not None:
        issues = output.get('issues', [])
        # Core acceptance: a genuine contradiction must be detected, not passed over.
        check("uncertainty_detected", len(issues) >= 1, f"issues={len(issues)}")

        touched = set()
        conflicts = 0
        for issue in issues:
            if issue.get('kind') == 'SOURCE_CONFLICT':
                conflicts += 1
            for ref in issue.get('source_refs', []):
                touched.add(ref['item_key'])
        check("conflict_kind_used", conflicts >= 1, f"SOURCE_CONFLICT findings={conflicts}")
        check("planted_items_cited",
              bool(touched & {'M2V1-05', 'M2V1-09'}) or
              ({'M2V1-04', 'M2V1-05'} <= touched) or ({'M2V1-09', 'M2V1-10'} <= touched),
              f"cited={sorted(touched)}")

        decls = {(d["item_key"], d["answer_revision_id"], d["item_version_id"])
                 for d in derived["declarations"]}
        bad = [ref for issue in issues for ref in issue.get("source_refs", [])
               if (ref["item_key"], ref["answer_revision_id"], ref["item_version_id"]) not in decls]
        check("source_fidelity", not bad, f"bad_refs={len(bad)}")

        exact, total = quote_fidelity(output, derived)
        # Advisory: the prompt asks for value-only quotes. Reported, not silently rounded up.
        print(f"NOTE  quote_fidelity  exact={exact}/{total} "
              f"(advisory: prompt requires value-only source quotes)")

        # BDJ-QUOTE-01 regression gate: isolate the quote check from rule coverage by
        # authorizing exactly the rule ids the model returned. A PASS here means the
        # quote contract is satisfied; it does NOT mean the finding is admissible in
        # production, because BDJEngine also requires deterministic rule coverage.
        from sitewise.project1.bdj import validate_candidates  # local import: script only
        try:
            validate_candidates(output, derived, {i['rule_id'] for i in issues})
            check("quote_gate", True, "admitted with model rule ids")
        except WorkflowHeld as exc:
            check("quote_gate", False, f"code={exc}")

    try:
        ledger.reserve("BDJ", "x", "c" * 64, "d" * 64)
        check("single_attempt_enforced", False, "second reserve allowed")
    except WorkflowHeld as exc:
        check("single_attempt_enforced", str(exc) == "MODEL_STAGE_ALREADY_RESERVED", f"code={exc}")

    rb = audit_readback(run_id)
    if rb is None:
        check("audit_readback", False, "PROJECT1_AUDIT_DATABASE_URL missing")
    else:
        cu, rows = rb
        ok = cu == "p1ai_audit" and len(rows) == 1 and rows[0]["outcome"] in {
            "returned", "rejected", "unknown_outcome"}
        check("audit_readback", ok,
              f"identity={cu} rows={len(rows)} outcome={rows[0]['outcome'] if rows else None}")

    if output is not None:
        out_dir = Path(__file__).resolve().parents[1] / "backups" / f"cp03d_uncertainty_{run_id}"
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / "probe.json").write_text(json.dumps({
            "run_id": str(run_id), "probe": "SYNTHETIC_CONTRADICTION",
            "packet_is_persisted_revision": False,
            "derived_from": {"assessment_id": str(ASSESSMENT), "assessment_revision": REV,
                             "source_fingerprint": packet["source_fingerprint"]},
            "derived_source_fingerprint": derived["source_fingerprint"],
            "mutations": mutations,
            "policy_fingerprint": policy_fp,
            "model_requested": MODEL, "endpoint": ENDPOINT,
            "output": output, "output_digest": digest(output),
            "checks": {k: {"pass": v[0], "detail": v[1]} for k, v in results.items()},
        }, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"evidence={out_dir}")

    hard = [k for k, (ok, _) in results.items() if not ok and k != "model_runner_returned"]
    verdict = "PASS" if (not hard and results.get("model_runner_returned", (False,))[0]) else "FAIL"
    print(f"VERDICT={verdict}")
    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
