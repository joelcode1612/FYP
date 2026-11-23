"""Offline transport contract tests; live PostgreSQL/RPC integration is separate."""
import httpx
import pytest
from sitewise.services.assignment_sync_worker import deliver, request_headers, retry_delay

EVENT = {'listing_id': 9235, 'revision': 42, 'operation': 'upsert', 'snapshot': {'listing_id': 9235, 'agent_id': 2}}

@pytest.mark.parametrize('status', ['applied', 'already_applied'])
def test_confirmed(status):
    def handle(request):
        assert request.url.path == '/rest/v1/rpc/sync_agent_assignment'
        assert request.headers['apikey'] == 'sb_secret_test'
        assert 'authorization' not in request.headers
        import json
        assert json.loads(request.content)['p_snapshot'] == EVENT['snapshot']
        return httpx.Response(200, json={'status': status, 'revision': 42})
    with httpx.Client(transport=httpx.MockTransport(handle)) as c:
        assert deliver(c, 'https://example.supabase.co', 'sb_secret_test', EVENT) is None

@pytest.mark.parametrize('body,expected', [({'status':'mapping_required'}, 'mapping_required'),
    ({'status':'mapping_changed'}, 'mapping_changed'), ({'status':'applied','revision':41}, 'invalid_sync_revision'),
    ({'status':'applied','revision':True}, 'invalid_sync_revision'), ([], 'invalid_sync_response')])
def test_blocked(body, expected):
    with httpx.Client(transport=httpx.MockTransport(lambda r:httpx.Response(200,json=body))) as c:
        assert deliver(c,'https://example.supabase.co','sb_secret_test',EVENT)==expected

def test_http_failure_sanitized():
    with httpx.Client(transport=httpx.MockTransport(lambda r:httpx.Response(409,text='private values'))) as c:
        assert deliver(c,'https://example.supabase.co','sb_secret_test',EVENT)=='supabase_http_409'

def test_transport_error():
    def fail(r): raise httpx.ConnectError('unavailable', request=r)
    with httpx.Client(transport=httpx.MockTransport(fail)) as c:
        assert deliver(c,'https://example.supabase.co','sb_secret_test',EVENT)=='supabase_connection_failed'

def test_delete_payload():
    def handle(r):
        import json
        payload=json.loads(r.content)
        assert payload['p_operation']=='delete' and payload['p_snapshot'] is None
        return httpx.Response(200,json={'status':'applied','revision':43})
    with httpx.Client(transport=httpx.MockTransport(handle)) as c:
        assert deliver(c,'https://example.supabase.co','sb_secret_test',{**EVENT,'operation':'delete','snapshot':None,'revision':43}) is None

def test_headers_and_retry():
    assert request_headers('legacy')['Authorization']=='Bearer legacy'
    assert retry_delay(1)==2 and retry_delay(100)<=300
