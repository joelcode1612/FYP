"""A10 claim registers: what may be said, and whether anyone has approved it.

Two registers exist, and the distinction is the whole point:

``PROPOSED_CLAIMS``
    Derived from the hash-pinned explanation registry. Each entry carries the
    item's own ``permitted_claim`` and ``prohibited_inference`` verbatim, so a
    proposal cannot paraphrase the instrument. Every entry is ``approved=False``.
    This is the raw material for decision D-01.

``AdoptedClaimRegister``
    What the adapter is actually given in production. It is **empty**: no claim
    register has been adopted, so no claim is approved, so C2 can never be
    satisfied. Constructing it with entries is possible only through
    ``from_adoption``, which requires a dated, attributed act per claim and an
    evidence hash. There is no constructor that turns the proposal into an
    adoption by accident.

The synthetic fixture lives in ``a10_synthetic`` and is marked with a
``TEST_ONLY`` identity that the adapter refuses on any production path. Keeping
it in a different module is deliberate: a synthetic approval must not be
importable from the module that production admission imports.
"""
from __future__ import annotations

from dataclasses import dataclass

from sitewise.project1.explanation_registry import load_registry

PROPOSED_REGISTER_VERSION = 'a10-claim-register-proposal/1'


@dataclass(frozen=True)
class Claim:
    """One sentence a report section may publish, and its forbiddances."""

    claim_id: str
    question_id: str
    construct_id: str
    section_id: str
    permitted_claim: str
    prohibited_inference: tuple[str, ...]
    response_kind: str
    #: The claim *class* — what kind of statement this is. A descriptive
    #: distribution is admissible in principle; a demand or viability claim is
    #: never admissible from this instrument. Required by the A10 V1 contract so
    #: a section cannot be filled with a stronger claim type than it permits.
    claim_type: str = 'DESCRIPTIVE_DISTRIBUTION'
    #: Never True in the proposal. Set only by ``from_adoption``.
    approved: bool = False
    #: The act that approved it: a document reference plus a hash. Empty while
    #: unapproved, and required by ``from_adoption``.
    authority_basis: str = ''
    evidence_hash: str = ''

    def prohibits(self, text: str) -> tuple[str, ...]:
        """Which prohibited inferences ``text`` appears to make.

        Deliberately a substring test on the instrument's own wording: it is a
        guard against a claim text drifting past what the item allows, not a
        semantic classifier. A false positive only makes the adapter stricter.
        """
        lowered = text.lower()
        hits = []
        for phrase in self.prohibited_inference:
            # Prohibited lists are semicolon-separated prose in the registry.
            for fragment in (f.strip() for f in phrase.split(';')):
                if len(fragment) >= 4 and fragment.lower() in lowered:
                    hits.append(fragment)
        return tuple(hits)


def _split(prohibited: str) -> tuple[str, ...]:
    return tuple(p.strip() for p in prohibited.split(';') if p.strip())


def _proposed() -> tuple[Claim, ...]:
    reg = load_registry()
    claims: list[Claim] = []
    for question_id, entry in reg.questions.items():
        permitted = entry.permitted_claim or ''
        prohibited = entry.prohibited_inference or ''
        for section_id in entry.report_sections:
            claims.append(Claim(
                claim_id=f'CLM-{question_id}-{section_id}',
                question_id=question_id,
                construct_id=entry.construct_id,
                section_id=section_id,
                permitted_claim=permitted,
                prohibited_inference=_split(prohibited),
                response_kind=getattr(entry, 'response_kind', '') or '',
                approved=False,
            ))
    return tuple(claims)


PROPOSED_CLAIMS: tuple[Claim, ...] = _proposed()
PROPOSED_BY_ID: dict[str, Claim] = {c.claim_id: c for c in PROPOSED_CLAIMS}


class AdoptedClaimRegister:
    """The register the adapter consults. Empty until an owner adopts claims."""

    def __init__(self, claims: dict[str, Claim] | None = None):
        self._claims = dict(claims or {})

    @classmethod
    def empty(cls) -> 'AdoptedClaimRegister':
        """The production register: nothing adopted, every lookup refuses."""
        return cls({})

    @classmethod
    def from_adoption(cls, claims: list[Claim]) -> 'AdoptedClaimRegister':
        """Build an adopted register from claims that each carry an act.

        Refuses any claim without ``approved=True``, a non-empty
        ``authority_basis`` and a 64-hex ``evidence_hash``. This is the only way
        to obtain a non-empty register, so "approved" cannot be asserted by
        editing a dataclass default.
        """
        adopted: dict[str, Claim] = {}
        for claim in claims:
            if not claim.approved:
                raise ValueError(f'A10_CLAIM_NOT_APPROVED:{claim.claim_id}')
            if not claim.authority_basis or len(claim.authority_basis) < 8:
                raise ValueError(f'A10_CLAIM_AUTHORITY_BASIS_MISSING:{claim.claim_id}')
            if len(claim.evidence_hash) != 64:
                raise ValueError(f'A10_CLAIM_EVIDENCE_HASH_INVALID:{claim.claim_id}')
            adopted[claim.claim_id] = claim
        return cls(adopted)

    def get(self, claim_id: str) -> Claim | None:
        return self._claims.get(claim_id)

    def for_section(self, section_id: str) -> tuple[Claim, ...]:
        return tuple(c for c in self._claims.values() if c.section_id == section_id)

    def __len__(self) -> int:
        return len(self._claims)

    @property
    def is_empty(self) -> bool:
        return not self._claims


__all__ = [
    'PROPOSED_BY_ID', 'PROPOSED_CLAIMS', 'PROPOSED_REGISTER_VERSION',
    'AdoptedClaimRegister', 'Claim',
]
