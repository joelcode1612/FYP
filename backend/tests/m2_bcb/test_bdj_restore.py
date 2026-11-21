"""Validate a guarded synthetic restore without fixture side effects."""
import json
import os
from pathlib import Path
from uuid import UUID
import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlmodel import Session
from sitewise.project1.contracts import digest
from sitewise.project1.projection import M2SourceProjection
from sitewise.repositories.m2_repository import SqlModelM2Repository
from sitewise.services.m2_service import M2Service


def test_v105_validate_restored_synthetic():
    source_path = os.environ.get('BDJ_V105_RESTORE_SOURCE')
    if not source_path: pytest.skip('explicit synthetic source evidence required')
    source = json.loads(Path(source_path).read_text(encoding='utf-8'))
    packet = source['packet']; actor = UUID(source['actor_id']); mid = UUID(packet['assessment_id'])
    url = make_url(os.environ['DATABASE_URL'])
    assert (url.host, url.port, url.database) == ('127.0.0.1',55441,'project1_m2_bcb_test')
    db = create_engine(url, hide_parameters=True)
    try:
        with db.connect() as c:
            assert Path(c.execute(text('SHOW data_directory')).scalar_one()).resolve() == (Path(os.environ['M2_BCB_PRIVATE_CLUSTER'])/'data').resolve()
            assert c.execute(text('SELECT count(*) FROM m2_answer_revisions WHERE assessment_id=:id'), {'id':mid}).scalar_one() == 11
        with Session(db) as session:
            repo = SqlModelM2Repository(session)
            with M2Service(repo).locked_confirmed_source(mid, actor,
                    confirmation_id=UUID(packet['confirmation']['confirmation_id']), expected_revision=11) as verified:
                assert verified['snapshot_digest'] == packet['confirmation']['snapshot_digest']
            restored = M2SourceProjection(repo).read(mid, actor, 11)
        restored['confirmation'] = packet['confirmation']
        restored['data_class'] = 'SYNTHETIC_NONHUMAN'
        restored['purpose'] = 'SYNTHETIC_BDJ_DIAGNOSTIC'
        restored['source_fingerprint'] = digest({k:v for k,v in restored.items() if k != 'source_fingerprint'})
        assert restored == packet
    finally:
        db.dispose()
