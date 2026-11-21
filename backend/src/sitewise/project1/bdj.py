"""Five bounded checkpoints. No rule adoption, factual acceptance or M2 writes."""
from importlib import import_module
from pathlib import Path
import hashlib

from pydantic import ValidationError

from sitewise.project1.contracts import BDJOutput, WorkflowHeld, digest, no_authority
from sitewise.project1.projection import verify_projection
from sitewise.core.exceptions import ConflictError, NotFoundError

RULE_MODULES = {
    'BDJ-EXPLICIT-FORMAT-0.1-CANDIDATE': 'sitewise.domain.bdj_rules',
    'BDJ-RULESET-0.2-CAND': 'sitewise.domain.bdj_candidate_rules',
    # ADOPTED 2026-11-21 on explicit owner direction ("update step 4 to my code
    # and verify"). Byte-identical copy of
    # tools/cp13_verification/v2/bdj_m2v1_information_gap_proposal.py; the pinned
    # SHA-256 is the identity of the adopted artifact. This entry is what
    # load_rules() treats as adoption — removing it reverts immediately.
    # NOTE: supersedes the S1/A1/P1 "synthetic trial only" scoping.
    'BDJ-M2V1-IG-0.1-PROP': 'sitewise.project1.rules.bdj_m2v1_ig_proposal',
    # 'BDJ-RULESET-0.3-M2V1-CAND' was authored and RETIRED on 2026-11-17. It
    # re-keyed the 0.2 catalogue onto M2V1 item keys, but its one executable
    # rule (SERVICE_FORMAT_EXPLICIT_CONFLICT over M2V1-02 + M2V1-07) restates the
    # M2V1_DELIVERY_WITH_ON_PREMISE_OCCASION objection that D02 rejected and the
    # Owner re-affirmed the same day. Retirement is not bypassable: load_rules()
    # refuses this version even with a correct hash and a valid receipt.
    # See src/sitewise/domain/bdj_candidate_rules_m2v1.py.
    # 'BDJ-M2V1-0.1-CAND' was RETIRED on 2026-11-17 (D02 decision). On review,
    # none of its four rules is a contradiction: they are planning uncertainty or
    # a research-clarification requirement, and every genuine M2V1 cross-item
    # contradiction is already prevented at write time by validate_m2_answer.
    # The module is kept for evidence but is no longer loadable, so no adoption
    # receipt can activate a ruleset that cannot legitimately emit SOURCE_CONFLICT.
    # See docs/cp00_integration/PROJECT1_D02_RULESET_RETIREMENT_DECISION_20261117.md
}

# The Owner's conditional decision applies only to this exact historical
# artifact in the separately guarded synthetic trial, never to load_rules().
SYNTHETIC_M2V1_RULESET = 'BDJ-M2V1-IG-0.1-PROP'
SYNTHETIC_M2V1_RULESET_SHA256 = 'bd8d345965eae37e7861e0199ca0516c41bcbcef0a64b34d2bdf8bc9681b14e8'


def load_rules(version: str, expected_sha256: str, adoption_receipt: str):
    if version not in RULE_MODULES or not adoption_receipt:
        raise WorkflowHeld('BDJ_RULE_ADOPTION_REQUIRED')
    module = import_module(RULE_MODULES[version])
    if hashlib.sha256(Path(module.__file__).read_bytes()).hexdigest() != expected_sha256:
        raise WorkflowHeld('BDJ_RULE_FINGERPRINT_MISMATCH')
    return module


def validate_candidates(raw, packet: dict, allowed_rules: set[str]) -> BDJOutput:
    """Exact references and quoted source spans; existence is not semantic proof."""
    result = BDJOutput.model_validate(raw)
    sources = {d['item_key']: d for d in packet['declarations']}
    seen = set()
    for issue in result.issues:
        if issue.rule_id not in allowed_rules:
            raise WorkflowHeld('BDJ_RULE_NOT_REGISTERED')
        for ref in issue.source_refs:
            current = packet.get("instrument_version") == "M2V1-20261114-1"
            if ref.item_key.startswith("M2V1-") != current:
                raise WorkflowHeld("BDJ_INSTRUMENT_REFERENCE_MISMATCH")
            source = sources.get(ref.item_key)
            if (not source or source['answer_state'] != 'ANSWERED' or
                    source['answer_revision_id'] != ref.answer_revision_id or
                    source['item_version_id'] != ref.item_version_id):
                raise WorkflowHeld('BDJ_SOURCE_REFERENCE_INVALID')
            values = source['value'] if isinstance(source['value'], list) else [source['value']]
            if not any(isinstance(v, str) and ref.quote in v for v in values):
                raise WorkflowHeld('BDJ_SOURCE_QUOTE_INVALID')
        if issue.kind == 'SOURCE_CONFLICT' and len({r.item_key for r in issue.source_refs}) < 2:
            raise WorkflowHeld('BDJ_CONFLICT_REQUIRES_TWO_SOURCES')
        signature = digest(issue.model_dump())
        if signature in seen:
            raise WorkflowHeld('BDJ_DUPLICATE_CANDIDATE')
        seen.add(signature)
    return result


class BDJEngine:
    def __init__(self, rules=None, model_runner=None):
        self.rules, self.model_runner = rules, model_runner

    def prepare_discovery_trial(self, packet, *, item_definitions, recheck_current, inventory_envelope=None,
                                registered_disclosure=None):
        """Build an isolated trial input; no provider call or approval is implied."""
        from sitewise.project1.bdj_discovery_candidate import validate_information_gap_trial_v101
        version = getattr(self.rules, 'RULE_VERSION', None)
        classified = packet.get('data_class') == 'SYNTHETIC_NONHUMAN'
        if registered_disclosure is not None:
            from sitewise.project1.disclosure import RegisteredSyntheticBdjDisclosure
            from sitewise.project1.synthetic_trial_registry import PrivateSyntheticTrialRegistry
            from sitewise.project1.provider import ENDPOINT, MODEL
            if (not isinstance(registered_disclosure, RegisteredSyntheticBdjDisclosure) or
                    not isinstance(registered_disclosure.registry, PrivateSyntheticTrialRegistry)):
                raise WorkflowHeld('BDJ_TRIAL_AUTHORITY_COMPOSITION_REQUIRED')
            registered_disclosure.require_current('BDJ', packet, ENDPOINT, MODEL)
            classified = True
        if (self.rules is None or version not in
                {'BDJ-M2V1-IG-TEST-1.0.1', SYNTHETIC_M2V1_RULESET} or
                not classified):
            raise WorkflowHeld('BDJ_TRIAL_SCOPE_REQUIRED')
        if version == SYNTHETIC_M2V1_RULESET:
            try:
                actual_hash = hashlib.sha256(Path(self.rules.__file__).read_bytes()).hexdigest()
            except (AttributeError, OSError):
                raise WorkflowHeld('BDJ_TRIAL_RULE_ARTIFACT_UNAVAILABLE') from None
            if actual_hash != SYNTHETIC_M2V1_RULESET_SHA256:
                raise WorkflowHeld('BDJ_TRIAL_RULE_ARTIFACT_MISMATCH')
        fingerprint = recheck_current()
        empty = {'contract_version':'bdj-discovery-output/1-candidate',
                 'issues':[], 'overall_note':'Source preflight only.'}
        validate_information_gap_trial_v101(empty, packet, item_definitions,
                                             current_source_fingerprint=fingerprint)
        answers = {d['item_key']: {'id': d['answer_revision_id'],
                   'answer_state': d['answer_state'], 'value_json': d['value']}
                   for d in packet['declarations']}
        proposals = self.rules.evaluate_candidate_issues(answers)
        triggered = {row['rule_id'] for row in proposals}
        catalogue = [row for row in self.rules.RULE_CATALOGUE if row['rule_id'] in triggered]
        model_packet = {**packet, 'rule_catalogue': catalogue}
        if inventory_envelope is not None:
            from sitewise.project1.projection import verify_bdj_inventory
            verify_bdj_inventory(inventory_envelope, item_definitions=item_definitions)
            if inventory_envelope['projection'] != packet:
                raise WorkflowHeld('BDJ_TRIAL_INVENTORY_SOURCE_MISMATCH')
            # The source fingerprint retains its historical meaning. The
            # separately hashed inventory is also covered by the exact provider
            # body digest in RegisteredSyntheticBdjDisclosure.require_request.
            model_packet['item_inventory'] = inventory_envelope['item_inventory']
        return model_packet, triggered

    def review_discovery_trial(self, packet, *, item_definitions, recheck_current, inventory_envelope=None):
        """Isolated candidate path; caller owns authorization and source binding.

        Never selected by the production route. A configured runner still must
        enforce the existing disclosure and attempt ledger before dispatch.
        """
        from sitewise.project1.bdj_discovery_candidate import (
            DiscoveryOutputCandidate, validate_information_gap_trial_v101)
        if self.model_runner is None:
            raise WorkflowHeld('BDJ_TRIAL_SCOPE_REQUIRED')
        model_packet, triggered = self.prepare_discovery_trial(
            packet, item_definitions=item_definitions, recheck_current=recheck_current,
            inventory_envelope=inventory_envelope,
            registered_disclosure=(self.model_runner.disclosure if
                type(getattr(self.model_runner, 'disclosure', None)).__name__ == 'RegisteredSyntheticBdjDisclosure'
                else None))
        raw = self.model_runner('BDJ', model_packet, DiscoveryOutputCandidate)
        verified = validate_information_gap_trial_v101(raw, packet, item_definitions,
            current_source_fingerprint=recheck_current())
        if any(issue.rule_id not in triggered for issue in verified.issues):
            raise WorkflowHeld('BDJ_TRIAL_RULE_NOT_TRIGGERED')
        # A shared rule identifier can cover several item codes. The selected
        # artifact may intentionally exclude some of them; accepting only the
        # identifier would let a model cite an excluded answer whenever that
        # rule fired for a different item. Bind each finding to the actual
        # detector's rule AND exact answer-revision set.
        answers = {d['item_key']: {'id': d['answer_revision_id'],
                   'answer_state': d['answer_state'], 'value_json': d['value']}
                   for d in packet['declarations']}
        permitted = {(p['rule_id'], frozenset(map(str, p['source_answer_ids'])))
                     for p in self.rules.evaluate_candidate_issues(answers)}
        for issue in verified.issues:
            identity = (issue.rule_id, frozenset(str(ref.answer_revision_id) for ref in issue.source_refs))
            if identity not in permitted:
                raise WorkflowHeld('BDJ_TRIAL_RULE_SOURCE_NOT_TRIGGERED')
        return self._result(packet, [{'checkpoint': 1, 'name': 'Synthetic trial source',
                            'outcome': 'verified'}, {'checkpoint': 2,
                            'name': 'Candidate validation', 'outcome': 'checked'}],
                            [issue.model_dump() for issue in verified.issues], 'reviewed')

    def review(self, packet: dict, *, recheck_current) -> dict:
        events = []
        verify_projection(packet)
        events.append({'checkpoint': 1, 'name': 'Source integrity', 'outcome': 'verified'})
        if self.rules is None:
            return self._result(packet, events + [
                {'checkpoint': i, 'outcome': 'held', 'reason': 'BDJ_RULE_ADOPTION_REQUIRED'}
                for i in range(2, 6)], [], 'held')
        # Legacy rules read M2-xx keys, so they cannot establish that an M2V1
        # declaration has no issues. Hold before model dispatch instead of
        # reporting a misleading successful review with an empty catalogue.
        if (packet.get('instrument_version') == 'M2V1-20261114-1' and
                getattr(self.rules, 'RULE_VERSION', None) in
                {'BDJ-EXPLICIT-FORMAT-0.1-CANDIDATE', 'BDJ-RULESET-0.2-CAND'}):
            return self._result(packet, events + [
                {'checkpoint': i, 'outcome': 'held', 'reason': 'BDJ_M2V1_RULESET_ADOPTION_REQUIRED'}
                for i in range(2, 6)], [], 'held')
        answers = {d['item_key']: {'id': d['answer_revision_id'],
                    'answer_state': d['answer_state'], 'value_json': d['value']}
                   for d in packet['declarations']}
        proposals = (self.rules.evaluate_candidate_issues(answers)
                     if hasattr(self.rules, 'evaluate_candidate_issues') else
                     list(filter(None, [self.rules.format_conflict(answers)])))
        by_id = {d['answer_revision_id']: d for d in packet['declarations']}
        candidates = []
        for p in proposals:
            refs = []
            for answer_id in p['source_answer_ids']:
                source = by_id[answer_id]
                value = source['value']
                refs.append({k: source[k] for k in
                             ('item_key', 'answer_revision_id', 'item_version_id')} | {
                                 'quote': value[0] if isinstance(value, list) else value})
            kind = ('INFORMATION_GAP' if p['issue_type'] == 'INFORMATION_GAP'
                    else 'SOURCE_CONFLICT' if len(refs) > 1 and
                    p['issue_type'] == 'POTENTIAL_DECLARATION_CONFLICT'
                    else 'UNSUPPORTED_ASSERTION')
            candidates.append({'rule_id': p['rule_id'],
                'kind': kind,
                'source_refs': refs, 'observed_condition': p['explanation'],
                'counterargument': p['not_proven'], 'justification': p['not_proven'],
                'next_action': p['next_action']})
        events.append({'checkpoint': 2, 'name': 'Consistency rules', 'outcome': 'checked',
                       'rule_version': self.rules.RULE_VERSION})
        # Model claims must also pass the selected independent detector. Source
        # existence/quoting alone cannot establish that a contradiction exists.
        allowed = {p['rule_id'] for p in proposals}
        raw = {'issues': candidates, 'overall_note':
               'Only the checked rules were reviewed. Business viability is not established.'}
        if self.model_runner:
            # The admission contract only accepts rule ids the deterministic
            # detector also fired, so the model must be told that vocabulary;
            # otherwise it invents identifiers (observed: 'BDJ-001') and every
            # candidate dies on BDJ_RULE_NOT_REGISTERED. The catalogue is policy,
            # not source data, and does not change the source fingerprint.
            model_packet = {**packet, 'rule_catalogue': sorted(allowed)}
            raw = self.model_runner('BDJ', model_packet, BDJOutput)
        events.append({'checkpoint': 3, 'name': 'Uncertainty interpretation',
                       'outcome': 'model_returned' if self.model_runner else 'not_called'})
        try:
            output = validate_candidates(raw, packet, allowed)
            # A model returning no issues cannot suppress a reproducible finding.
            deterministic = validate_candidates({'issues': candidates,
                'overall_note': 'Deterministic candidate checks only.'}, packet, allowed)
            merged = {digest({'rule': i.rule_id, 'refs': [r.answer_revision_id
                      for r in i.source_refs]}): i for i in deterministic.issues}
            for issue in output.issues:
                key = digest({'rule': issue.rule_id,
                              'refs': [r.answer_revision_id for r in issue.source_refs]})
                merged.setdefault(key, issue)
            output = output.model_copy(update={'issues': list(merged.values())})
        except (ValidationError, WorkflowHeld):
            return self._result(packet, events + [
                {'checkpoint': 4, 'outcome': 'rejected', 'reason': 'CANDIDATE_VALIDATION_FAILED'},
                {'checkpoint': 5, 'outcome': 'held'}], [], 'rejected')
        events.append({'checkpoint': 4, 'name': 'Candidate validation', 'outcome': 'checked'})
        # An edit while the model ran invalidates the response before presentation.
        try:
            current = recheck_current()
        except (ConflictError, NotFoundError):
            # A confirmed source edited or removed during inference is stale,
            # not a successful empty result. The caller can persist the receipt.
            current = None
        if current != packet['source_fingerprint']:
            return self._result(packet, events + [
                {'checkpoint': 5, 'outcome': 'stale'}], [], 'stale')
        events.append({'checkpoint': 5, 'name': 'Source-linked explanation',
                       'outcome': 'review_required' if output.issues else 'bounded_no_issue'})
        return self._result(packet, events, [i.model_dump() for i in output.issues], 'reviewed')

    @staticmethod
    def _result(packet, events, findings, outcome):
        return {'assessment_id': packet['assessment_id'],
                'assessment_revision': packet['assessment_revision'],
                'source_fingerprint': packet['source_fingerprint'],
                'outcome': outcome, 'checkpoints': events, 'findings': findings,
                'finding_authority': 'CANDIDATE_ONLY',
                'status_contract': 'UNRECONCILED_PROPOSAL', **no_authority()}
