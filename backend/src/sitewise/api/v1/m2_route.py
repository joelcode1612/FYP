"""Presentation mapping for missing M2 storage and domain input failures."""
from fastapi import HTTPException
from fastapi.routing import APIRoute
from sqlalchemy.exc import SQLAlchemyError

from sitewise.modules.decision_engine.domain.m2_rules import M2ValidationError
from sitewise.domain.m2_provenance import M2ConfirmationConflict


class M2SourceRoute(APIRoute):
    def get_route_handler(self):
        handler = super().get_route_handler()
        async def guarded(request):
            try:
                return await handler(request)
            except M2ConfirmationConflict as exc:
                raise HTTPException(409, detail={'code':exc.code,'message':str(exc)},
                                    headers={'Cache-Control':'no-store'}) from exc
            except M2ValidationError as exc:
                raise HTTPException(422, detail={'code':'M2_DECLARATION_INVALID',
                    'message':'A saved declaration is invalid for the current questionnaire conditions. Review and save it again.'}) from exc
            except SQLAlchemyError as exc:
                raise HTTPException(503, detail={'code':'M2_SOURCE_UNAVAILABLE',
                    'message':'Required M2 source storage is unavailable. The operation did not complete.'},
                    headers={'Cache-Control':'no-store'}) from exc
        return guarded
