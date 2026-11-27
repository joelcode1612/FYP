"""The methodology catalogue: one file, loaded and checked, never retrieved.

What this is
------------
The ten documents in ``deliverables/research_methodology_20261126`` established two
standards — ROAS-V1 (twelve objective criteria) and QGAS-V1 (thirteen question
criteria) — and then used them to review the actual corpus. Their *findings* are
records about a past state. Their *criteria* are reusable, and this module is how a
prompt reuses them.

It is deliberately not a knowledge base, an index, an embedding store or a second
policy engine. It is a JSON file in the package, loaded once, validated, and read by
key. The brief forbids "another knowledge-retrieval engine or database"; a dictionary
lookup over a versioned file is neither.

Why a fingerprint
-----------------
A prompt that says "apply the methodology" is unauditable: the methodology can change
underneath it and no record says which version was applied. ``fingerprint()`` is the
SHA-256 of the catalogue's canonical JSON, so an attempt can record the exact
catalogue it ran against and a later reader can tell whether the rules changed.

What it refuses to do
---------------------
It does not decide anything. ``criterion()`` returns the rule; it does not evaluate an
objective or an item against it. Evaluation is the review path's job, and keeping the
two apart is what stops a catalogue edit from silently changing an admission verdict.
"""
from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path

from sitewise.project1.contracts import WorkflowHeld, canonical, digest

CONTRACT_VERSION = 'methodology-catalogue/1'
CATALOGUE_PATH = Path(__file__).with_name('catalogue_v1.json')

#: The two prompt families the catalogue serves. Named rather than free-form so a
#: typo fails loudly instead of returning an empty list a prompt would then ignore.
PRINCIPLE_SETS = ('bdj_objective', 'qg_item')

_CODE_PREFIXES = {'R': 'objective_criteria', 'Q': 'question_criteria'}


@lru_cache(maxsize=1)
def _loaded() -> dict:
    return json.loads(CATALOGUE_PATH.read_text(encoding='utf-8'))


def catalogue() -> dict:
    """The catalogue as a plain dict. Callers must not mutate it."""
    return _loaded()


def fingerprint() -> str:
    """The identity of the catalogue this process is applying."""
    return digest(_loaded())


def criteria(kind: str) -> list[dict]:
    """All criteria of one kind, in document order."""
    if kind not in _CODE_PREFIXES.values():
        raise WorkflowHeld('METHODOLOGY_CATALOGUE_KIND_UNKNOWN')
    return list(_loaded()[kind])


def criterion(code: str) -> dict:
    """One criterion by its code — ``R4`` or ``Q13``.

    The code's first letter selects the family, so a caller that mixes the two up
    gets a refusal rather than a silently empty result.
    """
    if not isinstance(code, str) or not code:
        raise WorkflowHeld('METHODOLOGY_CATALOGUE_CODE_INVALID')
    kind = _CODE_PREFIXES.get(code[0].upper())
    if kind is None:
        raise WorkflowHeld('METHODOLOGY_CATALOGUE_CODE_INVALID')
    for item in _loaded()[kind]:
        if item['id'] == code.upper():
            return dict(item)
    raise WorkflowHeld('METHODOLOGY_CATALOGUE_CODE_UNKNOWN')


def principles(prompt_family: str) -> list[str]:
    """The imperative statements a prompt may carry, in catalogue order."""
    if prompt_family not in PRINCIPLE_SETS:
        raise WorkflowHeld('METHODOLOGY_CATALOGUE_FAMILY_UNKNOWN')
    return list(_loaded()['prompt_principles'][prompt_family])


def blocking_codes(prompt_family: str) -> list[str]:
    """The codes that block publication for this family."""
    key = 'objective' if prompt_family == 'bdj_objective' else 'question'
    return list(_loaded()['blocking_matrix'][key])


def verdicts() -> dict[str, str]:
    """The four permitted verdicts and what each means."""
    return dict(_loaded()['verdict_vocabulary'])


def problems() -> list[str]:
    """Integrity findings for the catalogue on disk. Empty means coherent.

    Checked here rather than trusted, because this file is edited by hand and a
    duplicate code or a blocking entry naming a criterion that does not exist would
    turn "blocking" into a word with no referent. The test suite asserts this is
    empty; the loader does not raise on it, so a broken catalogue is diagnosable
    rather than a hard import failure in the middle of a request.
    """
    found: list[str] = []
    data = _loaded()
    if data.get('contract_version') != CONTRACT_VERSION:
        found.append(f"contract_version is {data.get('contract_version')!r}, "
                     f'expected {CONTRACT_VERSION!r}')

    seen: dict[str, str] = {}
    for kind in _CODE_PREFIXES.values():
        for item in data.get(kind, []):
            code = item.get('id')
            if not code:
                found.append(f'{kind}: a criterion has no id')
                continue
            if code in seen:
                found.append(f'duplicate criterion id {code} in {kind} and {seen[code]}')
            seen[code] = kind
            if not str(item.get('rule', '')).strip():
                found.append(f'{code}: no rule text')
            if not item.get('provenance'):
                found.append(f'{code}: no provenance')
            if not isinstance(item.get('blocking'), bool):
                found.append(f'{code}: blocking is not a boolean')

    for key in ('objective', 'question'):
        for code in data.get('blocking_matrix', {}).get(key, []):
            if code not in seen:
                found.append(f'blocking_matrix.{key} names unknown criterion {code}')
    for code in data.get('blocking_matrix', {}).get('non_blocking', []):
        if code not in seen:
            found.append(f'blocking_matrix.non_blocking names unknown criterion {code}')

    # The blocking matrix and the per-criterion flag must agree. Two sources of truth
    # for "is this blocking" is exactly the drift this catalogue exists to prevent.
    for kind, key in (('objective_criteria', 'objective'),
                      ('question_criteria', 'question')):
        declared = set(data.get('blocking_matrix', {}).get(key, []))
        flagged = {c['id'] for c in data.get(kind, []) if c.get('blocking')}
        for code in sorted(flagged - declared):
            found.append(f'{code} is blocking on its own row but absent from '
                         f'blocking_matrix.{key}')
        for code in sorted(declared - flagged):
            found.append(f'{code} is in blocking_matrix.{key} but not blocking '
                         'on its own row')

    for family in PRINCIPLE_SETS:
        if not data.get('prompt_principles', {}).get(family):
            found.append(f'prompt_principles.{family} is empty')

    for source in data.get('sources', []):
        if source.get('inspected') and not source.get('contributes'):
            found.append(f"source {source.get('id')} is inspected but contributes "
                         'no criterion')
    return found


def prompt_preamble(prompt_family: str) -> str:
    """The principles rendered as a prompt block, with its own identity.

    The catalogue fingerprint is appended so that an attempt's recorded prompt can be
    traced to the exact rule set it carried, without the prompt having to embed the
    whole file.
    """
    lines = [f'Methodology catalogue {CONTRACT_VERSION} ({fingerprint()[:16]}).',
             'Apply these rules; do not restate them, and do not invent others:']
    lines += [f'- {text}' for text in principles(prompt_family)]
    return '\n'.join(lines)


__all__ = ['CONTRACT_VERSION', 'CATALOGUE_PATH', 'PRINCIPLE_SETS', 'catalogue',
           'fingerprint', 'criteria', 'criterion', 'principles', 'blocking_codes',
           'verdicts', 'problems', 'prompt_preamble']
