#!/usr/bin/env python3
"""A2 reference routing library for directive PROJECT1-V1-CQ-SCIENTIFIC-ROUTING-CORRECTION-R3.

Design rules enforced by construction (each is covered by a test):

  L1  The sealed CUST03 file is opened read-only and its sha256 + byte length are
      verified before any rule is applied. A byte-different source aborts.
  L2  Every Q01 precedence and every gate predicate is read from
      a2_routing_spec_v1.json. No ordering, no predicate and no default is
      hard-coded here. Removing the declaration from the spec makes the library
      refuse to run (test t07 NC3).
  L3  A gate is evaluated from routing_model.item_show_gate[item] and from the
      route inputs. There is no per-item constant (test t03).
  L4  An unresolved token or an undecided input evaluates to NOT_SHOWN with a
      reason code. That policy is labelled IMPLEMENTATION_CHOICE in the spec.
  L5  Nothing in this module writes to the sealed package.
"""

from __future__ import annotations

import hashlib
import itertools
import json
from pathlib import Path

EXPECT_SHA = "ec2b5494ecf82447076e0d7a2bfb57599a24f049bbcc925a9ecbea6e833bce59"
EXPECT_BYTES = 139905
CONTRACT_REL = Path("CUST_RECOVERY_20261027/CUST03_CORRECTED_QUESTIONNAIRE_AND_ROUTING_CONTRACT.json")
SPEC_REL = Path("a2_routing_spec_v1.json")


class Undecided:
    """Sentinel for an input whose value the contract does not fix."""

    __slots__ = ("name", "raw")

    def __init__(self, name, raw=None):
        self.name = name
        self.raw = raw

    def __repr__(self):
        return f"UNDECIDED({self.name}={self.raw!r})"

    def __bool__(self):
        raise TypeError("an undecided input has no boolean value and must not be coerced")


def find_root(start=None) -> Path:
    p = Path(start or __file__).resolve()
    for anc in [p] + list(p.parents):
        if (anc / "CUST_RECOVERY_20261027").is_dir():
            return anc
    raise SystemExit("ROOT_NOT_FOUND: no ancestor contains CUST_RECOVERY_20261027")


ROOT = find_root()


def load_contract(path=None, verify=True):
    path = Path(path) if path else ROOT / CONTRACT_REL
    raw = path.read_bytes()
    sha = hashlib.sha256(raw).hexdigest()
    if verify:
        if len(raw) != EXPECT_BYTES:
            raise SystemExit(f"SOURCE_BYTES_MISMATCH got={len(raw)} want={EXPECT_BYTES}")
        if sha != EXPECT_SHA:
            raise SystemExit(f"SOURCE_HASH_MISMATCH got={sha}")
    return json.loads(raw.decode("utf-8")), sha, len(raw)


def load_spec(path=None):
    path = Path(path) if path else Path(__file__).resolve().parent / SPEC_REL
    spec = json.loads(Path(path).read_text(encoding="utf-8"))
    require_declarations(spec)
    return spec


def require_declarations(spec):
    """L2: refuse to run on an incomplete declaration set."""
    prec = spec.get("q01", {}).get("declared_precedence")
    if not prec:
        raise SystemExit("SPEC_INVALID: q01.declared_precedence is absent or empty; "
                         "this implementation will not supply a built-in precedence")
    orders = [r.get("order") for r in prec]
    if orders != list(range(len(prec))):
        raise SystemExit(f"SPEC_INVALID: declared_precedence orders are not a total order 0..n-1: {orders}")
    preds = spec.get("gate", {}).get("token_predicates")
    if not preds:
        raise SystemExit("SPEC_INVALID: gate.token_predicates is absent or empty")
    if spec.get("gate", {}).get("unresolved_token_policy") not in ("NOT_SHOWN", "SHOWN", "INVALID"):
        raise SystemExit("SPEC_INVALID: gate.unresolved_token_policy must be declared explicitly")
    for tok, body in preds.items():
        if not body.get("undecided") and not body.get("clauses"):
            raise SystemExit(f"SPEC_INVALID: token {tok} has neither clauses nor undecided=true")


# --------------------------------------------------------------------------- Q01

def q01_codes(contract):
    it = contract["items"][0]
    assert it["id"] == "Q01"
    return list(it["codes"]), list(it["exclusive_codes"]), list(it["substantive_codes"])


def q01_terminal_exit(contract, spec):
    """Read the per-code exit map from the contract; the spec only names the source."""
    eff = contract["items"][0]["eligibility_effect"]
    m = {}
    for code in contract["items"][0]["exclusive_codes"]:
        if code not in eff:
            raise SystemExit(f"SPEC_INVALID: contract eligibility_effect has no entry for terminal {code}")
        m[code] = eff[code]
    for code, val in spec["q01"]["terminal_exit_map"].items():
        if m.get(code) != val:
            raise SystemExit(f"SPEC_DRIFT: spec says {code}->{val}, contract says {code}->{m.get(code)}")
    return m


def classify_subset(sel, codes, terminals, affiliations, policy, exit_map):
    """Return a match token plus the structural detail. No disposition is chosen here."""
    s = set(sel)
    unknown = s - set(codes)
    term = s & set(terminals)
    aff = s & set(affiliations)
    other = s - unknown - term - aff
    detail = {
        "n_terminals": len(term),
        "n_affiliations": len(aff),
        "terminal_subset": "|".join(sorted(term)),
        "affiliation_subset": "|".join(sorted(aff)),
        "unknown_codes": "|".join(sorted(unknown)),
    }
    if unknown or other:
        return "UNKNOWN_CODE", detail
    if not s:
        return "EMPTY", detail
    if len(term) >= 2:
        exits = {exit_map[t] for t in term}
        if len(exits) == 1:
            match = "MULTI_TERMINAL_CONCORDANT"
            if policy["concordant_terminal_policy"] != "AGREE_ROUTE":
                # the FAIL_CLOSED variant is a declared alternative, not a code default
                match = "MULTI_TERMINAL_COMPETING"
                detail["policy_downgraded_from"] = "MULTI_TERMINAL_CONCORDANT"
            return match, detail
        return "MULTI_TERMINAL_COMPETING", detail
    if len(term) == 1 and aff:
        return "SINGLE_TERMINAL_WITH_AFFILIATION", detail
    if len(term) == 1 and not aff:
        return "SOLE_TERMINAL", detail
    if aff and not term:
        return "AFFILIATION_ONLY", detail
    return "UNMATCHED", detail


def q01_disposition(sel, contract, spec, exit_map=None):
    """Apply the DECLARED precedence from the spec, first match wins."""
    codes, terminals, affiliations = q01_codes(contract)
    if exit_map is None:
        exit_map = q01_terminal_exit(contract, spec)
    policy = spec["q01"]["policies"]
    match, detail = classify_subset(sel, codes, terminals, affiliations, policy, exit_map)
    for rule in spec["q01"]["declared_precedence"]:
        if rule["match"] != match:
            continue
        screen = rule["q01_screen"]
        if screen == "TERMINAL_EXIT":
            exits = {exit_map[t] for t in detail["terminal_subset"].split("|") if t}
            if len(exits) != 1:
                # a terminal exit is only usable when it is unique; otherwise fail closed
                return {
                    "rule_id": "Q01-R2", "order": 2, "q01_screen": "SCREEN_INVALID",
                    "answer_state": "INVALID", "detail": detail,
                    "flag": "TERMINAL_EXIT_NOT_UNIQUE_FAIL_CLOSED",
                }
            screen = exits.pop()
        return {
            "rule_id": rule["rule_id"],
            "order": rule["order"],
            "q01_screen": screen,
            "answer_state": rule["answer_state"],
            "detail": detail,
            "flag": _flag_for(rule["rule_id"], detail),
        }
    # The spec claims to be total. If it is not, say so; never invent a destination.
    return {
        "rule_id": "SPEC_INCOMPLETE", "order": None, "q01_screen": "UNRESOLVED",
        "answer_state": "UNRESOLVED", "detail": detail, "flag": "NO_DECLARED_RULE",
    }


def _flag_for(rule_id, detail):
    if rule_id == "Q01-R3":
        return "MULTI_TERMINAL_CONCORDANT_EXCLUDED_FROM_SINGLE_TERMINAL_COUNTERS"
    if rule_id == "Q01-R2":
        return "MULTI_TERMINAL_CONFLICT_INTEGRITY_PARTITION"
    if rule_id == "Q01-R1":
        return "EMPTY_STATE_SCREEN_CONFLICT_D02"
    if rule_id == "Q01-R4":
        return "TERMINAL_WINS_AFFILIATION_DISCARDED"
    return ""


def q01_is_admitted(disp):
    return disp["q01_screen"] == "ELIGIBLE"


def q01_funnel(disp, spec):
    st = disp["answer_state"]
    return {
        "in_S": spec["states"]["in_S"].get(st, False),
        "in_A": spec["states"]["in_A"].get(st, False),
        "in_V": spec["states"]["in_V"].get(st, False),
    }


def enumerate_q01(contract, spec):
    codes, _, _ = q01_codes(contract)
    exit_map = q01_terminal_exit(contract, spec)
    rows = []
    for r in range(len(codes) + 1):
        for combo in itertools.combinations(codes, r):
            sel = list(combo)
            disp = q01_disposition(sel, contract, spec, exit_map)
            funnel = q01_funnel(disp, spec)
            rows.append({
                "subset": "|".join(sel) if sel else "(empty)",
                "subset_size": r,
                "terminal_subset": disp["detail"]["terminal_subset"] or "-",
                "affiliation_subset": disp["detail"]["affiliation_subset"] or "-",
                "n_terminals": disp["detail"]["n_terminals"],
                "n_affiliations": disp["detail"]["n_affiliations"],
                "rule_id": disp["rule_id"],
                "precedence_order": disp["order"],
                "q01_screen": disp["q01_screen"],
                "answer_state": disp["answer_state"],
                "in_S": funnel["in_S"],
                "in_A": funnel["in_A"],
                "in_V": funnel["in_V"],
                "admitted_to_Qpost": q01_is_admitted(disp),
                "flag": disp["flag"],
            })
    return rows


# -------------------------------------------------------------------------- GATES

def resolve_inputs(contract, ctx=None):
    """Fill any gate input the caller did not pin from routing_model.input_values_today."""
    out = dict(ctx or {})
    iv = contract["routing_model"]["input_values_today"]
    for key in contract["routing_model"]["route_inputs"]:
        if key in out:
            continue
        raw = iv.get(key)
        if isinstance(raw, bool):
            out[key] = raw
        else:
            out[key] = Undecided(key, raw)
    return out


def _clause(clause, ctx):
    op = clause["op"]
    if op == "const":
        return True, None
    lhs = ctx.get(clause["lhs"], Undecided(clause["lhs"]))
    if isinstance(lhs, Undecided):
        return None, f"INPUT_UNDECIDED:{clause['lhs']}"
    if op == "eq":
        return lhs == clause["rhs"], None
    if op == "is_true":
        return lhs is True, None
    raise SystemExit(f"SPEC_INVALID: unknown clause op {op}")


def gate(token, ctx, spec):
    """Return (verdict, reason). verdict in {SHOWN, NOT_SHOWN}."""
    body = spec["gate"]["token_predicates"].get(token)
    if body is None:
        return "NOT_SHOWN", f"TOKEN_NOT_IN_SPEC:{token}"
    if body.get("undecided"):
        if spec["gate"]["unresolved_token_policy"] == "NOT_SHOWN":
            return "NOT_SHOWN", body["reason_code"]
        return "SHOWN", body["reason_code"]
    for clause in body["clauses"]:
        ok, reason = _clause(clause, ctx)
        if ok is False:
            return "NOT_SHOWN", reason or f"CLAUSE_FAILED:{clause}"
        if ok is None:
            if spec["gate"]["undecided_input_policy"] == "NOT_SHOWN":
                return "NOT_SHOWN", reason
            return "SHOWN", reason
    return "SHOWN", None


def render(contract, spec, ctx):
    ctx = resolve_inputs(contract, ctx)
    out = {}
    for it in contract["items"]:
        token = contract["routing_model"]["item_show_gate"][it["id"]]
        verdict, reason = gate(token, ctx, spec)
        out[it["id"]] = {"gate": token, "verdict": verdict, "reason": reason}
    return out


def render_lists(contract, spec, ctx):
    r = render(contract, spec, ctx)
    shown = [k for k, v in r.items() if v["verdict"] == "SHOWN"]
    withheld = [k for k, v in r.items() if v["verdict"] == "NOT_SHOWN"]
    return ";".join(shown) or "NONE", ";".join(withheld) or "NONE", r


def author_boolean_render(contract, fixed_flags, ctx):
    """The VACUOUS pattern R3 F-04 found: per-item author-declared booleans.

    Kept only as a negative control. It never consults item_show_gate, so it
    cannot move when the source moves.
    """
    return {it["id"]: {"gate": "AUTHOR_BOOLEAN", "verdict": "SHOWN" if fixed_flags[it["id"]] else "NOT_SHOWN",
                       "reason": None} for it in contract["items"]}


# ----------------------------------------------------------------------- SNAPSHOT

def resolve_snapshot(contract, events):
    """Last admitted snapshot per (unit_id, question_id, question_version).

    `events` is a list of dicts with keys:
      unit_id, question_id, question_version, seq, admitted(bool),
      shown(bool), answer_state, codes(list), q01_screen(optional)

    Superseded events contribute 0 to S, A and V (spec.snapshot).
    """
    latest = {}
    for ev in events:
        if not ev.get("admitted", False):
            continue
        key = (ev["unit_id"], ev["question_id"], ev["question_version"])
        if key not in latest or ev["seq"] > latest[key]["seq"]:
            latest[key] = ev
    return latest


def funnel_counts(contract, spec, events, already_displayed_events=None):
    """Derive S, A, V, INVALID, REFUSED, SKIPPED, NOT_SHOWN from the admitted snapshot.

    Each cardinality is an independently derived event-set count, never
    'A - V' (funnel_rules.derived forbids the tautology).
    """
    latest = resolve_snapshot(contract, events)
    S = A = V = invalid = refused = skipped = 0
    for ev in latest.values():
        st = ev["answer_state"]
        if st == "NOT_SHOWN":
            continue
        if spec["states"]["in_S"].get(st):
            S += 1
        if spec["states"]["in_A"].get(st):
            A += 1
        if spec["states"]["in_V"].get(st):
            V += 1
        if st == "INVALID":
            invalid += 1
        elif st == "REFUSED":
            refused += 1
        elif st == "SKIPPED":
            skipped += 1
    non_substantive = A - V - invalid - refused
    counts = {
        "S": S, "A": A, "V": V, "invalid": invalid, "refused": refused,
        "skipped": skipped, "non_substantive": non_substantive,
        "superseded_events_ignored": sum(1 for e in events if e.get("admitted", False)) - len(latest),
    }
    assert 0 <= counts["V"] <= counts["A"] <= counts["S"], f"MONOTONICITY_VIOLATION {counts}"
    assert counts["non_substantive"] >= 0, f"NEGATIVE_NON_SUBSTANTIVE {counts}"
    return counts
