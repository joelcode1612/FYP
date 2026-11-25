"""Adoption binding for the LIVE BDJ objective prompt and issue policy.

Why this exists
---------------
``ruleset_resolver.resolve_ruleset`` already refuses a LIVE run whose findings
ruleset does not match its adopted version, digest and receipt. That gate covers
``rules/bdj_m2v2_ig_proposal`` only. The two artefacts that decide *which
objective* a run may propose — the objective prompt and the issue-resolution
policy — carried no such binding, so a LIVE dispatch could run with an
unadopted ``-CAND`` prompt and an unadopted issue policy.

This module adds the same three-part binding to those two artefacts and nothing
else. It deliberately reuses the existing mechanism: version string, SHA-256 and
an owner adoption receipt, read from settings, refusing with a fixed
``WorkflowHeld`` code. There is no new table, no new ledger and no second
governance framework.

What is fingerprinted, and why not the file bytes
-------------------------------------------------
The ruleset pin hashes a module file because a ruleset *is* a module. A prompt is
not: ``prompts.py`` holds every prompt, so a file hash would invalidate the
objective adoption whenever an unrelated explanation prompt was edited. The
fingerprint is therefore taken over the prompt's own declared content —
``version``, ``role``, ``instruction`` and ``examples`` — which is exactly what
"adopt BDJ-OBJECTIVE-4-M2V2-CAND" means. The issue policy is fingerprinted over
``issue_resolution.policy_summary()``, the policy's own published surface, for
the same reason: a comment or a reordering must not read as a policy change.

Both digests are stable across line endings and formatting because they are
computed over canonical JSON, not over source text.
"""
from __future__ import annotations

import hashlib
import json

from sitewise.core.config import settings
from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.prompts import PROMPTS

#: The objective prompt this binding is defined for.
OBJECTIVE_PROMPT_KEY = 'BDJ_OBJECTIVE_M2V2'

#: Refusal codes. Fixed and content-free, so a refusal never leaks policy text.
ADOPTION_REQUIRED = 'BDJ_OBJECTIVE_ADOPTION_REQUIRED'
PROMPT_VERSION_MISMATCH = 'BDJ_OBJECTIVE_PROMPT_VERSION_MISMATCH'
PROMPT_FINGERPRINT_MISMATCH = 'BDJ_OBJECTIVE_PROMPT_FINGERPRINT_MISMATCH'
POLICY_VERSION_MISMATCH = 'BDJ_ISSUE_POLICY_VERSION_MISMATCH'
POLICY_FINGERPRINT_MISMATCH = 'BDJ_ISSUE_POLICY_FINGERPRINT_MISMATCH'


def _digest(payload) -> str:
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, ensure_ascii=False,
                   separators=(',', ':')).encode('utf-8')).hexdigest()


def prompt_payload(prompt_key: str = OBJECTIVE_PROMPT_KEY) -> dict:
    """The adopted content of one prompt: what its version label refers to."""
    prompt = PROMPTS[prompt_key]
    return {
        'version': prompt.version,
        'role': prompt.role,
        'instruction': prompt.instruction,
        'examples': [[list(pair) for pair in example]
                     for example in prompt.examples],
    }


def prompt_fingerprint(prompt_key: str = OBJECTIVE_PROMPT_KEY) -> str:
    return _digest(prompt_payload(prompt_key))


def issue_policy_fingerprint() -> str:
    """Digest of the issue policy's published surface, not of its source file."""
    from sitewise.project1 import issue_resolution

    return _digest(issue_resolution.policy_summary())


def issue_policy_version() -> str:
    from sitewise.project1 import issue_resolution

    return issue_resolution.POLICY_VERSION


def _pins():
    return (
        settings.project1_objective_prompt_version,
        settings.project1_objective_prompt_sha256,
        settings.project1_objective_prompt_adoption_receipt,
        settings.project1_issue_policy_version,
        settings.project1_issue_policy_sha256,
        settings.project1_issue_policy_adoption_receipt,
    )


def adoption_is_configured() -> bool:
    """True only when all six values are present; a partial set is not adopted."""
    return all(_pins())


def require_objective_artifacts_adopted(prompt_key: str = OBJECTIVE_PROMPT_KEY) -> dict:
    """Refuse a LIVE run whose objective prompt or issue policy is not adopted.

    Order matters: the adoption receipt is checked first, so a half-configured
    environment is refused as *unadopted* rather than misreported as a
    fingerprint mismatch.
    """
    version, sha256, receipt, policy_version, policy_sha256, policy_receipt = _pins()
    if not all((version, sha256, receipt, policy_version, policy_sha256, policy_receipt)):
        raise WorkflowHeld(ADOPTION_REQUIRED)
    if PROMPTS[prompt_key].version != version:
        raise WorkflowHeld(PROMPT_VERSION_MISMATCH)
    if prompt_fingerprint(prompt_key) != sha256:
        raise WorkflowHeld(PROMPT_FINGERPRINT_MISMATCH)
    if issue_policy_version() != policy_version:
        raise WorkflowHeld(POLICY_VERSION_MISMATCH)
    if issue_policy_fingerprint() != policy_sha256:
        raise WorkflowHeld(POLICY_FINGERPRINT_MISMATCH)
    return {
        'prompt_version': version,
        'prompt_sha256': sha256,
        'prompt_adoption_receipt': receipt,
        'issue_policy_version': policy_version,
        'issue_policy_sha256': policy_sha256,
        'issue_policy_adoption_receipt': policy_receipt,
    }


__all__ = [
    'ADOPTION_REQUIRED', 'OBJECTIVE_PROMPT_KEY', 'POLICY_FINGERPRINT_MISMATCH',
    'POLICY_VERSION_MISMATCH', 'PROMPT_FINGERPRINT_MISMATCH',
    'PROMPT_VERSION_MISMATCH', 'adoption_is_configured', 'issue_policy_fingerprint',
    'issue_policy_version', 'prompt_fingerprint', 'prompt_payload',
    'require_objective_artifacts_adopted',
]
