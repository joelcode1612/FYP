from sqlmodel import SQLModel, create_engine, Session

from sitewise.core.config import settings

engine = create_engine(settings.database_url, pool_pre_ping=True, echo=False)


def get_db():
    with Session(engine) as session:
        yield session


def create_db_and_tables():
    import sitewise.db.models  # noqa: F401
    SQLModel.metadata.create_all(engine)
