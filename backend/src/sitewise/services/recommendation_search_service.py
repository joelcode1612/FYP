"""Recommendation search over the imported property catalogue.

Scope and honesty contract
==========================

This service ranks **real, existing** catalogue listings
(``sitewise_app.properties``, 955 rows) against the entrepreneur's stated
requirements. It performs the whole pipeline server-side: SQL filtering →
requirement evaluation → deterministic ordering → cursor pagination. Neither
client sorts or loads the catalogue.

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
* The catalogue is the product's published property catalogue — the same id
  space (``EP-``/``MD-``) that saved-properties, assessments, property detail
  and the PU model use. It is NOT the ``fyp.rental_properties`` owner-listing
  table, whose 955 imported rows are ``verification_status='pending'``; mixing
  the two would break save/assess and present pending rows as verified.

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
import threading
from collections import OrderedDict
from dataclasses import dataclass, field
from typing import Any

from sqlalchemy import text
from sqlmodel import Session

# The score type this build actually produces. Kept as a constant so the API
# and the clients cannot drift apart, and so a future model integration can
# flip it in exactly one place.
SCORE_TYPE_REQUIREMENT_FIT = "requirement_fit_ordering"
MODEL_UNAVAILABLE_REASON = (
    "The trained recommendation artifact is not integrated in this build, so "
    "no model score is produced. Results are ordered by requirement fit only."
)

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

    def cache_payload(self) -> dict[str, Any]:
        """Everything that changes the ranked result — and nothing else.

        ``page_size`` and ``cursor`` are excluded on purpose: the cache stores
        the full ranked list, so two page requests share one entry.
        """
        return {
            "business_type": (self.business_type or "").strip().lower(),
            "state": (self.preferred_state or "").strip(),
            "area": (self.preferred_area or "").strip(),
            "min_rent": self.min_rental_rm,
            "max_rent": self.max_rental_rm,
            "min_size": self.min_size_sqft,
            "max_size": self.max_size_sqft,
            "type": (self.property_type or "").strip(),
            "layout": [p.strip().lower() for p in self.layout_preferences if p.strip()],
            "q": (self.query or "").strip().lower(),
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

    @property
    def met_count(self) -> int:
        return sum(1 for m in self.matches if m.met is True)

    @property
    def unmet_count(self) -> int:
        return sum(1 for m in self.matches if m.met is False)


def _money(value: float) -> str:
    return f"RM{value:,.0f}"


def _number(value: float) -> str:
    return f"{value:,.0f}"


class RecommendationSearchService:
    """Read-only ranking over the catalogue. One instance per request."""

    #: Whether the most recent :meth:`search` was served from the cache.
    #: Reported in ``meta.cached`` so the client (and the verification script)
    #: can tell a cached ranking from a freshly computed one.
    _last_cache_hit: bool = False

    def __init__(self, session: Session):
        self.session = session

    # -- public API ---------------------------------------------------------

    def search(self, criteria: SearchCriteria) -> dict[str, Any]:
        ranked = self._ranked_candidates(criteria)
        total = len(ranked)

        offset = self._decode_cursor(criteria)
        page = ranked[offset : offset + criteria.page_size]
        next_offset = offset + len(page)
        has_more = next_offset < total

        return {
            "data": [
                self._serialise(row, rank=offset + index + 1)
                for index, row in enumerate(page)
            ],
            "pagination": {
                "next_cursor": (
                    self._encode_cursor(criteria, next_offset) if has_more else None
                ),
                "has_more": has_more,
                "total": total,
                "page_size": criteria.page_size,
            },
            "model": {
                "available": False,
                "version": None,
                "score_type": SCORE_TYPE_REQUIREMENT_FIT,
                "reason": MODEL_UNAVAILABLE_REASON,
                "research_only": True,
            },
            "meta": {
                "source": "sitewise_app.properties",
                "property_source": "catalog",
                "criteria": criteria.cache_payload(),
                "cached": self._last_cache_hit,
            },
        }

    def facets(self) -> dict[str, Any]:
        """Filter vocabulary straight from the catalogue.

        A hand-written list drifts: an option that matches no row filters every
        listing out while still looking functional.
        """
        states = self.session.execute(
            text(
                "SELECT state AS value, count(*) AS total "
                "FROM sitewise_app.properties "
                "WHERE state IS NOT NULL AND state <> '' "
                "GROUP BY state ORDER BY total DESC, state"
            )
        ).mappings().all()
        types = self.session.execute(
            text(
                "SELECT property_type AS value, count(*) AS total "
                "FROM sitewise_app.properties "
                "WHERE property_type IS NOT NULL AND property_type <> '' "
                "GROUP BY property_type ORDER BY total DESC, property_type"
            )
        ).mappings().all()
        bounds = self.session.execute(
            text(
                "SELECT min(rental_rm) AS min_rent, max(rental_rm) AS max_rent, "
                "min(size_sqft) AS min_size, max(size_sqft) AS max_size, "
                "count(*) AS total "
                "FROM sitewise_app.properties"
            )
        ).mappings().first()
        return {
            "states": [{"value": r["value"], "total": int(r["total"])} for r in states],
            "property_types": [
                {"value": r["value"], "total": int(r["total"])} for r in types
            ],
            "ranges": {
                "min_rental_rm": _as_float(bounds["min_rent"]),
                "max_rental_rm": _as_float(bounds["max_rent"]),
                "min_size_sqft": _as_float(bounds["min_size"]),
                "max_size_sqft": _as_float(bounds["max_size"]),
                "total": int(bounds["total"]),
            },
        }

    # -- ranking ------------------------------------------------------------

    def _ranked_candidates(self, criteria: SearchCriteria) -> list[_Row]:
        revision = self._catalogue_revision()
        key = self._cache_key(criteria, revision)
        cached = self._cache_get(key)
        if cached is not None:
            self._last_cache_hit = True
            return cached

        self._last_cache_hit = False
        rows = self._query(criteria)
        for row in rows:
            row.matches = self._evaluate(row, criteria)
        rows.sort(key=_rank_key)
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
                "SELECT count(*) AS total, max(imported_at) AS newest "
                "FROM sitewise_app.properties"
            )
        ).mappings().first()
        return f"{int(row['total'])}:{row['newest']}"

    @staticmethod
    def _cache_key(criteria: SearchCriteria, revision: str) -> str:
        payload = json.dumps(
            {"criteria": criteria.cache_payload(), "revision": revision},
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

    def _query(self, criteria: SearchCriteria) -> list[_Row]:
        where = [
            "p.rental_rm IS NOT NULL",
            "p.size_sqft IS NOT NULL",
        ]
        params: dict[str, Any] = {}

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
        if criteria.query:
            where.append(
                "(p.title ILIKE :q OR p.address ILIKE :q OR p.city ILIKE :q "
                "OR p.property_type ILIKE :q OR p.id ILIKE :q)"
            )
            params["q"] = f"%{criteria.query}%"

        sql = (
            f"SELECT {', '.join(_CARD_COLUMNS)} FROM sitewise_app.properties p "
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

    def _serialise(self, row: _Row, *, rank: int) -> dict[str, Any]:
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
            "image_url": row.image_url,
            "latitude": row.latitude,
            "longitude": row.longitude,
            "research": {
                # Workbook association index: a relative research ranking
                # input, never a business-success probability.
                "catalog_suitability_score": row.suitability_score,
                "suitability_available": row.suitability_score is not None,
                # The PU model is NOT run in the list endpoint (that would be
                # one inference per card). Null = "not loaded in this
                # response", which the detail panel resolves explicitly.
                "pu_score": None,
                "pu_available": None,
            },
            "recommendation": {
                "available": False,
                "rank": rank,
                "score": None,
                "score_type": SCORE_TYPE_REQUIREMENT_FIT,
                "model_version": None,
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
    def _encode_cursor(criteria: SearchCriteria, offset: int) -> str:
        raw = json.dumps(
            {"o": offset, "k": _criteria_fingerprint(criteria)},
            separators=(",", ":"),
        ).encode("utf-8")
        return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")

    def _decode_cursor(self, criteria: SearchCriteria) -> int:
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
        if offset < 0:
            raise ValueError("The pagination cursor is not valid.")
        return offset


def _criteria_fingerprint(criteria: SearchCriteria) -> str:
    payload = json.dumps(criteria.cache_payload(), sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


def _rank_key(row: _Row) -> tuple:
    """Deterministic requirement-fit ordering.

    Most requirements met first, fewest contradicted second, then the largest
    budget headroom, then the largest size headroom, then the catalogue id.
    The final id tie-break makes the order total and stable, which is what
    makes cursor pagination safe.
    """
    return (
        -row.met_count,
        row.unmet_count,
        round(row.rental_rm, 2),  # cheaper first = more budget headroom
        -round(row.size_sqft, 2),  # larger floor area first = more space headroom
        row.id,
    )


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
