"""Explicit synthetic-only capability probe. No DB, .env reader or real M2 data."""
import argparse
import json
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from pydantic import SecretStr
from sitewise.project1.contracts import BDJOutput, WorkflowHeld
from sitewise.project1.prompts import PROMPTS
from sitewise.project1.provider import TokenHarbor


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--synthetic-only', required=True, action='store_true')
    parser.add_argument('--mode', choices=['json_schema', 'json_object'], default='json_schema')
    args = parser.parse_args()
    provider = TokenHarbor(SecretStr(os.environ.get('TOKENHARBOR_API_KEY', '')),
                           enabled=True, structured_mode=args.mode)
    packet = {'synthetic': True, 'declarations': [], 'note':
              'Synthetic capability test only. Return no issues and a bounded overall_note.'}
    try:
        result = provider.complete(PROMPTS['BDJ'].messages(packet, BDJOutput.model_json_schema()), BDJOutput)
        if result['issues']:
            raise WorkflowHeld('SYNTHETIC_EMPTY_SOURCE_RETURNED_FINDINGS')
        print(json.dumps({'synthetic_only': True, 'model_structured_response': 'passed',
                          'mode': args.mode, 'scientific_acceptance': False}))
        return 0
    except WorkflowHeld as exc:
        # Only controlled adapter codes; never print the provider body or credential.
        print(json.dumps({'synthetic_only': True, 'model_structured_response': 'not_verified',
                          'reason': str(exc)}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
