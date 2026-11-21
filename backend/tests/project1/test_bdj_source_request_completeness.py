"""Offline verification of the preserved explicitly synthetic BDJ source."""
import json
from pathlib import Path

from pydantic import SecretStr

from sitewise.project1.contracts import BDJOutput
from sitewise.project1.prompts import PROMPTS
from sitewise.project1.provider import TokenHarbor


def test_eleven_saved_declarations_survive_actual_prompt_and_payload_builder():
    root = Path(__file__).resolve().parents[3]
    source_path = root / 'artifacts/stage34_integration_20261119/bdj_v101_synthetic_source.json'
    source = json.loads(source_path.read_text(encoding='utf-8-sig'))['packet']
    assert source['confirmed'] and source['confirmation']['confirmation_id']
    declarations = source['declarations']
    assert {d['item_key'] for d in declarations} == {f'M2V1-{n:02d}' for n in range(1, 12)}
    for declaration in declarations:
        for field in ('question', 'item_version_id', 'answer_revision_id', 'answer_revision', 'answer_state'):
            assert declaration[field], (declaration['item_key'], field)
        assert 'value' in declaration
    payload = TokenHarbor(SecretStr('offline-only')).prepare_payload(
        PROMPTS['BDJ'].messages(source, BDJOutput.model_json_schema()), BDJOutput)
    projected = json.loads(payload['messages'][-1]['content'])['source_data']
    assert projected == source
