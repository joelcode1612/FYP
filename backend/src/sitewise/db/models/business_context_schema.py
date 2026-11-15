"""Explicit-migration-only BCB persistence metadata; never startup create_all.

Physical constraints/triggers/RLS are declared in the reviewed SQL migration.
No second M2 or source-authority table is defined here.
"""
from sqlalchemy import Column, DateTime, Integer, MetaData, String, Table, Text, Uuid
from sqlalchemy.dialects.postgresql import JSONB

bcb_metadata = MetaData()
contexts = Table('m2_business_contexts', bcb_metadata,
    Column('context_id', Uuid, primary_key=True),
    Column('assessment_id', Uuid, nullable=False),
    Column('owner_user_id', Uuid, nullable=False),
    Column('confirmation_id', Uuid, nullable=False),
    Column('assessment_revision', Integer, nullable=False),
    Column('schema_version', String(100), nullable=False),
    Column('builder_version', String(100), nullable=False),
    Column('purpose', String(64), nullable=False),
    Column('tenant_id', String(200), nullable=False),
    Column('concept_version', String(200), nullable=False),
    Column('snapshot_digest', String(64), nullable=False),
    Column('packet_hash', String(64), nullable=False),
    Column('canonical_body', Text, nullable=False),
    Column('packet_json', JSONB, nullable=False),
    Column('lifecycle_status', String(24), nullable=False),
    Column('created_at', DateTime(timezone=True)),
)
builds = Table('m2_business_context_builds', bcb_metadata,
    Column('confirmation_id', Uuid, primary_key=True),
    Column('assessment_id', Uuid, nullable=False),
    Column('owner_user_id', Uuid, nullable=False),
    Column('assessment_revision', Integer, nullable=False),
    Column('status', String(24), nullable=False),
    Column('last_code', String(100)),
    Column('context_id', Uuid),
    Column('attempt_count', Integer, nullable=False),
    Column('created_at', DateTime(timezone=True)),
    Column('updated_at', DateTime(timezone=True)),
)
