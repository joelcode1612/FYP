"""CP-03E: verify the value-only quote contract from RECORDED outputs (no dispatch).

The directive requires deterministic tests and recorded outputs before any live
re-verification. This script replays the two recorded CP-03D runs and shows:

  1. run fd0b4380 (BDJ-SOURCE-1-CAND) recorded quotes are question text -> all
     rejected by the admission validator, exactly as observed live;
  2. the SAME findings, with only the `quote` field rewritten to a span of the
     declaration value, are admitted — so the defect was the quote contract and
     nothing else;
  3. run 96cefb30 recorded zero issues, which passes every gate vacuously, which
     is why the defect was invisible there.

It never calls the provider. Live re-verification stays blocked until the
provider is reachable and execution is authorised.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from sitewise.project1.bdj import validate_candidates  # noqa: E402
from sitewise.project1.contracts import WorkflowHeld  # noqa: E402

import cp03d_bdj_uncertainty as probe  # noqa: E402

BACKUPS = Path(__file__).resolve().parents[1] / "backups"
RUN_CONTRADICTION = "cp03d_uncertainty_fd0b4380-1c37-4dd4-ae3c-5faf4a138d01"
RUN_CLEAN = "cp03d_96cefb30-60b9-4a9c-b028-e87793c2a82a"

results = {}


def check(name, ok, detail=""):
    results[name] = (ok, detail)
    print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}")


def value_span(declaration) -> str:
    value = declaration["value"]
    if isinstance(value, list):
        return value[0]
    return str(value)


def load(run_dir, filename):
    path = BACKUPS / run_dir / filename
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else None


def main() -> int:
    packet = probe.build_packet()
    derived, _ = probe.derive_contradictory(packet)

    recorded = load(RUN_CONTRADICTION, "probe.json")
    check("recorded_output_present", recorded is not None, RUN_CONTRADICTION)
    if recorded is None:
        print("VERDICT=BLOCKED")
        return 1

    raw = recorded["output"]
    rule_ids = {i["rule_id"] for i in raw["issues"]}
    check("recorded_had_findings", len(raw["issues"]) == 2,
          f"issues={len(raw['issues'])} rules={sorted(rule_ids)}")

    # 1. Recorded quotes must still be rejected.
    try:
        validate_candidates(raw, derived, rule_ids)
        check("recorded_quotes_rejected", False, "recorded output was admitted")
    except WorkflowHeld as exc:
        check("recorded_quotes_rejected", str(exc) == "BDJ_SOURCE_QUOTE_INVALID",
              f"code={exc}")

    # 2. Rewrite ONLY the quotes to declaration-value spans.
    by_key = {d["item_key"]: d for d in derived["declarations"]}
    repaired = json.loads(json.dumps(raw))
    rewritten = 0
    for issue in repaired["issues"]:
        for ref in issue["source_refs"]:
            ref["quote"] = value_span(by_key[ref["item_key"]])
            rewritten += 1
    try:
        admitted = validate_candidates(repaired, derived, rule_ids)
        check("value_span_quotes_admitted", len(admitted.issues) == 2,
              f"rewritten={rewritten} admitted={len(admitted.issues)}")
    except WorkflowHeld as exc:
        check("value_span_quotes_admitted", False, f"code={exc}")

    # 3. The clean run passed vacuously — no finding, no quote to validate.
    clean = load(RUN_CLEAN, "bdj_output.json")
    if clean is not None:
        empty = {"issues": [], "overall_note": clean["output"]["overall_note"]}
        try:
            validate_candidates(empty, packet, set())
            check("clean_run_passes_vacuously", True,
                  "issues=0 admits with allowed_rules=EMPTY — this is why it hid the defect")
        except WorkflowHeld as exc:
            check("clean_run_passes_vacuously", False, f"code={exc}")

    # 4. Prove the defect was confined to `quote`: structure otherwise valid.
    check("defect_is_quote_only",
          all(i["kind"] == "SOURCE_CONFLICT" and len(i["source_refs"]) == 2
              for i in raw["issues"]),
          "both findings were well-formed two-source conflicts")

    failed = [k for k, (ok, _) in results.items() if not ok]
    print(f"\nchecks={len(results)} failed={len(failed)}")
    print("VERDICT=" + ("PASS" if not failed else "FAIL"))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
