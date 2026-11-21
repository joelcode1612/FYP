"""Explicit M2 target without retargeting the application's other modules."""
from functools import lru_cache

from sqlalchemy.engine import make_url
from sqlmodel import Session, create_engine

from sitewise.core.config import settings
from sitewise.core.exceptions import AssessmentError


@lru_cache(maxsize=4)
def _engine(url):
    return create_engine(url,pool_pre_ping=True,echo=False)


def get_m2_engine():
    raw=settings.m2_database_url.get_secret_value() or settings.database_url
    try:
        url=make_url(raw)
        valid=(url.drivername=='postgresql+psycopg2' and
               url.database==settings.m2_expected_database and bool(url.database))
    except (ValueError,TypeError):
        valid=False
    if not valid:
        raise AssessmentError('The dedicated M2 database target has not been verified.',
            code='M2_DATABASE_TARGET_UNVERIFIED',status_code=503)
    return _engine(raw)


def get_m2_db():
    with Session(get_m2_engine()) as session:
        yield session
