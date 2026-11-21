"""Presentation mapping for missing M2 storage and domain input failures."""
from fastapi import HTTPException
from fastapi.routing import APIRoute
from sqlalchemy.exc import SQLAlchemyError

from sitewise.domain.m2_rules import M2ValidationError


class M2SourceRoute(APIRoute):
    def get_route_handler(self):
        handler = super().get_route_handler()
        async def guarded(request):
            try:
                return await handler(request)
            except M2ValidationError as exc:
                raise HTTPException(422, detail=str(exc)) from exc
            except SQLAlchemyError as exc:
                raise HTTPException(503, detail={'code':'M2_SOURCE_UNAVAILABLE',
                    'message':'Required M2 source storage is unavailable. The operation did not complete.'},
                    headers={'Cache-Control':'no-store'}) from exc
        return guarded
