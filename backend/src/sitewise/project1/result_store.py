"""Durable writer for a validated cloud-BDJ result.

This is the only importer of ``result_contracts.classify()``. The contract owns
the mapping from engine verdict + transport outcome to the four persisted
dimensions; this module owns provenance, transaction order, the projection
allow-list and the refusal to store plaintext model output.

Design constraints that are not negotiable here:

* one transaction: ``bdj_results`` then its children, because every child has
  an FK to the parent. A failure on any child removes the parent too.
* ``result_id`` is derived from ``(run_id, attempt_no)``, so re-persisting the
  same attempt is a no-op instead of a duplicate-key error.
* the restricted principal is the ledger's principal (``principal.py``), so
  ``attempts`` and ``bdj_results`` cannot disagree about who acted.
* ``bdj_raw_responses`` is write-only for the runtime. ``read()`` never selects
  it; there is no "read it back for completeness" path.
* ``read()`` returns an explicit allow-list. ``redact_payload()`` strips
  ``source_refs[].quote`` before the INSERT, because that field is a verbatim
  substring of an entrepreneur answer; ``read()`` then projects the payload
  instead of returning it. The projection stays even though the quote is gone:
  a payload column nobody projects is how the next unconstrained field reaches
  a response.
* finding prose can still restate a declaration, so ``result_payload`` is
  additionally sealed in a versioned envelope when ``payload_custody`` is
  supplied (``_seal_payload`` / ``_open_payload``). The envelope is a shape
  inside the existing jsonb column -- no schema change -- and a payload without
  the marker is legacy plaintext that still reads unchanged. The payload key is
  namespaced (``payload-*``) and lives in its own custody slot, separate from
  the raw-response cipher: ``bdj_results`` is retained indefinitely, so a key
  that ``run_retention()`` can name must never be the key that opens a result.
* ``locator`` and ``detail`` are the two other free-text columns in this schema.
  Both are constrained at this boundary to a pointer and a closed code
  respectively, because a writer holding a ``SourceRef`` would otherwise drop
  the quote into whichever text column is nearest.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import json
import re
from typing import Iterable, Mapping
from uuid import NAMESPACE_URL, UUID, uuid5

from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlmodel import Session

from sitewise.core.cipher import KeyCipher
from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.key_custody import (CustodyCipher, KeyCustody,
                                           KeyCustodyError, payload_cipher)
from sitewise.project1.principal import restricted_scope
from sitewise.project1.result_contracts import classify

RESULT_SCHEMA_VERSION = 'project1-bdj-result/1'
DISCOVERY_RESULT_SCHEMA_VERSION = 'project1-bdj-result/2-candidate'
DEFAULT_RAW_RETENTION_DAYS = 90

# Versioned envelope inside the existing jsonb column. The marker is a key no
# legacy payload has, so its presence -- not a guess about shape -- is what
# selects the decrypt path. A row written before this change is plaintext and
# keeps reading unchanged.
PAYLOAD_ENVELOPE_MARKER = '__payload_envelope__'
PAYLOAD_ENVELOPE_V1 = 'v1'
PAYLOAD_ENVELOPE_FIELDS = frozenset({PAYLOAD_ENVELOPE_MARKER, 'key_id',
                                     'ciphertext', 'plaintext_digest',
                                     'plaintext_bytes'})

# The payload stores the Finding model's keys (contracts.py:41-49), not the
# m2_bdj_findings column names. source_refs[].quote is deliberately absent.
FINDING_KEYS = ('rule_id', 'kind', 'observed_condition', 'counterargument',
                'justification', 'next_action')
REFERENCE_KEYS = ('item_key', 'answer_revision_id', 'item_version_id')

# Same pattern as contracts.py:27. The item key is the only prose-shaped part
# of a locator; the version is an opaque identifier. It must admit every
# registered instrument, otherwise a persisted M2V2 finding cannot be written or
# read back (DD-010).
_ITEM_KEY = re.compile(
    r'^(?:M2-(?:\d{2}|O-0[12])|M2V1-(?:0[1-9]|1[01])|M2V2-(?:0[1-9]|1[0-9]))$')
_LOCATOR = re.compile(
    r'^(?P<item_key>(?:M2-(?:\d{2}|O-0[12])|M2V1-(?:0[1-9]|1[01])'
    r'|M2V2-(?:0[1-9]|1[0-9])))'
    r'@(?P<version>[A-Za-z0-9._:-]{1,128})$')
_DETAIL_CODE = re.compile(r'^[A-Z][A-Z0-9_]{0,63}$')

# Closed set. Adding a member is a deliberate review decision, not a call-site
# convenience: free text here would reprint the answer span it describes.
VALIDATION_DETAIL_CODES = frozenset({
    'SOURCE_QUOTE_NOT_FOUND',
    'SOURCE_ITEM_NOT_ANSWERED',
    'REFERENCE_VERSION_MISMATCH',
    'CANDIDATE_VALIDATION_FAILED',
})

_SOURCE_KEYS = frozenset({'source_id', 'source_version', 'source_fingerprint', 'locator'})
_VALIDATION_KEYS = frozenset({'check_no', 'check_code', 'severity', 'passed', 'detail'})

READ_COLUMNS = (
    'result_id', 'run_id', 'attempt_no', 'assessment_id', 'assessment_revision',
    'execution_outcome', 'review_outcome', 'review_reason', 'validation_status',
    'finding_authority', 'finding_count', 'prompt_version', 'model_requested',
    'model_returned', 'output_digest', 'created_at',
)


def result_id_for(run_id: UUID, attempt_no: int) -> UUID:
    """Deterministic id: a retry of the same attempt is the same row."""
    return uuid5(NAMESPACE_URL, f'sitewise:bdj:{run_id}:{attempt_no}')


def _hex64(value: str, code: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r'[a-f0-9]{64}', value):
        raise WorkflowHeld(code)
    return value


def _text(value, low: int, high: int, code: str) -> str:
    if not isinstance(value, str) or not low <= len(value) <= high:
        raise WorkflowHeld(code)
    return value


def _locator(value) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not _LOCATOR.fullmatch(value):
        # A sentence, a quote or any other prose is refused rather than
        # truncated: a truncated quote is still a quote.
        raise WorkflowHeld('RESULT_SOURCE_LOCATOR_INVALID')
    return value


def _detail(value) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not _DETAIL_CODE.fullmatch(value):
        raise WorkflowHeld('RESULT_VALIDATION_DETAIL_INVALID')
    if value not in VALIDATION_DETAIL_CODES:
        raise WorkflowHeld('RESULT_VALIDATION_DETAIL_INVALID')
    return value


def _sources(sources: Iterable[Mapping]) -> list[dict]:
    rows = []
    for rank, source in enumerate(sources, start=1):
        if not isinstance(source, Mapping) or set(source) - _SOURCE_KEYS:
            raise WorkflowHeld('RESULT_SOURCE_SHAPE_INVALID')
        row = {
            'source_rank': rank,
            'source_id': _text(source.get('source_id'), 1, 256, 'RESULT_SOURCE_SHAPE_INVALID'),
            'source_version': _text(source.get('source_version'), 1, 128,
                                    'RESULT_SOURCE_SHAPE_INVALID'),
            'source_fingerprint': (
                None if source.get('source_fingerprint') is None else
                _hex64(source['source_fingerprint'], 'RESULT_SOURCE_SHAPE_INVALID')),
            'locator': _locator(source.get('locator')),
        }
        rows.append(row)
    return rows


def _validations(validations: Iterable[Mapping]) -> list[dict]:
    rows = []
    for source in validations:
        if not isinstance(source, Mapping) or set(source) - _VALIDATION_KEYS:
            raise WorkflowHeld('RESULT_VALIDATION_SHAPE_INVALID')
        check_no = source.get('check_no')
        if isinstance(check_no, bool) or not isinstance(check_no, int) or check_no < 1:
            raise WorkflowHeld('RESULT_VALIDATION_SHAPE_INVALID')
        severity = source.get('severity')
        if severity not in ('ERROR', 'WARNING', 'INFO'):
            raise WorkflowHeld('RESULT_VALIDATION_SHAPE_INVALID')
        passed = source.get('passed')
        if not isinstance(passed, bool):
            raise WorkflowHeld('RESULT_VALIDATION_SHAPE_INVALID')
        rows.append({
            'check_no': check_no,
            'check_code': _text(source.get('check_code'), 1, 64,
                                'RESULT_VALIDATION_SHAPE_INVALID'),
            'severity': severity,
            'passed': passed,
            'detail': _detail(source.get('detail')),
        })
    return rows


def _finding_ids(findings: Iterable[UUID | str]) -> list[UUID]:
    ids = []
    for finding in findings:
        try:
            ids.append(finding if isinstance(finding, UUID) else UUID(str(finding)))
        except (TypeError, ValueError):
            raise WorkflowHeld('RESULT_FINDING_ID_INVALID') from None
    return ids


def _seal_payload(cipher: KeyCipher, payload: dict) -> dict:
    """Encrypt a redacted payload into the versioned envelope.

    The plaintext is exactly the JSON that used to be written to the column, so
    this is a storage change and nothing else: the same bytes, inside a token.
    ``plaintext_digest`` and ``plaintext_bytes`` are verifiable without the key,
    which is what lets an auditor see the row is intact while custody is
    unavailable -- the same property ``bdj_raw_responses`` relies on.
    """
    plaintext = json.dumps(payload, ensure_ascii=False,
                           separators=(',', ':')).encode('utf-8')
    if not plaintext:
        raise WorkflowHeld('RESULT_PAYLOAD_SHAPE_INVALID')
    try:
        ciphertext, key_id = cipher.encrypt(plaintext)
    except KeyCustodyError:
        raise WorkflowHeld('RESULT_PAYLOAD_CIPHER_UNAVAILABLE') from None
    if not isinstance(ciphertext, (bytes, bytearray)) or not ciphertext:
        raise WorkflowHeld('RESULT_PAYLOAD_CIPHER_INVALID')
    key_id = _text(key_id, 1, 64, 'RESULT_PAYLOAD_CIPHER_INVALID')
    return {
        PAYLOAD_ENVELOPE_MARKER: PAYLOAD_ENVELOPE_V1,
        'key_id': key_id,
        'ciphertext': base64.urlsafe_b64encode(bytes(ciphertext)).decode('ascii'),
        'plaintext_digest': hashlib.sha256(plaintext).hexdigest(),
        'plaintext_bytes': len(plaintext),
    }


def _open_payload(envelope: Mapping, cipher: KeyCipher) -> dict:
    """Decrypt and integrity-check one v1 envelope."""
    if set(envelope) != PAYLOAD_ENVELOPE_FIELDS:
        raise WorkflowHeld('RESULT_PAYLOAD_ENVELOPE_INVALID')
    key_id = _text(envelope.get('key_id'), 1, 64, 'RESULT_PAYLOAD_ENVELOPE_INVALID')
    encoded = envelope.get('ciphertext')
    if not isinstance(encoded, str):
        raise WorkflowHeld('RESULT_PAYLOAD_ENVELOPE_INVALID')
    try:
        # Fernet emits urlsafe base64, so '-' and '_' are part of the alphabet;
        # validate=True still rejects anything else rather than discarding it.
        ciphertext = base64.b64decode(encoded.encode('ascii'), altchars=b'-_',
                                      validate=True)
    except (binascii.Error, UnicodeEncodeError, ValueError):
        raise WorkflowHeld('RESULT_PAYLOAD_ENVELOPE_INVALID') from None
    if not ciphertext:
        raise WorkflowHeld('RESULT_PAYLOAD_ENVELOPE_INVALID')
    digest = _hex64(envelope.get('plaintext_digest'),
                    'RESULT_PAYLOAD_ENVELOPE_INVALID')
    size = envelope.get('plaintext_bytes')
    if isinstance(size, bool) or not isinstance(size, int) or size < 1:
        raise WorkflowHeld('RESULT_PAYLOAD_ENVELOPE_INVALID')

    try:
        plaintext = cipher.decrypt(ciphertext, key_id)
    except KeyCustodyError:
        # Fixed code only. The caller learns the payload is unreadable, not
        # which key was requested, and not whether it was destroyed or missing.
        raise WorkflowHeld('RESULT_PAYLOAD_UNAVAILABLE') from None
    if not isinstance(plaintext, (bytes, bytearray)):
        raise WorkflowHeld('RESULT_PAYLOAD_ENVELOPE_INVALID')
    plaintext = bytes(plaintext)
    if len(plaintext) != size or hashlib.sha256(plaintext).hexdigest() != digest:
        raise WorkflowHeld('RESULT_PAYLOAD_INTEGRITY_FAILED')
    try:
        payload = json.loads(plaintext.decode('utf-8'))
    except (UnicodeDecodeError, ValueError):
        raise WorkflowHeld('RESULT_PAYLOAD_INTEGRITY_FAILED') from None
    if not isinstance(payload, dict):
        raise WorkflowHeld('RESULT_PAYLOAD_ENVELOPE_INVALID')
    return payload


def _payload_for_read(payload, cipher: KeyCipher | None) -> dict | None:
    """Return the plaintext payload, decrypting only when the marker is present.

    The marker -- not a guess about shape -- selects the branch, so a row written
    before the envelope existed is read exactly as it always was. An envelope
    with no cipher is a refusal rather than an empty projection: returning "no
    findings" for a result that has some would be a silent lie.
    """
    if payload is None:
        return None
    if not isinstance(payload, Mapping):
        raise WorkflowHeld('RESULT_PAYLOAD_SHAPE_INVALID')
    version = payload.get(PAYLOAD_ENVELOPE_MARKER)
    if version is None:
        return payload
    if version != PAYLOAD_ENVELOPE_V1:
        raise WorkflowHeld('RESULT_PAYLOAD_ENVELOPE_UNSUPPORTED')
    if cipher is None:
        raise WorkflowHeld('RESULT_PAYLOAD_CIPHER_REQUIRED')
    return _open_payload(payload, cipher)


def _project_payload(payload: dict | None, cipher: KeyCipher | None = None,
                     *, include_finding_refs: bool = False,
                     include_discovery: bool = False
                     ) -> tuple[list[dict], list[dict]]:
    """Allow-list projection. The quote never leaves this function."""
    payload = _payload_for_read(payload, cipher)
    findings: list[dict] = []
    references: list[dict] = []
    for finding in (payload or {}).get('findings', []) or []:
        projected = {key: finding.get(key) for key in FINDING_KEYS}
        if include_discovery:
            from sitewise.project1.bdj_discovery_candidate import DISCOVERY_SIGNALS
            classification = finding.get('discovery_signal')
            if not isinstance(classification, str) or classification not in DISCOVERY_SIGNALS:
                raise WorkflowHeld('RESULT_DISCOVERY_CLASSIFICATION_INVALID')
            projected['discovery_signal'] = classification
        finding_refs = []
        for ref in finding.get('source_refs', []) or []:
            safe_ref = {key: ref.get(key) for key in REFERENCE_KEYS}
            references.append(safe_ref)
            finding_refs.append(safe_ref.copy())
        if include_finding_refs:
            projected['source_refs'] = finding_refs
        findings.append(projected)
    return findings, references


def redact_payload(payload: dict | None) -> dict | None:
    """Return a copy of the payload with every ``source_refs[].quote`` removed.

    The quote is a verbatim substring of an entrepreneur declaration. Redaction
    runs before any encryption, so the quote is never even inside the envelope
    that ``_seal_payload`` may produce. The quote is written but never consumed
    -- ``_project_payload`` reads only ``REFERENCE_KEYS`` from ``source_refs``,
    and the pointer rows live in ``bdj_result_sources``. Removing it therefore
    drops no information any read path uses, while keeping answer text out of
    the column even when no cipher is configured.

    Everything else is preserved by value, including the finding prose. This is
    a storage concern and lives at the write boundary rather than in
    ``result_contracts.classify()``, which owns classification only. The caller's
    dict is never mutated: a redactor that edited its argument in place would
    silently change a caller's copy of the evidence.
    """
    if payload is None:
        return None
    findings = []
    for finding in payload.get('findings', []) or []:
        if not isinstance(finding, Mapping):
            raise WorkflowHeld('RESULT_PAYLOAD_SHAPE_INVALID')
        refs = []
        for ref in finding.get('source_refs', []) or []:
            if not isinstance(ref, Mapping):
                raise WorkflowHeld('RESULT_PAYLOAD_SHAPE_INVALID')
            refs.append({key: value for key, value in ref.items() if key != 'quote'})
        findings.append({**{key: value for key, value in finding.items()
                            if key != 'source_refs'}, 'source_refs': refs})
    return {**{key: value for key, value in payload.items() if key != 'findings'},
            'findings': findings}


class BdjResultStore:
    def __init__(self, engine, actor_id: UUID, run_id: UUID,
                 cipher: KeyCipher | None = None,
                 payload_custody: KeyCustody | None = None):
        """``cipher`` seals raw model output; ``payload_custody`` seals the
        validated result.

        Two collaborators, not one, because the two keys have different
        lifecycles: a raw-response key is destroyed when ``retention_until``
        passes, while a ``bdj_results`` row is retained indefinitely. Sharing a
        cipher between them would put the result on the raw response's
        retention clock. ``payload_custody`` names its own key
        (``payload_key_id(result_id)``), so the caller cannot choose a name that
        retention is able to select.
        """
        self.engine, self.actor_id, self.run_id = engine, actor_id, run_id
        self.cipher = cipher
        self.payload_custody = payload_custody

    def _payload_reader(self) -> KeyCipher | None:
        """A cipher that resolves the envelope's ``key_id``; None when unset.

        No key-id factory is supplied because this instance only decrypts: the
        envelope already names the key it was sealed under, so rotation can
        re-wrap a row without the reader changing.
        """
        return None if self.payload_custody is None else CustodyCipher(self.payload_custody)

    def persist(self, attempt_no: int, review_result: dict | None,
                execution_outcome: str, *, output_digest: str | None,
                ruleset_version: str, prompt_version: str, model_requested: str,
                model_returned: str | None = None, review_reason: str | None = None,
                result_schema_version: str = RESULT_SCHEMA_VERSION,
                source_fingerprint: str | None = None,
                sources: Iterable[Mapping] = (), validations: Iterable[Mapping] = (),
                findings: Iterable[UUID | str] = (), raw_output: bytes | None = None,
                retention_days: int = DEFAULT_RAW_RETENTION_DAYS) -> UUID:
        """Write one result and its children atomically; return its id.

        Provenance that the run row owns (assessment id/revision/fingerprint) is
        read from that row inside the transaction rather than trusted from the
        caller. The version/model labels are not in the run row and are supplied
        explicitly. ``classify()`` is called first and its refusal propagates
        before a connection is opened.
        """
        if (isinstance(attempt_no, bool) or not isinstance(attempt_no, int)
                or not 1 <= attempt_no <= 6):
            raise WorkflowHeld('RESULT_ATTEMPT_INVALID')
        if raw_output is not None:
            if self.cipher is None:
                # There is no plaintext fallback. Dropping the bytes silently is
                # how evidence disappears; refusing is the contract.
                raise WorkflowHeld('RESULT_RAW_RESPONSE_CIPHER_REQUIRED')
            if not isinstance(raw_output, (bytes, bytearray)) or not raw_output:
                raise WorkflowHeld('RESULT_RAW_RESPONSE_EMPTY')
        ruleset_version = _text(ruleset_version, 1, 64, 'RESULT_PROVENANCE_INVALID')
        prompt_version = _text(prompt_version, 1, 64, 'RESULT_PROVENANCE_INVALID')
        model_requested = _text(model_requested, 1, 128, 'RESULT_PROVENANCE_INVALID')
        if model_returned is not None:
            model_returned = _text(model_returned, 1, 128, 'RESULT_PROVENANCE_INVALID')
        if review_reason is not None:
            review_reason = _text(review_reason, 1, 512, 'RESULT_PROVENANCE_INVALID')
        result_schema_version = _text(result_schema_version, 1, 64,
                                      'RESULT_PROVENANCE_INVALID')
        if source_fingerprint is not None:
            source_fingerprint = _hex64(source_fingerprint, 'RESULT_PROVENANCE_INVALID')
        if isinstance(retention_days, bool) or not isinstance(retention_days, int) \
                or retention_days < 1:
            raise WorkflowHeld('RESULT_RAW_RETENTION_INVALID')

        source_rows = _sources(sources)
        validation_rows = _validations(validations)
        finding_ids = _finding_ids(findings)

        # The contract owns the outcome columns. Never build them by hand.
        row = classify(review_result, execution_outcome, output_digest=output_digest)
        if (result_schema_version == DISCOVERY_RESULT_SCHEMA_VERSION and
                row['result_payload'] is not None):
            from pydantic import ValidationError
            from sitewise.project1.bdj_discovery_candidate import DiscoveryOutputCandidate
            try:
                DiscoveryOutputCandidate.model_validate({
                    'contract_version': 'bdj-discovery-output/1-candidate',
                    'issues': row['result_payload']['findings'],
                    'overall_note': 'Validated candidate result.'})
            except ValidationError:
                raise WorkflowHeld('RESULT_DISCOVERY_CLASSIFICATION_INVALID') from None

        raw = None
        if raw_output is not None:
            ciphertext, key_id = self.cipher.encrypt(bytes(raw_output))
            if not isinstance(ciphertext, (bytes, bytearray)) or not ciphertext:
                raise WorkflowHeld('RESULT_RAW_RESPONSE_CIPHER_INVALID')
            key_id = _text(key_id, 1, 64, 'RESULT_RAW_RESPONSE_CIPHER_INVALID')
            raw = {
                'ciphertext': bytes(ciphertext),
                'key_id': key_id,
                'plaintext_digest': hashlib.sha256(bytes(raw_output)).hexdigest(),
                'plaintext_bytes': len(raw_output),
            }

        result_id = result_id_for(self.run_id, attempt_no)
        payload = redact_payload(row['result_payload'])
        # Sealed before the transaction opens: a custody failure must not leave
        # a partially-written result, and the envelope is what the INSERT
        # stores. Without payload custody the payload is written as before, so a
        # deployment that has not chosen custody keeps working unchanged.
        if payload is not None and self.payload_custody is not None:
            payload = _seal_payload(payload_cipher(self.payload_custody, result_id),
                                    payload)
        try:
            with Session(self.engine) as session:
                restricted_scope(session, self.actor_id)
                run = session.execute(text(
                    'SELECT assessment_id, assessment_revision, source_fingerprint '
                    'FROM project1_ai.runs WHERE id=:run AND owner_user_id=:actor'),
                    {'run': self.run_id, 'actor': self.actor_id}).mappings().one_or_none()
                if run is None:
                    raise WorkflowHeld('WORKFLOW_RUN_NOT_FOUND')
                if (source_fingerprint is not None
                        and source_fingerprint != run['source_fingerprint']):
                    raise WorkflowHeld('WORKFLOW_RUN_SOURCE_MISMATCH')

                inserted = session.execute(text(
                    'INSERT INTO project1_ai.bdj_results ('
                    ' result_id, run_id, owner_user_id, attempt_no, assessment_id,'
                    ' assessment_revision, source_fingerprint, ruleset_version,'
                    ' prompt_version, model_requested, model_returned, execution_outcome,'
                    ' output_digest, result_schema_version, result_payload, review_outcome,'
                    ' finding_authority, finding_count, review_reason) VALUES ('
                    ' :result_id, :run_id, :actor, :attempt_no, :assessment_id,'
                    ' :assessment_revision, :source_fingerprint, :ruleset_version,'
                    ' :prompt_version, :model_requested, :model_returned, :execution_outcome,'
                    ' :output_digest, :result_schema_version, CAST(:result_payload AS jsonb),'
                    ' :review_outcome, :finding_authority, :finding_count, :review_reason)'
                    ' ON CONFLICT (result_id) DO NOTHING RETURNING result_id'), {
                        'result_id': result_id, 'run_id': self.run_id,
                        'actor': self.actor_id, 'attempt_no': attempt_no,
                        'assessment_id': run['assessment_id'],
                        'assessment_revision': run['assessment_revision'],
                        'source_fingerprint': run['source_fingerprint'],
                        'ruleset_version': ruleset_version,
                        'prompt_version': prompt_version,
                        'model_requested': model_requested,
                        'model_returned': model_returned,
                        'execution_outcome': row['execution_outcome'],
                        'output_digest': row['output_digest'],
                        'result_schema_version': result_schema_version,
                        'result_payload': (None if payload is None else
                                           json.dumps(payload, ensure_ascii=False,
                                                      separators=(',', ':'))),
                        'review_outcome': row['review_outcome'],
                        'finding_authority': row['finding_authority'],
                        'finding_count': row['finding_count'],
                        'review_reason': review_reason,
                    }).scalar()
                if inserted is None:
                    existing = session.execute(text(
                        'SELECT result_id FROM project1_ai.bdj_results '
                        'WHERE result_id=:id'), {'id': result_id}).scalar()
                    if existing is None:
                        raise WorkflowHeld('RESULT_ATTEMPT_ALREADY_STORED')
                    session.commit()
                    return existing

                for source in source_rows:
                    session.execute(text(
                        'INSERT INTO project1_ai.bdj_result_sources ('
                        ' result_id, owner_user_id, source_rank, source_id,'
                        ' source_version, source_fingerprint, locator)'
                        ' VALUES (:result_id, :actor, :source_rank, :source_id,'
                        ' :source_version, :source_fingerprint, :locator)'),
                        {'result_id': result_id, 'actor': self.actor_id, **source})

                for validation in validation_rows:
                    session.execute(text(
                        'INSERT INTO project1_ai.bdj_result_validations ('
                        ' result_id, owner_user_id, check_no, check_code, severity,'
                        ' passed, detail) VALUES (:result_id, :actor, :check_no,'
                        ' :check_code, :severity, :passed, :detail)'),
                        {'result_id': result_id, 'actor': self.actor_id, **validation})

                for finding_id in finding_ids:
                    session.execute(text(
                        'INSERT INTO project1_ai.bdj_result_findings ('
                        ' result_id, finding_id, owner_user_id, authority)'
                        " VALUES (:result_id, :finding_id, :actor, 'candidate')"),
                        {'result_id': result_id, 'finding_id': finding_id,
                         'actor': self.actor_id})

                if raw is not None:
                    session.execute(text(
                        'INSERT INTO project1_ai.bdj_raw_responses ('
                        ' result_id, owner_user_id, encryption_alg, key_id, ciphertext,'
                        ' plaintext_digest, plaintext_bytes, retention_until)'
                        " VALUES (:result_id, :actor, 'FERNET-AES128-CBC-HMAC-SHA256',"
                        ' :key_id, :ciphertext, :plaintext_digest, :plaintext_bytes,'
                        ' now() + make_interval(days => :retention_days))'),
                        {'result_id': result_id, 'actor': self.actor_id,
                         'retention_days': retention_days, **raw})

                session.commit()
                return result_id
        except WorkflowHeld:
            raise
        except SQLAlchemyError:
            raise WorkflowHeld('WORKFLOW_STORAGE_UNAVAILABLE') from None

    def read(self, result_id: UUID) -> dict:
        """Return the projection allow-list for one result.

        Deliberately does not select ``bdj_raw_responses`` (the runtime cannot
        read it) and does not return ``result_payload``: the quote is redacted
        before it is stored, but the column is still not part of the response
        contract, and a payload returned wholesale would ship whatever field is
        added to it next.

        When the stored payload is an envelope, ``self.cipher`` is what opens
        it. Without a cipher the read holds rather than returning an empty
        finding list, because "no findings" and "cannot read the findings" must
        never look the same to a caller.
        """
        try:
            with Session(self.engine) as session:
                restricted_scope(session, self.actor_id)
                row = session.execute(text(
                    'SELECT result_id, run_id, attempt_no, assessment_id,'
                    ' assessment_revision, execution_outcome, review_outcome,'
                    ' review_reason, validation_status, finding_authority, finding_count,'
                    ' prompt_version, model_requested, model_returned, output_digest,'
                    ' created_at, result_schema_version, result_payload FROM project1_ai.bdj_results'
                    ' WHERE result_id=:id'), {'id': result_id}).mappings().one_or_none()
                if row is None:
                    raise WorkflowHeld('BDJ_RESULT_NOT_FOUND')
                findings, references = _project_payload(
                    row['result_payload'], self._payload_reader(),
                    include_finding_refs=row['result_schema_version'] == DISCOVERY_RESULT_SCHEMA_VERSION,
                    include_discovery=row['result_schema_version'] == DISCOVERY_RESULT_SCHEMA_VERSION)
                result = {column: row[column] for column in READ_COLUMNS}
                if row['result_schema_version'] == DISCOVERY_RESULT_SCHEMA_VERSION:
                    result['result_schema_version'] = row['result_schema_version']
                result['findings'] = findings
                result['references'] = references
                session.rollback()
                return result
        except WorkflowHeld:
            raise
        except SQLAlchemyError:
            raise WorkflowHeld('WORKFLOW_STORAGE_UNAVAILABLE') from None


def results_for_assessment(engine, actor_id: UUID, assessment_id: UUID,
                           limit: int = 50, *,
                           payload_custody: KeyCustody | None = None,
                           expected_revision: int | None = None,
                           expected_fingerprint: str | None = None,
                           include_finding_refs: bool = False) -> list[dict]:
    """Activity History V1.1 readback: owner-scoped projection of saved results.

    A module-level function rather than a ``BdjResultStore`` method because this
    read spans runs: the store is bound to one run, and a history query is not.

    Three separate controls keep entrepreneur-private answer text out of the
    response, and each is asserted by a test rather than assumed:

    1. ``result_payload`` is selected only to be projected, never returned. The
       quote no longer reaches it (``redact_payload`` runs before the INSERT),
       and the projection does not depend on that: a column returned wholesale
       would ship whatever field is added to it next.
    2. ``_project_payload`` copies ``FINDING_KEYS`` and ``REFERENCE_KEYS`` only.
       Neither tuple contains ``quote``, and ``source_refs`` is not a finding key,
       so the quote has no path into the output.
    3. ``bdj_raw_responses`` is never referenced. The runtime principal has no
       SELECT on it; the audit principal does, and that is the only reader.

    At rest the column may additionally be sealed in the versioned envelope
    (``_seal_payload``), which is what keeps finding prose -- the part redaction
    cannot remove -- out of a plaintext column the row owner can select.

    Owner scoping is applied twice on purpose: ``restricted_scope`` binds
    ``project1.actor_id`` so RLS filters the rows, and the WHERE clause filters
    them again. A projection that relied on RLS alone would silently widen if a
    future session ran as a role with BYPASSRLS.

    ``payload_custody`` opens an envelope payload and is not needed for legacy
    plaintext rows. It is keyword-only and defaults to None so the History route
    keeps working against rows written before the envelope existed; an envelope
    with no custody raises rather than projecting an empty finding list.
    """
    try:
        with Session(engine) as session:
            restricted_scope(session, actor_id)
            rows = session.execute(text(
                'SELECT result_id, run_id, attempt_no, assessment_id,'
                ' assessment_revision, execution_outcome, review_outcome, review_reason,'
                ' validation_status, finding_authority, finding_count, prompt_version,'
                ' model_requested, model_returned, output_digest, created_at,'
                ' source_fingerprint, ruleset_version, result_schema_version, result_payload FROM project1_ai.bdj_results'
                ' WHERE assessment_id=:assessment AND owner_user_id=:owner'
                ' AND (CAST(:revision AS integer) IS NULL OR assessment_revision=:revision)'
                ' AND (CAST(:fingerprint AS text) IS NULL OR source_fingerprint=:fingerprint)'
                ' ORDER BY created_at DESC, attempt_no DESC LIMIT :limit'), {
                    'assessment': assessment_id, 'owner': actor_id,
                    'revision': expected_revision, 'fingerprint': expected_fingerprint,
                    'limit': limit}).mappings().all()
            results = []
            reader = (None if payload_custody is None
                      else CustodyCipher(payload_custody))
            for row in rows:
                findings, references = _project_payload(
                    row['result_payload'], reader,
                    include_finding_refs=include_finding_refs or row['result_schema_version'] == DISCOVERY_RESULT_SCHEMA_VERSION,
                    include_discovery=row['result_schema_version'] == DISCOVERY_RESULT_SCHEMA_VERSION)
                item = {column: row[column] for column in READ_COLUMNS}
                if row['result_schema_version'] == DISCOVERY_RESULT_SCHEMA_VERSION:
                    item['result_schema_version'] = row['result_schema_version']
                if expected_fingerprint is not None:
                    item['source_fingerprint'] = row['source_fingerprint']
                    item['ruleset_version'] = row['ruleset_version']
                item['findings'] = findings
                item['references'] = references
                results.append(item)
            session.rollback()
            return results
    except WorkflowHeld:
        raise
    except SQLAlchemyError:
        raise WorkflowHeld('WORKFLOW_STORAGE_UNAVAILABLE') from None
