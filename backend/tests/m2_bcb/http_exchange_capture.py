"""Test-only ASGI wire capture, guarded to the freshly initialized local lab.

Records actual request/response bodies for UI and native calls, never bearer
values, cookies or authentication endpoints. No application routes are added.
"""
import base64,json,os,time,threading
from pathlib import Path


class HttpExchangeCapture:
    def __init__(self,app,output):
        assert os.environ.get('M2_BCB_PRIVATE_CLUSTER')
        self.app=app;self.output=Path(output);self.lock=threading.Lock();self.sequence=0

    async def __call__(self,scope,receive,send):
        if scope['type']!='http' or not scope['path'].startswith(('/api/v1/m2/','/api/v1/cq/')):
            return await self.app(scope,receive,send)
        started=time.time();request_body=bytearray();response_body=bytearray();status=None
        headers=dict(scope.get('headers',[]));subject=None
        # Metadata only. Authorization is still verified by the real endpoint.
        try:
            payload=headers.get(b'authorization',b'').decode().split('.')[1]
            subject=json.loads(base64.urlsafe_b64decode(payload+'='*(-len(payload)%4)))['sub']
        except Exception:pass
        async def received():
            message=await receive()
            if message['type']=='http.request':request_body.extend(message.get('body',b''))
            return message
        async def sent(message):
            nonlocal status
            if message['type']=='http.response.start':status=message['status']
            if message['type']=='http.response.body':response_body.extend(message.get('body',b''))
            await send(message)
        try:await self.app(scope,received,sent)
        finally:
            def decode(value):
                if not value:return None
                try:return json.loads(value)
                except Exception:return {'non_json_bytes':len(value)}
            with self.lock:
                self.sequence+=1
                record={'sequence':self.sequence,'scope':'ISOLATED_TEST_ACTUAL_ASGI_HTTP','started_utc':started,
                    'duration_ms':round((time.time()-started)*1000,2),'request_subject_metadata':subject,
                    'request':{'method':scope['method'],'path':scope['path'],'query':scope.get('query_string',b'').decode(),
                        'headers':{'Authorization':'[REDACTED]' if b'authorization' in headers else None},'body':decode(request_body)},
                    'response':{'status':status,'body':decode(response_body)}}
                with self.output.open('a',encoding='utf-8') as f:f.write(json.dumps(record,ensure_ascii=False,default=str)+'\n')
