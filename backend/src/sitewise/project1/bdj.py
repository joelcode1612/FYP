"""Five bounded checkpoints. No rule adoption, factual acceptance or M2 writes."""
from importlib import import_module
from pathlib import Path
import hashlib

from pydantic import ValidationError

from sitewise.project1.contracts import BDJOutput, WorkflowHeld, digest, no_authority
from sitewise.project1.projection import verify_projection

RULE_MODULES = {
    'BDJ-EXPLICIT-FORMAT-0.1-CANDIDATE': 'sitewise.domain.bdj_rules',
    'BDJ-RULESET-0.2-CAND': 'sitewise.db.bdj_rules',
}


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

    def review(self, packet: dict, *, recheck_current) -> dict:
        events = []
        verify_projection(packet)
        events.append({'checkpoint': 1, 'name': 'Source integrity', 'outcome': 'verified'})
        if self.rules is None:
            return self._result(packet, events + [
                {'checkpoint': i, 'outcome': 'held', 'reason': 'BDJ_RULE_ADOPTION_REQUIRED'}
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
            candidates.append({'rule_id': p['rule_id'],
                'kind': 'SOURCE_CONFLICT' if len(refs) > 1 and
                        p['issue_type'] == 'POTENTIAL_DECLARATION_CONFLICT' else 'UNSUPPORTED_ASSERTION',
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
            raw = self.model_runner('BDJ', packet, BDJOutput)
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
        if recheck_current() != packet['source_fingerprint']:
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
