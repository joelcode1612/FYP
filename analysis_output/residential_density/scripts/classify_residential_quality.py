"""Classify residential-feature data quality per spec section 6.

States (documented rule, applied identically to P and U):
- calculated:        >=1 verified residential polygon in buffer -> real values
- confirmed_zero:    0 residential polygons but >=10 any-tagged OSM buildings within
                     the 500m anchor -> OSM has mapped this area, no residential
                     classification present. Measured zero, NOT a fill.
- manual_review:     0 residential polygons and 1..9 mapped buildings within 500m ->
                     mapping too sparse to trust a zero. Metric values set to NULL.
- insufficient_coverage: 0 residential polygons and 0 mapped buildings within 500m ->
                     area effectively unmapped. Metric values set to NULL.
- dwelling units:    unavailable_dwelling for every subject. OSM carries building:units
                     on only 28 polygons Malaysia-wide (15 in the residential tag set);
                     no licensed national dwelling-unit register is available. Fields
                     stay NULL; never derived from building counts.
Additional note flag: residential landuse polygon present but zero verified
residential buildings (spec section 4: landuse does not confirm buildings).

Output: data/residential_quality_1849.csv
"""
import os
import sys

import pandas as pd

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANY_THRESHOLD = 10

df = pd.read_csv(os.path.join(BASE, "data", "residential_features_1849.csv"))
df.columns = [c.replace("_1km", "_1000m") for c in df.columns]
assert len(df) == 1849 and df["subject_id"].is_unique

METRICS_500 = [
    "residential_building_count_500m", "residential_building_density_500m_km2",
    "residential_footprint_coverage_500m_pct", "residential_landuse_coverage_500m_pct",
]
METRICS_1KM = [
    "residential_building_count_1000m", "residential_building_density_1000m_km2",
    "residential_footprint_coverage_1000m_pct", "residential_landuse_coverage_1000m_pct",
]

df["quality_note"] = ""

def classify(row):
    if row["residential_building_count_500m"] > 0:
        q = "calculated"
    elif row["any_building_count_500m"] >= ANY_THRESHOLD:
        q = "confirmed_zero"
    elif row["any_building_count_500m"] >= 1:
        q = "manual_review"
        row["quality_note"] = "sparse OSM mapping (<10 buildings within 500m); zero not asserted"
    else:
        q = "insufficient_coverage"
        row["quality_note"] = "no OSM buildings mapped within 500m"
    return q, row

qcol = df.apply(classify, axis=1, result_type="expand")
df["residential_data_quality_500m"] = qcol[0]
df["quality_note"] = qcol[1]

# 1km quality keyed on the same 500m mapping-evidence anchor; if 1km has residential
# polygons the values there are calculated even when 500m is sparse.
def classify_1000m(row):
    if row["residential_building_count_1000m"] > 0:
        return "calculated"
    if row["residential_data_quality_500m"] == "confirmed_zero":
        return "confirmed_zero"
    if row["residential_data_quality_500m"] == "manual_review" and row["any_building_count_1000m"] >= 1:
        return "manual_review"
    return "insufficient_coverage"

df["residential_data_quality_1000m"] = df.apply(classify_1000m, axis=1)

# NULL metric values where a zero cannot be trusted (rule: never fill missing with zero)
sparse = df["residential_data_quality_500m"].isin(["manual_review", "insufficient_coverage"])
df.loc[sparse, METRICS_500] = pd.NA
sparse1 = df["residential_data_quality_1000m"].isin(["manual_review", "insufficient_coverage"])
df.loc[sparse1, METRICS_1KM] = pd.NA

# landuse-present-but-no-verified-residential note
lu_only = (df["residential_landuse_coverage_500m_pct"].fillna(0) > 0) & (df["residential_building_count_500m"].fillna(0) == 0)
note = "landuse=residential present but zero verified residential buildings"
existing = df.loc[lu_only, "quality_note"].astype(str)
df.loc[lu_only, "quality_note"] = (existing + "; " + note).str.replace("^; ", "", regex=False)

df["dwelling_data_quality"] = "unavailable_dwelling"
df["dwelling_units_reason"] = "OSM building:units on 28 polygons Malaysia-wide (15 in residential tag set); no licensed national dwelling-unit register; building counts not converted per spec"

out_path = os.path.join(BASE, "data", "residential_quality_1849.csv")
df.to_csv(out_path, index=False)

print("quality distributions:")
print(" 500m:", df["residential_data_quality_500m"].value_counts().to_dict())
print(" 1km :", df["residential_data_quality_1000m"].value_counts().to_dict())
print(" P/U split of calculated (500m):")
print(df[df["residential_data_quality_500m"] == "calculated"]["sample_class"].value_counts().to_dict())
print("landuse-only note rows:", int(lu_only.sum()))
print("saved", out_path)
