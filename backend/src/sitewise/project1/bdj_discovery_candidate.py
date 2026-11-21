"""M2V1 discovery signal candidate; not an adopted or dispatchable ruleset.

Only call on a server-authorized, current source from M2SourceProjection. The
fingerprint proves integrity, not ownership, codebook validity or approval.
This module makes no model call and does not create findings or objectives.
"""
from uuid import UUID
from typing import Literal
from pydantic import Field
from sitewise.project1.contracts import Finding, StrictModel, WorkflowHeld, digest
from sitewise.project1.projection import M2V1_VERSION, verify_projection

CONTRACT_VERSION = 'bdj-discovery-signals/1-candidate'
STATUS = 'PROPOSED_NOT_ADOPTED'
DISCOVERY_SIGNALS = frozenset({
    'INFORMATION_INTEREST', 'EXPLICIT_UNCERTAINTY', 'DECLARED_ASSUMPTION',
    'EVIDENCE_LIMITATION', 'POTENTIAL_INCONSISTENCY', 'DECISION_NEED',
})


class DiscoveryFindingCandidate(Finding):
    """Versioned proposal only; classification is not semantic approval."""
    discovery_signal: Literal['INFORMATION_INTEREST', 'EXPLICIT_UNCERTAINTY',
        'DECLARED_ASSUMPTION', 'EVIDENCE_LIMITATION', 'POTENTIAL_INCONSISTENCY',
        'DECISION_NEED']


class DiscoveryOutputCandidate(StrictModel):
    contract_version: Literal['bdj-discovery-output/1-candidate']
    issues: list[DiscoveryFindingCandidate] = Field(max_length=20)
    overall_note: str = Field(min_length=1, max_length=1000)


def validate_supported_discovery(raw, packet, item_definitions, allowed_rules):
    """Validate a candidate against existing BDJ checks and supported pointers.

    This is a test-only adapter; passing it is not semantic approval. Signals
    without an authoritative evidence adapter, including DS03/DS05, fail
    closed. It must not be wired to live dispatch without adoption.
    """
    from sitewise.project1.bdj import validate_candidates

    output = DiscoveryOutputCandidate.model_validate(raw)
    base = {'issues': [issue.model_dump(exclude={'discovery_signal'})
                       for issue in output.issues], 'overall_note': output.overall_note}
    validate_candidates(base, packet, allowed_rules)
    supported = project_declared_signals(packet, item_definitions)['signals']
    def refs(rows):
        return frozenset((r['item_key'], r['answer_revision_id'], r['item_version_id'])
                         for r in rows)
    permitted = {(row['classification'], refs(row['source_refs'])) for row in supported}
    for issue in output.issues:
        source = refs([ref.model_dump() for ref in issue.source_refs])
        if (issue.discovery_signal, source) not in permitted:
            raise WorkflowHeld('BDJ_DISCOVERY_SOURCE_UNSUPPORTED')
    return output


def validate_information_gap_trial_v101(raw, packet, item_definitions, *,
                                        current_source_fingerprint):
    """Additional V1.0.1 synthetic-only admission; no execution authority.

    The caller must independently authenticate the owner and establish that the
    fingerprint is from the current, persisted confirmation. This function
    cannot establish confirmation ownership or existence from a client value.
    """
    if (not isinstance(current_source_fingerprint, str) or
            not current_source_fingerprint or
            current_source_fingerprint != packet.get('source_fingerprint')):
        raise WorkflowHeld('BDJ_TRIAL_CONFIRMATION_SOURCE_MISMATCH')
    confirmation = packet.get('confirmation')
    if (not isinstance(confirmation, dict) or
            not isinstance(confirmation.get('confirmation_id'), str) or
            not confirmation['confirmation_id'].strip() or
            not isinstance(confirmation.get('snapshot_digest'), str) or
            len(confirmation['snapshot_digest']) != 64 or
            any(c not in '0123456789abcdef' for c in confirmation['snapshot_digest'])):
        raise WorkflowHeld('BDJ_TRIAL_CONFIRMATION_IDENTITY_MISSING')
    for row in packet.get('declarations', []):
        if row.get('answer_state') == 'ANSWERED' and any(
                not isinstance(row.get(key), str) or not row[key].strip()
                for key in ('item_key', 'item_version_id', 'answer_revision_id')):
            raise WorkflowHeld('BDJ_TRIAL_SOURCE_ID_MISSING')
    rules = {
        'M2V1_EXPLICIT_PLANNING_UNDECIDED': (
            set(f'M2V1-{n:02d}' for n in range(1, 8)), {'UNDECIDED'}, 'EXPLICIT_UNCERTAINTY'),
        'M2V1_EVIDENCE_INVENTORY_UNKNOWN': ({'M2V1-08'}, {'UNKNOWN'}, 'EVIDENCE_LIMITATION'),
        'M2V1_RESEARCH_PURPOSE_UNSURE': ({'M2V1-11'}, {'UNSURE', 'UNDECIDED'}, 'EXPLICIT_UNCERTAINTY'),
    }
    output = validate_supported_discovery(raw, packet, item_definitions, set(rules))
    declarations = {row['item_key']: row for row in packet['declarations']}
    for issue in output.issues:
        keys, codes, signal = rules[issue.rule_id]
        if (issue.kind != 'INFORMATION_GAP' or issue.discovery_signal != signal or
                len(issue.source_refs) != 1):
            raise WorkflowHeld('BDJ_TRIAL_RULE_SIGNAL_MISMATCH')
        ref = issue.source_refs[0]
        source = declarations.get(ref.item_key)
        if not source or ref.item_key not in keys:
            raise WorkflowHeld('BDJ_TRIAL_RULE_SOURCE_MISMATCH')
        values = source['value'] if isinstance(source['value'], list) else [source['value']]
        if len(values) != 1 or values[0] not in codes or ref.quote != values[0]:
            raise WorkflowHeld('BDJ_TRIAL_RULE_SOURCE_MISMATCH')
    return output


def project_declared_signals(packet, item_definitions):
    """Return bounded pointers, after source authorization by the caller.

    Item definitions must come from the registered version, not provider data.
    No inference about assumptions, inconsistencies, demand or viability is made.
    """
    verify_projection(packet)
    if packet.get('instrument_version') != M2V1_VERSION or packet.get('confirmed') is not True:
        raise WorkflowHeld('BDJ_CONFIRMED_M2V1_REQUIRED')
    items = {item['item_key']: item for item in item_definitions}
    if len(items) != len(item_definitions):
        raise WorkflowHeld('BDJ_CODEBOOK_INVALID')
    signals = []
    declarations = {row['item_key']: row for row in packet['declarations']}

    def add(signal, meaning, rows):
        signals.append({'classification': signal, 'meaning': meaning,
            'source_refs': [{'item_key': row['item_key'],
                'answer_revision_id': row['answer_revision_id'],
                'item_version_id': row['item_version_id']} for row in rows]})

    def selected(row):
        value = row.get('value')
        values = value if isinstance(value, list) else [value]
        item = items.get(row['item_key'])
        if (not item or str(item.get('id')) != str(row.get('item_version_id')) or
                str(item.get('instrument_id')) != str(packet.get('instrument_id')) or
                digest({k: str(v) if isinstance(v, UUID) else v for k, v in item.items()}) != row.get('definition_digest')):
            raise WorkflowHeld('BDJ_CODEBOOK_ITEM_MISMATCH')
        options = item.get('option_values') or {}
        allowed = {option['code'] for option in options.get('options', [])}
        # 05 and 10 are dynamically derived from 04 and 09 respectively.
        if row['item_key'] in {'M2V1-05', 'M2V1-10'}:
            prior = declarations.get('M2V1-04' if row['item_key'] == 'M2V1-05' else 'M2V1-09')
            if not prior or prior.get('answer_state') != 'ANSWERED':
                raise WorkflowHeld('BDJ_CODEBOOK_DEPENDENCY_MISSING')
            rules = options.get('rules', {})
            allowed = set(selected(prior)) - set(rules.get('exclude', []))
            if rules.get('allow_undecided') is True:
                allowed.add('UNDECIDED')
        if not values or any(not isinstance(v, str) or v not in allowed for v in values):
            raise WorkflowHeld('BDJ_CODEBOOK_VALUE_INVALID')
        exclusive = set(options.get('rules', {}).get('exclusive', []))
        if len(values) > 1 and exclusive.intersection(values):
            raise WorkflowHeld('BDJ_CODEBOOK_VALUE_INVALID')
        return values

    for key in ('M2V1-01', 'M2V1-02', 'M2V1-03', 'M2V1-04', 'M2V1-05',
                'M2V1-06', 'M2V1-07', 'M2V1-08', 'M2V1-09', 'M2V1-10', 'M2V1-11'):
        row = declarations.get(key)
        if not row or row.get('answer_state') != 'ANSWERED':
            continue
        if key == 'M2V1-07':
            service = declarations.get('M2V1-02')
            if not service or service.get('answer_state') != 'ANSWERED':
                raise WorkflowHeld('BDJ_CODEBOOK_DEPENDENCY_MISSING')
            if selected(service) == ['DELIVERY']:
                raise WorkflowHeld('BDJ_SOURCE_NOT_APPLICABLE')
        if key == 'M2V1-11':
            priority = declarations.get('M2V1-10')
            if not priority or priority.get('answer_state') != 'ANSWERED':
                raise WorkflowHeld('BDJ_CODEBOOK_DEPENDENCY_MISSING')
            selected(priority)
        values = selected(row)
        if key in {'M2V1-01','M2V1-02','M2V1-03','M2V1-04','M2V1-05','M2V1-06','M2V1-07','M2V1-11'} and any(
                value in {'UNDECIDED', 'UNSURE'} for value in values):
            add('EXPLICIT_UNCERTAINTY', 'DECLARED_UNDECIDED', [row])
        if key in {'M2V1-09', 'M2V1-10'} and values != ['NONE']:
            add('INFORMATION_INTEREST', 'DECLARED_RESEARCH_INTEREST', [row])
        if key == 'M2V1-08':
            meaning = ('NO_INFORMATION_DECLARED' if values == ['NONE'] else
                       'INFORMATION_AVAILABILITY_UNKNOWN' if values == ['UNKNOWN'] else
                       'DECLARED_SOURCE_NOT_INDEPENDENTLY_VERIFIED')
            add('EVIDENCE_LIMITATION', meaning, [row])
    # A declared priority and position provide only a broad decision context.
    priority, position = declarations.get('M2V1-10'), declarations.get('M2V1-11')
    if priority and position and priority.get('answer_state') == position.get('answer_state') == 'ANSWERED':
        selected(priority)
        selected(position)
        add('DECISION_NEED', 'RESEARCH_PRIORITY_AND_POSITION_ONLY', [priority, position])
    return {'contract_version': CONTRACT_VERSION, 'status': STATUS,
            'source_fingerprint': packet['source_fingerprint'], 'signals': signals}
