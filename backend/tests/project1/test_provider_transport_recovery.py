"""Offline transport regression tests for sitewise.project1.provider.

Copy of the supplied R01 test, bound to the real ``sitewise.project1.contracts``
and extended to cover the model-identity record. No outbound requests:
``httpx.MockTransport`` only.
"""
import json

import httpx
import pytest
from pydantic import BaseModel, SecretStr

from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.provider import MODEL, ModelRunner, TokenHarbor


class SmallOutput(BaseModel):
    issues: list[str]


class StubPrompt:
    version = 'synthetic-test-v1'
    fingerprint = 'synthetic-only'

    def messages(self, packet, schema):
        return [{'role': 'user', 'content': 'synthetic only'}]


class StubLedger:
    def __init__(self):
        self.reservations = []
        self.reservation_kwargs = []
        self.finishes = []
        self.finish_kwargs = []

    def reserve(self, *args, **kwargs):
        # Positional arguments stay flat because these tests index them; the
        # keyword arguments are recorded beside them rather than merged in.
        self.reservations.append(args)
        self.reservation_kwargs.append(kwargs)
        return len(self.reservations)

    def finish(self, *args, **kwargs):
        # DD-055 records two bounded provider facts with the receipt
        # (``model_returned``, ``provider_response_status``). The double accepts
        # them rather than asserting an older signature: these tests are about
        # transport behaviour, and a double that cannot accept what the real
        # ledger accepts tests the double instead of the code.
        self.finishes.append(args)
        self.finish_kwargs.append(kwargs)


class StubDisclosure:
    def require_current(self, stage, packet, endpoint, model):
        assert stage == 'BDJ'
        assert packet['synthetic'] is True


def _runner(handler, *, identity_exception=False, model=None):
    ledger = StubLedger()
    provider = TokenHarbor(
        SecretStr('test-secret-not-real'),
        enabled=True,
        identity_exception=identity_exception,
        transport=httpx.MockTransport(handler),
        **({'model': model} if model else {}),
    )
    runner = ModelRunner(provider, ledger, {'BDJ': StubPrompt()}, disclosure=StubDisclosure())
    return runner, ledger


def _ok_body(content: str, model: str = MODEL) -> dict:
    return {'model': model,
            'choices': [{'finish_reason': 'stop', 'message': {'content': content}}]}


def test_bad_gzip_header_fails_closed_and_consumes_exactly_one_attempt():
    requests = []

    def handler(request):
        requests.append(request)
        assert request.headers['accept-encoding'] == 'identity'
        return httpx.Response(
            200,
            headers={'Content-Encoding': 'gzip', 'Content-Type': 'application/json'},
            content=b'{"model":"not-compressed"}',
        )

    runner, ledger = _runner(handler)
    with pytest.raises(WorkflowHeld, match='E_PROVIDER_RESPONSE_DECODE_OUTCOME_UNKNOWN'):
        runner('BDJ', {'synthetic': True}, SmallOutput)
    assert len(requests) == 1
    assert len(ledger.reservations) == 1
    assert len(ledger.finishes) == 1
    assert ledger.finishes[0][1] == 'unknown_outcome'
    assert ledger.finishes[0][2] is None
    assert runner.last_identity is None


def test_valid_uncompressed_response_survives_and_finishes_returned():
    requests = []

    def handler(request):
        requests.append(request)
        assert request.headers['accept-encoding'] == 'identity'
        return httpx.Response(200, json=_ok_body(json.dumps({'issues': []})))

    runner, ledger = _runner(handler)
    assert runner('BDJ', {'synthetic': True}, SmallOutput) == {'issues': []}
    assert len(requests) == 1
    assert ledger.finishes[0][1] == 'returned'


def test_structured_output_failure_is_not_mistaken_for_decode_unknown():
    def handler(request):
        return httpx.Response(200, json={'model': MODEL, 'choices': []})

    runner, ledger = _runner(handler)
    with pytest.raises(WorkflowHeld, match='PROVIDER_INCOMPLETE_RESPONSE'):
        runner('BDJ', {'synthetic': True}, SmallOutput)
    assert ledger.finishes[0][1] == 'rejected'


def test_exact_model_identity_is_recorded_as_verified():
    def handler(request):
        return httpx.Response(200, json=_ok_body(json.dumps({'issues': []})))

    runner, _ = _runner(handler)
    runner('BDJ', {'synthetic': True}, SmallOutput)
    assert runner.last_identity == {
        'requested_model': MODEL,
        'returned_model': MODEL,
        'classification': 'EXACT_MATCH',
        'identity_verified': True,
    }


def test_unqualified_model_requires_the_explicit_test_exception():
    # The exception tolerates exactly one alternative identity: the configured
    # model with its ``:free`` qualifier removed (``_unqualified``). It is
    # deliberately single-valued, so the excusal path only exists for a model
    # that carries that qualifier.
    #
    # This test used to derive the alternative as ``MODEL.partition(':')[0]``.
    # MODEL has no qualifier, so that returned MODEL itself, the handler echoed
    # an exact match, and the excusal branch was never reached — the test was
    # asserting a refusal it could no longer produce. The pair below is built so
    # the qualified and unqualified labels genuinely differ.
    qualified = f'{MODEL}:free'
    unqualified = MODEL

    def handler(request):
        return httpx.Response(200, json=_ok_body(json.dumps({'issues': []}), model=unqualified))

    strict_runner, strict_ledger = _runner(handler, model=qualified)
    with pytest.raises(WorkflowHeld, match='PROVIDER_MODEL_MISMATCH'):
        strict_runner('BDJ', {'synthetic': True}, SmallOutput)
    assert strict_ledger.finishes[0][1] == 'rejected'

    excused_runner, _ = _runner(handler, identity_exception=True, model=qualified)
    assert excused_runner('BDJ', {'synthetic': True}, SmallOutput) == {'issues': []}
    assert excused_runner.last_identity == {
        'requested_model': qualified,
        'returned_model': unqualified,
        'classification': 'MODEL_IDENTITY_UNVERIFIED_TEST_EXCEPTION',
        'identity_verified': False,
    }


def test_identity_record_never_leaks_from_an_earlier_call():
    calls = []

    def handler(request):
        calls.append(request)
        if len(calls) == 1:
            return httpx.Response(200, json=_ok_body(json.dumps({'issues': []})))
        return httpx.Response(500, json={'error': 'synthetic'})

    runner, ledger = _runner(handler)
    runner('BDJ', {'synthetic': True}, SmallOutput)
    assert runner.last_identity['identity_verified'] is True

    # The second dispatch fails before any envelope is parsed. It must not
    # inherit the first call's verified identity.
    with pytest.raises(WorkflowHeld, match='PROVIDER_TEMPORARILY_UNAVAILABLE'):
        runner('BDJ', {'synthetic': True}, SmallOutput)
    assert len(calls) == 2
    assert runner.last_identity is None
    assert ledger.finishes[1][1] == 'rejected'
