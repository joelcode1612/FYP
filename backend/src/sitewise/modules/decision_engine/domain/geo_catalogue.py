"""Approved versioned GEO authority, projected for M2 ``GEO`` items.

Why this module exists
----------------------
``M2V2-01`` is the only ``GEO`` item registered in any instrument version. Its
stored ``option_values.rules.geography`` block declares
``status = AUTHORITY_UNVERIFIED``, ``areas = []`` and ``catalogue_version =
null``, because no catalogue was connected when the instrument was registered.
``validate_m2_answer`` consequently accepted the literal ``UNDECIDED`` and
nothing else, so an entrepreneur who had in fact decided on a study area was
forced to declare that they had not. That is the defect this module closes.

Why the catalogue is served, not stored
---------------------------------------
``m2_item_versions.option_values`` is hashed into every confirmation's
``item_definition_hashes`` (``sitewise.domain.m2_provenance.declaration_pins``),
and ``pins_match`` re-derives those hashes from the *current* row. Editing the
stored block would therefore retroactively report every existing M2V2
confirmation as unpinned — a historical-integrity break, not a correction. The
catalogue is instead supplied at serving time as ``effective_geography``, which
is exactly how ``effective_options`` already overlays conditional option domains
without touching the stored definition.

What authority is reused
------------------------
``GEO_V1`` — the versioned geographic authority that
``services.business_context_v1`` validates against. Its jurisdiction and
district-count tables now live here so there is a single definition rather than
two; ``business_context_v1`` imports them unchanged.

Granularity, and what is deliberately absent
--------------------------------------------
``GEO_V1`` names four jurisdictions (``1`` Johor, ``7`` Pulau Pinang, ``10``
Selangor, ``14`` W.P. Kuala Lumpur) and knows how many districts each contains,
but it carries no district names and no district-level catalogue content: no
``MY-ADM2`` name list exists anywhere in this repository and
``public.district_demographic`` is empty. ``M2V2-01`` asks for a study area at
jurisdiction granularity and its own ``source_rules`` forbid inferring an exact
premises location, so the catalogue is projected at jurisdiction level only.

``area_ref`` is ``MY-ADM1-`` plus the GEO_V1 jurisdiction source code. The code
is GEO_V1's own; the prefix follows the ``MY-ADM2-`` convention GEO_V1 already
uses for districts, one administrative level up. No jurisdiction name is
invented and no district is fabricated — district-level references remain
unavailable rather than guessed, which is why ``granularity`` is published
alongside the areas and asserted by the tests.
"""
from __future__ import annotations

import hashlib
import json

#: Catalogue family name accepted by ``business_context_v1``'s GEO binding.
GEO_V1_FAMILY = 'GEO_V1'

#: GEO_V1 jurisdiction source code -> the jurisdiction's own registered name.
GEO_V1_JURISDICTIONS = {
    '1': 'Johor',
    '7': 'Pulau Pinang',
    '10': 'Selangor',
    '14': 'W.P. Kuala Lumpur',
}

#: GEO_V1 administrative district count per jurisdiction source code. A district
#: code is only valid in ``1..count``; the names themselves are not available.
GEO_V1_DISTRICT_COUNTS = {'1': 10, '7': 5, '10': 9, '14': 1}

#: ``area_id`` prefix GEO_V1 already uses for administrative level 2.
DISTRICT_AREA_PREFIX = 'MY-ADM2-'

#: Prefix used for the administrative level 1 projection defined here.
JURISDICTION_AREA_PREFIX = 'MY-ADM1-'

JURISDICTION_GRANULARITY = 'JURISDICTION'

#: A stored GEO block that declares it has no connected authority. Only this
#: exact status is overlaid: any other non-verified status is a different
#: declaration and is left to fail closed.
UNVERIFIED_STATUS = 'AUTHORITY_UNVERIFIED'
VERIFIED_STATUS = 'VERIFIED'

CATALOGUE_VERSION = GEO_V1_FAMILY

#: Stable label for the value the catalogue accepts when the entrepreneur has
#: not decided. Never a fabricated area.
UNDECIDED = 'UNDECIDED'


def jurisdiction_source_codes() -> tuple[str, ...]:
    """GEO_V1 jurisdiction codes in administrative order (1, 7, 10, 14)."""
    return tuple(sorted(GEO_V1_JURISDICTIONS, key=int))


def jurisdiction_area_ref(source_code: str) -> str:
    """The ``area_ref`` for one GEO_V1 jurisdiction.

    Raises ``KeyError`` for an unregistered code so a caller cannot mint a
    reference the authority does not know.
    """
    code = str(source_code)
    if code not in GEO_V1_JURISDICTIONS:
        raise KeyError(code)
    return JURISDICTION_AREA_PREFIX + code


def jurisdiction_area(source_code: str) -> dict:
    """One catalogue entry: the exact shape ``validate_m2_answer`` accepts."""
    code = str(source_code)
    return {
        'jurisdiction': GEO_V1_JURISDICTIONS[code],
        'area_ref': jurisdiction_area_ref(code),
        'catalogue_version': CATALOGUE_VERSION,
    }


def jurisdiction_areas() -> list[dict]:
    """Every selectable area, in the instrument's own option order."""
    return [jurisdiction_area(code) for code in jurisdiction_source_codes()]


def m2_geography_catalogue() -> dict:
    """The verified geography block served to M2 ``GEO`` items.

    A fresh dict each call: callers must not be able to mutate the authority by
    editing a served copy.
    """
    return {
        'status': VERIFIED_STATUS,
        'catalogue_version': CATALOGUE_VERSION,
        'granularity': JURISDICTION_GRANULARITY,
        'areas': jurisdiction_areas(),
        'note': (
            'GEO_V1 jurisdiction catalogue. Area references are administrative '
            'level 1; no premises location is inferred.'
        ),
    }


def catalogue_fingerprint() -> str:
    """sha256 of the canonical catalogue, so drift is detectable and pinnable."""
    payload = json.dumps(m2_geography_catalogue(), sort_keys=True,
                         ensure_ascii=False, separators=(',', ':'))
    return hashlib.sha256(payload.encode('utf-8')).hexdigest()


def area_label(value: object) -> str | None:
    """Display label for a stored GEO answer value, or ``None``.

    Used by readers that render a confirmed declaration; it never invents a
    label for a value that is not in the catalogue.
    """
    if value == UNDECIDED:
        return None
    if not isinstance(value, dict):
        return None
    if value.get('catalogue_version') != CATALOGUE_VERSION:
        return None
    jurisdiction = value.get('jurisdiction')
    area_ref = value.get('area_ref')
    if not isinstance(jurisdiction, str) or not isinstance(area_ref, str):
        return None
    if not area_ref.startswith(JURISDICTION_AREA_PREFIX):
        return None
    code = area_ref[len(JURISDICTION_AREA_PREFIX):]
    if GEO_V1_JURISDICTIONS.get(code) != jurisdiction:
        return None
    return jurisdiction


def option_codes() -> list[str]:
    """The ``area_ref`` of every selectable area, in catalogue order."""
    return [area['area_ref'] for area in jurisdiction_areas()]


def area_for_ref(area_ref: str) -> dict | None:
    """The catalogue entry for one ``area_ref``, or ``None`` when unregistered."""
    for area in jurisdiction_areas():
        if area['area_ref'] == area_ref:
            return area
    return None


__all__ = [
    'CATALOGUE_VERSION', 'DISTRICT_AREA_PREFIX', 'GEO_V1_DISTRICT_COUNTS',
    'GEO_V1_FAMILY', 'GEO_V1_JURISDICTIONS', 'JURISDICTION_AREA_PREFIX',
    'JURISDICTION_GRANULARITY', 'UNDECIDED', 'UNVERIFIED_STATUS',
    'VERIFIED_STATUS', 'area_for_ref', 'area_label', 'catalogue_fingerprint',
    'jurisdiction_area', 'jurisdiction_area_ref', 'jurisdiction_areas',
    'jurisdiction_source_codes', 'm2_geography_catalogue', 'option_codes',
]
