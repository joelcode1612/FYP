"""Default-off composition of the existing trial, source, registry and ledger.

No approval writer, alternate endpoint, model runner or result store lives here.
The normal HTTP actions accept only an assessment ID and expected revision.
"""
import hashlib
import importlib.util
from pathlib import Path
from uuid import UUID

from sitewise.core.config import settings
from sitewise.project1.bdj import SYNTHETIC_M2V1_RULESET_SHA256
from sitewise.project1.bdj_discovery_candidate import DiscoveryOutputCandidate
from sitewise.project1.contracts import WorkflowHeld, digest
from sitewise.project1.database_identity import verify_workflow_database
from sitewise.project1.disclosure import RegisteredSyntheticBdjDisclosure, SyntheticBdjAuthorization
from sitewise.project1.key_custody import LocalKeyCustody
from sitewise.project1.ledger import PostgresAttemptLedger
from sitewise.project1.model_assisted import run_registered_synthetic_bdj_trial, _response
from sitewise.project1.prompts import Prompt
from sitewise.project1.provider import ENDPOINT, MODEL
from sitewise.project1.result_store import BdjResultStore
from sitewise.project1.synthetic_trial_registry import PrivateSyntheticTrialRegistry
from sitewise.repositories.m2_repository import SqlModelM2Repository


def prepare_registered_trial(*, session, user, assessment_id, revision, packet_source,
                             runtime, runner_factory):
    if (not settings.project1_synthetic_bdj_trial_enabled or
            not settings.m2_protected_identity_enabled):
        raise WorkflowHeld('BDJ_TRIAL_DISABLED')
    verify_workflow_database(session, private_only=True)
    envelope = packet_source(session, user, assessment_id, revision, include_inventory=True)
    packet = envelope['projection']
    definitions = SqlModelM2Repository(session).list_items(UUID(packet['instrument_id']))
    registry = PrivateSyntheticTrialRegistry(runtime, user.user_id,
        verify_private_instance=lambda s: verify_workflow_database(s, private_only=True))
    record = registry.get_server_authorization(assessment_id=assessment_id,
        revision=revision, fingerprint=packet['source_fingerprint'])
    schema_hash = digest(DiscoveryOutputCandidate.model_json_schema())
    if (not isinstance(record, dict) or record.get('output_schema_sha256') != schema_hash or
            record.get('inventory_fingerprint') != envelope['item_inventory']['inventory_fingerprint']):
        raise WorkflowHeld('BDJ_TRIAL_SCHEMA_INVENTORY_AUTHORIZATION_REQUIRED')
    # This exact historical artifact is authorized for synthetic conformance
    # only. It remains excluded from the production rules registry.
    rules_path = Path(__file__).resolve().parents[3] / 'tools/cp13_verification/v2/bdj_m2v1_information_gap_proposal.py'
    if hashlib.sha256(rules_path.read_bytes()).hexdigest() != SYNTHETIC_M2V1_RULESET_SHA256:
        raise WorkflowHeld('BDJ_TRIAL_RULE_ARTIFACT_MISMATCH')
    spec = importlib.util.spec_from_file_location('sitewise_bdj_scoped_trial', rules_path)
    rules = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rules)
    try:
        prompt_bytes = Path(settings.project1_synthetic_bdj_prompt_path).read_bytes()
        if hashlib.sha256(prompt_bytes).hexdigest() != settings.project1_synthetic_bdj_prompt_sha256:
            raise WorkflowHeld('BDJ_TRIAL_PROMPT_ARTIFACT_MISMATCH')
        prompt = Prompt('BDJ-M2V1-INFO-GAP-TEST-1.0.1',
            'You are a bounded business declaration reviewer.', prompt_bytes.decode('utf-8'))
        run_id = UUID(record['run_id'])
        authorization = SyntheticBdjAuthorization(run_id=str(run_id),
            source_fingerprint=packet['source_fingerprint'], operator_receipt=record['approval_receipt'])
    except (OSError, ValueError, KeyError, UnicodeError):
        raise WorkflowHeld('BDJ_TRIAL_ARTIFACT_OR_AUTHORIZATION_UNAVAILABLE') from None

    def current_source():
        current = packet_source(session, user, assessment_id, revision, include_inventory=True)
        if current['item_inventory']['inventory_fingerprint'] != envelope['item_inventory']['inventory_fingerprint']:
            raise WorkflowHeld('BDJ_TRIAL_INVENTORY_SOURCE_MISMATCH')
        p = current['projection']
        return dict(owner_id=str(user.user_id), assessment_id=p['assessment_id'],
            revision=p['assessment_revision'], confirmation_id=p['confirmation']['confirmation_id'],
            source_fingerprint=p['source_fingerprint'])

    disclosure = RegisteredSyntheticBdjDisclosure(authorization, registry=registry,
        current_source=current_source, owner_id=user.user_id, assessment_id=assessment_id,
        revision=revision, confirmation_id=packet['confirmation']['confirmation_id'],
        rules_sha256=SYNTHETIC_M2V1_RULESET_SHA256, prompt_fingerprint=prompt.fingerprint,
        request_sha256=record.get('request_sha256'))
    # The server registry classifies the source. Never mutate the historical
    # projection fingerprint by adding a client/fixture synthetic marker.
    disclosure.require_current('BDJ', packet, ENDPOINT, MODEL)
    ledger = PostgresAttemptLedger(runtime, user.user_id, run_id)
    runner = runner_factory(ledger, disclosure, {'BDJ': prompt})
    store = BdjResultStore(runtime, user.user_id, run_id, payload_custody=LocalKeyCustody())
    return dict(enabled=True, packet=packet, item_definitions=definitions, rules=rules,
        runner=runner, store=store, inventory_envelope=envelope,
        current_fingerprint=lambda: current_source()['source_fingerprint'])


def execute_registered_trial(**kwargs):
    prepared = prepare_registered_trial(**kwargs)
    stored = run_registered_synthetic_bdj_trial(**prepared)
    return _response(stored, prepared['packet'], stored['review_outcome'])
