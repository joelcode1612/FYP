"""Versioned calculation definitions for the recovered Expanded64 inputs.

This module is the single source of truth for the six inputs whose definitions
are being standardised for the Expanded64_v2 retraining:

* ``road_length_density_500m_km_km2``
* ``osm_walkway_length_density_500m_km_km2``
* ``pop_2000m``
* ``pop_3000m``
* ``walk_isochrone_area_10min_km2``
* ``worldpop_walk_reachable_10min``

The runtime calculators in :mod:`sitewise.ml.coordinate_features` and
:mod:`sitewise.ml.expanded64_network` import the constants below; the exact
SQL, filters, units and buffer methodology are quoted from those calculators
in ``deliverables/expanded64_v2_runtime_feature_handoff.md``. Nothing here
retrains a model, and nothing here changes the values admitted to the
original ``sitewise_pu_64_expanded`` artifact: eligibility is decided by
:func:`sitewise.ml.pu_expanded.coordinate_input_validated`, which keeps the
original allowlist unless the validated Expanded64_v2 artifact is active.
"""
from __future__ import annotations

from dataclasses import dataclass

#: Bump only when a calculation definition changes in a way that changes a
#: number. The version travels with every persisted measurement and is fenced
#: by ``fyp.property_enrichment_category.calculation_version``.
DEFINITIONS_VERSION = "expanded64-feature-definitions-v1"

# ---------------------------------------------------------------- road/walkway
# Identical to the research pipeline's STEP roads / STEP inter class sets.
ROAD_CLASSES = (
    "motorway", "trunk", "primary", "secondary", "tertiary", "unclassified",
    "residential", "living_street", "service", "motorway_link", "trunk_link",
    "primary_link", "secondary_link", "tertiary_link", "road",
)
MAJOR_CLASSES = (
    "motorway", "trunk", "primary", "secondary", "motorway_link", "trunk_link",
    "primary_link", "secondary_link",
)
WALK_CLASSES = (
    "footway", "path", "steps", "pedestrian", "corridor", "living_street", "track",
)
ALL_CLASSES = tuple(dict.fromkeys(ROAD_CLASSES + WALK_CLASSES))

ROAD_BUFFER_500M = 500
ROAD_BUFFER_1000M = 1000
#: Flat-circle areas from the research workbook. The geodesic ST_Buffer is
#: used only to clip the lines; it is deliberately NOT the denominator.
CIRCLE_500_KM2 = 0.785398163
CIRCLE_1000_KM2 = 3.141592654
JUNCTION_SEARCH_DEG = 0.0045
MAJOR_ROAD_SEARCH_DEG = 0.05
ROAD_PRECISION = 3

# ------------------------------------------------------------------- WorldPop
#: Whole 100 m pixel selected by centroid inside the named radius, on a
#: 6378137 m sphere, NoData (-99999) excluded.
POP_RADII = (500, 1000, 2000, 3000)
POP_NODATA = -99999
POP_SPHERE_RADIUS_M = 6378137.0
POP_WINDOW_DEG = 0.045
POP_INCLUSION_RULE = (
    "PIXEL_CENTRE_INSIDE_HAVERSINE_RADIUS_WHOLE_PIXEL_R6378137M_NODATA_MINUS99999_EXCLUDED"
)
POP_RASTER_VERSION = (
    "R2025A v1 / mys_pop_2025_CN_100m_R2025A_v1.tif / public.worldpop_2025_constrained"
)
POP_PRECISION = 1

# --------------------------------------------------------- 10-minute walk shed
#: Directed pgRouting tree, nearest component vertex, concave hull (no holes)
#: of vertices reached within 600 s; geodesic area in km2 to 4 decimals.
WALK_ISOCHRONE_SECONDS = 600
WALK_ISOCHRONE_WINDOW_DEG = 0.025
WALK_ISOCHRONE_HULL_RATIO = 0.90
WALK_ISOCHRONE_EXCLUDED_CLASSES = ("motorway", "motorway_link")
WALK_ISOCHRONE_AREA_PRECISION = 4
WALK_REACHABLE_POPULATION_PRECISION = 3  # Expanded64CoordinateExtractor._hull_population rounds to 3


@dataclass(frozen=True)
class FeatureDefinition:
    """One versioned measurement contract, shared by runtime and ML handoff."""

    name: str
    group: str
    source: str
    method: str
    units: str
    precision: int
    eligibility: str
    definition_version: str = DEFINITIONS_VERSION


FEATURE_DEFINITIONS: dict[str, FeatureDefinition] = {
    "road_length_density_500m_km_km2": FeatureDefinition(
        name="road_length_density_500m_km_km2",
        group="road_geometry",
        source="fyp_features.roads_v2 (OpenStreetMap, ODbL)",
        method=(
            "ST_Length(ST_Intersection(way, ST_Buffer(point::geography, 500)::geometry)"
            "::geography) summed over ROAD_CLASSES, / 1000 / 0.785398163 km2"
        ),
        units="km of road per km2 of flat 500 m circle",
        precision=ROAD_PRECISION,
        eligibility=(
            "v2 only while parity with the original Expanded64 definition is unresolved"
        ),
    ),
    "osm_walkway_length_density_500m_km_km2": FeatureDefinition(
        name="osm_walkway_length_density_500m_km_km2",
        group="road_geometry",
        source="fyp_features.roads_v2 (OpenStreetMap, ODbL)",
        method=(
            "ST_Length(ST_Intersection(way, ST_Buffer(point::geography, 500)::geometry)"
            "::geography) summed over WALK_CLASSES, / 1000 / 0.785398163 km2"
        ),
        units="km of walkway per km2 of flat 500 m circle",
        precision=ROAD_PRECISION,
        eligibility=(
            "v2 only while parity with the original Expanded64 definition is unresolved"
        ),
    ),
    "pop_2000m": FeatureDefinition(
        name="pop_2000m",
        group="population_rings",
        source="public.worldpop_2025_constrained (WorldPop R2025A v1, CC-BY-4.0)",
        method=POP_INCLUSION_RULE + "; radius 2000 m",
        units="people",
        precision=POP_PRECISION,
        eligibility="v2; raster coverage guard requires valid pixels in the ring",
    ),
    "pop_3000m": FeatureDefinition(
        name="pop_3000m",
        group="population_rings",
        source="public.worldpop_2025_constrained (WorldPop R2025A v1, CC-BY-4.0)",
        method=POP_INCLUSION_RULE + "; radius 3000 m",
        units="people",
        precision=POP_PRECISION,
        eligibility="v2; raster coverage guard requires valid pixels in the ring",
    ),
    "walk_isochrone_area_10min_km2": FeatureDefinition(
        name="walk_isochrone_area_10min_km2",
        group="isochrone_population",
        source="Expanded64CoordinateExtractor._isochrone (pgRouting, OSM, ODbL)",
        method=(
            f"concave hull ratio {WALK_ISOCHRONE_HULL_RATIO} of vertices reached in "
            f"{WALK_ISOCHRONE_SECONDS} s; ST_Area(::geography)/1e6"
        ),
        units="km2",
        precision=WALK_ISOCHRONE_AREA_PRECISION,
        eligibility="v2; requires a polygonal hull with at least three reach vertices",
    ),
    "worldpop_walk_reachable_10min": FeatureDefinition(
        name="worldpop_walk_reachable_10min",
        group="isochrone_population",
        source=(
            "Expanded64CoordinateExtractor._isochrone + "
            "public.worldpop_2025_constrained (CC-BY-4.0)"
        ),
        method="area-weighted WorldPop pixels intersecting the 600 s walk hull",
        units="people",
        precision=WALK_REACHABLE_POPULATION_PRECISION,
        eligibility="v2; requires a polygonal hull and positive raster coverage",
    ),
}


def definition(name: str) -> FeatureDefinition | None:
    """Return the versioned definition of one standardised input, if any."""
    return FEATURE_DEFINITIONS.get(name)


def definitions_for_group(group: str) -> tuple[FeatureDefinition, ...]:
    """Return all standardised inputs produced by one calculator group."""
    return tuple(
        item for item in FEATURE_DEFINITIONS.values() if item.group == group
    )


def definition_versions() -> dict[str, str]:
    """Per-feature version map for provenance in persisted measurements."""
    return {name: item.definition_version for name, item in FEATURE_DEFINITIONS.items()}
