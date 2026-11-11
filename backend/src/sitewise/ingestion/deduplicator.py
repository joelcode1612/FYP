"""Evidence-based duplicate resolution.

An OSM id is NEVER assumed to equal an Overture or Google id. Matches are
ranked by evidence strength:

1. explicit provider cross-references carried by the record;
2. verified shared identifiers in ``fnb_a.outlet_source_ids`` (passed in by
   the synchronizer as a set of provider-native ids already verified);
3. spatial proximity + normalized-name similarity, with category and address
   agreement as supporting evidence;
4. anything in between is AMBIGUOUS and recorded for review — never merged.

Both original provider identifiers are always retained on the surviving
record; this module never deletes a source id.
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from difflib import SequenceMatcher

from sitewise.ingestion.config import RefreshConfig
from sitewise.ingestion.normalizer import haversine_m, name_tokens, normalize_name
from sitewise.ingestion.records import SourceRecord

MATCH = "MATCH"
DISTINCT = "DISTINCT"
AMBIGUOUS = "AMBIGUOUS"


@dataclass(frozen=True)
class DuplicateDecision:
    decision: str  # MATCH | DISTINCT | AMBIGUOUS
    incoming: SourceRecord
    matched_record_id: str | None
    evidence: str
    score: float


@dataclass(frozen=True)
class WithinSourceGroup:
    """A group of identical-source records that represent one venue."""

    canonical: SourceRecord
    members: tuple[SourceRecord, ...]


def within_source_duplicates(records: Iterable[SourceRecord]) -> tuple[list[SourceRecord], int]:
    """Collapse exact natural-key repeats and near-identical same-source rows.

    Returns (survivors, duplicate_count). Provenance for collapsed rows is
    preserved in the surviving record's ``source_tags`` by the caller.
    """
    seen: dict[tuple[str, str], SourceRecord] = {}
    by_cell: dict[tuple[str, int, int], list[SourceRecord]] = {}
    duplicates = 0
    for record in records:
        if record.natural_key in seen:
            duplicates += 1
            continue
        seen[record.natural_key] = record
        # ~25 m grid cell for same-source spatial duplicate detection.
        cell = (
            record.source_name,
            int(record.latitude * 400),
            int(record.longitude * 400),
        )
        bucket = by_cell.setdefault(cell, [])
        peer = next(
            (
                r for r in bucket
                if r.category == record.category
                and normalize_name(r.name) == normalize_name(record.name)
            ),
            None,
        )
        if peer is not None:
            seen.pop(record.natural_key, None)
            duplicates += 1
            continue
        bucket.append(record)
    return list(seen.values()), duplicates


def _name_similarity(a: SourceRecord, b: SourceRecord) -> float:
    # Always derive from the name itself: a stale/blank normalized_name must
    # never make two different businesses look identical.
    left, right = normalize_name(a.name), normalize_name(b.name)
    if not left or not right:
        return 0.0
    if left == right:
        return 1.0
    ratio = SequenceMatcher(None, left, right).ratio()
    tokens_a, tokens_b = name_tokens(left), name_tokens(right)
    if tokens_a and tokens_b:
        overlap = len(tokens_a & tokens_b) / len(tokens_a | tokens_b)
        ratio = max(ratio, 0.55 * ratio + 0.45 * overlap)
    return ratio


def _address_agreement(a: SourceRecord, b: SourceRecord) -> float:
    if not a.address or not b.address:
        return 0.0
    left = normalize_name(a.address)
    right = normalize_name(b.address)
    if not left or not right:
        return 0.0
    return SequenceMatcher(None, left, right).ratio()


def classify_match(
    incoming: SourceRecord,
    candidates: Iterable[SourceRecord],
    config: RefreshConfig,
    verified_shared_ids: frozenset[str] = frozenset(),
) -> DuplicateDecision:
    """Decide whether ``incoming`` is the same venue as an existing record.

    ``candidates`` are records of a DIFFERENT provider (caller filters).
    ``verified_shared_ids`` are provider-native ids the database has already
    verified as shared identifiers (evidence tier 2).
    """
    explicit = set(incoming.explicit_cross_refs)
    if explicit:
        for candidate in candidates:
            native = candidate.source_record_id.split("/")[-1]
            if native in explicit or candidate.source_record_id in explicit:
                return DuplicateDecision(
                    MATCH, incoming, candidate.source_record_id,
                    "explicit_provider_cross_reference", 1.0,
                )
    if verified_shared_ids:
        for candidate in candidates:
            if candidate.source_record_id in verified_shared_ids:
                return DuplicateDecision(
                    MATCH, incoming, candidate.source_record_id,
                    "verified_shared_identifier", 0.99,
                )

    scored: list[tuple[float, float, SourceRecord, str]] = []
    for candidate in candidates:
        distance = haversine_m(
            incoming.latitude, incoming.longitude,
            candidate.latitude, candidate.longitude,
        )
        if distance > config.dedup_distance_m:
            continue
        similarity = _name_similarity(incoming, candidate)
        if similarity < config.ambiguous_similarity:
            continue
        category_ok = incoming.category == candidate.category
        address = _address_agreement(incoming, candidate)
        # Distance dominates; name is the second signal; category/address
        # are supporting evidence only.
        score = (
            0.45 * max(0.0, 1.0 - distance / config.dedup_distance_m)
            + 0.40 * similarity
            + (0.10 if category_ok else 0.0)
            + (0.05 if address >= 0.70 else 0.0)
        )
        evidence = (
            f"distance_m={distance:.1f}; name_similarity={similarity:.3f}; "
            f"category_agreement={category_ok}; address_similarity={address:.3f}"
        )
        scored.append((score, distance, candidate, evidence))

    if not scored:
        return DuplicateDecision(DISTINCT, incoming, None, "no_nearby_name_candidate", 0.0)
    scored.sort(key=lambda row: row[0], reverse=True)
    best_score, _distance, best, best_evidence = scored[0]
    if best_score >= config.dedup_name_similarity:
        return DuplicateDecision(
            MATCH, incoming, best.source_record_id, best_evidence, best_score
        )
    # Multiple plausible candidates or a borderline score: never auto-merge.
    return DuplicateDecision(
        AMBIGUOUS, incoming, None,
        f"candidates={len(scored)}; best={best_evidence}; score={best_score:.3f}",
        best_score,
    )


def merged_provenance(primary: SourceRecord, duplicate: SourceRecord) -> dict[str, str]:
    """Both provider identifiers survive a confirmed match."""
    return {
        "primary_source": primary.source_name,
        "primary_source_record_id": primary.source_record_id,
        "duplicate_source": duplicate.source_name,
        "duplicate_source_record_id": duplicate.source_record_id,
        "primary_licence": primary.source_licence,
        "duplicate_licence": duplicate.source_licence,
    }
