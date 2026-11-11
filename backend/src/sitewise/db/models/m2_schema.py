"""Opt-in SQLAlchemy Core schema for draft M2/BDJ/confirmation infrastructure.

Separate metadata deliberately prevents the existing SQLModel.metadata.create_all()
startup hook from creating these tables without a reviewed migration.
No questionnaire definition is seeded; only separately authorized versions may be used.
"""
from sqlalchemy import (
    JSON, Column, DateTime, ForeignKey, Integer, MetaData, String, Table,
    Text, UniqueConstraint, Uuid, func,
)

m2_metadata = MetaData()

instruments = Table(
    "m2_instrument_versions", m2_metadata,
    Column("id", Uuid(as_uuid=True), primary_key=True),
    Column("code", String(32), nullable=False),
    Column("version_tag", String(100), nullable=False),
    Column("approval_state", String(24), nullable=False),
    Column("schema_digest", String(64), nullable=False),
    Column("created_at", DateTime(timezone=True), server_default=func.now(), nullable=False),
    UniqueConstraint("code", "version_tag", name="uq_m2_instrument_code_version"),
)
items = Table(
    "m2_item_versions", m2_metadata,
    Column("id", Uuid(as_uuid=True), primary_key=True),
    Column("instrument_id", Uuid(as_uuid=True), ForeignKey("m2_instrument_versions.id"), nullable=False),
    Column("item_key", String(32), nullable=False),
    Column("question_text", Text, nullable=False),
    Column("requiredness", String(24), nullable=False),
    Column("answer_kind", String(20), nullable=False),
    Column("option_values", JSON, nullable=False),
    Column("allowed_states", JSON, nullable=False),
    Column("lifecycle", String(24), nullable=False),
    Column("sort_order", Integer, nullable=False),
    UniqueConstraint("instrument_id", "item_key", name="uq_m2_item_instrument_key"),
)
assessments = Table(
    "m2_assessments", m2_metadata,
    Column("id", Uuid(as_uuid=True), primary_key=True),
    Column("owner_user_id", Uuid(as_uuid=True), nullable=False, index=True),
    Column("instrument_id", Uuid(as_uuid=True), ForeignKey("m2_instrument_versions.id"), nullable=False),
    Column("revision", Integer, nullable=False, default=0),
    Column("confirmed_revision", Integer, nullable=True),
    Column("created_at", DateTime(timezone=True), server_default=func.now(), nullable=False),
)
answers = Table(
    "m2_answer_revisions", m2_metadata,
    Column("id", Uuid(as_uuid=True), primary_key=True),
    Column("assessment_id", Uuid(as_uuid=True), ForeignKey("m2_assessments.id"), nullable=False, index=True),
    Column("item_version_id", Uuid(as_uuid=True), ForeignKey("m2_item_versions.id"), nullable=False),
    Column("assessment_revision", Integer, nullable=False),
    Column("answer_state", String(32), nullable=False),
    Column("value_json", JSON, nullable=True),
    Column("created_at", DateTime(timezone=True), server_default=func.now(), nullable=False),
    UniqueConstraint("assessment_id", "item_version_id", "assessment_revision", name="uq_m2_answer_revision"),
)
findings = Table(
    "m2_bdj_findings", m2_metadata,
    Column("id", Uuid(as_uuid=True), primary_key=True),
    Column("assessment_id", Uuid(as_uuid=True), ForeignKey("m2_assessments.id"), nullable=False),
    Column("assessment_revision", Integer, nullable=False),
    Column("rule_id", String(64), nullable=False),
    Column("rule_version", String(32), nullable=False),
    Column("source_answer_ids", JSON, nullable=False),
    Column("issue_type", String(48), nullable=False),
    Column("explanation", Text, nullable=False),
    Column("not_proven", Text, nullable=False),
    Column("next_action", Text, nullable=False),
    Column("review_state", String(24), nullable=False),
    Column("created_at", DateTime(timezone=True), server_default=func.now(), nullable=False),
    UniqueConstraint("assessment_id", "assessment_revision", "rule_id", "rule_version", name="uq_m2_bdj_rule_revision"),
)
evaluations = Table(
    "m2_bdj_evaluations", m2_metadata,
    Column("id", Uuid(as_uuid=True), primary_key=True),
    Column("assessment_id", Uuid(as_uuid=True), ForeignKey("m2_assessments.id"), nullable=False),
    Column("assessment_revision", Integer, nullable=False),
    Column("evaluator_version", String(64), nullable=False),
    Column("created_at", DateTime(timezone=True), server_default=func.now(), nullable=False),
    UniqueConstraint("assessment_id", "assessment_revision", "evaluator_version", name="uq_m2_bdj_evaluation"),
)
reviews = Table(
    "m2_review_events", m2_metadata,
    Column("id", Uuid(as_uuid=True), primary_key=True),
    Column("assessment_id", Uuid(as_uuid=True), ForeignKey("m2_assessments.id"), nullable=False),
    Column("assessment_revision", Integer, nullable=False),
    Column("actor_user_id", Uuid(as_uuid=True), nullable=False),
    Column("created_at", DateTime(timezone=True), server_default=func.now(), nullable=False),
    UniqueConstraint("assessment_id", "assessment_revision", name="uq_m2_review_revision"),
)
confirmations = Table(
    "m2_confirmation_snapshots", m2_metadata,
    Column("id", Uuid(as_uuid=True), primary_key=True),
    Column("assessment_id", Uuid(as_uuid=True), ForeignKey("m2_assessments.id"), nullable=False),
    Column("assessment_revision", Integer, nullable=False),
    Column("actor_user_id", Uuid(as_uuid=True), nullable=False),
    Column("snapshot_json", JSON, nullable=False),
    Column("snapshot_digest", String(64), nullable=False),
    Column("acknowledged_issue_ids", JSON, nullable=False),
    Column("created_at", DateTime(timezone=True), server_default=func.now(), nullable=False),
    UniqueConstraint("assessment_id", "assessment_revision", name="uq_m2_confirmation_revision"),
)
uncertainties = Table(
    "m2_confirmed_uncertainties", m2_metadata,
    Column("id", Uuid(as_uuid=True), primary_key=True),
    Column("confirmation_id", Uuid(as_uuid=True), ForeignKey("m2_confirmation_snapshots.id"), nullable=False),
    Column("actor_user_id", Uuid(as_uuid=True), nullable=False),
    Column("exact_text", Text, nullable=False),
    Column("created_at", DateTime(timezone=True), server_default=func.now(), nullable=False),
)


# Append-only entrepreneur decisions about candidate BDJ findings.
# A decision does NOT rewrite the source M2 answer or establish issue resolution.
# Separate metadata and a reviewed additive migration are still required.
clarification_events = Table(
    "m2_clarification_events", m2_metadata,
    Column("id", Uuid(as_uuid=True), primary_key=True),
    Column("assessment_id", Uuid(as_uuid=True),
           ForeignKey("m2_assessments.id"), nullable=False),
    Column("assessment_revision", Integer, nullable=False),
    Column("finding_id", Uuid(as_uuid=True),
           ForeignKey("m2_bdj_findings.id"), nullable=False),
    Column("actor_user_id", Uuid(as_uuid=True), nullable=False),
    Column("decision", String(24), nullable=False),
    Column("event_sequence", Integer, nullable=False),
    Column("request_id", Uuid(as_uuid=True), nullable=False),
    Column("created_at", DateTime(timezone=True), server_default=func.now(), nullable=False),
    UniqueConstraint("assessment_id", "request_id",
                     name="uq_m2_clarification_request"),
    UniqueConstraint("assessment_id", "assessment_revision", "event_sequence",
                     name="uq_m2_clarification_sequence"),
)
