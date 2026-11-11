"""Server-only TokenHarbor adapter; no retry/downgrade and no body/error logging."""
import json

import httpx
from pydantic import SecretStr

from sitewise.project1.contracts import WorkflowHeld

ENDPOINT = 'https://tokenharbor.ai/v1/chat/completions'
MODEL = 'mimo-v2.6-flash:free'
MAX_RESPONSE_BYTES = 128_000


def strict_json(text: str):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('duplicate key')
            result[key] = value
        return result
    return json.loads(text, object_pairs_hook=pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite')))


class TokenHarbor:
    def __init__(self, key: SecretStr, *, enabled=False, structured_mode='json_schema',
                 timeout=30, transport=None):
        self._key = key
        self.enabled, self.mode = enabled, structured_mode
        self.timeout, self.transport = timeout, transport

    def complete(self, messages: list[dict], output_type):
        if not self.enabled or not self._key.get_secret_value():
            raise WorkflowHeld('PROVIDER_NOT_CONFIGURED')
        if self.mode not in {'json_schema', 'json_object'}:
            raise WorkflowHeld('PROVIDER_STRUCTURED_MODE_UNVERIFIED')
        schema = output_type.model_json_schema()
        response_format = {'type': self.mode}
        if self.mode == 'json_schema':
            response_format['json_schema'] = {'name': output_type.__name__,
                                             'strict': True, 'schema': schema}
        payload = {'model': MODEL, 'messages': messages, 'temperature': 0,
                   'max_tokens': 4000, 'stream': False, 'response_format': response_format}
        if len(json.dumps(payload).encode()) > 64_000:
            raise WorkflowHeld('PROVIDER_INPUT_TOO_LARGE')
        try:
            # follow_redirects=False prevents redirecting the bearer credential.
            with httpx.Client(timeout=httpx.Timeout(self.timeout, connect=5),
                              follow_redirects=False, transport=self.transport) as client:
                with client.stream('POST', ENDPOINT, headers={
                        'Authorization': 'Bearer ' + self._key.get_secret_value(),
                        'Cache-Control': 'no-store', 'Content-Type': 'application/json'},
                        json=payload) as response:
                    if response.status_code != 200:
                        raise WorkflowHeld('PROVIDER_HTTP_REJECTED')
                    body = bytearray()
                    for chunk in response.iter_bytes():
                        body.extend(chunk)
                        if len(body) > MAX_RESPONSE_BYTES:
                            raise WorkflowHeld('PROVIDER_RESPONSE_TOO_LARGE')
            envelope = strict_json(body.decode('utf-8'))
            if envelope.get('model') != MODEL:
                raise WorkflowHeld('PROVIDER_MODEL_MISMATCH')
            choices = envelope['choices']
            if len(choices) != 1 or choices[0]['finish_reason'] != 'stop':
                raise WorkflowHeld('PROVIDER_INCOMPLETE_RESPONSE')
            message = choices[0]['message']
            if message.get('tool_calls') or message.get('refusal'):
                raise WorkflowHeld('PROVIDER_UNEXPECTED_ACTION')
            content = message['content']
            if not isinstance(content, str):
                raise WorkflowHeld('PROVIDER_INVALID_ENVELOPE')
            return output_type.model_validate(strict_json(content)).model_dump()
        except httpx.TransportError:
            # Dispatch may have completed upstream. Never repeat a POST automatically.
            raise WorkflowHeld('E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN') from None
        except WorkflowHeld:
            raise
        except (ValueError, TypeError, KeyError, IndexError):
            raise WorkflowHeld('PROVIDER_INVALID_STRUCTURED_RESPONSE') from None


class ModelRunner:
    """Ledger reservation commits BEFORE dispatch. All failures consume the attempt."""
    def __init__(self, provider, ledger, prompts, *, disclosure):
        self.provider, self.ledger, self.prompts, self.disclosure = provider, ledger, prompts, disclosure

    def __call__(self, stage, packet, output_type):
        from sitewise.project1.contracts import digest
        prompt = self.prompts[stage]
        # Trusted adapter must verify exact source purpose/consent/version and provider policy.
        self.disclosure.require_current(stage, packet, ENDPOINT, MODEL)
        messages = prompt.messages(packet, output_type.model_json_schema())
        request_hash = digest({'messages': messages, 'model': MODEL,
                               'schema': output_type.model_json_schema(), 'mode': self.provider.mode})
        attempt = self.ledger.reserve(stage, prompt.version, prompt.fingerprint, request_hash)
        try:
            output = self.provider.complete(messages, output_type)
        except WorkflowHeld as exc:
            reason = 'unknown_outcome' if str(exc) == 'E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN' else 'rejected'
            self.ledger.finish(attempt, reason, None)
            raise
        self.ledger.finish(attempt, 'returned', digest(output))
        return output


def configured_runner(ledger, disclosure, prompts):
    """Server composition only; no web caller can choose a provider or credential."""
    from sitewise.core.config import settings
    provider = TokenHarbor(settings.tokenharbor_api_key,
        enabled=settings.tokenharbor_enabled,
        structured_mode=settings.tokenharbor_structured_mode,
        timeout=max(1, min(settings.tokenharbor_timeout_seconds, 60)))
    return ModelRunner(provider, ledger, prompts, disclosure=disclosure)
