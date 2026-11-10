import uuid
from datetime import datetime
from decimal import Decimal
from typing import Optional

from sqlalchemy import Column
from sqlalchemy.dialects.postgresql import JSONB
from sqlmodel import Field, SQLModel


class RecommendationResult(SQLModel, table=True):
    """One ranked property in one generated recommendation batch.

    Phase 5 persistence (migration 0008 / apply script
    ``scripts/apply_recommendation_persistence_migration.py``):

    * ``property_id`` was an INTEGER legacy reference into ``public.property``,
      retired by migration 0005. The table was empty, so the column was retyped
      to TEXT and now holds the catalogue's canonical id (``EP-01877``,
      ``MD-00510``) - text ids are NEVER forced through an integer key.
    * ``batch_id`` groups the ranked results of one generation so the latest
      batch survives restarts and crosses worker boundaries.
    * ``payload`` stores the full API result contract (components, component
      details, cautions, verification) so reads reconstruct exactly what was
      generated; typed columns exist for queryability.
    * ``shap`` caches the attached Layer 3 explanation.
    * The ``user_id`` foreign key is ON DELETE CASCADE: deleting a user removes
      their generated results with them.
    """

    __tablename__ = "recommendation_result"

    result_id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    user_id: uuid.UUID = Field(foreign_key="users.user_id")
    property_id: str = Field()  # canonical catalogue text id (EP-/MD-)
    score: Decimal = Field(max_digits=8, decimal_places=5)
    ranking: Optional[int] = None
    created_at: datetime = Field(default_factory=datetime.utcnow)
    batch_id: Optional[uuid.UUID] = None
    pu_association_score: Optional[Decimal] = Field(
        default=None, max_digits=8, decimal_places=6
    )
    preference_match_score: Optional[Decimal] = Field(
        default=None, max_digits=8, decimal_places=6
    )
    scoring_version: Optional[str] = None
    model_name: Optional[str] = None
    payload: Optional[dict] = Field(default=None, sa_column=Column(JSONB))
    shap: Optional[dict] = Field(default=None, sa_column=Column(JSONB))
