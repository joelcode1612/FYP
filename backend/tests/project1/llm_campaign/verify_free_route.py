"""Verify the configured provider route is genuinely free before any dispatch.

The Owner's standing condition is: use only ``mimo-v2.6-flash:free``, ceiling
USD $0.00, and "verify that the selected provider route is genuinely free before
dispatch". A model *name* ending in ``:free`` is not proof; the catalogue entry's
pricing is. This reads ``/v1/models`` -- a catalogue GET, not a completion -- so
it consumes no budget slot and no completion quota.

Outcomes:
  FREE_ROUTE_CONFIRMED        the catalogue prices this model at zero
  FREE_TIER_UNAVAILABLE       quota exhausted / payment requested / 429
  PRICING_UNCERTAIN           the catalogue does not state a usable price
  CATALOGUE_UNREACHABLE       transport or HTTP failure

Exit code 0 only for FREE_ROUTE_CONFIRMED.
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import httpx

CATALOGUE = 'https://tokenharbor.ai/v1/models'
MODEL = 'mimo-v2.6-flash:free'
ZERO = {'0', '0.0', '0.00', '0.000000', 0, 0.0}


def _zero(value) -> bool:
    return value in ZERO or str(value).strip() in {'0', '0.0', '0.00', '0.000000'}


def verify(*, transport=None, timeout: float = 30.0) -> dict:
    from pydantic import SecretStr
    from sitewise.core.config import settings

    key = settings.tokenharbor_api_key
    result = {'model': MODEL, 'catalogue': CATALOGUE,
              'checked_at': datetime.now(timezone.utc).isoformat(),
              'budget_slot_consumed': False}
    if not isinstance(key, SecretStr) or not key.get_secret_value():
        return {**result, 'outcome': 'CATALOGUE_UNREACHABLE',
                'reason': 'TOKENHARBOR_API_KEY is empty'}
    headers = {'Authorization': f'Bearer {key.get_secret_value()}',
               'Accept': 'application/json',
               # The corporate proxy corrupts compressed bodies (see the
               # E_PROVIDER_RESPONSE_DECODE_OUTCOME_UNKNOWN incident); never
               # negotiate an encoding we cannot decode.
               'Accept-Encoding': 'identity'}
    try:
        with httpx.Client(timeout=timeout, transport=transport,
                          headers=headers) as client:
            response = client.get(CATALOGUE)
    except httpx.TransportError as exc:
        return {**result, 'outcome': 'CATALOGUE_UNREACHABLE',
                'reason': type(exc).__name__}
    result['status'] = response.status_code
    if response.status_code == 429:
        return {**result, 'outcome': 'FREE_TIER_UNAVAILABLE',
                'reason': 'HTTP 429 on the catalogue endpoint'}
    if response.status_code in {401, 403}:
        return {**result, 'outcome': 'CATALOGUE_UNREACHABLE',
                'reason': f'HTTP {response.status_code}: credentials rejected'}
    if response.status_code != 200:
        return {**result, 'outcome': 'CATALOGUE_UNREACHABLE',
                'reason': f'HTTP {response.status_code}'}
    try:
        payload = response.json()
    except ValueError:
        return {**result, 'outcome': 'PRICING_UNCERTAIN',
                'reason': 'catalogue body is not JSON'}
    rows = payload.get('data') if isinstance(payload, dict) else payload
    if not isinstance(rows, list):
        return {**result, 'outcome': 'PRICING_UNCERTAIN',
                'reason': 'catalogue has no data array'}
    entry = next((row for row in rows
                  if isinstance(row, dict) and row.get('id') == MODEL), None)
    if entry is None:
        return {**result, 'outcome': 'FREE_TIER_UNAVAILABLE',
                'reason': 'the configured model is absent from the catalogue',
                'catalogue_size': len(rows)}
    pricing = entry.get('pricing') if isinstance(entry.get('pricing'), dict) else {}
    result['pricing'] = pricing
    result['catalogue_entry_keys'] = sorted(entry)
    if not pricing:
        return {**result, 'outcome': 'PRICING_UNCERTAIN',
                'reason': 'catalogue entry carries no pricing object'}
    priced = {k: v for k, v in pricing.items()
              if any(t in k.lower() for t in ('prompt', 'completion', 'input', 'output',
                                              'request', 'image', 'price'))}
    if not priced:
        return {**result, 'outcome': 'PRICING_UNCERTAIN',
                'reason': 'pricing object has no recognisable price fields'}
    if not all(_zero(v) for v in priced.values()):
        return {**result, 'outcome': 'FREE_TIER_UNAVAILABLE',
                'reason': 'the catalogue prices this model above zero',
                'non_zero': {k: v for k, v in priced.items() if not _zero(v)}}
    return {**result, 'outcome': 'FREE_ROUTE_CONFIRMED', 'reason': None,
            'zero_priced_fields': sorted(priced)}


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    out = None
    if '--out' in argv:
        out = Path(argv[argv.index('--out') + 1])
    result = verify()
    if out is not None:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(result, indent=2, sort_keys=True, default=str),
                       encoding='utf-8')
    print(json.dumps(result, indent=2, sort_keys=True, default=str))
    return 0 if result['outcome'] == 'FREE_ROUTE_CONFIRMED' else 1


if __name__ == '__main__':
    raise SystemExit(main())
