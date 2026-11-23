#!/usr/bin/env python3
"""Build test/fixtures/cq_session_isolated.json deterministically.

Why this exists
---------------
`cq_synthetic_transport_test.dart` reads `test/fixtures/cq_session_isolated.json`,
which was absent from the repository, so three tests failed with
`PathNotFoundException`. Hand-writing a session payload is not acceptable: the
DTO is integrity-checked (`cqDigest(manifest) == manifest_hash`) and its routing
table must cover exactly the manifest's slot set.

So this builder derives the missing fixture from the **committed** fixture of the
same synthetic run (`cq_synthetic_completed.json`, run
3d58c824-a82f-5b5f-b037-f70487971917) by applying the documented state
transition COMPLETED -> IN_PROGRESS. The manifest, the routing table and the
question versions are carried over byte-for-byte, so every integrity invariant
still holds; only the session-lifecycle fields change.

Usage
-----
    python shared_logic/tool/build_cq_session_isolated_fixture.py [--check]

`--check` regenerates in memory and compares with the file on disk (exit 1 on
drift), so CI can prove the fixture was not hand-edited.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

FIXTURES = Path(__file__).resolve().parents[1] / "test" / "fixtures"
SOURCE = FIXTURES / "cq_synthetic_completed.json"
TARGET = FIXTURES / "cq_session_isolated.json"

# The lifecycle transition this builder performs, stated once so it is auditable.
TRANSITIONS = {
    "status": ("SUBMITTED", "ACTIVE"),
    "lifecycle_status": ("COMPLETED", "IN_PROGRESS"),
    "synthetic_case": ("01-normal-completion", "02-isolated-in-progress"),
}


def cq_digest(value: object) -> str:
    """Mirror of `cqDigest` in customer_questionnaire.dart.

    Sorted keys, compact separators, ASCII-escaped — then SHA-256 over UTF-8.
    """
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def build() -> dict:
    source = json.loads(SOURCE.read_text(encoding="utf-8"))

    # Integrity of the source must hold before it is used as a base.
    manifest = source["manifest"]
    if cq_digest(manifest) != source["manifest_hash"]:
        raise SystemExit("source fixture manifest digest does not match its manifest_hash")
    if source["status"] != TRANSITIONS["status"][0]:
        raise SystemExit(f"source fixture is not {TRANSITIONS['status'][0]}: {source['status']}")

    target = json.loads(json.dumps(source))  # deep copy, preserves key order

    for key, (expected, replacement) in TRANSITIONS.items():
        if target[key] != expected:
            raise SystemExit(f"{key}: expected {expected!r}, found {target[key]!r}")
        target[key] = replacement

    # A submitted session's revision is the submit bump; the pre-submit revision
    # is what the receipt recorded as answer_revision. Carrying that over keeps
    # the in-progress revision consistent with the answers it represents.
    receipt = target.get("receipt")
    if not isinstance(receipt, dict):
        raise SystemExit("source fixture has no receipt to derive the in-progress revision from")
    answer_revision = receipt.get("answer_revision")
    if not isinstance(answer_revision, int) or answer_revision < 0:
        raise SystemExit("receipt.answer_revision is missing or invalid")
    target["revision"] = answer_revision

    # No submission happened, so there is no receipt to display or verify.
    target["receipt"] = None

    # Invariants that must survive the transformation.
    if cq_digest(target["manifest"]) != target["manifest_hash"]:
        raise SystemExit("derived fixture manifest digest drifted")
    if [r["slot_id"] for r in target["routing"]] != [r["slot_id"] for r in source["routing"]]:
        raise SystemExit("derived fixture routing table drifted")
    if target["execution_scope"] != "ISOLATED_TEST":
        raise SystemExit("derived fixture is not an isolated-test session")
    if target["production_fielding_authorized"] is not False:
        raise SystemExit("derived fixture claims production fielding authorization")
    return target


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify the file matches the builder output")
    args = parser.parse_args()

    built = build()
    text = json.dumps(built, indent=2, ensure_ascii=False) + "\n"

    if args.check:
        if not TARGET.is_file():
            print(f"MISSING {TARGET}", file=sys.stderr)
            return 1
        if TARGET.read_text(encoding="utf-8") != text:
            print(f"DRIFT   {TARGET} differs from the deterministic builder output", file=sys.stderr)
            return 1
        print(f"OK      {TARGET.name} matches the builder ({len(text)} bytes)")
        return 0

    TARGET.write_text(text, encoding="utf-8")
    print(f"wrote   {TARGET} ({len(text)} bytes)")
    print(f"manifest_hash  {built['manifest_hash']}")
    print(f"session_id     {built['session_id']}")
    print(f"revision       {built['revision']} (was {json.loads(SOURCE.read_text(encoding='utf-8'))['revision']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
