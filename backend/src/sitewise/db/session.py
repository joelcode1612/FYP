from sqlalchemy import inspect
from sqlmodel import SQLModel, create_engine, Session

from sitewise.core.config import settings

engine = create_engine(settings.database_url, pool_pre_ping=True, echo=False)


def get_db():
    with Session(engine) as session:
        yield session


def create_db_and_tables():
    import sitewise.db.models  # noqa: F401

    # Research/operational mirrors are not schema provisioning instructions.
    # Check before any DDL so a wrong database cannot receive partial tables.
    tables = list(SQLModel.metadata.sorted_tables)
    inspector = inspect(engine)
    missing = [
        table.fullname
        for table in tables
        if table.info.get("externally_managed")
        and not inspector.has_table(table.name, schema=table.schema)
    ]
    if missing:
        raise RuntimeError(
            "Required externally managed tables are missing: "
            + ", ".join(missing)
            + ". Verify DATABASE_URL and the reviewed deployment schema; "
            "startup will not create these tables."
        )
    SQLModel.metadata.create_all(
        engine,
        tables=[table for table in tables if not table.info.get("externally_managed")],
    )
