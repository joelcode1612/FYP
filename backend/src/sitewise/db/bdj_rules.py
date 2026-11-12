"""Compatibility import for the existing BDJ candidate rules.

The pure rules now belong to the domain. This path grants no adoption authority.
"""
from sitewise.domain.bdj_candidate_rules import (  # noqa: F401
    RULE_VERSION, RULE_CATALOGUE, format_conflict, explicit_unsupported_claims,
    evaluate_candidate_issues, interpretation_notices,
)
