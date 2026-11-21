"""LLM-01 synthetic campaign preparation. No database, no provider, no network.

The five fixtures under ``fixtures/`` are synthetic, non-human records. They are
loaded here, validated against the registered M2V1-20261114-1 instrument, and
projected through the *production* ``M2SourceProjection`` so the packet handed to
the model runner is built from the versioned instrument fields rather than from
constants in this file.

Nothing in this module dispatches. ``test_llm01_preparation.py`` is the only
caller, and it injects a local ``httpx.MockTransport``.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
from dataclasses import dataclass
from pathlib import Path
from types import SimpleNamespace
from uuid import UUID, uuid4

HERE = Path(__file__).resolve().parent
BACKEND = HERE.parents[2]
FIXTURE_DIR = HERE / 'fixtures'
AUTHORIZATION_PATH = HERE / 'test_scope_authorization.json'

SYNTHETIC_DATA_CLASS = 'SYNTHETIC_NONHUMAN'
SYNTHETIC_PURPOSE = 'SYNTHETIC_BDJ_DIAGNOSTIC'

FIXTURES = {
    'consistent': '01_consistent_declarations.json',
    'contradictory': '02_contradictory_service_format.json',
    'missing': '03_missing_ambiguous.json',
    'confirmed_uncertainty': '04_confirmed_uncertainty.json',
    'requires_clarification': '05_uncertainty_requires_clarification.json',
}


def _register_module():
    """Load the operator's canonical instrument reader without copying it."""
    path = BACKEND / 'scripts' / 'register_m2_v1.py'
    spec = importlib.util.spec_from_file_location('llm01_register_m2_v1', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def instrument():
    """Return ``(definition, schema_digest, instrument_id, item_rows)``.

    ``definition()`` re-reads ``definition.json``, verifies ``source.txt`` against
    the declared ``source_sha256``, and derives the same UUIDv5 instrument id the
    registration script uses. Reusing it means this harness cannot drift from the
    registered source.
    """
    return _register_module().definition()


def load_fixture(name: str) -> dict:
    data = json.loads((FIXTURE_DIR / FIXTURES[name]).read_text(encoding='utf-8'))
    assert data['synthetic'] is True and data['contains_personal_data'] is False
    return data


def authorization() -> dict:
    return json.loads(AUTHORIZATION_PATH.read_text(encoding='utf-8'))


class VersionedInstrumentRepository:
    """In-memory stand-in for ``SqlModelM2Repository`` over the versioned fields.

    Every item field (key, question, options, allowed states, lifecycle) is taken
    from ``definition.json``; only the answer values come from the fixture.
    """

    def __init__(self, *, fixture, actor_id: UUID, assessment_id: UUID):
        self.definition, self.schema_digest, self.instrument_id, self.items = instrument()
        self.actor_id, self.assessment_id = actor_id, assessment_id
        self.rollback_count = 0
        self.answers: dict[str, dict] = {}
        self.revision = 0
        self.confirmed = 'confirmation' in fixture
        self._load_answers(fixture['m2_answers'])

    def _load_answers(self, declared: dict) -> None:
        by_key = {row['item_key']: row for row in self.items}
        unknown = set(declared) - set(by_key)
        assert not unknown, f'fixture uses item keys absent from the instrument: {sorted(unknown)}'
        # Deterministic, instrument-ordered revisions: one saved answer per step.
        for row in sorted(self.items, key=lambda r: r['sort_order']):
            key = row['item_key']
            if key not in declared:
                continue
            entry = declared[key]
            self.revision += 1
            self.answers[key] = {
                'id': uuid4(), 'assessment_id': self.assessment_id,
                'item_version_id': row['id'], 'assessment_revision': self.revision,
                'answer_state': entry['state'], 'value_json': entry['value'],
            }

    # --- the four calls M2SourceProjection makes ---------------------------
    def get_assessment_for_update(self, assessment_id, actor_id):
        if (assessment_id, actor_id) != (self.assessment_id, self.actor_id):
            return None
        return {
            'id': self.assessment_id, 'revision': self.revision,
            'confirmed_revision': self.revision if self.confirmed else None,
            'instrument_id': self.instrument_id,
        }

    def get_instrument(self, instrument_id):
        if instrument_id != self.instrument_id:
            return None
        return {
            'id': self.instrument_id, 'approval_state': 'AUTHORIZED',
            'version_tag': self.definition['version_tag'],
            'schema_digest': self.schema_digest,
        }

    def list_items(self, instrument_id):
        return [dict(row) for row in self.items] if instrument_id == self.instrument_id else []

    def get_latest_answers(self, assessment_id, revision):
        if assessment_id != self.assessment_id:
            return {}
        return {key: dict(value) for key, value in self.answers.items()
                if 0 < value['assessment_revision'] <= revision}

    def rollback(self):
        self.rollback_count += 1


@dataclass(frozen=True)
class Case:
    """One synthetic case: the projected packet plus its versioned source rows."""
    name: str
    fixture: dict
    packet: dict
    items: list
    answers: dict
    revision: int


def build_case(name: str, *, actor_id: UUID | None = None,
               assessment_id: UUID | None = None) -> Case:
    """Project one fixture through the production projection.

    The synthetic markers are part of the fingerprinted content, so
    ``verify_projection`` still passes and the disclosure predicate can decide
    the packet is synthetic. They are not added afterwards as an override.
    """
    from sitewise.project1.contracts import digest
    from sitewise.project1.projection import M2SourceProjection

    fixture = load_fixture(name)
    repo = VersionedInstrumentRepository(
        fixture=fixture, actor_id=actor_id or uuid4(),
        assessment_id=assessment_id or uuid4())
    packet = M2SourceProjection(repo).read(
        repo.assessment_id, repo.actor_id, repo.revision)
    content = {key: value for key, value in packet.items() if key != 'source_fingerprint'}
    content.update({
        'data_class': SYNTHETIC_DATA_CLASS,
        'purpose': SYNTHETIC_PURPOSE,
        'synthetic_fixture_id': fixture['fixture_id'],
    })
    packet = {**content, 'source_fingerprint': digest(content)}
    return Case(name=name, fixture=fixture, packet=packet, items=repo.items,
                answers=repo.get_latest_answers(repo.assessment_id, repo.revision),
                revision=repo.revision)


def expected_item_keys() -> list[str]:
    """The exact registered keys, in instrument order."""
    return [row['item_key'] for row in instrument()[3]]


def source_hash() -> str:
    folder = BACKEND / 'src' / 'sitewise' / 'instruments' / 'm2v1_20261114'
    return hashlib.sha256((folder / 'source.txt').read_bytes()).hexdigest()


class RecordingLedger:
    """Ledger port double: records the reservation order, writes nothing."""

    def __init__(self):
        self.calls: list[tuple] = []

    def reserve(self, stage, prompt_version, prompt_hash, request_hash):
        self.calls.append(('reserve', stage, prompt_version, prompt_hash, request_hash))
        return len(self.calls)

    def finish(self, attempt, outcome, output_digest):
        self.calls.append(('finish', attempt, outcome, output_digest))


def fake_transport(recorder: dict, *, content: str):
    """A local ``httpx.MockTransport`` handler. No socket is opened."""
    import httpx

    def handler(request):
        recorder['requests'] = recorder.get('requests', 0) + 1
        recorder['url'] = str(request.url)
        recorder['method'] = request.method
        recorder['headers'] = dict(request.headers)
        recorder['body'] = json.loads(request.content)
        return httpx.Response(200, json={
            'model': 'mimo-v2.6-flash',
            'choices': [{'finish_reason': 'stop', 'message': {'content': content}}],
        })

    return httpx.MockTransport(handler)


def disclosure_for(packet: dict):
    """The real synthetic-only disclosure adapter, bound to one packet."""
    from sitewise.project1.disclosure import (SyntheticBdjAuthorization,
                                              SyntheticBdjDisclosure)
    return SyntheticBdjDisclosure(SyntheticBdjAuthorization(
        run_id='synthetic-run-llm01',
        source_fingerprint=packet['source_fingerprint'],
        operator_receipt=authorization()['adoption_receipt'],
        data_class=packet.get('data_class'), purpose=packet.get('purpose')))


def runner_for(transport, ledger, packet: dict):
    """Compose the production runner with a fake transport and a stub ledger."""
    from pydantic import SecretStr
    from sitewise.project1.provider import ENDPOINT, MODEL, ModelRunner, TokenHarbor
    from sitewise.project1.prompts import PROMPTS

    provider = TokenHarbor(SecretStr('synthetic-local-transport-key'), enabled=True,
                           # The fake transport reports the canonical model name
                           # without ':free'; this is the explicit dev exception.
                           identity_exception=True,
                           transport=transport)
    runner = ModelRunner(provider, ledger, PROMPTS, disclosure=disclosure_for(packet))
    return SimpleNamespace(runner=runner, provider=provider, endpoint=ENDPOINT, model=MODEL)
