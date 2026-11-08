"""Unregistered synthetic API factory. Never imported by the production router.

Use a TestClient against create_synthetic_app(service). The service rejects all
configured/shared databases. No fielding route or migration runner is supplied.
"""
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy.exc import IntegrityError

from sitewise.services.customer_questionnaire_candidate import CustomerCandidateService


class StrictBody(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)


class NewSession(StrictBody):
    session_id: str
    locale: str = 'EN'
    q02_policy: str = 'UNDECIDED'
    qualification: str = 'NOT_ASSESSED'
    asset_ids: dict[str, str] = Field(default_factory=dict)
    optional: bool = False


class Revision(StrictBody):
    expected_revision: int = Field(ge=0)


class Display(Revision):
    feature: str = ''


class Answer(Display):
    value: str | list[str] | None
    request_id: str = Field(min_length=1, max_length=80)
    display_id: str


class Pretest(Display):
    check: str
    result: str


def create_synthetic_app(service: CustomerCandidateService) -> FastAPI:
    app = FastAPI(title='CUST03 synthetic candidate — no fielding authorization')

    def call(fn, *args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except ValueError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        except IntegrityError as exc:
            raise HTTPException(status_code=409, detail='Candidate record conflicts with existing history.') from exc

    @app.post('/candidate/sessions', status_code=201)
    def create(payload: NewSession):
        values = payload.model_dump()
        sid = values.pop('session_id')
        return call(service.create, sid, **values)

    @app.get('/candidate/sessions/{sid}/route')
    def route(sid: str):
        return call(service.route, sid)

    @app.post('/candidate/sessions/{sid}/stimuli/{kind}')
    def expose(sid: str, kind: str, payload: Revision):
        return call(service.expose, sid, kind, **payload.model_dump())

    @app.post('/candidate/sessions/{sid}/items/{q}/display')
    def display(sid: str, q: str, payload: Display):
        shown = call(service.show, sid, q, **payload.model_dump())
        item = service.items[q]
        locale = shown['provenance']['locale']
        return {'display': shown, 'question_id': q, 'option_codes': item['codes'],
                'option_labels_en': service.policy['q02_distinct_day_labels'] if q == 'Q02' else None,
                'stem': item['stem'] if locale == 'EN' else None,
                'translation_status': 'PENDING_REVIEW' if locale == 'EN' else 'MISSING_NOT_APPROVED',
                'structured_pretest': service.policy['structured_pretest'][q],
                'fielding_authorized': False}

    @app.post('/candidate/sessions/{sid}/items/{q}/answers')
    def answer(sid: str, q: str, payload: Answer):
        values = payload.model_dump()
        value = values.pop('value')
        return call(service.answer, sid, q, value, **values)

    @app.get('/candidate/sessions/{sid}/history')
    def history(sid: str):
        return call(service.history, sid)

    @app.get('/candidate/sessions/{sid}/items/{q}/counts')
    def counts(sid: str, q: str, feature: str = ''):
        return call(service.counts, sid, q, feature=feature)

    @app.post('/candidate/sessions/{sid}/items/{q}/pretests')
    def pretest(sid: str, q: str, payload: Pretest):
        values = payload.model_dump()
        check, result = values.pop('check'), values.pop('result')
        return call(service.record_pretest, sid, q, check, result, **values)

    return app
