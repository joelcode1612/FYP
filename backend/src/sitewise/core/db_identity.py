"""Database identity verification for PROJECT1.

The guard in ``sitewise.db.m2_session`` refuses a URL whose database name is not
``settings.m2_expected_database``. That catches a misconfigured *URL*. It does not catch a
database that was renamed, restored over, or reached through a different server than the one
the operator believes they configured. This module answers the question the URL cannot:

    what database is this connection actually in, right now?

It is deliberately small and side-effect free: one read-only ``select current_database()``,
plus the server address and the principal. Nothing is cached across a target change, and no
write is ever issued.

Usage
-----
    from sitewise.core.db_identity import describe, verify_or_raise

    identity = describe(engine)                 # dict, never raises on a live connection
    verify_or_raise(engine, expected="Dss")     # raises DatabaseIdentityMismatch

Both are safe to call at startup and from a health endpoint.
"""
from __future__ import annotations

from dataclasses import dataclass, asdict
from typing import Any

from sqlalchemy import text
from sqlalchemy.engine import Engine

#: Databases this application is allowed to write PROJECT1 records into. Anything else is
#: either the legacy marketplace database or a disposable clone, and must be labelled as such.
AUTHORITATIVE_DATABASES = frozenset({"Dss"})


class DatabaseIdentityMismatch(RuntimeError):
    """Raised when a connection is not in the database it is supposed to be in."""

    def __init__(self, expected: str, actual: str, *, authoritative: bool):
        self.expected = expected
        self.actual = actual
        self.authoritative = authoritative
        super().__init__(
            f"database identity mismatch: expected {expected!r}, connected to {actual!r}"
        )


@dataclass(frozen=True)
class DatabaseIdentity:
    database: str
    principal: str
    server_address: str | None
    server_port: int | None
    server_version: str
    authoritative: bool

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)


def describe(engine: Engine) -> DatabaseIdentity:
    """Read the real identity of the connection pool behind ``engine``.

    Read-only. Raises only if the connection itself cannot be opened.
    """
    with engine.connect() as conn:
        row = conn.execute(
            text(
                "select current_database() as database, current_user as principal, "
                "       inet_server_addr()::text as address, inet_server_port() as port, "
                "       version() as version"
            )
        ).mappings().one()
        conn.rollback()
    database = str(row["database"])
    return DatabaseIdentity(
        database=database,
        principal=str(row["principal"]),
        server_address=row["address"],
        server_port=row["port"],
        server_version=str(row["version"]).split(" on ")[0],
        authoritative=database in AUTHORITATIVE_DATABASES,
    )


def verify_or_raise(engine: Engine, expected: str) -> DatabaseIdentity:
    """Fail closed when the connection is not in ``expected``.

    ``expected`` is the operator's declared target (``settings.m2_expected_database`` for the
    M2/BCB engine). A clone is *not* silently accepted: the caller must declare the clone's
    name explicitly, which is what makes "this was a clone run" a written fact rather than an
    accident.
    """
    identity = describe(engine)
    if identity.database != expected:
        raise DatabaseIdentityMismatch(expected, identity.database,
                                       authoritative=identity.authoritative)
    return identity


def banner(identity: DatabaseIdentity) -> str:
    """One line an operator can read in the startup log."""
    tag = "AUTHORITATIVE" if identity.authoritative else "NON-AUTHORITATIVE"
    return (
        f"[db-target] {tag} database={identity.database} "
        f"principal={identity.principal} "
        f"server={identity.server_address}:{identity.server_port}"
    )
