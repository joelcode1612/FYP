"""Probe: build the BDJ source packet from the synthetic assessment (read-only)."""
import sys
from pathlib import Path
from uuid import UUID

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from sqlalchemy import create_engine, text  # noqa: E402
from sqlmodel import Session  # noqa: E402

from sitewise.core.config import settings  # noqa: E402
from sitewise.project1.projection import M2SourceProjection  # noqa: E402
from sitewise.repositories.m2_repository import SqlModelM2Repository  # noqa: E402

ACTOR = UUID("11111111-1111-4111-8111-111111111111")
ASSESSMENT = UUID("da90aa4a-f9cf-4145-9acf-7de36c9d6fad")
REV = 12

engine = create_engine(settings.m2_database_url.get_secret_value(), hide_parameters=True)
with Session(engine) as session:
    session.execute(text("SELECT set_config('project1.actor_id', :a, true)"), {"a": str(ACTOR)})
    packet = M2SourceProjection(SqlModelM2Repository(session)).read(ASSESSMENT, ACTOR, REV)

print("schema_version", packet["schema_version"])
print("assessment", packet["assessment_id"], "rev", packet["assessment_revision"], "confirmed", packet["confirmed"])
print("declarations", len(packet["declarations"]))
print("source_fingerprint", packet["source_fingerprint"])
for d in packet["declarations"][:8]:
    print("  ", d["item_key"], "|", d["answer_state"], "|", str(d["value"])[:70])
