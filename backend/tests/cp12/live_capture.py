"""Local authorized Fiesta test recorder wrapping the original ASGI app.

Captures only target assessment/M2 routes and Fiesta creation. No headers,
cookies, tokens, or unrelated assessment responses are recorded.
"""
import json, logging, threading
from pathlib import Path

ROOT=Path(__file__).resolve().parents[3];OUT=ROOT/'artifacts/cp12_20261118'
TARGETS=OUT/'live_capture_targets.json';LOG=OUT/'live_http_exchanges.jsonl';LOCK=threading.Lock();MAX=2_000_000
def redact(v):
    if isinstance(v,dict):return {k:('[REDACTED]' if k.lower() in {'authorization','password','access_token','refresh_token','token','cookie','set-cookie'} else redact(x)) for k,x in v.items()}
    if isinstance(v,list):return [redact(x) for x in v]
    return v
def decoded(b):
    if not b:return None
    try:return redact(json.loads(b))
    except (ValueError,UnicodeError):return '[non-JSON omitted]'
class Recorder:
    def __init__(self,app):self.app=app
    async def __call__(self,scope,receive,send):
        if scope['type']!='http':return await self.app(scope,receive,send)
        path=scope['path'];method=scope['method']
        if not path.startswith(('/api/v1/assessments/','/api/v1/m2/assessments/')):return await self.app(scope,receive,send)
        try:
            with LOCK:state=json.loads(TARGETS.read_text())
        except (OSError,ValueError):return await self.app(scope,receive,send)
        create=method=='POST' and path=='/api/v1/assessments/'
        allowed=any(x in path for x in state['marketplace_ids']+state['m2_ids'])
        if not create and not allowed:return await self.app(scope,receive,send)
        events=[];parts=[];size=0
        if method in ('POST','PUT','PATCH'):
            while True:
                event=await receive();events.append(event)
                if event['type']!='http.request':break
                part=event.get('body',b'');size+=len(part)
                if size<=MAX:parts.append(part)
                if not event.get('more_body',False):break
            async def replay():
                if events:return events.pop(0)
                return await receive()
        else:replay=receive
        body=decoded(b''.join(parts)) if size<=MAX else '[request too large]'
        if create:allowed=isinstance(body,dict) and body.get('property_id')==state['property_id']
        if not allowed:return await self.app(scope,replay,send)
        status=None;reply=[];replysize=0
        async def observe(event):
            nonlocal status,replysize
            if event['type']=='http.response.start':status=event['status']
            if event['type']=='http.response.body':
                part=event.get('body',b'');replysize+=len(part)
                if replysize<=MAX:reply.append(part)
                if not event.get('more_body',False):
                    response=decoded(b''.join(reply)) if replysize<=MAX else '[response too large]'
                    try:
                        with LOCK:
                            current=json.loads(TARGETS.read_text())
                            if create and status in (200,201) and isinstance(response,dict):
                                rec=response.get('assessment') or {};aid=rec.get('assessment_id')
                                if aid and rec.get('property_id')==current['property_id'] and aid not in current['marketplace_ids']:current['marketplace_ids'].append(aid)
                            if '/by-marketplace/' in path and path.endswith('/link') and status in (200,201) and isinstance(response,dict):
                                mid=response.get('m2_assessment_id')
                                if mid and mid not in current['m2_ids']:current['m2_ids'].append(mid)
                            TARGETS.write_text(json.dumps(current,indent=2)+'\n')
                            with LOG.open('a',encoding='utf-8') as f:f.write(json.dumps({'method':method,'path':path,'status':status,'request':body,'response':response,'scope':'AUTHORIZED_FIESTA_TEST'},ensure_ascii=False)+'\n')
                    except (OSError,ValueError,TypeError):logging.getLogger(__name__).exception('CP12 evidence capture failed; response unchanged')
            await send(event)
        await self.app(scope,replay,observe)
if __name__=='__main__':
    import uvicorn
    from sitewise.main import app
    uvicorn.run(Recorder(app),host='127.0.0.1',port=8090)
