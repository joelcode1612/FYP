"""CP-04A — negative authorization and constraint tests against the CLONE.

Every check runs against `project1_workflow_tests`. Nothing here touches `Dss`.

What this proves:
  * the runtime role can record a result and read its own rows;
  * a different actor sees nothing and cannot write another owner's row;
  * the append-only trigger refuses UPDATE and DELETE;
  * the protected raw response is write-only for the runtime and readable only
    by the audit role;
  * the CHECK constraints make an inconsistent state unrepresentable
    (reviewed-but-unvalidated, digest-without-return, two results per attempt,
    a cloud result claiming verified authority);
  * `validation_status` is a generated column and produces exactly the value the
    review outcome implies, for every review outcome.

Vocabulary: D1 `execution_outcome` is the ledger's lowercase triple, D3
`review_outcome` is the engine's lowercase verdict (nullable), D2
`validation_status` is generated from D3, D4 `finding_authority` is fixed at
`candidate_only`. See docs/cp00_integration/CP04A_VOCAB_RECONCILIATION_SPEC.md.

Expected refusals are asserted against the *constraint name*, not merely "some
error", so a refusal for the wrong reason (a unique violation, a privilege
error) fails the check instead of passing it.

Run:  .venv/Scripts/python.exe scripts/cp04a_clone_security_verify.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT / "src"))

from sqlalchemy import create_engine, text  # noqa: E402
from pydantic import ValidationError  # noqa: E402

from sitewise.project1.contracts import SourceRef  # noqa: E402

CLONE = "project1_workflow_tests"
from sitewise.core.config import local_database_url

DSN = local_database_url(CLONE)

OWNER = "11111111-1111-4111-8111-111111111111"
OTHER = "22222222-2222-4222-8222-222222222222"
ASSESSMENT = "da90aa4a-f9cf-4145-9acf-7de36c9d6fad"
DIGEST = "a" * 64
DIGEST2 = "b" * 64

# The corpus both patterns must agree on. The expected verdicts are stated here
# rather than derived from either pattern, so a copy that is wrong in the same
# way as its sibling still fails.
ITEM_KEYS_ACCEPT = ['M2-04', 'M2-12', 'M2-O-01', 'M2-O-02', 'M2V1-01', 'M2V1-02',
                    'M2V1-09', 'M2V1-10', 'M2V1-11']
ITEM_KEYS_REJECT = ['M2V1-00', 'M2V1-12', 'M2-4', 'M2-O-3', 'm2-04', 'M2-04 ',
                    ' M2-04', 'M2-04@x']

# The suffix branch, which the item_key corpus cannot reach because it requires
# the absence of '@'. The version id lives wholly in this branch.
LOCATOR_ACCEPT = ['M2-04@iv-0002', 'M2-04@' + 'x' * 128]
LOCATOR_REJECT = ['M2-04@', 'M2-04@' + 'x' * 129, 'M2-04@two words', 'M2-04@ x']

results: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    results.append((name, ok, detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""))


def run(conn, sql: str, params=None):
    """Execute inside a savepoint so one failure does not poison the session.

    Uses text() rather than exec_driver_sql: the latter does not translate
    `:name` placeholders, so every statement would fail with a syntax error and
    every "expected refusal" check would pass for the wrong reason.

    A refusal reports the violated constraint name first, so the caller can
    assert *which* constraint fired.
    """
    try:
        with conn.begin_nested():
            conn.execute(text(sql), params or {})
        return True, "ok"
    except Exception as exc:  # noqa: BLE001
        diag = getattr(getattr(exc, "orig", None), "diag", None)
        name = getattr(diag, "constraint_name", None)
        first = str(exc).splitlines()[0][:110]
        return False, (f"{name}: " if name else "") + first


def refused_by(conn, sql: str, params, constraint: str) -> tuple[bool, str]:
    ok, detail = run(conn, sql, params)
    return (not ok) and detail.startswith(constraint + ":"), detail


def scalar(conn, sql: str, params=None):
    return conn.execute(text(sql), params or {}).scalar()


def find_attempts(conn, limit: int = 2):
    """Real (run, owner, attempt) triples that the FK will accept."""
    rows = conn.execute(text("""
        select a.run_id, a.owner_user_id, a.attempt_no
          from project1_ai.attempts a
         where a.owner_user_id = :o
         order by a.reserved_at limit :n"""), {"o": OWNER, "n": limit}).all()
    if len(rows) < limit:
        raise SystemExit(f"clone has fewer than {limit} attempts for the synthetic owner")
    return [tuple(r) for r in rows]


INSERT_RESULT = """
    insert into project1_ai.bdj_results
      (run_id, owner_user_id, attempt_no, assessment_id, assessment_revision,
       source_fingerprint, ruleset_version, prompt_version, model_requested,
       model_returned, execution_outcome, output_digest, result_schema_version,
       result_payload, review_outcome, finding_authority, finding_count)
    values
      (:run, :owner, :attempt, :assessment, 12,
       :fingerprint, 'BDJ-RULESET-0.2-CAND', 'BDJ-SOURCE-1-CAND', 'gpt-test',
       'gpt-test', :outcome, :out_digest, 'bdj-result/1',
       :payload, :review, :authority, :count)
"""


INSERT_FINDING = """
    insert into project1_ai.bdj_result_findings
      (result_id, finding_id, owner_user_id, authority)
    values (:rid, :fid, :owner, :authority)
"""

INSERT_PROVENANCE = """
    insert into project1_ai.finding_provenance
      (finding_id, owner_user_id, assessment_id, assessment_revision,
       execution_mode, run_id, attempt_no, output_digest, ruleset_version,
       prompt_version, model_requested, model_returned, authority,
       source_fingerprint)
    values (:fid, :owner, :assessment, 12, 'CLOUD', :run, :attempt, :out_digest,
            'BDJ-RULESET-0.2-CAND', 'BDJ-SOURCE-1-CAND', 'gpt-test', 'gpt-test',
            :authority, :fingerprint)
"""


INSERT_SOURCE = """
    insert into project1_ai.bdj_result_sources
      (result_id, owner_user_id, source_rank, source_id, source_version, locator)
    values (:rid, :owner, :rank, :sid, :sver, :locator)
"""


def row_body(run_id, attempt_no, *, outcome="returned", review="reviewed",
             out_digest=DIGEST2, payload='{"findings": []}', count=0,
             authority="candidate_only", owner=OWNER, fingerprint=DIGEST) -> dict:
    return {"run": run_id, "owner": owner, "attempt": attempt_no,
            "assessment": ASSESSMENT, "fingerprint": fingerprint,
            "outcome": outcome, "out_digest": out_digest, "payload": payload,
            "review": review, "authority": authority, "count": count}


def main() -> int:
    engine = create_engine(DSN, future=True)
    with engine.connect() as conn:
        db = scalar(conn, "select current_database()")
        if db != CLONE:
            raise SystemExit(f"refusing to run against {db!r}: clone-only script")
        print(f"target database: {db}\n")

        # This clone is shared with other workers, so every count assertion is
        # relative to what was already here. An absolute count would fail for a
        # reason that has nothing to do with the constraints.
        baseline_results = scalar(conn, "select count(*) from project1_ai.bdj_results")
        baseline_raw = scalar(conn, "select count(*) from project1_ai.bdj_raw_responses")
        print(f"pre-existing rows: bdj_results={baseline_results} "
              f"bdj_raw_responses={baseline_raw}\n")

        # Nine synthetic attempts are seeded per owner; each refused insert is
        # rolled back by its savepoint, so a triple stays reusable after a
        # refusal. Successful inserts consume one triple each.
        attempts = find_attempts(conn, 9)
        run_id, owner_id, attempt_no = attempts[0]
        spare_run, _, spare_attempt = attempts[1]
        print(f"subject attempt: run={run_id} owner={owner_id} attempt={attempt_no}")
        print(f"spare attempt:   run={spare_run} attempt={spare_attempt}")

        # Both authority tables reference public.m2_bdj_findings(id) NOT NULL, so
        # proving "authority='candidate' is accepted" needs a real finding row.
        # Two are seeded here as the superuser and never committed: the script
        # ends in a rollback, so the clone is left exactly as it was. f1 is used
        # only by refusal tests (which create nothing), f2 by the acceptances.
        seeded = []
        for index, rule in enumerate(("CP04A-SECURITY-F1", "CP04A-SECURITY-F2"), start=1):
            finding_id = f"00000000-0000-4000-8000-00000000000{index}"
            conn.execute(text("""
                insert into public.m2_bdj_findings
                  (id, assessment_id, assessment_revision, rule_id, rule_version,
                   source_answer_ids, issue_type, explanation, not_proven,
                   next_action, review_state)
                values (:id, :assessment, 12, :rule, 'cp04a-test', '[]',
                        'UNSUPPORTED_ASSERTION', 'Synthetic.', 'Synthetic.',
                        'Synthetic.', 'CANDIDATE')"""),
                {"id": finding_id, "assessment": ASSESSMENT, "rule": rule})
            seeded.append(finding_id)
        print(f"seeded findings: {seeded[0]} (refusals), {seeded[1]} (acceptances)\n")

        # --- 1. write path, bound to the owner -------------------------------
        conn.exec_driver_sql("set role p1ai_runtime")
        conn.exec_driver_sql(f"select set_config('project1.actor_id', '{OWNER}', true)")
        ok, detail = run(conn, INSERT_RESULT, row_body(run_id, attempt_no))
        check("runtime records a result for its own owner", ok, detail)

        visible = scalar(conn, "select count(*) from project1_ai.bdj_results")
        check("runtime reads back its own result", visible == 1, f"rows={visible}")

        # --- 2. same connection, different actor -----------------------------
        conn.exec_driver_sql(f"select set_config('project1.actor_id', '{OTHER}', true)")
        hidden = scalar(conn, "select count(*) from project1_ai.bdj_results")
        check("a different actor sees zero rows", hidden == 0, f"rows={hidden}")

        # --- 3. write a row belonging to someone else -------------------------
        # The FK on (run, owner, attempt) already binds the owner, so a
        # cross-owner insert is normally refused by the FK before RLS is even
        # consulted. To observe the RLS WITH CHECK itself, use a *spare* attempt
        # (so no unique collision) that genuinely belongs to OWNER, while the
        # session actor is OTHER.
        ok, detail = run(conn, INSERT_RESULT, row_body(spare_run, spare_attempt))
        check("RLS WITH CHECK refuses a row owned by someone else",
              not ok and "row-level security" in detail, detail)

        # --- 4. append-only ---------------------------------------------------
        # Two distinct controls, tested separately: the runtime holds no UPDATE
        # or DELETE privilege at all, and the owner (who does hold them) is
        # stopped by the immutable_history trigger.
        conn.exec_driver_sql(f"select set_config('project1.actor_id', '{OWNER}', true)")
        ok, detail = run(conn, "update project1_ai.bdj_results set review_outcome = 'reviewed'")
        check("runtime holds no UPDATE privilege", not ok and "permission denied" in detail, detail)

        ok, detail = run(conn, "delete from project1_ai.bdj_results")
        check("runtime holds no DELETE privilege", not ok and "permission denied" in detail, detail)

        conn.exec_driver_sql("reset role")
        conn.exec_driver_sql("set role p1ai_owner")
        ok, detail = run(conn, "update project1_ai.bdj_results set review_outcome = 'reviewed'")
        check("owner UPDATE is stopped by the append-only trigger",
              not ok and "permission denied" not in detail, detail)

        ok, detail = run(conn, "delete from project1_ai.bdj_results")
        check("owner DELETE is stopped by the append-only trigger",
              not ok and "permission denied" not in detail, detail)

        conn.exec_driver_sql("reset role")
        conn.exec_driver_sql("set role p1ai_runtime")
        conn.exec_driver_sql(f"select set_config('project1.actor_id', '{OWNER}', true)")

        # --- 5. protected raw response ---------------------------------------
        result_id = scalar(conn, "select result_id from project1_ai.bdj_results limit 1")
        ok, detail = run(conn, """
            insert into project1_ai.bdj_raw_responses
              (result_id, owner_user_id, encryption_alg, key_id, ciphertext,
               plaintext_digest, plaintext_bytes, retention_until)
            values (:rid, :owner, 'FERNET-AES128-CBC-HMAC-SHA256', 'cp04a-test',
                    :ct, :digest, 64, now() + interval '90 days')""", {
                "rid": result_id, "owner": OWNER, "ct": b"x" * 64, "digest": DIGEST})
        check("runtime can write the raw response", ok, detail)

        ok, detail = run(conn, "select * from project1_ai.bdj_raw_responses")
        check("runtime CANNOT read the raw response", not ok, detail)

        # --- 6. audit role ----------------------------------------------------
        conn.exec_driver_sql("reset role")
        conn.exec_driver_sql("set role p1ai_audit")
        n = scalar(conn, "select count(*) from project1_ai.bdj_raw_responses")
        check("audit role can read the raw response", n == 1, f"rows={n}")
        n = scalar(conn, "select count(*) from project1_ai.bdj_results")
        check("audit role can read results", n >= 1, f"rows={n}")
        ok, detail = run(conn, INSERT_RESULT, row_body(run_id, attempt_no))
        check("audit role cannot write", not ok, detail)

        # --- 7. unbound connection -------------------------------------------
        conn.exec_driver_sql("reset role")
        conn.exec_driver_sql("set role p1ai_runtime")
        conn.exec_driver_sql("select set_config('project1.actor_id', '', true)")
        n = scalar(conn, "select count(*) from project1_ai.bdj_results")
        check("unbound actor sees zero rows", n == 0, f"rows={n}")

        # --- 8. constraints make inconsistency unrepresentable ----------------
        conn.exec_driver_sql(f"select set_config('project1.actor_id', '{OWNER}', true)")

        ok, detail = refused_by(conn, INSERT_RESULT, row_body(
            spare_run, spare_attempt, out_digest=None),
            "bdj_results_digest_matches_outcome")
        check("a returned response without a digest is refused (C1)", ok, detail)

        ok, detail = refused_by(conn, INSERT_RESULT, row_body(
            attempts[2][0], attempts[2][2], outcome="rejected", review=None,
            payload=None, count=0),
            "bdj_results_digest_matches_outcome")
        check("a rejected transport outcome carrying a digest is refused (C1)", ok, detail)

        # A second result for the same attempt, with every other constraint met.
        ok, detail = run(conn, INSERT_RESULT, row_body(run_id, attempt_no))
        check("a second result for one attempt is refused (C4)",
              not ok and "bdj_results_one_per_attempt" in detail, detail)

        # --- 9. D4: a cloud result may never claim authority ------------------
        ok, detail = refused_by(conn, INSERT_RESULT, row_body(
            attempts[3][0], attempts[3][2], authority="verified"),
            "bdj_results_finding_authority_check")
        check("finding_authority='verified' is refused (C6)", ok, detail)

        ok, detail = refused_by(conn, INSERT_RESULT, row_body(
            attempts[3][0], attempts[3][2], authority="CANDIDATE_ONLY"),
            "bdj_results_finding_authority_check")
        check("finding_authority in any other spelling is refused (C6)", ok, detail)

        # --- 10. C2/C3: reviewed means validated, validated means a payload ---
        ok, detail = refused_by(conn, INSERT_RESULT, row_body(
            attempts[4][0], attempts[4][2], review="reviewed", payload=None, count=0),
            "bdj_results_payload_requires_valid")
        check("review_outcome='reviewed' with a NULL payload is refused (C2/C3)", ok, detail)

        # --- 11. the persisted review enum refuses everything else ------------
        # A payload is supplied on purpose: without one, C2 fires first (any
        # value other than NULL/'rejected' generates validation_status='valid')
        # and the refusal would prove the wrong constraint.
        held = run(conn, INSERT_RESULT, row_body(
            attempts[5][0], attempts[5][2], review="held", count=0))
        upper = run(conn, INSERT_RESULT, row_body(
            attempts[6][0], attempts[6][2], review="ADMITTED", count=0))
        check("an unknown review_outcome is refused ('held', 'ADMITTED')",
              (not held[0] and "bdj_results_review_outcome_check" in held[1])
              and (not upper[0] and "bdj_results_review_outcome_check" in upper[1]),
              held[1])

        # --- 12. D2: validation_status is generated, and cannot drift ---------
        generated = scalar(conn, """
            select is_generated from information_schema.columns
             where table_schema = 'project1_ai' and table_name = 'bdj_results'
               and column_name = 'validation_status'""")
        check("validation_status is a generated column (D2)", generated == "ALWAYS",
              f"is_generated={generated}")

        # One successful insert per review outcome; each must come back with the
        # validation status D3 implies, because no application writes that column.
        cases = [
            (attempts[7], None, "unknown_outcome", None, None, "not_validated"),
            (attempts[8], "rejected", "returned", DIGEST2, None, "invalid"),
            (attempts[1], "reviewed", "returned", DIGEST2, '{"findings": []}', "valid"),
        ]
        for (run_row, _, run_attempt), review, outcome, digest, payload, expected in cases:
            with conn.begin_nested():
                observed = conn.execute(
                    text(INSERT_RESULT + " returning validation_status"),
                    row_body(run_row, run_attempt, review=review, outcome=outcome,
                             payload=payload, out_digest=digest, count=0)).scalar()
            check(f"validation_status is '{expected}' when review_outcome is {review!r}",
                  observed == expected, f"observed={observed!r}")

        # --- 13. C8: a returned response is always judged ---------------------
        ok, detail = refused_by(conn, INSERT_RESULT, row_body(
            attempts[6][0], attempts[6][2], review=None, payload=None, count=0),
            "bdj_results_returned_requires_review")
        check("a returned response with no review is refused (C8)", ok, detail)

        # --- 13b. C9: only a real review may count findings --------------------
        # The state classify() refuses but the schema used to allow: a rejected
        # attempt carrying candidate-authority findings. C1/C2/C3/C7/C8 all pass
        # on this row, so only C9 can refuse it.
        ok, detail = refused_by(conn, INSERT_RESULT, row_body(
            attempts[5][0], attempts[5][2], review="rejected", payload=None, count=5),
            "bdj_results_findings_require_review_check")
        check("a rejected result carrying findings is refused (C9)", ok, detail)

        # --- 14. per-finding authority on both tables -------------------------
        main_result = scalar(conn, """select result_id from project1_ai.bdj_results
                                       where run_id = :r and attempt_no = :a""",
                             {"r": run_id, "a": attempt_no})

        def finding_body(finding_id, authority):
            return {"rid": main_result, "fid": finding_id, "owner": OWNER,
                    "authority": authority, "assessment": ASSESSMENT,
                    "run": run_id, "attempt": attempt_no, "out_digest": DIGEST2,
                    "fingerprint": DIGEST}

        ok, detail = refused_by(conn, INSERT_FINDING,
                                finding_body(seeded[0], "ADMITTED"),
                                "bdj_result_findings_authority_check")
        check("bdj_result_findings refuses authority='ADMITTED'", ok, detail)

        ok, detail = run(conn, INSERT_FINDING, finding_body(seeded[1], "candidate"))
        check("bdj_result_findings accepts authority='candidate'", ok, detail)

        ok, detail = refused_by(conn, INSERT_PROVENANCE,
                                finding_body(seeded[0], "ADMITTED"),
                                "finding_provenance_authority_check")
        check("finding_provenance refuses authority='ADMITTED'", ok, detail)

        ok, detail = run(conn, INSERT_PROVENANCE, finding_body(seeded[1], "candidate"))
        check("finding_provenance accepts authority='candidate'", ok, detail)

        # --- 15. locator is a pointer, not prose ------------------------------
        # A writer holding a source_refs[] entry has ref['quote'] to hand, and
        # `locator` is the field that looks like it wants it. The CHECK keeps a
        # verbatim answer span out by requiring an item_key prefix and no
        # whitespace anywhere.
        def source_body(rank, locator):
            return {"rid": main_result, "owner": OWNER, "rank": rank,
                    "sid": f"src-{rank}", "sver": "1", "locator": locator}

        ok, detail = run(conn, INSERT_SOURCE, source_body(1, "M2-04@iv-0001"))
        check("bdj_result_sources accepts an item_key@version locator", ok, detail)

        # M2V1-02..09 are real instrument items; a pattern that only allowed
        # 00/01 would silently make eight of eleven pointers impossible.
        ok, detail = run(conn, INSERT_SOURCE, source_body(2, "M2V1-07@iv-0002"))
        check("bdj_result_sources accepts an M2V1 pointer in the 02-09 range", ok, detail)

        ok, detail = refused_by(conn, INSERT_SOURCE,
                                source_body(3, "We are takeaway-only."),
                                "bdj_result_sources_locator_pointer_check")
        check("bdj_result_sources refuses a verbatim answer quote as locator", ok, detail)

        # --- 16. item_key parity: the SQL pattern and the Pydantic model agree --
        # The locator CHECK transcribes SourceRef.item_key (contracts.py:29). That
        # pattern was hand-retyped three times in one afternoon and two of the
        # copies were wrong, because nothing asserted the copies agree. This does:
        # one corpus, both directions, and the two acceptance sets must be equal
        # *and* equal to the expected set -- equality alone would pass if both
        # copies were wrong in the same way.
        definition = scalar(conn, """select pg_get_constraintdef(oid) from pg_constraint
                                      where conname = 'bdj_result_sources_locator_pointer_check'""")
        # A regex with an explicit failure, not str.index: the rendering of
        # pg_get_constraintdef is not contractual and differs across majors, and
        # a ValueError inside a check would read as neither pass nor fail.
        found = re.search(r"locator ~ '([^']+)'", definition or "")
        if found is None:
            check("locator SQL pattern and SourceRef.item_key accept the same corpus",
                  False, "could not extract the pattern from pg_get_constraintdef")
            sql_pattern = None
        else:
            sql_pattern = found.group(1)

        def sql_accepts_item_key(value: str) -> bool:
            # The installed pattern's only optional part is the '@version'
            # suffix, so "matches with no '@' anywhere" is its item_key half.
            return bool(conn.execute(text(
                "select (:v ~ :p) and position('@' in :v) = 0"),
                {"v": value, "p": sql_pattern}).scalar())

        def model_accepts_item_key(value: str) -> bool:
            try:
                SourceRef(item_key=value, answer_revision_id='r',
                          item_version_id='v', quote='q')
            except ValidationError:
                return False
            return True

        if sql_pattern is not None:
            corpus = (ITEM_KEYS_ACCEPT + ITEM_KEYS_REJECT)
            sql_set = {v for v in corpus if sql_accepts_item_key(v)}
            model_set = {v for v in corpus if model_accepts_item_key(v)}
            expected = set(ITEM_KEYS_ACCEPT)
            check("locator SQL pattern and SourceRef.item_key accept the same corpus",
                  sql_set == model_set == expected,
                  f"sql-vs-model={sorted(sql_set ^ model_set)} "
                  f"sql-vs-expected={sorted(sql_set ^ expected)}")

        # The item_key half above deliberately excludes '@', so it says nothing
        # about the suffix branch -- and the suffix is where the version id lives.
        # Without this, a pattern that accepted a bare '@' or had no length bound
        # would still pass every other check.
        if sql_pattern is not None:
            suffix_observed = {v for v in LOCATOR_ACCEPT + LOCATOR_REJECT
                               if conn.execute(text("select :v ~ :p"),
                                               {"v": v, "p": sql_pattern}).scalar()}
            check("locator suffix branch enforces non-empty and bounded",
                  suffix_observed == set(LOCATOR_ACCEPT),
                  f"diff={sorted(v[:40] for v in suffix_observed ^ set(LOCATOR_ACCEPT))}")

        # --- 17. receipt ------------------------------------------------------
        conn.exec_driver_sql("reset role")
        n = scalar(conn, """select count(*) from project1_ai.schema_versions
                            where version = '20261117_03_bdj_result_persistence'""")
        check("migration receipt recorded", n == 1, f"rows={n}")

        conn.rollback()

    passed = sum(1 for _, ok, _ in results if ok)
    failed = len(results) - passed
    print(f"\nVERDICT={'PASS' if failed == 0 else 'FAIL'}  "
          f"({passed} passed, {failed} failed)")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
