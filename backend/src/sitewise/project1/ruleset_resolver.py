"""Per-instrument BDJ ruleset resolution.

One global ``PROJECT1_RULES_VERSION`` could not serve two instruments. Because
the instrument guard is symmetric and fail-closed, adopting the M2V2 ruleset
would have refused every M2V1 run, and vice versa. This resolver binds each
instrument family to its **own** version, hash and adoption receipt, so:

* the two instruments can be adopted independently, on their own receipts;
* neither can silently stand in for the other — a family whose pins are not all
  set is simply not adopted, and its runs are refused;
* historical M2V1 identities are preserved, because the legacy global trio is
  still the M2V1 default.

The hash is recomputed from the module file on every resolution. A version
string that disagrees with the module's own ``RULE_VERSION`` is a mismatch, not
a warning: pinning the wrong artefact is exactly how an unadopted ruleset would
otherwise get executed.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass
from importlib import import_module
from pathlib import Path

from sitewise.core.config import settings
from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.prompts import instrument_family


@dataclass(frozen=True)
class RulesetBinding:
    """The resolved ruleset for one instrument, with its adoption provenance."""
    family: str
    version: str
    sha256: str
    adoption_receipt: str
    module: object


#: family -> (module path, (version attr, sha attr, receipt attr))
SPECS = {
    'M2V1': ('sitewise.project1.rules.bdj_m2v1_ig_proposal',
             ('project1_rules_m2v1_version', 'project1_rules_m2v1_sha256',
              'project1_rules_m2v1_adoption_receipt')),
    'M2V2': ('sitewise.project1.rules.bdj_m2v2_ig_proposal',
             ('project1_rules_m2v2_version', 'project1_rules_m2v2_sha256',
              'project1_rules_m2v2_adoption_receipt')),
}

#: Pre-per-instrument configuration. Used for M2V1 only, and only when none of
#: the M2V1-specific pins are set at all.
LEGACY_M2V1 = ('project1_rules_version', 'project1_rules_sha256',
               'project1_rules_adoption_receipt')


def _pins(family: str) -> tuple[str, list[str]]:
    module_path, keys = SPECS[family]
    values = [getattr(settings, key) for key in keys]
    if family == 'M2V1' and not any(values):
        # A partially set M2V1 pin is never completed from the legacy trio:
        # that would mix two artefacts under one adoption decision.
        values = [getattr(settings, key) for key in LEGACY_M2V1]
    return module_path, values


def resolve_ruleset(instrument: str) -> RulesetBinding:
    """Bind this instrument to its own adopted ruleset, or hold.

    Refusals, in order: unknown instrument, unadopted family, pinned version
    disagreeing with the module, hash mismatch, and finally an instrument the
    resolved module does not claim to support.
    """
    family = instrument_family(instrument)
    module_path, (version, sha256, receipt) = _pins(family)
    if not (version and sha256 and receipt):
        raise WorkflowHeld('BDJ_RULE_ADOPTION_REQUIRED')
    module = import_module(module_path)
    if getattr(module, 'RULE_VERSION', None) != version:
        raise WorkflowHeld('BDJ_RULE_FINGERPRINT_MISMATCH')
    actual = hashlib.sha256(Path(module.__file__).read_bytes()).hexdigest()
    if actual != sha256:
        raise WorkflowHeld('BDJ_RULE_FINGERPRINT_MISMATCH')
    if instrument not in getattr(module, 'SUPPORTED_INSTRUMENT_VERSIONS', ()):
        raise WorkflowHeld('BDJ_INSTRUMENT_RULESET_UNVERIFIED')
    return RulesetBinding(family, version, sha256, receipt, module)
