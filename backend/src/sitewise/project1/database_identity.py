"""Exact workflow database binding; private targets require explicit server config."""
from sqlalchemy import text
from sqlalchemy.engine import make_url
from sitewise.core.config import settings
from sitewise.project1.contracts import WorkflowHeld


def configured_target():
    name = settings.project1_isolated_database_name
    port = settings.project1_isolated_database_port
    if not name and not port:
        return 'Dss', None
    if (not name.startswith('project1_') or not name.endswith('_test') or
            not 1024 <= port <= 65535 or port == 5432 or
            settings.m2_expected_database != name):
        raise WorkflowHeld('WORKFLOW_ISOLATED_TARGET_INVALID')
    return name, port


def verify_workflow_database(session, *, private_only=False):
    name, private_port = configured_target()
    if private_only and private_port is None:
        raise WorkflowHeld('SYNTHETIC_PRIVATE_INSTANCE_UNVERIFIED')
    configured = make_url(settings.m2_database_url.get_secret_value() or settings.database_url)
    connected = session.get_bind().url
    if (configured.drivername != 'postgresql+psycopg2' or configured.database != name or
            (connected.host, connected.port, connected.database) !=
            (configured.host, configured.port, configured.database) or
            (private_port is not None and (configured.host != '127.0.0.1' or
                                           configured.port != private_port))):
        raise WorkflowHeld('WORKFLOW_DATABASE_IDENTITY_MISMATCH')
    row = session.execute(text('SELECT current_database(), inet_server_port(), '
        'r.rolsuper, r.rolbypassrls, l.rolsuper, l.rolbypassrls '
        'FROM pg_roles r, pg_roles l WHERE r.rolname=current_user AND l.rolname=session_user')).one()
    if (row[0] != name or (private_port is not None and row[1] != private_port) or
            any(row[2:])):
        raise WorkflowHeld('SOURCE_PRINCIPAL_REVIEW_REQUIRED')
    return True
