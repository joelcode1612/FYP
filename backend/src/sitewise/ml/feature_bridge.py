"""Bridge the live database to the exact 47-feature training contract.

Evidence (verified 2026-11-11 against this deployment)
=====================================================
The selected PU artifact (``sitewise_selected_pu_model.joblib``, feature_set
``baseline_47``) requires 47 features. After the duplicate-population fix in
``property_features.PropertyFeatureRepository`` the live database resolves 42
of them for every catalogue property (39 direct columns/JSON keys plus the
three documented WorldPop ring equivalents). FIVE features exist in NO table:

* ``pop_2000m``                      - no 2 km ring is stored anywhere
* ``landscan_ambient_pop_1000m``     - only WorldPop-derived ``ambient_population_1km``
* ``landscan_ambient_pop_2000m``     - absent
* ``landscan_ambient_pop_3000m``     - absent
* ``worldpop_walk_reachable_10min``  - absent from every source examined

FOUR of the five (``pop_2000m`` and the three LandScan rasters) are present,
keyed by subject id, in the ORIGINAL training dataset that produced both PU
artifacts. The verified copy is committed as
``backend/ml_reference/training_population_bridge_1849.csv`` (1,849 rows =
894 P + 955 U, the exact training population). Byte-parity was validated for
the reference property MD-00510 against the supplied
``example_property_47.json``: ``pop_2000m=35472.8``,
``landscan_ambient_pop_1000m=2749``, ``..._2000m=30743``, ``..._3000m=85886``.

``worldpop_walk_reachable_10min`` cannot be recovered: it is absent from the
database, the training export, every workbook and both SQL dumps. It survives
only for the 25 complete-case rows of ``shap_background_47.csv``. Any live
47-feature inference is therefore UNAVAILABLE for every property, and this
module reports that state explicitly instead of fabricating or zero-filling.

LandScan licence: the training export records
``landscan_ml_training_eligible=NO_PENDING_LICENCE`` for all 1,849 rows. The
values are reproduced here ONLY because they are the artifact's own training
inputs (in-sample research use, stated in the model card); every response
carries the licence status so downstream consumers can gate on it.
"""
from __future__ import annotations

import csv
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any

BRIDGE_CSV = Path(__file__).resolve().parents[3] / "ml_reference" / "training_population_bridge_1849.csv"

#: The features the bridge supplies (absent from every database table).
BRIDGE_FEATURES: tuple[str, ...] = (
    "pop_2000m",
    "landscan_ambient_pop_1000m",
    "landscan_ambient_pop_2000m",
    "landscan_ambient_pop_3000m",
)

#: Known unrecoverable feature (evidence documented in the module docstring).
UNRECOVERABLE_FEATURES: tuple[str, ...] = ("worldpop_walk_reachable_10min",)


@dataclass(frozen=True)
class BridgeRow:
    subject_id: str
    canonical_property_id: str
    sample_class: str
    values: dict[str, float]
    landscan_licence: str
    landscan_quality_flag: str


@dataclass(frozen=True)
class FeatureCoverage:
    """Explicit per-feature resolution for one property."""

    property_id: str
    subject_id: str | None
    values: dict[str, float | None]
    sources: dict[str, str]
    missing_features: list[str]
    unrecoverable_features: list[str]
    flags: list[str] = field(default_factory=list)

    @property
    def complete(self) -> bool:
        return not self.missing_features

    @property
    def available_count(self) -> int:
        return sum(v is not None for v in self.values.values())

    def as_dict(self) -> dict[str, Any]:
        return {
            "property_id": self.property_id,
            "subject_id": self.subject_id,
            "feature_count": len(self.values),
            "available_features": self.available_count,
            "complete": self.complete,
            "missing_features": self.missing_features,
            "unrecoverable_features": self.unrecoverable_features,
            "value_sources": self.sources,
            "flags": self.flags,
            "values": self.values,
        }


@lru_cache(maxsize=1)
def _load_bridge() -> dict[str, BridgeRow]:
    if not BRIDGE_CSV.is_file():
        raise FileNotFoundError(f"Training bridge dataset is missing: {BRIDGE_CSV}")
    by_key: dict[str, BridgeRow] = {}
    with BRIDGE_CSV.open(encoding="utf-8", newline="") as fp:
        for row in csv.DictReader(fp):
            canonical = (row.get("canonical_property_id") or "").strip()
            subject = (row.get("subject_id") or "").strip()
            values: dict[str, float] = {}
            for name in BRIDGE_FEATURES:
                raw = (row.get(name) or "").strip()
                if raw:
                    values[name] = float(raw)
            bridge = BridgeRow(
                subject_id=subject,
                canonical_property_id=canonical,
                sample_class=(row.get("sample_class") or "").strip().upper(),
                values=values,
                landscan_licence=(row.get("landscan_ml_training_eligible") or "").strip(),
                landscan_quality_flag=(row.get("landscan_quality_flag") or "").strip(),
            )
            if canonical:
                by_key.setdefault(f"catalog:{canonical}", bridge)
            if subject:
                by_key.setdefault(f"subject:{subject}", bridge)
    return by_key


def bridge_row_for(property_id: str, subject_id: str | None) -> BridgeRow | None:
    """Look up one training record by catalogue id, falling back to subject id."""
    index = _load_bridge()
    hit = index.get(f"catalog:{property_id}")
    if hit is None and subject_id:
        hit = index.get(f"subject:{subject_id}")
    return hit


def merge_bridge_features(
    bundle: Any,
    *,
    expected_features: list[str],
) -> FeatureCoverage:
    """Combine a live DB bundle with the training-bridge file.

    The database result wins for features it resolved (it is the live
    provenance); the bridge supplies only the DB-absent training columns.
    Nothing is invented for features neither source holds.
    """
    row = bridge_row_for(bundle.property_id, bundle.subject_id)
    values: dict[str, float | None] = dict(bundle.values)
    sources: dict[str, str] = dict(bundle.value_sources)
    flags: list[str] = list(bundle.flags)

    if row is None:
        flags.append(
            "No training-population bridge record for this property; "
            + ", ".join(BRIDGE_FEATURES)
            + " stay unresolved"
        )
    else:
        for name in BRIDGE_FEATURES:
            if values.get(name) is None and name in row.values:
                values[name] = row.values[name]
                sources[name] = (
                    f"ml_reference/training_population_bridge_1849.csv (original "
                    f"training record, subject {row.subject_id})"
                )
        if row.landscan_licence and row.landscan_licence.upper() not in {"ALLOWED", "YES", "TRUE"}:
            flags.append(
                f"LandScan licence status is '{row.landscan_licence}': values are the "
                "model artifact's own training inputs (in-sample research use); "
                "gate any other use on licensing."
            )
        if row.landscan_quality_flag and row.landscan_quality_flag not in {"OK", "VALID"}:
            flags.append(f"LandScan quality flag: {row.landscan_quality_flag}")

    missing = [name for name in expected_features if values.get(name) is None]
    unrecoverable = [name for name in missing if name in UNRECOVERABLE_FEATURES]
    return FeatureCoverage(
        property_id=bundle.property_id,
        subject_id=bundle.subject_id,
        values=values,
        sources=sources,
        missing_features=missing,
        unrecoverable_features=unrecoverable,
        flags=sorted(set(flags)),
    )
