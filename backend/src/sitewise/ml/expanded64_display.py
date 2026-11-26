"""Human-readable presentation of the 64 Expanded64 measurements.

The model contract is a list of 64 column names. Nobody outside the ML code
should ever see one: ``pop_age_65_plus_1km`` is not a sentence, and a raw
number without its unit and its radius is not a measurement — "3 421" could be
people, buildings or metres.

This module is the single catalogue that turns a contract name into something
an entrepreneur can read:

* a **label** (``Age 65+ · 1 km``),
* a **unit** (``people``, ``km/km²``, ``%``, ``m`` — empty for a plain count),
* a **radius** in metres (``None`` for point-distance and isochrone values),
* a **group** with a title and a one-line description of what the group means
  for a business location.

It also answers the two questions the pipeline has to be able to ask:

* :func:`coverage_gap` — which contract features have no display entry, i.e.
  which measurements would render as a raw column name. The pipeline asserts
  this is empty.
* :func:`orphaned` — which display entries no longer exist in the contract,
  i.e. catalogue drift after a model change.

Nothing here calculates, imputes or scores anything. It is presentation only,
so a display gap can never change a number.
"""
from __future__ import annotations

from dataclasses import dataclass

#: Display order of the eight measured groups. Mirrors
#: ``sitewise.services.expanded64_enrichment.CATEGORIES`` and the shared Dart
#: ``LocationAnalysisRules.measurementGroupOrder``.
GROUP_ORDER: tuple[str, ...] = (
    "population",
    "age",
    "residential",
    "demand",
    "competition",
    "transit",
    "network",
    "parking",
)

#: District socio-economic statistics are shown between "age" and
#: "residential" in the UI. They are DOSM district values, not property
#: measurements and not model inputs, so they are deliberately outside
#: ``GROUP_ORDER`` and outside the 64-feature catalogue.
SOCIOECONOMIC_GROUP = "socioeconomic"
SOCIOECONOMIC_AFTER = "age"

GROUP_TITLES: dict[str, str] = {
    "population": "Nearby population",
    "age": "Population by age",
    "residential": "Residential surroundings",
    "demand": "Nearby demand generators",
    "competition": "Food and beverage competition",
    "transit": "Public transport",
    "network": "Road, walking and driving access",
    "parking": "Parking",
    SOCIOECONOMIC_GROUP: "Household and income",
}

GROUP_DESCRIPTIONS: dict[str, str] = {
    "population": (
        "How many people live within a short walk of the location. More "
        "nearby residents means a larger immediate catchment."
    ),
    "age": (
        "Who those residents are. A young-adult share supports cafes and "
        "fitness; a family share supports groceries and education."
    ),
    "residential": (
        "How densely built-up the surroundings are. Residential density is "
        "the difference between a catchment and an empty road."
    ),
    "demand": (
        "Places that already pull people to the area — offices, schools, "
        "retail, hospitals. They generate footfall you do not have to create."
    ),
    "competition": (
        "Existing food and beverage outlets within the same radii. High "
        "counts mean proven demand and also a harder fight for share."
    ),
    "transit": (
        "Whether customers can arrive without a car, and how far they must "
        "walk to do it."
    ),
    "network": (
        "Street connectivity and how much area — and population — is "
        "genuinely reachable on foot or by car in ten minutes."
    ),
    "parking": (
        "Whether a customer who drives can stop nearby. For a dine-in "
        "business this decides the evening trade."
    ),
    SOCIOECONOMIC_GROUP: (
        "District-level household statistics. They describe the wider area, "
        "not this property, and are shown for context only."
    ),
}

#: District socio-economic rows, read from the backend ``district_context``
#: block. Each is ``(field, label, unit)``.
DISTRICT_ROWS: tuple[tuple[str, str, str], ...] = (
    ("income_median", "Median household income (district)", "RM/month"),
    ("income_mean", "Mean household income (district)", "RM/month"),
    ("expenditure_mean", "Mean household expenditure (district)", "RM/month"),
    ("gini", "Income inequality, Gini (district)", ""),
    ("poverty", "Poverty rate (district)", "%"),
)


@dataclass(frozen=True)
class MeasurementDisplay:
    """How one contract feature is presented to a reader.

    ``radius_m`` is the measurement buffer in metres, or ``None`` for a
    distance to the nearest facility (the value *is* a distance) and for the
    ten-minute isochrones (the value is an area or a population inside a
    travel-time shed, not a circle).
    """

    name: str
    group: str
    label: str
    unit: str
    radius_m: int | None

    @property
    def group_title(self) -> str:
        return GROUP_TITLES[self.group]


#: The 64-entry catalogue, in display order. Written out explicitly rather than
#: derived from the column names: a derived label is how ``pop_age_65_plus_1km``
#: ends up on screen as "Pop Age 65 Plus 1km".
_CATALOGUE: tuple[MeasurementDisplay, ...] = (
    # ---------------------------------------------------------- population (4)
    MeasurementDisplay("pop_500m", "population", "Population · 500 m", "people", 500),
    MeasurementDisplay("pop_1000m", "population", "Population · 1 km", "people", 1000),
    MeasurementDisplay("pop_2000m", "population", "Population · 2 km", "people", 2000),
    MeasurementDisplay("pop_3000m", "population", "Population · 3 km", "people", 3000),
    # ----------------------------------------------------------------- age (12)
    MeasurementDisplay("pop_age_0_14_500m", "age", "Age 0–14 · 500 m", "people", 500),
    MeasurementDisplay("pop_age_15_24_500m", "age", "Age 15–24 · 500 m", "people", 500),
    MeasurementDisplay("pop_age_25_34_500m", "age", "Age 25–34 · 500 m", "people", 500),
    MeasurementDisplay("pop_age_35_49_500m", "age", "Age 35–49 · 500 m", "people", 500),
    MeasurementDisplay("pop_age_50_64_500m", "age", "Age 50–64 · 500 m", "people", 500),
    MeasurementDisplay("pop_age_65_plus_500m", "age", "Age 65+ · 500 m", "people", 500),
    MeasurementDisplay("pop_age_0_14_1km", "age", "Age 0–14 · 1 km", "people", 1000),
    MeasurementDisplay("pop_age_15_24_1km", "age", "Age 15–24 · 1 km", "people", 1000),
    MeasurementDisplay("pop_age_25_34_1km", "age", "Age 25–34 · 1 km", "people", 1000),
    MeasurementDisplay("pop_age_35_49_1km", "age", "Age 35–49 · 1 km", "people", 1000),
    MeasurementDisplay("pop_age_50_64_1km", "age", "Age 50–64 · 1 km", "people", 1000),
    MeasurementDisplay("pop_age_65_plus_1km", "age", "Age 65+ · 1 km", "people", 1000),
    # --------------------------------------------------------- residential (8)
    MeasurementDisplay(
        "residential_building_count_500m", "residential",
        "Residential buildings · 500 m", "", 500,
    ),
    MeasurementDisplay(
        "residential_building_count_1000m", "residential",
        "Residential buildings · 1 km", "", 1000,
    ),
    MeasurementDisplay(
        "residential_building_density_500m_km2", "residential",
        "Residential building density · 500 m", "buildings/km²", 500,
    ),
    MeasurementDisplay(
        "residential_building_density_1000m_km2", "residential",
        "Residential building density · 1 km", "buildings/km²", 1000,
    ),
    MeasurementDisplay(
        "residential_footprint_coverage_500m_pct", "residential",
        "Residential footprint coverage · 500 m", "%", 500,
    ),
    MeasurementDisplay(
        "residential_footprint_coverage_1000m_pct", "residential",
        "Residential footprint coverage · 1 km", "%", 1000,
    ),
    MeasurementDisplay(
        "residential_landuse_coverage_500m_pct", "residential",
        "Residential land-use coverage · 500 m", "%", 500,
    ),
    MeasurementDisplay(
        "residential_landuse_coverage_1000m_pct", "residential",
        "Residential land-use coverage · 1 km", "%", 1000,
    ),
    # -------------------------------------------------------------- demand (14)
    MeasurementDisplay("office_pois_500m", "demand", "Offices · 500 m", "", 500),
    MeasurementDisplay("office_pois_1000m", "demand", "Offices · 1 km", "", 1000),
    MeasurementDisplay("schools_count_500m", "demand", "Schools · 500 m", "", 500),
    MeasurementDisplay("schools_count_1000m", "demand", "Schools · 1 km", "", 1000),
    MeasurementDisplay(
        "universities_colleges_count_500m", "demand",
        "Universities and colleges · 500 m", "", 500,
    ),
    MeasurementDisplay(
        "universities_colleges_count_1000m", "demand",
        "Universities and colleges · 1 km", "", 1000,
    ),
    MeasurementDisplay("retail_pois_500m", "demand", "Retail outlets · 500 m", "", 500),
    MeasurementDisplay("retail_pois_1000m", "demand", "Retail outlets · 1 km", "", 1000),
    MeasurementDisplay("malls_count_500m", "demand", "Malls · 500 m", "", 500),
    MeasurementDisplay("malls_count_1000m", "demand", "Malls · 1 km", "", 1000),
    MeasurementDisplay("hospitals_count_500m", "demand", "Hospitals · 500 m", "", 500),
    MeasurementDisplay("hospitals_count_1000m", "demand", "Hospitals · 1 km", "", 1000),
    MeasurementDisplay(
        "supermarkets_count_500m", "demand", "Supermarkets · 500 m", "", 500,
    ),
    MeasurementDisplay(
        "supermarkets_count_1000m", "demand", "Supermarkets · 1 km", "", 1000,
    ),
    # --------------------------------------------------------- competition (10)
    MeasurementDisplay(
        "fnb_competitors_500m", "competition", "F&B competitors · 500 m", "", 500,
    ),
    MeasurementDisplay(
        "fnb_competitors_1000m", "competition", "F&B competitors · 1 km", "", 1000,
    ),
    MeasurementDisplay("cafe_count_500m", "competition", "Cafés · 500 m", "", 500),
    MeasurementDisplay("cafe_count_1000m", "competition", "Cafés · 1 km", "", 1000),
    MeasurementDisplay(
        "restaurant_count_500m", "competition", "Restaurants · 500 m", "", 500,
    ),
    MeasurementDisplay(
        "restaurant_count_1000m", "competition", "Restaurants · 1 km", "", 1000,
    ),
    MeasurementDisplay(
        "fast_food_count_500m", "competition", "Fast food · 500 m", "", 500,
    ),
    MeasurementDisplay(
        "fast_food_count_1000m", "competition", "Fast food · 1 km", "", 1000,
    ),
    MeasurementDisplay(
        "bakery_dessert_beverage_count_500m", "competition",
        "Bakeries, dessert and beverage · 500 m", "", 500,
    ),
    MeasurementDisplay(
        "bakery_dessert_beverage_count_1000m", "competition",
        "Bakeries, dessert and beverage · 1 km", "", 1000,
    ),
    # ------------------------------------------------------------- transit (5)
    MeasurementDisplay(
        "nearest_transit_walk_m", "transit",
        "Nearest transit stop (walking)", "m", None,
    ),
    MeasurementDisplay(
        "transit_stops_500m_walk", "transit",
        "Transit stops · 500 m walking", "", 500,
    ),
    MeasurementDisplay(
        "transit_stops_1km_walk", "transit",
        "Transit stops · 1 km walking", "", 1000,
    ),
    MeasurementDisplay(
        "weekday_transit_routes_1km_walk", "transit",
        "Weekday transit routes · 1 km walking", "", 1000,
    ),
    MeasurementDisplay(
        "weekday_departures_500m_walk_am", "transit",
        "Weekday morning departures · 500 m walking", "", 500,
    ),
    # ------------------------------------------------------------- network (8)
    MeasurementDisplay(
        "nearest_major_road_m", "network", "Nearest major road", "m", None,
    ),
    MeasurementDisplay(
        "road_intersection_density_500m_km2", "network",
        "Road intersection density · 500 m", "intersections/km²", 500,
    ),
    MeasurementDisplay(
        "road_length_density_500m_km_km2", "network",
        "Road density · 500 m", "km/km²", 500,
    ),
    MeasurementDisplay(
        "osm_walkway_length_density_500m_km_km2", "network",
        "Walkway density · 500 m", "km/km²", 500,
    ),
    MeasurementDisplay(
        "road_length_density_1km_km_km2", "network",
        "Road density · 1 km", "km/km²", 1000,
    ),
    MeasurementDisplay(
        "walk_isochrone_area_10min_km2", "network",
        "Walkable area · 10 min", "km²", None,
    ),
    MeasurementDisplay(
        "worldpop_walk_reachable_10min", "network",
        "Population reachable on foot · 10 min", "people", None,
    ),
    MeasurementDisplay(
        "drive_isochrone_area_10min_km2", "network",
        "Drivable area · 10 min", "km²", None,
    ),
    # ------------------------------------------------------------- parking (3)
    MeasurementDisplay(
        "parking_facilities_500m", "parking", "Parking facilities · 500 m", "", 500,
    ),
    MeasurementDisplay(
        "parking_facilities_1km", "parking", "Parking facilities · 1 km", "", 1000,
    ),
    MeasurementDisplay(
        "nearest_parking_distance_m", "parking", "Nearest parking", "m", None,
    ),
)

_BY_NAME: dict[str, MeasurementDisplay] = {item.name: item for item in _CATALOGUE}


def catalogue() -> tuple[MeasurementDisplay, ...]:
    """Every displayed measurement, in display order."""
    return _CATALOGUE


def display(name: str) -> MeasurementDisplay:
    """The display entry for one contract feature.

    Falls back to a readable form of the column name rather than raising: a
    display gap must never be able to fail a measurement response. The fallback
    is detectable through :func:`coverage_gap`, which the pipeline treats as an
    error.
    """
    entry = _BY_NAME.get(name)
    if entry is not None:
        return entry
    group = group_of(name) or "network"
    return MeasurementDisplay(
        name=name, group=group, label=name.replace("_", " "), unit="", radius_m=None
    )


def group_of(name: str) -> str | None:
    """The group a contract feature belongs to, or ``None`` if unknown."""
    entry = _BY_NAME.get(name)
    if entry is not None:
        return entry.group
    try:
        from sitewise.services.expanded64_enrichment import _category

        return _category(name)
    except (ValueError, ImportError):
        return None


def group_rows(group: str) -> tuple[MeasurementDisplay, ...]:
    """Every catalogue entry in one group, in display order."""
    return tuple(item for item in _CATALOGUE if item.group == group)


def coverage_gap(contract_names) -> tuple[str, ...]:
    """Contract features with no display entry, sorted.

    A non-empty result means a measurement would be shown under its raw column
    name. Callers that render measurements must treat this as a defect.
    """
    return tuple(sorted(name for name in contract_names if name not in _BY_NAME))


def orphaned(contract_names) -> tuple[str, ...]:
    """Catalogue entries the contract no longer contains, sorted.

    A non-empty result means the catalogue has drifted from the model; the
    stale entries are harmless to display but should be removed.
    """
    names = set(contract_names)
    return tuple(sorted(item.name for item in _CATALOGUE if item.name not in names))


def used_by_model(name: str, contract_names) -> bool:
    """Whether this measurement is an input to the active model.

    Informational measurements (for example the standardised v2 inputs while
    the original artifact is active) are still real measurements; this flag
    only explains why one of them does not move the score.
    """
    return name in set(contract_names)


def district_rows() -> tuple[tuple[str, str, str], ...]:
    """District socio-economic rows: ``(field, label, unit)``."""
    return DISTRICT_ROWS
