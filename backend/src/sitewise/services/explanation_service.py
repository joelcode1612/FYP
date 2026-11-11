"""Property-specific SHAP explanation for a persisted assessment.

The explanation is produced by the SAME artifact the assessment scores with
(``PU_model.joblib``, ``baseline_47``, bagged logistic regression) over the
property's actual 47 resolved features. Nothing here is synthesised:

* the subject features come from ``PropertyFeatureRepository`` with per-value
  provenance;
* the SHAP background comes from real ``sitewise_analytics.subject_features``
  rows, never zero-filled or invented;
* additivity (``base_value + sum(contributions) == model output``) is checked
  before the payload is returned, so an explanation that does not reconstruct
  the score is refused rather than shown;
* the score is labelled a research positive-label association, never a
  business-success probability.

Every failure mode raises ``AssessmentError`` with a stable code, which the
assessment API turns into an honest "unavailable" state. No mock SHAP values
are ever returned.
"""

from __future__ import annotations

from typing import Any

from sqlmodel import Session

from sitewise.core.exceptions import AssessmentError, ModelUnavailableError
from sitewise.db.models.ai_explanation import AiExplanation
from sitewise.db.models.assessment import Assessment
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.property_features import FeatureResolutionError, PropertyFeatureRepository
from sitewise.ml.shap_explainer import ShapExplainer

# Deterministic feature -> analysis category mapping. The five categories are
# the ones the evidence stage presents, so a contribution is always shown next
# to the measurement it belongs to.
_CATEGORY_RULES: tuple[tuple[str, str], ...] = (
    ("pop_", "population"),
    ("landscan_", "population"),
    # Walk-reachable population is an accessibility measure in the approved
    # baseline_47 grouping (7/14/13/3/10), not a catchment population figure.
    ("worldpop_walk_reachable_", "accessibility"),
    ("worldpop_", "population"),
    ("office_pois_", "demand_generators"),
    ("schools_count_", "demand_generators"),
    ("universities_", "demand_generators"),
    ("retail_pois_", "demand_generators"),
    ("malls_count_", "demand_generators"),
    ("hospitals_count_", "demand_generators"),
    ("supermarkets_count_", "demand_generators"),
    ("nearest_transit_walk_m", "accessibility"),
    ("nearest_major_road_m", "accessibility"),
    ("road_", "accessibility"),
    ("osm_walkway_", "accessibility"),
    ("transit_stops_", "accessibility"),
    ("weekday_", "accessibility"),
    ("walk_isochrone_", "accessibility"),
    ("drive_isochrone_", "accessibility"),
    ("parking_", "parking"),
    ("nearest_parking_", "parking"),
    ("fnb_competitors_", "competitors"),
    ("cafe_count_", "competitors"),
    ("restaurant_count_", "competitors"),
    ("fast_food_count_", "competitors"),
    ("bakery_dessert_", "competitors"),
)

CATEGORY_ORDER = (
    "population",
    "demand_generators",
    "accessibility",
    "parking",
    "competitors",
)

CATEGORY_LABELS = {
    "population": "Population",
    "demand_generators": "Demand generators",
    "accessibility": "Accessibility and transportation",
    "parking": "Parking",
    "competitors": "Competitors",
}

# Additivity tolerance. float64 permutation SHAP over <=47 features accumulates
# well below this; a larger gap means the explanation does not describe the
# score and must not be shown.
_ADDITIVITY_TOLERANCE = 1e-6


def category_of(feature: str) -> str:
    """The analysis category a model feature belongs to."""
    for prefix, category in _CATEGORY_RULES:
        if feature.startswith(prefix):
            return category
    # Unknown names are grouped explicitly rather than silently dropped, so a
    # future feature addition is visible instead of vanishing from the totals.
    return "other"


def group_contributions(contributions: dict[str, float]) -> list[dict]:
    """Signed per-category totals, in the evidence stage's order."""
    totals: dict[str, float] = {key: 0.0 for key in CATEGORY_ORDER}
    members: dict[str, list[str]] = {key: [] for key in CATEGORY_ORDER}
    other_total = 0.0
    other_members: list[str] = []
    for feature, value in contributions.items():
        category = category_of(feature)
        if category in totals:
            totals[category] += value
            members[category].append(feature)
        else:
            other_total += value
            other_members.append(feature)

    groups = [
        {
            "key": key,
            "label": CATEGORY_LABELS[key],
            "contribution": round(totals[key], 10),
            "feature_count": len(members[key]),
            "features": sorted(members[key]),
        }
        for key in CATEGORY_ORDER
        if members[key]
    ]
    if other_members:
        groups.append(
            {
                "key": "other",
                "label": "Other model features",
                "contribution": round(other_total, 10),
                "feature_count": len(other_members),
                "features": sorted(other_members),
            }
        )
    return groups


class ExplanationService:
    def __init__(self, session: Session, analytics_session: Session | None = None):
        self.session = session
        self.analytics = analytics_session

    # -- persistence --------------------------------------------------------

    def create(self, explanation: AiExplanation) -> AiExplanation:
        self.session.add(explanation)
        self.session.commit()
        self.session.refresh(explanation)
        return explanation

    # -- explanation --------------------------------------------------------

    def explain_assessment(self, assessment: Assessment) -> dict:
        """Genuine SHAP for one assessment's property, or a coded refusal."""
        if self.analytics is None:
            raise AssessmentError(
                "The analytics database is not configured, so model features "
                "cannot be resolved.",
                code="analytics_unavailable",
                status_code=503,
            )

        try:
            loaded = ModelLoader().load("pu_model")
        except ModelUnavailableError as exc:
            raise AssessmentError(
                "The trained PU model artifact cannot be loaded, so no "
                "explanation can be produced.",
                code="model_unavailable",
                status_code=503,
            ) from exc

        repo = PropertyFeatureRepository(self.analytics)
        try:
            bundle = repo.get(
                assessment.property_id, loaded.feature_names, source="catalog"
            )
        except FeatureResolutionError as exc:
            raise AssessmentError(
                str(exc), code="features_unresolved", status_code=409
            ) from exc

        if bundle.missing_features:
            raise AssessmentError(
                "The property is missing "
                f"{len(bundle.missing_features)} of {len(loaded.feature_names)} "
                "model features, so an explanation cannot be computed.",
                code="features_missing",
                status_code=409,
            )

        background = repo.background(loaded.feature_names, limit=50)
        if not background:
            raise AssessmentError(
                "No complete analysed subject rows are available to build the "
                "SHAP background matrix. Synthetic background data is never "
                "substituted.",
                code="shap_background_missing",
                status_code=409,
            )

        features: dict[str, float] = {
            name: float(value)  # type: ignore[arg-type]
            for name, value in bundle.values.items()
            if value is not None
        }

        try:
            explained = ShapExplainer(loader=ModelLoader()).explain(
                features, background=background
            )
        except ModelUnavailableError as exc:
            raise AssessmentError(
                str(exc), code="shap_unavailable", status_code=503
            ) from exc

        contributions: dict[str, float] = explained["contributions"]
        base_value = float(explained["baseline_association"])
        output = float(explained["positive_label_association"])
        reconstructed = base_value + sum(contributions.values())

        if abs(reconstructed - output) > _ADDITIVITY_TOLERANCE:
            raise AssessmentError(
                "The SHAP contributions do not reconstruct the model output "
                f"(base {base_value:.6f} + contributions {reconstructed:.6f} "
                f"!= output {output:.6f}), so the explanation is withheld.",
                code="shap_inconsistent",
                status_code=500,
            )

        ranked = sorted(contributions.items(), key=lambda kv: kv[1])
        payload = {
            "property_id": assessment.property_id,
            "assessment_id": str(assessment.assessment_id),
            "available": True,
            "model": explained.get("model"),
            "model_version": (loaded.meta or {}).get("version")
            or (loaded.meta or {}).get("feature_set"),
            "feature_set": (loaded.meta or {}).get("feature_set"),
            "feature_count": len(loaded.feature_names),
            "explainer": explained.get("explainer"),
            "score_meaning": explained.get("score_meaning")
            or "research_positive_label_association_NOT_business_success_probability",
            "research_only": True,
            "base_value": base_value,
            "output": output,
            "reconstructed": reconstructed,
            "additivity_ok": True,
            "background_size": explained.get("background_size"),
            "contributions": contributions,
            # The exact resolved values the contributions were computed from,
            # so a read-only consumer never pairs them with re-measured data.
            "values": dict(bundle.values),
            "groups": group_contributions(contributions),
            "strongest_negative": [
                {"feature": name, "contribution": value} for name, value in ranked[:5]
            ],
            "strongest_positive": [
                {"feature": name, "contribution": value}
                for name, value in ranked[-5:][::-1]
            ],
            "missing_features": list(bundle.missing_features),
            "flags": bundle.flags,
            "value_sources": bundle.value_sources,
        }

        self._persist(assessment, payload)
        return payload

    def latest_for_assessment(self, assessment: Assessment) -> dict | None:
        """The newest persisted explanation that belongs to this assessment.

        Recomputing permutation SHAP on every report read would be wasteful, so
        the report reuses the stored payload. The row is only accepted when its
        embedded ``assessment_id`` matches, which is what keeps one
        assessment's explanation from being shown against another property.
        """
        import json

        from sqlmodel import select

        rows = self.session.exec(
            select(AiExplanation)
            .where(AiExplanation.user_id == assessment.user_id)
            .order_by(AiExplanation.created_at.desc())
            .limit(20)
        ).all()
        for row in rows:
            try:
                content = json.loads(row.content)
            except (TypeError, ValueError):
                continue
            if content.get("assessment_id") == str(assessment.assessment_id):
                return content
        return None

    def _persist(self, assessment: Assessment, payload: dict) -> None:
        """Store the explanation content; a storage failure never voids it."""
        import json

        try:
            self.create(
                AiExplanation(
                    user_id=assessment.user_id,
                    content=json.dumps(payload, default=str),
                )
            )
        except Exception:  # noqa: BLE001 - the response is still valid
            self.session.rollback()
