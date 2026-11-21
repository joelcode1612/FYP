"""CP-03E: one bounded live admission test on a REPRESENTABLE M2V1 contradiction.

Unlike the CP-03D contradiction probe (which mutated M2V1-05 to a value the
instrument can never store), this uses a combination validate_m2_answer accepts:

    M2V1-03 = ['UNDECIDED']   (product range undecided; UNDECIDED is exclusive)
    M2V1-06 = 'QUALITY'       (emphasis on product quality)

So the deterministic M2V1 ruleset fires a real proposal, `allowed_rules` is
non-empty, and the model's finding must land on that same registered rule with a
value-span quote to be admitted. That is the full admission path.

Exactly one attempt. No retry. Synthetic-only. If the provider times out the
ledger records unknown_outcome and nothing is claimed as validated.
"""
import json
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from sqlalchemy import create_engine, text  # noqa: E402
from sqlmodel import Session  # noqa: E402

import cp03d_bdj_uncertainty as probe  # noqa: E402
from sitewise.core.config import settings  # noqa: E402
from sitewise.domain import bdj_m2v1_candidate_rules as rules  # noqa: E402
from sitewise.project1.bdj import BDJEngine  # noqa: E402
from sitewise.project1.contracts import digest  # noqa: E402
from sitewise.project1.disclosure import (  # noqa: E402
    SyntheticBdjAuthorization, SyntheticBdjDisclosure,
)
from sitewise.project1.ledger import PostgresAttemptLedger  # noqa: E402
from sitewise.project1.prompts import PROMPTS  # noqa: E402
from sitewise.project1.provider import ENDPOINT, MODEL, ModelRunner, TokenHarbor  # noqa: E402

ACTOR = uuid.UUID("11111111-1111-4111-8111-111111111111")
TIMEOUT = 60

REPRESENTABLE = {'M2V1-03': ['UNDECIDED'], 'M2V1-06': 'QUALITY'}
results = {}


def check(name, ok, detail=""):
    results[name] = (ok, detail)
    print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}")


def representable_packet():
    packet = probe.build_packet()
    derived = json.loads(json.dumps(packet))
    derived.pop('source_fingerprint', None)
    for declaration in derived['declarations']:
        if declaration['item_key'] in REPRESENTABLE:
            declaration['value'] = REPRESENTABLE[declaration['item_key']]
    derived['source_fingerprint'] = digest(derived)
    return packet, derived


def provision_run(engine, run_id, source_fp, policy_fp, work_id):
    with engine.connect() as c:
        c.execute(text("SET LOCAL ROLE p1ai_runtime"))
        c.execute(text("SELECT set_config('project1.actor_id', :a, true)"), {"a": str(ACTOR)})
        c.execute(text(
            "INSERT INTO project1_ai.runs(id,owner_user_id,assessment_id,assessment_revision,"
            "source_fingerprint,policy_fingerprint,work_identity) VALUES (:r,:o,:a,:rev,:s,:p,:w)"),
            {"r": run_id, "o": ACTOR, "a": probe.ASSESSMENT, "rev": probe.REV,
             "s": source_fp, "p": policy_fp, "w": work_id})
        c.commit()


def audit(run_id):
    engine = create_engine(settings.project1_audit_database_url.get_secret_value(),
                           hide_parameters=True)
    with engine.connect() as c:
        c.execute(text("SET LOCAL ROLE p1ai_audit"))
        who = c.execute(text("SELECT current_user")).scalar()
        rows = c.execute(text(
            "SELECT a.attempt_no,a.prompt_version,r.outcome,r.output_digest "
            "FROM project1_ai.attempts a LEFT JOIN project1_ai.attempt_receipts r "
            "ON r.run_id=a.run_id AND r.attempt_no=a.attempt_no WHERE a.run_id=:i"),
            {"i": run_id}).mappings().all()
    return who, [dict(x) for x in rows]


def main() -> int:
    original, packet = representable_packet()
    check("packet_representable",
          packet['source_fingerprint'] != original['source_fingerprint'],
          f"{original['source_fingerprint'][:12]} -> {packet['source_fingerprint'][:12]}")

    answers = {d['item_key']: {'id': d['answer_revision_id'],
                               'answer_state': d['answer_state'],
                               'value_json': d['value']} for d in packet['declarations']}
    proposals = rules.evaluate_candidate_issues(answers)
    check("deterministic_proposal_fired", len(proposals) == 1,
          f"rules={[p['rule_id'] for p in proposals]}")

    runtime = create_engine(settings.project1_runtime_database_url.get_secret_value(),
                            hide_parameters=True)
    run_id = uuid.uuid4()
    provision_run(runtime, run_id, packet['source_fingerprint'],
                  PROMPTS['BDJ'].fingerprint, uuid.uuid4().hex + uuid.uuid4().hex[:32])
    check("run_provisioned", True, f"run_id={run_id}")

    auth = SyntheticBdjAuthorization(
        run_id=str(run_id), source_fingerprint=packet['source_fingerprint'],
        operator_receipt=("CP-03E representable-contradiction admission test; "
                          "M2V1-03=UNDECIDED M2V1-06=QUALITY; one attempt; TokenHarbor only."))
    provider = TokenHarbor(settings.tokenharbor_api_key, enabled=True,
                           structured_mode=settings.tokenharbor_structured_mode, timeout=TIMEOUT)
    ledger = PostgresAttemptLedger(runtime, ACTOR, run_id)
    runner = ModelRunner(provider, ledger, PROMPTS, disclosure=SyntheticBdjDisclosure(auth))
    captured = {}

    def capturing(stage, pkt, out_type):
        # Capture BEFORE validation: a rejected candidate is still evidence and must
        # be diagnosable without a second provider call.
        output = runner(stage, pkt, out_type)
        captured['raw'] = output
        return output

    engine = BDJEngine(rules=rules, model_runner=capturing)

    result = engine.review(packet, recheck_current=lambda: packet['source_fingerprint'])
    outcome = result['outcome']
    check("engine_returned", outcome in {'reviewed', 'rejected'}, f"outcome={outcome}")

    if outcome == 'reviewed':
        check("admitted_findings", len(result['findings']) >= 1,
              f"findings={[f['rule_id'] for f in result['findings']]}")
        check("admitted_rule_is_registered",
              all(f['rule_id'] in {p['rule_id'] for p in proposals}
                  for f in result['findings']),
              "every admitted finding maps to a deterministic proposal")
    else:
        reasons = [c.get('reason') for c in result['checkpoints'] if c.get('reason')]
        check("admitted_findings", False, f"rejected: {reasons}")
        check("admitted_rule_is_registered", False, "not admitted")

    check("no_authority_asserted",
          result['scientific_acceptance'] is False and result['publication_authorized'] is False
          and result['finding_authority'] == 'CANDIDATE_ONLY',
          "candidate-only; no scientific or release authority")

    who, rows = audit(run_id)
    check("audit_readback", who == 'p1ai_audit' and len(rows) == 1,
          f"identity={who} rows={rows}")

    # Diagnose the candidate against the contract, whether or not it was admitted.
    raw = captured.get('raw')
    diagnostics = {}
    if raw is not None:
        allowed = {p['rule_id'] for p in proposals}
        returned = [i['rule_id'] for i in raw.get('issues', [])]
        diagnostics['rules_returned'] = returned
        diagnostics['rules_allowed'] = sorted(allowed)
        diagnostics['rules_outside_allowed'] = [r for r in returned if r not in allowed]
        by_key = {d['item_key']: d for d in packet['declarations']}
        quote_report = []
        for issue in raw.get('issues', []):
            for ref in issue.get('source_refs', []):
                decl = by_key.get(ref['item_key'])
                value = decl['value'] if decl else None
                spans = value if isinstance(value, list) else [value]
                ok = any(isinstance(s, str) and ref['quote'] in s for s in spans)
                quote_report.append({'item_key': ref['item_key'],
                                     'quote': ref['quote'], 'value_span': ok})
        diagnostics['quotes'] = quote_report
        diagnostics['quotes_value_span'] = sum(1 for q in quote_report if q['value_span'])
        diagnostics['quotes_total'] = len(quote_report)
        check("quote_contract_value_span",
              quote_report and diagnostics['quotes_value_span'] == diagnostics['quotes_total'],
              f"{diagnostics['quotes_value_span']}/{diagnostics['quotes_total']} value spans")
        check("rules_within_allowed", not diagnostics['rules_outside_allowed'],
              f"outside={diagnostics['rules_outside_allowed']}")
        print(f"NOTE  rules_returned={returned} allowed={sorted(allowed)}")
    else:
        check("quote_contract_value_span", False, "no model output captured")
        check("rules_within_allowed", False, "no model output captured")

    out_dir = Path(__file__).resolve().parents[1] / "backups" / f"cp03e_{run_id}"
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "result.json").write_text(json.dumps({
        "run_id": str(run_id), "probe": "REPRESENTABLE_M2V1_CONTRADICTION",
        "mutation": REPRESENTABLE, "ruleset": rules.RULE_VERSION,
        "prompt_version": PROMPTS['BDJ'].version,
        "source_fingerprint": packet['source_fingerprint'],
        "deterministic_proposals": [p['rule_id'] for p in proposals],
        "engine_outcome": outcome, "findings": result['findings'],
        "checkpoints": result['checkpoints'], "audit": rows,
        "model_output_raw": raw, "diagnostics": diagnostics,
    }, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"evidence={out_dir}")

    failed = [k for k, (ok, _) in results.items() if not ok]
    print(f"\nchecks={len(results)} failed={len(failed)}")
    print("VERDICT=" + ("PASS" if not failed else "FAIL"))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
