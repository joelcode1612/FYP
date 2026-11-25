"""Recommendation search over the imported property catalogue.

Scope and honesty contract
==========================

This service ranks **real, existing** catalogue listings
(the ``fyp.catalogue_properties`` view over the canonical
``fyp.rental_properties`` research rows, 955 rows) against the
entrepreneur's stated requirements. It performs the whole pipeline
server-side: SQL filtering → requirement evaluation → deterministic
ordering → cursor pagination. Neither client sorts or loads the catalogue.

What this build does NOT do: load the trained recommendation ``.joblib``.
The artifact is not present in this repository, so the model seam reports
``available: false`` with a machine-readable reason and **no score is
invented**. The ordering that is returned is a documented *requirement-fit
ordering* (see :func:`_rank_key`), not a model output. Callers must label it
as such; the API says so in ``model.score_type``.

Deliberate distinctions
-----------------------

* A requirement that the catalogue cannot answer (for example "ground floor"
  — the catalogue has no floor column) is reported as **unverified**, never
  as unmet. Silently treating unknown data as a failed requirement is the
  same class of error as treating NULL as 0.
* Missing rental/size is impossible in this dataset (100 % coverage), but the
  SQL still refuses rows without them: a listing with no rent cannot be
  evaluated against a budget.
* Every returned property passed the strict PU eligibility gate
  (``suitability_score > 50`` on the verified 0-100 scale) BEFORE
  requirement-fit ranking. The threshold is never lowered to fill a result
  page, the score is reported per card, and it remains a research association
  index — not a probability of business success.
* The catalogue is the product's published property catalogue — the same id
  space (``EP-``/``MD-``) that saved-properties, assessments, property detail
  and the PU model use. Those 955 research rows are the SAME canonical
  ``fyp.rental_properties`` records, but with ``is_published = false`` so they
  can never leak into the entrepreneur Explore listing flow, whose eligibility
  rules (approved + published owner listings) are untouched here.

Performance
-----------

* One SELECT per uncached search, card columns only (13 columns, no
  ``SELECT *``), filters pushed into PostgreSQL.
* One aggregate query per search for the cache revision (count + newest
  import timestamp) — the cache is invalidated automatically when the
  catalogue changes, without Redis or a new table.
* Ranking happens over the **complete** eligible set before any pagination,
  so page 2 can never disagree with page 1.
* Results are cached per (normalised criteria, catalogue revision) in a small
  bounded in-process LRU. Each worker owns its cache; nothing is shared.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import math
import threading
from collections import OrderedDict
from dataclasses import dataclass, field, replace
from math import asin, cos, radians, sin, sqrt
from functools import lru_cache
from pathlib import Path
from typing import Any

from sqlalchemy import text
from sqlmodel import Session

from sitewise.services import recommendation_filter_fields as advanced_fields

# The score type this build actually produces. Kept as a constant so the API
# and the clients cannot drift apart, and so a future model integration can
# flip it in exactly one place.
SCORE_TYPE_REQUIREMENT_FIT = "requirement_fit_ordering"
MODEL_UNAVAILABLE_REASON = (
    "The trained recommendation artifact is not integrated in this build, so "
    "no model score is produced. Results are ordered by requirement fit only."
)

# ---------------------------------------------------------------------------
# Layer-1 PU variant
# ---------------------------------------------------------------------------
#
# Search applies the eligibility gate to live expanded64 inference. The feature
# resolver applies the artifact's missing-data policy before scoring.


@lru_cache(maxsize=12)
def _artifact_digest_cached(path: str, mtime_ns: int, size: int) -> str:
    """Hash a trusted artifact once per file identity, not on every request."""
    try:
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()[:16]
    except OSError:
        return "missing"


def _expanded_model_token() -> str:
    """Content fingerprint of the expanded64 artifact, for cache/cursor keys.

    A replaced PU artifact changes every live score, so the ranking cache and
    the cursor fingerprint must change with it. The digest reads the file
    bytes only (cheap); it does not deserialise the model.
    """
    from sitewise.ml.pu_expanded import EXPANDED_MODEL_NAME

    path = Path(__file__).resolve().parent.parent / "ml" / f"{EXPANDED_MODEL_NAME}.joblib"
    try:
        stat = path.stat()
        digest = _artifact_digest_cached(str(path), stat.st_mtime_ns, stat.st_size)
    except OSError:
        digest = "missing"
    return f"expanded64:{digest}"

# ---------------------------------------------------------------------------
# PU eligibility gate
# ---------------------------------------------------------------------------
#
#: Strict PU eligibility threshold on the verified 0-100 scale. A property is
#: eligible only when its PU score is STRICTLY greater than this value, so a
#: score of exactly 50.0 is excluded.
#:
#: Operational25 reassessment (2026-11-25, shadow mode): 905 eligible canonical
#: properties scored, median 37.34, mean 38.65, 111/905 (12.3%) exceeded 50;
#: 11/916 had no measurable required input. The supplied artifact reports mean
#: holdout AUC 0.704 and supplies no per-property held-out scores, so there is
#: no evidence for changing the gate. It remains 50 for BOTH variants; do not
#: lower it merely to increase recommendation volume.
PU_ELIGIBILITY_THRESHOLD = 50.0
PU_SCORE_SCALE = "0-100"

# ---------------------------------------------------------------------------
# Ordering
# ---------------------------------------------------------------------------
#
#: The orderings the API accepts. ``best_match`` is the requirement-fit
#: ordering this build documents; the rest are transparent single-column
#: orderings of the SAME eligible set, so switching sort never changes which
#: properties qualify — only their sequence. Every key ends with the catalogue
#: id, which keeps the order total and therefore cursor pagination safe.
SORT_BEST_MATCH = "best_match"

SORT_OPTIONS: dict[str, str] = {
    SORT_BEST_MATCH: "Best requirement match",
    "rent_asc": "Lowest monthly rent",
    "rent_desc": "Highest monthly rent",
    "size_desc": "Largest floor area",
    "size_asc": "Smallest floor area",
    "pu_desc": "Highest PU research index",
}
DEFAULT_SORT = SORT_BEST_MATCH

# ---------------------------------------------------------------------------
# Contextual filter fields
# ---------------------------------------------------------------------------
#
#: What each recommendation field actually does to the eligible set. This is
#: declared once, here, and travels with the facets response so the UI cannot
#: present a ranking-only or unverifiable field as an eligibility filter.
#:
#: ``hard_filter``  — applied in the search SQL; a selected value removes
#:                    properties that do not satisfy it.
#: ``ranking_only`` — never removes a property. ``business_type`` is the
#:                    entrepreneur's own stated business type: recorded with
#:                    the search and used where verifiable competitor and
#:                    preference evidence supports it, but it neither filters
#:                    nor re-sequences this ranking.
#: ``unverified``   — the catalogue records nothing that can answer it, so the
#:                    field is reported per property as an unverifiable
#:                    requirement and affects neither filtering nor ordering.
#:                    "Target market" arrives as ``layout_preferences``; there
#:                    is no customer-mix column in ``fyp.catalogue_properties``.
FILTER_FIELDS: tuple[dict[str, str], ...] = (
    {
        "key": "preferred_state",
        "label": "Preferred state",
        "role": "hard_filter",
        "effect": "Only listings in the selected state remain eligible.",
    },
    {
        "key": "city",
        "label": "City / District",
        "role": "hard_filter",
        "effect": "Only properties in the selected city or district remain eligible.",
    },
    {
        "key": "property_type",
        "label": "Property type",
        "role": "hard_filter",
        "effect": "Only listings of the selected type remain eligible.",
    },
    {
        "key": "rental_budget",
        "label": "Monthly rental budget",
        "role": "hard_filter",
        "effect": "Only listings whose monthly rent falls in the selected "
                  "range remain eligible.",
    },
    {
        "key": "property_size",
        "label": "Preferred property size",
        "role": "hard_filter",
        "effect": "Only listings whose floor area falls in the selected range "
                  "remain eligible.",
    },
    {
        "key": "preferred_area",
        "label": "Preferred area",
        "role": "hard_filter",
        "effect": "Only listings whose city or address mentions the area "
                  "remain eligible.",
    },
    {
        "key": "query",
        "label": "Search",
        "role": "hard_filter",
        "effect": "Only listings whose title, address, city, type or id "
                  "match the text remain eligible.",
    },
    {
        "key": "business_type",
        "label": "Business type",
        "role": "ranking_only",
        "effect": "Recorded as the entrepreneur's stated business type. It "
                  "does not remove properties and does not re-sequence them; "
                  "the selection is used where verifiable competitor and "
                  "preference evidence supports it.",
    },
    {
        "key": "target_market",
        "label": "Target market",
        "role": "unverified",
        "effect": "The catalogue records no customer-mix field, so this is "
                  "reported per property as a requirement that cannot be "
                  "verified. It neither filters nor ranks.",
    },
)

#: The ``FILTER_FIELDS`` keys whose selection narrows the eligible set.
HARD_FILTER_KEYS = tuple(
    field["key"] for field in FILTER_FIELDS if field["role"] == "hard_filter"
)

#: Target number of rental/size options. The generated intervals are always
#: non-overlapping; this only steers how many of them the data is cut into.
FACET_TARGET_BUCKETS = 6

#: Rounded interval widths, smallest first, used to pick a readable step.
_FACET_STEP_MULTIPLES = (1.0, 2.0, 2.5, 5.0, 10.0)

# Card payload: exactly what a listing card renders. Detail pages load the
# full record separately, so no gallery/description is fetched here.
_CARD_COLUMNS = (
    "p.id",
    "p.title",
    "p.address",
    "p.city",
    "p.state",
    "p.postcode",
    "p.rental_rm",
    "p.size_sqft",
    "p.latitude",
    "p.longitude",
    "p.property_type",
    "p.image_url",
    "p.suitability_score",
)

_MAX_CACHE_ENTRIES = 24
_CACHE: OrderedDict[str, list[dict[str, Any]]] = OrderedDict()
_CACHE_LOCK = threading.Lock()

#: One batch read of analytical columns is reused across searches and facet
#: calls until the catalogue revision changes. No per-card geospatial query.
_ADVANCED_CACHE: dict[str, dict[str, dict[str, Any]]] = {}


@dataclass(frozen=True)
class SearchCriteria:
    """Normalised, validated search criteria.

    Built by the API layer from the request body, so the service never has to
    re-interpret raw client input.
    """

    business_type: str | None = None
    preferred_state: str | None = None
    preferred_area: str | None = None
    min_rental_rm: float | None = None
    max_rental_rm: float | None = None
    min_size_sqft: float | None = None
    max_size_sqft: float | None = None
    property_type: str | None = None
    layout_preferences: tuple[str, ...] = ()
    query: str | None = None
    page_size: int = 20
    cursor: str | None = None
    sort: str = DEFAULT_SORT
    managed_only: bool = False
    management_ids: tuple[str, ...] = ()

    # Dependent location and advanced selections. ``city`` is the district
    # read from the property address — the research catalogue's ``city``
    # column is empty for every row, so the address is the authoritative
    # location source. Missing advanced measurements are never matched.
    city: str | None = None
    location_latitude: float | None = None
    location_longitude: float | None = None
    nearby_radius_km: float | None = None
    floor_level: str | None = None
    transit_max_m: float | None = None
    nearby_parking_min: float | None = None
    fnb_competition_max: float | None = None
    demand_generator: str | None = None
    population_min_1000m: float | None = None
    population_max_1000m: float | None = None

    def cache_payload(self) -> dict[str, Any]:
        """Everything that changes the ranked result — and nothing else.

        ``page_size`` and ``cursor`` are excluded on purpose: the cache stores
        the full ranked list, so two page requests share one entry. ``sort`` IS
        included: two orderings are two different rankings, and the cursor
        fingerprint is derived from this payload, so a cursor issued under one
        sort is rejected under another instead of returning page N of the wrong
        sequence.
        """
        return {
            "business_type": (self.business_type or "").strip().lower(),
            "state": (self.preferred_state or "").strip(),
            "area": (self.preferred_area or "").strip(),
            "city": (self.city or "").strip(),
            # Search-local consent data, never persisted in a user profile.
            "nearby": {
                "lat": self.location_latitude,
                "lon": self.location_longitude,
                "radius_km": self.nearby_radius_km,
            },
            "advanced": {
                key: advanced_fields.selected(self, key)
                for key in advanced_fields.FIELDS
            },
            "population_max": self.population_max_1000m,
            "min_rent": self.min_rental_rm,
            "max_rent": self.max_rental_rm,
            "min_size": self.min_size_sqft,
            "max_size": self.max_size_sqft,
            "type": (self.property_type or "").strip(),
            "layout": [p.strip().lower() for p in self.layout_preferences if p.strip()],
            "q": (self.query or "").strip().lower(),
            "sort": self.sort if self.sort in SORT_OPTIONS else DEFAULT_SORT,
            "managed_only": self.managed_only,
            "management_scope": (
                hashlib.sha256("\n".join(self.management_ids).encode()).hexdigest()[:16]
                if self.managed_only else ""
            ),
            # The PU variant and artifact fingerprint change the eligible SET,
            # so they are part of the cache/cursor identity: a cursor issued
            # under one model can never serve a page of another model's
            # ranking, and replacing the artifact invalidates cached pages.
            "pu_model": _expanded_model_token(),
        }


@dataclass(frozen=True)
class _Match:
    label: str
    met: bool | None  # None = the catalogue cannot verify this requirement

    @property
    def state(self) -> str:
        if self.met is True:
            return "met"
        if self.met is False:
            return "unmet"
        return "unverified"


@dataclass
class _Row:
    id: str
    title: str
    address: str
    city: str
    state: str
    postcode: str
    rental_rm: float
    size_sqft: float
    latitude: float | None
    longitude: float | None
    property_type: str
    image_url: str | None
    suitability_score: float | None
    matches: list[_Match] = field(default_factory=list)
    #: Live expanded64 association score (raw 0-1). Set ONLY by the expanded64
    #: ranking path; legacy rows keep it None so the stored score is used.
    expanded_score: float | None = None
    #: The model version that produced [expanded_score], for provenance.
    expanded_model_version: str | None = None
    #: Verified advanced measurements, loaded in ONE batch query. An absent
    #: measurement stays None — never zero, never a guess.
    advanced: dict[str, Any] = field(default_factory=dict)

    @property
    def district(self) -> str:
        """The City / District shown in the UI: the address prefix."""
        return str(self.address or "").split(",", 1)[0].strip()

    @property
    def pu_score(self) -> float | None:
        """The ranking PU score on the 0-100 scale, whichever path produced it.

        Expanded64 rows carry the live model output x100; legacy rows carry
        the stored catalogue value. The two never coexist on one row, and one
        ranking batch only ever contains rows of one path.
        """
        if self.expanded_score is not None:
            return self.expanded_score * 100.0
        return self.suitability_score

    @property
    def pu_score_source(self) -> str:
        return "expanded64_live_inference" if self.expanded_score is not None else "stored_catalogue"

    @property
    def met_count(self) -> int:
        return sum(1 for m in self.matches if m.met is True)

    @property
    def unmet_count(self) -> int:
        return sum(1 for m in self.matches if m.met is False)


def _money(value: float) -> str:
    # Malaysian Ringgit with a space between the symbol and the grouped
    # amount: "RM 3,000", never "RM3000". Used by the range labels the
    # monthly-rental dropdown shows verbatim.
    return f"RM {value:,.0f}"


def _number(value: float) -> str:
    return f"{value:,.0f}"


def _pu_eligibility() -> dict[str, Any]:
    """The gate every facet count already respects."""
    return {
        "threshold": PU_ELIGIBILITY_THRESHOLD,
        "scale": PU_SCORE_SCALE,
        "comparison": "strictly_greater_than",
        "column": "live_expanded64_inference",
        "score_meaning": (
            "Uncalibrated P-vs-U research association index, not a probability "
            "of commercial success."
        ),
    }


def _has_selection(criteria: SearchCriteria, key: str) -> bool:
    """Whether the entrepreneur currently holds a constraint for this field."""
    values = {
        "preferred_state": criteria.preferred_state,
        "property_type": criteria.property_type,
        "rental_budget": criteria.min_rental_rm if criteria.min_rental_rm is not None
        else criteria.max_rental_rm,
        "property_size": criteria.min_size_sqft if criteria.min_size_sqft is not None
        else criteria.max_size_sqft,
        "preferred_area": criteria.preferred_area,
        "city": criteria.city,
        "query": criteria.query,
        "floor_level": criteria.floor_level,
        "transit_walk_m": criteria.transit_max_m,
        "nearby_parking_500m": criteria.nearby_parking_min,
        "fnb_competition_500m": criteria.fnb_competition_max,
        "demand_generator": criteria.demand_generator,
        "surrounding_population_1000m": criteria.population_min_1000m,
    }
    value = values.get(key)
    if isinstance(value, str):
        return bool(value.strip())
    return value is not None


def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance between two points in km, not travel time."""
    d_lat = radians(lat2 - lat1)
    d_lon = radians(lon2 - lon1)
    a = sin(d_lat / 2) ** 2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(d_lon / 2) ** 2
    return 6371.0088 * 2 * asin(min(1, sqrt(a)))


def _within_nearby(row: _Row, criteria: SearchCriteria) -> bool:
    """Exclude unmeasured/invalid property coordinates, never treat as zero."""
    if criteria.location_latitude is None:
        return True
    lat, lon = row.latitude, row.longitude
    if lat is None or lon is None or not (-90 <= lat <= 90 and -180 <= lon <= 180):
        return False
    if lat == 0 and lon == 0:
        return False
    assert criteria.location_longitude is not None
    assert criteria.nearby_radius_km is not None
    return _haversine_km(criteria.location_latitude, criteria.location_longitude,
                         lat, lon) <= criteria.nearby_radius_km


def _satisfies(row: _Row, criteria: SearchCriteria, *, excluding: str | None) -> bool:
    """The Python mirror of the hard filters :meth:`_query` pushes into SQL.

    Counting contextual options needs the same predicates applied to the rows
    the search already returned, with one field released. The comparison is the
    SQL comparison — inclusive bounds for rent and size, exact match for state
    and type, case-insensitive substring for the area and free-text search —
    and :mod:`tests.test_recommendation_facets` checks it against real queries
    over the live catalogue, so a drift between the two is a failing test, not a
    silently wrong count.
    """
    if not _within_nearby(row, criteria):
        return False
    if excluding != "rental_budget":
        max_rent, min_rent = criteria.max_rental_rm, criteria.min_rental_rm
        if max_rent is not None and row.rental_rm > max_rent:
            return False
        if min_rent is not None and row.rental_rm < min_rent:
            return False
    if excluding != "property_size":
        min_size, max_size = criteria.min_size_sqft, criteria.max_size_sqft
        if min_size is not None and row.size_sqft < min_size:
            return False
        if max_size is not None and row.size_sqft > max_size:
            return False
    state = "" if excluding == "preferred_state" else (criteria.preferred_state or "")
    if state and row.state != state:
        return False
    ptype = "" if excluding == "property_type" else (criteria.property_type or "")
    if ptype and row.property_type != ptype:
        return False
    area = "" if excluding == "preferred_area" else (criteria.preferred_area or "")
    if area:
        needle = area.lower()
        if needle not in row.city.lower() and needle not in row.address.lower():
            return False
    term = "" if excluding == "query" else (criteria.query or "")
    if term:
        needle = term.lower()
        haystack = (row.title, row.address, row.city, row.property_type, row.id)
        if not any(needle in value.lower() for value in haystack):
            return False
    if excluding != "city" and criteria.city:
        if row.district.casefold() != criteria.city.strip().casefold():
            return False
    # Advanced filters use verified measurements only: an unmeasured value
    # can never satisfy a selection. They are analytical columns joined once
    # for the whole candidate set (one query, never one query per card).
    if not advanced_fields.matches(row.advanced, criteria, excluding=excluding):
        return False
    return True


def _value_counts(
    rows: list[_Row],
    value_of: Any,
    *,
    keep: str | None,
) -> list[dict[str, Any]]:
    """Real values with real counts, most available first.

    Blank values never become options. ``keep`` is the entrepreneur's own
    selection: it stays listed with a count of zero when nothing matches it,
    because a dropdown that silently drops the value on screen would be
    clearing a choice nobody asked it to clear.
    """
    counts: dict[str, int] = {}
    for row in rows:
        value = str(value_of(row) or "").strip()
        if not value:
            continue
        counts[value] = counts.get(value, 0) + 1
    selected = (keep or "").strip()
    if selected and selected not in counts:
        counts[selected] = 0
    return [
        {"value": value, "total": total}
        for value, total in sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    ]


def _facet_step(lowest: float, highest: float) -> float:
    """A readable interval width for the observed span.

    Derived from the data, never a fixed list: RM 500–20,000 and 118–5,760
    square feet need different steps, and a re-imported catalogue with a
    different span gets different intervals without a code change.
    """
    raw = (highest - lowest) / FACET_TARGET_BUCKETS
    if raw <= 0:
        return 1.0
    magnitude = 10 ** math.floor(math.log10(raw))
    for multiple in _FACET_STEP_MULTIPLES:
        step = multiple * magnitude
        if step >= raw:
            return max(step, 1.0)
    return 10.0 * magnitude


def _range_label(
    money: bool,
    low: float | None,
    high: float | None,
    unit: str = "sq ft",
) -> str:
    """The interval in words, matching the bounds it actually sends.

    ``None`` on one side is a genuine open interval — a saved preference can
    hold a ceiling with no floor — and is labelled as one rather than being
    rounded into a number nobody chose.
    """
    def amount(value: float) -> str:
        return f"RM {value:,.0f}" if money else f"{value:,.0f}"

    if low is not None and high is not None and low == high:
        return f"{_money(low)}" if money else f"{_number(high)} {unit}"
    if money:
        if low is None:
            return f"Up to {_money(high)}" if high is not None else "Any available budget"
        return f"{_money(low)} – {_money(high)}" if high is not None else f"From {_money(low)}"
    if low is None:
        return f"Up to {_number(high)} {unit}" if high is not None else f"Any {unit}"
    return (
        f"{_number(low)} – {_number(high)} {unit}"
        if high is not None
        else f"{_number(low)}+ {unit}"
    )


def _numeric_ranges(
    rows: list[_Row],
    value_of: Any,
    *,
    keys: tuple[str, str],
    money: bool,
    unit: str = "sq ft",
) -> list[dict[str, Any]]:
    """Non-overlapping intervals built from the values that actually exist.

    Each bound is an observed rental or floor-area figure from the scoped set,
    so consecutive intervals can neither overlap (an upper bound is always
    strictly below the next lower bound) nor leave a priced listing outside
    every option (the bounds come from the listing's own value). The count is
    then exactly what the ``min``/``max`` pair sent to the search returns — no
    rounding of a boundary into or out of a range.
    """
    values: dict[float, int] = {}
    for row in rows:
        value = value_of(row)
        if value is None:
            continue
        key = float(value)
        values[key] = values.get(key, 0) + 1
    if not values:
        return []
    distinct = sorted(values)
    step = _facet_step(distinct[0], distinct[-1])
    low_key, high_key = keys
    options: list[dict[str, Any]] = []
    index = 0
    while index < len(distinct):
        low = distinct[index]
        limit = low + step
        end = index
        while end + 1 < len(distinct) and distinct[end + 1] < limit:
            end += 1
        options.append(
            {
                low_key: low,
                high_key: distinct[end],
                "total": sum(values[value] for value in distinct[index : end + 1]),
                "label": _range_label(money, low, distinct[end], unit),
            }
        )
        index = end + 1
    return options


def _selected_range(
    low: float | None,
    high: float | None,
    options: list[dict[str, Any]],
    low_key: str,
    high_key: str,
    *,
    money: bool,
    matching_total: int,
) -> dict[str, Any] | None:
    """The active interval, whether or not it is one of the generated options.

    A saved preference can hold bounds the catalogue never offers as a bucket
    (``max_rental_rm = 25000`` with no floor, for instance). Reporting it
    separately keeps that choice visible and counted instead of pretending the
    entrepreneur never made it.
    """
    if low is None and high is None:
        return None
    for option in options:
        if option[low_key] == low and option[high_key] == high:
            return {
                low_key: low,
                high_key: high,
                "label": option["label"],
                "total": option["total"],
                "generated": True,
            }
    return {
        low_key: low,
        high_key: high,
        "label": _range_label(money, low, high),
        "total": matching_total,
        "generated": False,
    }


def _span(rows: list[_Row], value_of: Any, *, lowest: bool) -> float | None:
    """Observed bound over the eligible population, None when there is none."""
    present = [float(value_of(row)) for row in rows if value_of(row) is not None]
    if not present:
        return None
    return min(present) if lowest else max(present)


class StaleRankingCursor(ValueError):
    """The current ranking no longer matches the requested page."""


class RecommendationSearchService:
    """Read-only ranking over the catalogue. One instance per request."""

    #: Whether the most recent :meth:`search` was served from the cache.
    #: Reported in ``meta.cached`` so the client (and the verification script)
    #: can tell a cached ranking from a freshly computed one.
    _last_cache_hit: bool = False

    def __init__(self, session: Session, app_session: Session | None = None):
        self.session = session
        # Operational25 snapshots live in the application database; the
        # research catalogue used by this search service lives in analytics.
        self.app_session = app_session or session

    # -- public API ---------------------------------------------------------

    def _model_metadata(self) -> dict[str, Any]:
        """The Layer-1 PU provenance block for one search response."""
        try:
            from sitewise.ml.model_loader import ModelLoader
            from sitewise.ml.pu_expanded import EXPANDED_MODEL_NAME

            loaded = ModelLoader().load_cached(EXPANDED_MODEL_NAME)
            return {
                "available": True,
                "version": str(loaded.meta.get("model_variant") or "unknown"),
                "feature_count": len(loaded.feature_names),
                "artifact": loaded.meta.get("artifact_filename"),
                "score_type": "live_pu_association_requirement_fit_ordering",
                "reason": (
                    "Ranking gates and tie-breaks on LIVE inference from the "
                    "expanded 64-feature research artifact; every candidate in "
                    "one ranking used this same model version."
                ),
                "research_only": True,
                "production_ready": bool(loaded.meta.get("production_ready", False)),
            }
        except Exception as exc:  # noqa: BLE001 - report honestly, never fake
            return {
                "available": False,
                "version": None,
                "score_type": SCORE_TYPE_REQUIREMENT_FIT,
                "reason": f"The expanded64 artifact could not be loaded: {exc}",
                "research_only": True,
            }

    def search(self, criteria: SearchCriteria) -> dict[str, Any]:
        ranked = self._ranked_candidates(criteria)
        # Advanced selections are applied server-side to the FULL eligible
        # set before pagination. The ranked cache itself is never narrowed:
        # a later search without these selections must still see every row.
        self._advanced(ranked)
        ranked = [row for row in ranked if _satisfies(row, criteria, excluding=None)]
        total = len(ranked)

        ranking_revision = hashlib.sha256(
            json.dumps([row.id for row in ranked], separators=(",", ":")).encode("utf-8")
        ).hexdigest()
        offset = self._decode_cursor(criteria, ranking_revision)
        page = ranked[offset : offset + criteria.page_size]
        next_offset = offset + len(page)
        has_more = next_offset < total

        return {
            "data": [
                self._serialise(row, rank=offset + index + 1, criteria=criteria)
                for index, row in enumerate(page)
            ],
            "pagination": {
                "next_cursor": (
                    self._encode_cursor(criteria, next_offset, ranking_revision) if has_more else None
                ),
                "has_more": has_more,
                "total": total,
                "page_size": criteria.page_size,
            },
            "model": self._model_metadata(),
            "meta": {
                "source": "fyp.catalogue_properties",
                "property_source": "catalog",
                "criteria": criteria.cache_payload(),
                "cached": self._last_cache_hit,
                # Eligibility provenance: every result passed this gate BEFORE
                # requirement-fit ranking. The threshold is never relaxed to
                # reach a target count. Under expanded64 the gate runs on LIVE
                # model scores after feature resolution (properties whose
                # vector does not resolve are excluded with their missing
                # fields reported), not on the stored catalogue column.
                "pu_eligibility": {
                    "threshold": PU_ELIGIBILITY_THRESHOLD,
                    "scale": PU_SCORE_SCALE,
                    "comparison": "strictly_greater_than",
                    "column": "live_expanded64_inference",
                    "score_meaning": (
                        "Uncalibrated P-vs-U research association index, not a "
                        "probability of commercial success."
                    ),
                },
            },
        }

    def _advanced_options(
        self,
        active: SearchCriteria,
        scoped: dict[str, list[_Row]],
    ) -> dict[str, Any]:
        """Real options and counts for each data-supported advanced filter."""
        units = {
            "transit_walk_m": "m",
            "nearby_parking_500m": "facilities",
            "fnb_competition_500m": "outlets",
            "surrounding_population_1000m": "people",
        }
        result: dict[str, Any] = {}
        for key, (label, kind, group, source) in advanced_fields.FIELDS.items():
            block: dict[str, Any] = {
                "label": label,
                "kind": kind,
                "group": group,
                "source": source,
            }
            rows = scoped[key]
            if kind == "value":
                block["options"] = _value_counts(
                    rows,
                    lambda row, k=key: (row.advanced.get(k) or "").strip(),
                    keep=advanced_fields.selected(active, key),
                )
            elif kind == "choice":
                options = [
                    {
                        "value": choice,
                        "label": text,
                        "total": sum(
                            1
                            for row in rows
                            if row.advanced.get("demand", {}).get(choice) is True
                        ),
                    }
                    for choice, text in advanced_fields.DEMAND_OPTIONS.items()
                ]
                wanted = str(advanced_fields.selected(active, key) or "").strip()
                if wanted and not any(item["value"] == wanted for item in options):
                    options.append(
                        {"value": wanted, "label": wanted, "total": 0}
                    )
                block["options"] = options
            else:
                block["options"] = _numeric_ranges(
                    rows,
                    lambda row, k=key: row.advanced.get(k),
                    keys=("min_value", "max_value"),
                    money=False,
                    unit=units[key],
                )
            result[key] = block
        return result

    def facets(self, criteria: SearchCriteria | None = None) -> dict[str, Any]:
        """Filter vocabulary and ranges, contextualised to the selections.

        A hand-written list drifts: an option that matches no row filters every
        listing out while still looking functional. The counts are contextual in
        the leave-one-out sense the UI needs: for each dropdown every OTHER
        selected hard filter is applied and only that dropdown's own constraint
        is dropped. Choosing Johor therefore prices the rental options with
        Johor listings, and choosing a budget restates which states and types
        still have anything inside it.

        Everything is counted over the same PU-gated population the search
        ranks, before pagination, and nothing is counted from a result page.
        """
        active = criteria or SearchCriteria()
        universe = self._facet_universe(active)
        self._advanced(universe)
        keys = HARD_FILTER_KEYS + tuple(advanced_fields.FIELDS)
        scoped = {
            key: [r for r in universe if _satisfies(r, active, excluding=key)] for key in keys
        }
        matching = [r for r in universe if _satisfies(r, active, excluding=None)]

        budget_options = _numeric_ranges(
            scoped["rental_budget"],
            lambda row: row.rental_rm,
            keys=("min_rental_rm", "max_rental_rm"),
            money=True,
        )
        size_options = _numeric_ranges(
            scoped["property_size"],
            lambda row: row.size_sqft,
            keys=("min_size_sqft", "max_size_sqft"),
            money=False,
        )
        labels = {field["key"]: field["label"] for field in FILTER_FIELDS}
        labels.update(
            {key: value[0] for key, value in advanced_fields.FIELDS.items()}
        )
        return {
            "states": _value_counts(
                scoped["preferred_state"], lambda row: row.state, keep=active.preferred_state
            ),
            "property_types": _value_counts(
                scoped["property_type"],
                lambda row: row.property_type,
                keep=active.property_type,
            ),
            # City / District is derived from the address prefix: the
            # catalogue's city column is empty for every research row.
            "cities": _value_counts(
                scoped["city"], lambda row: row.district, keep=active.city
            ),
            # Advanced options are generated ONLY from properties with a
            # measured value; NULL is never bucketed as zero. Counts are
            # leave-one-out over the same eligible set as the result list.
            "advanced": self._advanced_options(active, scoped),
            # The accepted orderings travel with the facets so the client does
            # not keep a second copy of this list. Order matters: the first
            # entry is the default.
            "sort_options": [
                {"value": value, "label": label}
                for value, label in SORT_OPTIONS.items()
            ],
            # Contextual rental/size choices. `options` never overlap and never
            # leave a priced listing outside every interval, because each bound
            # is a rental or floor-area value that exists in the scoped set;
            # selecting one sends exactly those two bounds to the search.
            "rental_ranges": {
                "options": budget_options,
                "unbounded_total": len(scoped["rental_budget"]),
                "selected": _selected_range(
                    active.min_rental_rm,
                    active.max_rental_rm,
                    budget_options,
                    "min_rental_rm",
                    "max_rental_rm",
                    money=True,
                    matching_total=len(matching),
                ),
            },
            "size_ranges": {
                "options": size_options,
                "unbounded_total": len(scoped["property_size"]),
                "selected": _selected_range(
                    active.min_size_sqft,
                    active.max_size_sqft,
                    size_options,
                    "min_size_sqft",
                    "max_size_sqft",
                    money=False,
                    matching_total=len(matching),
                ),
            },
            # Listings under every selection (the live "N properties match"
            # figure) and under none of them, so an empty combination can be
            # stated as a fact instead of an error.
            "matching_total": len(matching),
            "universe_total": len(universe),
            "relaxations": sorted(
                (
                    {
                        "field": key,
                        "label": labels[key],
                        "total": len(scoped[key]),
                    }
                    for key in keys
                    if _has_selection(active, key)
                ),
                key=lambda item: (-item["total"], item["label"]),
            ),
            "fields": [dict(field) for field in FILTER_FIELDS],
            "contextual": True,
            "pu_eligibility": _pu_eligibility(),
            "ranges": {
                # Bounds of the eligible population, not of the whole
                # catalogue: the two differ and the UI quotes these.
                "min_rental_rm": _span(universe, lambda row: row.rental_rm, lowest=True),
                "max_rental_rm": _span(universe, lambda row: row.rental_rm, lowest=False),
                "min_size_sqft": _span(universe, lambda row: row.size_sqft, lowest=True),
                "max_size_sqft": _span(universe, lambda row: row.size_sqft, lowest=False),
                "total": len(universe),
            },
        }

    def _facet_universe(self, criteria: SearchCriteria) -> list[_Row]:
        """Every listing the search could return, before the user's filters.

        Built by the same ranking call the search uses, with the user's hard
        filters removed, so the PU gate, the non-null rental/size requirement
        and the management scope are applied exactly once and in exactly one
        way — the model is never inferred a second time for the facets, and the
        result shares the search's cache entry whenever nothing is selected.
        """
        browse = replace(
            criteria,
            preferred_state=None,
            preferred_area=None,
            min_rental_rm=None,
            max_rental_rm=None,
            min_size_sqft=None,
            max_size_sqft=None,
            property_type=None,
            city=None,
            floor_level=None,
            transit_max_m=None,
            nearby_parking_min=None,
            fnb_competition_max=None,
            demand_generator=None,
            population_min_1000m=None,
            population_max_1000m=None,
            query=None,
            sort=DEFAULT_SORT,
            cursor=None,
        )
        rows = self._ranked_candidates(browse)
        # The facet universe must agree with the nearby results count.
        if criteria.location_latitude is not None:
            rows = [row for row in rows if _within_nearby(row, criteria)]
        return rows

    # -- ranking ------------------------------------------------------------

    def _ranked_candidates(self, criteria: SearchCriteria) -> list[_Row]:
        """Rank on LIVE expanded64 inference — the stored score is not used.

        Every candidate in one call is scored with the SAME artifact version
        (the cache key carries the artifact digest, so a replaced artifact
        cannot serve a stale ranking). A property whose 64-feature vector does
        not resolve reports the missing fields and is EXCLUDED from this
        ranking — it is never imputed, never borrowed, and never gated on the
        stored legacy score it does have.
        """
        from sitewise.ml.pu_expanded import EXPANDED_MODEL_NAME, expanded_scores_many
        from sitewise.ml.model_loader import ModelLoader
        from sitewise.ml import operational25 as op25
        from sitewise.ml.pu_variant import resolve_variant

        variant = resolve_variant()
        revision = self._catalogue_revision()
        key = self._cache_key(
            criteria, revision,
            model_token=(f"operational25:{op25.ARTIFACT_SHA256}"
                         if variant.key == "operational25" else _expanded_model_token()),
        )
        cached = self._cache_get(key)
        if cached is not None:
            self._last_cache_hit = True
            return cached

        self._last_cache_hit = False
        rows = self._query(criteria)
        if rows:
            if variant.key == "operational25":
                from sitewise.services.operational25_enrichment import score_for_catalogue_id

                version = variant.version or op25.MODEL_NAME
                scores = {
                    row.id: score_for_catalogue_id(self.app_session, row.id)
                    for row in rows
                }
            else:
                loaded = ModelLoader().load_cached(EXPANDED_MODEL_NAME)
                version = str(loaded.meta.get("model_variant") or "unknown")
                scores = expanded_scores_many(self.session, [row.id for row in rows])
            eligible: list[_Row] = []
            for row in rows:
                row.matches = self._evaluate(row, criteria)
                result = scores.get(row.id) or {}
                if not result.get("available"):
                    continue  # unavailable features: excluded, never fabricated
                score = float(result["score"])
                # Same strictly-above threshold on the 0-100 scale, applied to
                # the LIVE score. The threshold was reviewed against the
                # expanded model's own score distribution (47.7% of its
                # training rows pass) before being applied here.
                if not (score * 100.0 > PU_ELIGIBILITY_THRESHOLD):
                    continue
                row.expanded_score = score
                row.suitability_score = None  # the stored value is a DIFFERENT model's output
                row.expanded_model_version = version
                eligible.append(row)
            rows = eligible
        rows.sort(key=_sort_key(criteria.sort))
        self._cache_put(key, rows)
        return rows

    def _catalogue_revision(self) -> str:
        """Cheap fingerprint of the catalogue's current content.

        Count + newest import timestamp is enough to invalidate on re-import.
        Rental/price edits without a re-import are caught by the 30 s TTL on
        the whole cache entry (see :meth:`_cache_get`).
        """
        row = self.session.execute(
            text(
                "SELECT count(*) AS total, max(imported_at) AS newest, "
                "(SELECT max(created_at) FROM fyp.verification_audit "
                "WHERE action IN ('property_published','property_unpublished','property_rejected','property_information_requested')) AS publication_revision "
                "FROM fyp.catalogue_properties"
            )
        ).mappings().first()
        return f"{int(row['total'])}:{row['newest']}:{row['publication_revision']}"

    @staticmethod
    def _cache_key(criteria: SearchCriteria, revision: str, model_token: str = "") -> str:
        payload = json.dumps(
            {"criteria": criteria.cache_payload(), "revision": revision, "model": model_token},
            sort_keys=True,
            separators=(",", ":"),
        )
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()

    @staticmethod
    def _cache_get(key: str) -> list[_Row] | None:
        with _CACHE_LOCK:
            rows = _CACHE.get(key)
            if rows is not None:
                _CACHE.move_to_end(key)
            return rows

    @staticmethod
    def _cache_put(key: str, rows: list[_Row]) -> None:
        with _CACHE_LOCK:
            _CACHE[key] = rows
            _CACHE.move_to_end(key)
            while len(_CACHE) > _MAX_CACHE_ENTRIES:
                _CACHE.popitem(last=False)

    def _advanced(self, rows: list[_Row]) -> None:
        """Attach verified analytical values in ONE query per catalogue version."""
        if not rows:
            return
        revision = self._catalogue_revision()
        values = _ADVANCED_CACHE.get(revision)
        if values is None:
            values = advanced_fields.load_all(self.session)
            with _CACHE_LOCK:
                _ADVANCED_CACHE.clear()
                _ADVANCED_CACHE[revision] = values
        for row in rows:
            row.advanced = values.get(row.id, {})

    def _query(self, criteria: SearchCriteria) -> list[_Row]:
        """Candidate query for the expanded64 path — NO stored-score gate.

        The stored ``suitability_score`` is the LEGACY model's output; gating
        on it here would mix two model versions in one ranking. Eligibility is
        applied after live expanded64 scoring in
        :meth:`_ranked_candidates`.
        """
        where = [
            "p.rental_rm IS NOT NULL",
            "p.size_sqft IS NOT NULL",
        ]
        params: dict[str, Any] = {}
        if criteria.managed_only:
            if not criteria.management_ids:
                return []
            where.append("p.id = ANY(:managed_ids)")
            params["managed_ids"] = list(criteria.management_ids)

        if criteria.max_rental_rm is not None:
            where.append("p.rental_rm <= CAST(:max_rent AS double precision)")
            params["max_rent"] = criteria.max_rental_rm
        if criteria.min_rental_rm is not None:
            where.append("p.rental_rm >= CAST(:min_rent AS double precision)")
            params["min_rent"] = criteria.min_rental_rm
        if criteria.min_size_sqft is not None:
            where.append("p.size_sqft >= CAST(:min_size AS double precision)")
            params["min_size"] = criteria.min_size_sqft
        if criteria.max_size_sqft is not None:
            where.append("p.size_sqft <= CAST(:max_size AS double precision)")
            params["max_size"] = criteria.max_size_sqft
        if criteria.preferred_state:
            where.append("p.state = :state")
            params["state"] = criteria.preferred_state
        if criteria.property_type:
            where.append("p.property_type = :ptype")
            params["ptype"] = criteria.property_type
        if criteria.preferred_area:
            where.append("(p.city ILIKE :area OR p.address ILIKE :area)")
            params["area"] = f"%{criteria.preferred_area}%"
        if criteria.city:
            # The research catalogue's city column is empty; its address
            # prefix is the authoritative district (mirrored in _satisfies).
            where.append("lower(split_part(p.address, ',', 1)) = lower(:city)")
            params["city"] = criteria.city.strip()
        if criteria.query:
            where.append(
                "(p.title ILIKE :q OR p.address ILIKE :q OR p.city ILIKE :q "
                "OR p.property_type ILIKE :q OR p.id ILIKE :q)"
            )
            params["q"] = f"%{criteria.query}%"

        sql = (
            f"SELECT {', '.join(_CARD_COLUMNS)} FROM fyp.catalogue_properties p "
            f"WHERE {' AND '.join(where)}"
        )
        rows = self.session.execute(text(sql), params).mappings().all()
        return [_to_row(row) for row in rows]

    @staticmethod
    def _evaluate(row: _Row, criteria: SearchCriteria) -> list[_Match]:
        """Requirement evaluation against real catalogue fields.

        Labels are business language and are the same strings the UI shows, so
        there is no second copy of the rules in Dart.
        """
        matches: list[_Match] = []

        if criteria.max_rental_rm is not None:
            matches.append(
                _Match(
                    f"Monthly rental within {_money(criteria.max_rental_rm)}",
                    row.rental_rm <= criteria.max_rental_rm,
                )
            )
        if criteria.min_rental_rm is not None and criteria.min_rental_rm > 0:
            matches.append(
                _Match(
                    f"Monthly rental at least {_money(criteria.min_rental_rm)}",
                    row.rental_rm >= criteria.min_rental_rm,
                )
            )
        if criteria.min_size_sqft is not None and criteria.min_size_sqft > 0:
            matches.append(
                _Match(
                    f"Floor area at least {_number(criteria.min_size_sqft)} sq ft",
                    row.size_sqft >= criteria.min_size_sqft,
                )
            )
        if criteria.max_size_sqft is not None and criteria.max_size_sqft > 0:
            matches.append(
                _Match(
                    f"Floor area within {_number(criteria.max_size_sqft)} sq ft",
                    row.size_sqft <= criteria.max_size_sqft,
                )
            )
        if criteria.preferred_state:
            matches.append(
                _Match(f"In {criteria.preferred_state}", row.state == criteria.preferred_state)
            )
        if criteria.preferred_area:
            needle = criteria.preferred_area.lower()
            matches.append(
                _Match(
                    f"In {criteria.preferred_area}",
                    needle in row.city.lower() or needle in row.address.lower(),
                )
            )
        if criteria.property_type:
            matches.append(
                _Match(
                    f"{criteria.property_type} property type",
                    row.property_type == criteria.property_type,
                )
            )

        # Layout preferences are real user inputs, but the catalogue records no
        # floor/unit/layout column. Reporting them as "unverified" is the only
        # honest answer — inventing a match, or a mismatch, would both lie.
        for preference in criteria.layout_preferences:
            label = preference.strip()
            if label:
                matches.append(_Match(label, None))

        return matches

    def _serialise(self, row: _Row, *, rank: int, criteria: SearchCriteria) -> dict[str, Any]:
        matched = [m.label for m in row.matches if m.met is True]
        unmatched = [m.label for m in row.matches if m.met is False]
        unverified = [m.label for m in row.matches if m.met is None]
        verifiable = len(matched) + len(unmatched)
        return {
            "property_id": row.id,
            "property_source": "catalog",
            "title": row.title,
            "address": row.address,
            "city": row.city,
            "state": row.state,
            "postcode": row.postcode,
            "rental_rm": row.rental_rm,
            "size_sqft": row.size_sqft,
            "property_type": row.property_type,
            "district": row.district,
            # Verified research characteristics for the Selected Property
            # panel. A field with no measurement is reported as unavailable
            # by its absence, never as zero.
            "characteristics": {
                "floor_level": row.advanced.get("floor_level"),
                "transit_walk_m": row.advanced.get("transit_walk_m"),
                "nearby_parking_500m": row.advanced.get("nearby_parking_500m"),
                "fnb_competition_500m": row.advanced.get("fnb_competition_500m"),
                "demand_generators": [
                    label
                    for key, label in advanced_fields.DEMAND_OPTIONS.items()
                    if row.advanced.get("demand", {}).get(key) is True
                ],
                "population_1000m": row.advanced.get("surrounding_population_1000m"),
            },
            "image_url": row.image_url,
            "latitude": row.latitude,
            "longitude": row.longitude,
            "research": {
                # Workbook association index: a relative research ranking
                # input, never a business-success probability. Under the
                # default variant this value IS the stored PU score x100
                # (verified); under expanded64 it is None — the stored value
                # belongs to a DIFFERENT model and must not leak into an
                # expanded ranking — and ``pu_score`` carries the LIVE
                # expanded64 score x100 instead.
                "catalog_suitability_score": row.suitability_score,
                "suitability_available": row.suitability_score is not None,
                "pu_score": row.pu_score,
                "pu_available": row.pu_score is not None,
                "pu_score_scale": PU_SCORE_SCALE,
                "pu_score_source": row.pu_score_source,
                "pu_model_version": row.expanded_model_version,
            },
            "recommendation": {
                "available": False,
                "rank": rank,
                "score": None,
                "score_type": SCORE_TYPE_REQUIREMENT_FIT,
                "model_version": row.expanded_model_version,
                "reason": MODEL_UNAVAILABLE_REASON,
                "matched_requirements": matched,
                "unmatched_requirements": unmatched,
                "unverified_requirements": unverified,
                "match_ratio": (
                    round(len(matched) / verifiable, 4) if verifiable else None
                ),
                "matched_count": len(matched),
                "verifiable_count": verifiable,
            },
        }

    # -- cursor -------------------------------------------------------------

    @staticmethod
    def _encode_cursor(criteria: SearchCriteria, offset: int, revision: str = "") -> str:
        raw = json.dumps(
            {"o": offset, "k": _criteria_fingerprint(criteria), "r": revision},
            separators=(",", ":"),
        ).encode("utf-8")
        return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")

    def _decode_cursor(self, criteria: SearchCriteria, revision: str = "") -> int:
        """Offset encoded in the cursor, or 0.

        A cursor from a *different* search is rejected instead of silently
        returning page N of the wrong ranking — that is the failure mode that
        makes paging look correct while showing duplicated or missing rows.
        """
        cursor = (criteria.cursor or "").strip()
        if not cursor:
            return 0
        try:
            padded = cursor + "=" * (-len(cursor) % 4)
            payload = json.loads(base64.urlsafe_b64decode(padded.encode("ascii")))
            offset = int(payload["o"])
            key = str(payload["k"])
        except (ValueError, KeyError, TypeError, binascii.Error) as exc:
            raise ValueError("The pagination cursor is not valid.") from exc
        if key != _criteria_fingerprint(criteria):
            raise ValueError(
                "The pagination cursor belongs to a different search. "
                "Restart the search from the first page."
            )
        if payload.get("r", "") != revision:
            raise StaleRankingCursor("The ranking changed. Restart the search from the first page.")
        if offset < 0:
            raise ValueError("The pagination cursor is not valid.")
        return offset


def _criteria_fingerprint(criteria: SearchCriteria) -> str:
    payload = json.dumps(criteria.cache_payload(), sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


def _rank_key(row: _Row) -> tuple:
    """Deterministic requirement-fit ordering with PU tie-breaks.

    Most requirements met first, fewest contradicted second, then HIGHER PU
    score (all rows already passed the strict >50 eligibility gate), then the
    largest budget headroom, then the largest size headroom, then the catalogue
    id.

    Requirement fit stays the primary ranking signal — an existing preference
    outcome is never overridden by a research score, and no undocumented weight
    is applied to any model output. The final id tie-break makes the order
    total and stable, which is what makes cursor pagination safe.
    """
    return (
        -row.met_count,
        row.unmet_count,
        -round(row.pu_score or 0.0, 6),
        round(row.rental_rm, 2),  # cheaper first = more budget headroom
        -round(row.size_sqft, 2),  # larger floor area first = more space headroom
        row.id,
    )


def _sort_key(sort: str):
    """The ordering function for one accepted sort key.

    Every alternative ordering ends with the catalogue id so the sequence is
    total and stable — the same guarantee cursor pagination relies on. The
    eligible SET is identical for all of them; sort only re-sequences it, so no
    ordering can surface a property that failed the PU gate or the filters.
    All orderings are purely numeric; none consults the selected business
    type.

    An unknown value falls back to ``best_match`` rather than raising: the API
    layer already rejects unknown values with 422, and a stale client must
    never receive an unsorted list.
    """
    if sort == "rent_asc":
        return lambda row: (round(row.rental_rm, 2), row.id)
    if sort == "rent_desc":
        return lambda row: (-round(row.rental_rm, 2), row.id)
    if sort == "size_desc":
        return lambda row: (-round(row.size_sqft, 2), row.id)
    if sort == "size_asc":
        return lambda row: (round(row.size_sqft, 2), row.id)
    if sort == "pu_desc":
        return lambda row: (-round(row.pu_score or 0.0, 6), row.id)
    return lambda row: _rank_key(row)


def _as_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _to_row(row: Any) -> _Row:
    return _Row(
        id=str(row["id"]),
        title=str(row["title"] or ""),
        address=str(row["address"] or ""),
        city=str(row["city"] or ""),
        state=str(row["state"] or ""),
        postcode=str(row["postcode"] or ""),
        rental_rm=float(row["rental_rm"]),
        size_sqft=float(row["size_sqft"]),
        latitude=_as_float(row["latitude"]),
        longitude=_as_float(row["longitude"]),
        property_type=str(row["property_type"] or ""),
        image_url=row["image_url"],
        suitability_score=_as_float(row["suitability_score"]),
    )

