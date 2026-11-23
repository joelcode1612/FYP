"""Server-only TokenHarbor adapter; no retry/downgrade and no body/error logging."""
import json
import hashlib
import logging
import math
import time

import httpx
from pydantic import SecretStr

from sitewise.project1.contracts import WorkflowHeld

ENDPOINT = 'https://tokenharbor.ai/v1/chat/completions'
MODEL = 'deepseek-v4.1-flash-1017'
MAX_RESPONSE_BYTES = 128_000

# Development-evaluation only. A provider that reports the same model without
# its ``:free`` qualifier is not proof that a different model served the call,
# but it is also not proof that the requested one did. The classification is
# therefore a NEGATIVE result: identity remains unverified, and every consumer
# must treat the response as unverified rather than as an exact match.
TEST_IDENTITY_EXCEPTION = 'MODEL_IDENTITY_UNVERIFIED_TEST_EXCEPTION'
EXACT_IDENTITY = 'EXACT_MATCH'


def _unqualified(model: str) -> str | None:
    """The only alternative identity the test exception may accept.

    Deliberately exact and single-valued: the configured model with its
    ``:free`` qualifier removed. No prefix, case-folding or version matching,
    so the exception cannot widen into "any model by this vendor".
    """
    head, sep, tail = model.partition(':')
    return head if sep and tail == 'free' and head else None


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
                 timeout=30, transport=None, identity_exception=False, model=MODEL,
                 endpoint=None):
        self._key = key
        self.enabled, self.mode = enabled, structured_mode
        # Defaults to the adopted endpoint. An override exists for the standalone
        # diagnostic script, which may point at an equivalent OpenAI-compatible
        # host; it must be HTTPS, and the default keeps production identical.
        self.endpoint = endpoint or ENDPOINT
        self.timeout, self.transport = timeout, transport
        # Defaults to the adopted model. An explicit override exists only for
        # the separately authorised availability fallback; identity checks below
        # compare against whatever is configured here, never against a constant.
        self.model = model
        # Strict by default. When enabled, ONLY the single ``_unqualified``
        # alternative is tolerated, and the outcome is recorded as unverified.
        self.identity_exception = identity_exception
        self.last_identity: dict | None = None
        self.last_execution: dict | None = None
        # Opt-in, content-free timing. Never holds prompts, answers, headers or
        # credentials — only phases and sizes, so an unknown outcome can be
        # diagnosed without widening disclosure.
        self.telemetry: dict | None = None

    def prepare_payload(self, messages, output_type):
        """Build the exact provider payload without opening a network connection."""
        if self.mode not in {'json_schema', 'json_object'}:
            raise WorkflowHeld('PROVIDER_STRUCTURED_MODE_UNVERIFIED')
        schema = output_type.model_json_schema()
        response_format = {'type': self.mode}
        if self.mode == 'json_schema':
            response_format['json_schema'] = {'name': output_type.__name__,
                                             'strict': True, 'schema': schema}
        payload = {'model': self.model, 'messages': messages, 'temperature': 0,
                   'max_tokens': 4000, 'stream': False, 'response_format': response_format}
        if len(json.dumps(payload).encode()) > 64_000:
            raise WorkflowHeld('PROVIDER_INPUT_TOO_LARGE')
        return payload

    def complete(self, messages: list[dict], output_type):
        # Reset per call: an earlier call's identity must never be attributed to
        # a later one that failed before its envelope was parsed.
        self.last_identity = None
        self.last_execution = {'model_requested': self.model, 'model_returned': None,
            'identity_verified': False, 'http_status': None, 'usage': None,
            'provider_reported_cost': None, 'cost_currency': None,
            'schema_validation': 'NOT_VALIDATED', 'dispatched': False, 'dispatch_attempted': False}
        # Socket inactivity timeouts alone allow a slow stream to run indefinitely.
        # This acceptance deadline also covers serialization and local validation.
        if (isinstance(self.timeout, bool) or not isinstance(self.timeout, (int, float))
                or not math.isfinite(self.timeout) or self.timeout <= 0):
            raise WorkflowHeld('PROVIDER_BUDGET_INVALID')
        deadline = time.monotonic() + self.timeout
        started = deadline - self.timeout
        telemetry = self.telemetry
        if telemetry is not None:
            telemetry.clear()
            telemetry['phase'] = 'request_built'

        def remaining():
            value = deadline - time.monotonic()
            if value <= 0:
                # A dispatched POST may have completed upstream. Do not retry.
                raise WorkflowHeld('E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN')
            return value

        if not self.enabled or not self._key.get_secret_value():
            raise WorkflowHeld('PROVIDER_NOT_CONFIGURED')
        payload = self.prepare_payload(messages, output_type)
        if telemetry is not None:
            telemetry['request_bytes'] = len(json.dumps(payload).encode())
            telemetry['phase'] = 'dispatch'
        try:
            # follow_redirects=False prevents redirecting the bearer credential.
            budget = remaining()
            with httpx.Client(timeout=httpx.Timeout(budget, connect=min(5, budget)),
                              follow_redirects=False, transport=self.transport) as client:
                self.last_execution.update(dispatch_attempted=True, dispatched=None)
                with client.stream('POST', self.endpoint, headers={
                        'Authorization': 'Bearer ' + self._key.get_secret_value(),
                        'Cache-Control': 'no-store', 'Content-Type': 'application/json',
                        # Request an uncompressed response from providers/proxies.
                        # If ignored or misreported, decoding still fails closed below.
                        'Accept-Encoding': 'identity'},
                        json=payload) as response:
                    remaining()
                    if telemetry is not None:
                        telemetry['status_code'] = response.status_code
                        telemetry['headers_seconds'] = round(
                            time.monotonic() - started, 3)
                        telemetry['phase'] = 'reading_body'
                    self.last_execution.update(http_status=response.status_code, dispatched=True)
                    if response.status_code != 200:
                        if response.status_code in {401, 403}:
                            raise WorkflowHeld('PROVIDER_CREDENTIALS_REJECTED')
                        if response.status_code == 429:
                            raise WorkflowHeld('PROVIDER_RATE_LIMITED')
                        if 500 <= response.status_code < 600:
                            raise WorkflowHeld('PROVIDER_TEMPORARILY_UNAVAILABLE')
                        raise WorkflowHeld('PROVIDER_HTTP_REJECTED')
                    body = bytearray()
                    for chunk in response.iter_bytes():
                        remaining()
                        body.extend(chunk)
                        if len(body) > MAX_RESPONSE_BYTES:
                            raise WorkflowHeld('PROVIDER_RESPONSE_TOO_LARGE')
                if telemetry is not None:
                    telemetry['body_bytes'] = len(body)
                    telemetry['body_seconds'] = round(time.monotonic() - started, 3)
                    telemetry['phase'] = 'parsing'
            remaining()
            envelope = strict_json(body.decode('utf-8'))
            if not isinstance(envelope,dict):
                raise WorkflowHeld('PROVIDER_INVALID_STRUCTURED_RESPONSE')
            self.last_execution['response_sha256'] = hashlib.sha256(body).hexdigest()
            returned = envelope.get('model')
            # Metadata is bounded and allow-listed; no provider text, headers,
            # source records, credentials or arbitrary envelope fields escape.
            self.last_execution['model_returned'] = returned if isinstance(returned,str) and len(returned)<=128 else None
            usage = envelope.get('usage')
            if isinstance(usage,dict):
                counts = {k:v for k,v in usage.items() if k in {
                    'prompt_tokens','completion_tokens','total_tokens'} and
                    isinstance(v,int) and not isinstance(v,bool) and 0<=v<=100_000_000}
                self.last_execution['usage'] = counts or None
                cost = usage.get('cost')
                if isinstance(cost,(int,float)) and not isinstance(cost,bool) and math.isfinite(cost) and cost>=0:
                    self.last_execution['provider_reported_cost'] = cost
                    self.last_execution['cost_currency'] = usage.get('cost_currency') if usage.get('cost_currency') in {'USD','MYR'} else None
            self.last_identity = self._check_identity(envelope.get('model'))
            self.last_execution['identity_verified'] = self.last_identity['identity_verified']
            choices = envelope['choices']
            if len(choices) != 1 or choices[0]['finish_reason'] != 'stop':
                raise WorkflowHeld('PROVIDER_INCOMPLETE_RESPONSE')
            message = choices[0]['message']
            if message.get('tool_calls') or message.get('refusal'):
                raise WorkflowHeld('PROVIDER_UNEXPECTED_ACTION')
            content = message['content']
            if not isinstance(content, str):
                raise WorkflowHeld('PROVIDER_INVALID_ENVELOPE')
            result = output_type.model_validate(strict_json(content)).model_dump()
            self.last_execution['schema_validation'] = 'VALID'
            remaining()
            return result
        except httpx.DecodingError:
            # A malformed Content-Encoding response may arrive after the provider
            # has already processed the request. It cannot be retried safely, and
            # the bytes are possibly corrupt, so they are never parsed.
            self.last_execution['failure_code']='E_PROVIDER_RESPONSE_DECODE_OUTCOME_UNKNOWN'
            raise WorkflowHeld('E_PROVIDER_RESPONSE_DECODE_OUTCOME_UNKNOWN') from None
        except httpx.TransportError:
            # Dispatch may have completed upstream. Never repeat a POST automatically.
            self.last_execution['failure_code']='E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN'
            raise WorkflowHeld('E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN') from None
        except WorkflowHeld as exc:
            self.last_execution['failure_code']=str(exc)
            raise
        except (ValueError, TypeError, KeyError, IndexError):
            self.last_execution['failure_code']='PROVIDER_INVALID_STRUCTURED_RESPONSE'
            raise WorkflowHeld('PROVIDER_INVALID_STRUCTURED_RESPONSE') from None

    def _check_identity(self, returned) -> dict:
        """Enforce model identity. Strict unless the narrow test exception is on.

        Returns the record that must travel with the result. Raises
        ``PROVIDER_MODEL_MISMATCH`` for anything that is not an exact match or,
        when explicitly enabled, the single documented ``:free`` variant.
        """
        if self.telemetry is not None:
            # Model name is public metadata, not prompt or answer content. It is
            # recorded even on refusal so a mismatch can be diagnosed without
            # another dispatch.
            self.telemetry['returned_model'] = returned
        if returned == self.model:
            return {'requested_model': self.model, 'returned_model': returned,
                    'classification': EXACT_IDENTITY, 'identity_verified': True}
        if self.identity_exception and returned == _unqualified(self.model):
            # Tolerated for development evaluation ONLY. identity_verified stays
            # False: the caller must not treat this as an exact match.
            return {'requested_model': self.model, 'returned_model': returned,
                    'classification': TEST_IDENTITY_EXCEPTION,
                    'identity_verified': False}
        raise WorkflowHeld('PROVIDER_MODEL_MISMATCH')


class ModelRunner:
    """Ledger reservation commits BEFORE dispatch. All failures consume the attempt."""
    #: Tells callers this runner can select a prompt independently of the governed
    #: ledger stage. Contract 2.0 needs it: the ledger stage stays ``QG`` (a
    #: registered governance stage, and the value the attempts table accepts)
    #: while the prompt is ``QG_PROPOSE`` — a different prompt, same stage. Without
    #: this the ledger would have to learn a new stage name, which is a schema
    #: change for what is really a prompt-version distinction.
    supports_prompt_key = True

    def __init__(self, provider, ledger, prompts, *, disclosure):
        self.provider, self.ledger, self.prompts, self.disclosure = provider, ledger, prompts, disclosure
        # The disclosure adapter is bound to the model actually requested, so an
        # authorised fallback cannot silently inherit the primary's identity.
        self.model = getattr(provider, 'model', MODEL)
        self._execution_receipt = None

    @property
    def last_execution(self):
        if self._execution_receipt is None:
            return None
        from copy import deepcopy
        return deepcopy({**(getattr(self.provider,'last_execution',None) or {}), **self._execution_receipt})

    @property
    def last_identity(self) -> dict | None:
        """Identity record of the most recent completed call (for the audit trail)."""
        return getattr(self.provider, 'last_identity', None)

    def __call__(self, stage, packet, output_type, *, prompt_key=None):
        self._execution_receipt = None
        from sitewise.project1.contracts import digest
        # `stage` is the governed ledger label; `prompt_key` selects the template.
        # They are the same by default, and the ledger always records the *actual*
        # prompt version, so the audit trail cannot claim a prompt that did not run.
        prompt = self.prompts[prompt_key or stage]
        # Trusted adapter must verify exact source purpose/consent/version and provider policy.
        self.disclosure.require_current(stage, packet, ENDPOINT, self.model)
        messages = prompt.messages(packet, output_type.model_json_schema())
        if hasattr(self.disclosure, 'require_request'):
            self.disclosure.require_request(self.provider, prompt, messages, output_type)
        request_hash = digest({'messages': messages, 'model': self.model,
                               'schema': output_type.model_json_schema(), 'mode': self.provider.mode})
        attempt = self.ledger.reserve(stage, prompt.version, prompt.fingerprint, request_hash)
        self._execution_receipt = {'stage':stage, 'attempt_no':attempt,
            'prompt_version':prompt.version, 'prompt_sha256':prompt.fingerprint,
            'request_sha256':request_hash, 'receipt_recorded':False}
        try:
            output = self.provider.complete(messages, output_type)
        except WorkflowHeld as exc:
            reason = ('unknown_outcome' if str(exc) in {
                'E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN',
                'E_PROVIDER_RESPONSE_DECODE_OUTCOME_UNKNOWN',
            } else 'rejected')
            self.ledger.finish(attempt, reason, None)
            self._execution_receipt.update(receipt_recorded=True, receipt_outcome=reason)
            raise
        self.ledger.finish(attempt, 'returned', digest(output))
        self._execution_receipt.update(receipt_recorded=True, receipt_outcome='returned', output_sha256=digest(output))
        return output


def configured_runner(ledger, disclosure, prompts):
    """Server composition only; no web caller can choose a provider or credential."""
    from sitewise.core.config import settings
    if settings.tokenharbor_model_identity_exception:
        # Loud on purpose: this must never be enabled silently or in production.
        logging.getLogger("sitewise").warning(
            "TokenHarbor model-identity test exception is ENABLED "
            "(classification=%s). Responses are recorded as unverified.",
            TEST_IDENTITY_EXCEPTION,
        )
    provider = TokenHarbor(settings.tokenharbor_api_key,
        enabled=settings.tokenharbor_enabled,
        structured_mode=settings.tokenharbor_structured_mode,
        timeout=max(1, min(settings.tokenharbor_timeout_seconds, 60)),
        identity_exception=settings.tokenharbor_model_identity_exception)
    return ModelRunner(provider, ledger, prompts, disclosure=disclosure)
