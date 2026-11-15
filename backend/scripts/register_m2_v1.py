"""Register the Owner-adopted M2V1 definition in existing M2 tables; no DDL.

Default is a read-only preflight. --apply requires the explicit adoption receipt.
Does not create assessments, answers, approvals for customer research or campaigns.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
from uuid import NAMESPACE_URL, uuid5

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'src'))


def definition():
    folder = ROOT / 'src/sitewise/instruments/m2v1_20261114'
    data = json.loads((folder / 'definition.json').read_text(encoding='utf-8'))
    assert hashlib.sha256((folder / 'source.txt').read_bytes()).hexdigest() == data['source_sha256']
    assert [q['item_key'] for q in data['items']] == [f'M2V1-{i:02}' for i in range(1, 12)] + ['M2-20', 'M2-21']
    digest = hashlib.sha256(json.dumps(data, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()
    iid = uuid5(NAMESPACE_URL, data['code'] + ':' + data['version_tag'] + ':' + digest)
    rows = [dict(id=uuid5(iid, q['item_key']), instrument_id=iid,
                 **{k: v for k, v in q.items() if k != 'title'}) for q in data['items']]
    return data, digest, iid, rows


def register(engine, *, apply=False, expected_database='Dss'):
    from sqlalchemy import inspect, select, text
    from sitewise.db.models.m2_schema import instruments, items
    data, digest, iid, rows = definition()
    with engine.begin() as conn:
        if not apply:
            conn.exec_driver_sql('SET TRANSACTION READ ONLY')
        database = conn.scalar(text('SELECT current_database()'))
        if database != expected_database:
            raise ValueError('Database identity does not match the explicit target.')
        for table in (instruments, items):
            columns = {c['name'] for c in inspect(conn).get_columns(table.name, schema='public')}
            if not set(table.c.keys()).issubset(columns):
                raise ValueError('Existing M2 schema is incompatible; no DDL permitted.')
        if apply:
            conn.execute(text('SELECT pg_advisory_xact_lock(hashtext(:version))'), {'version': data['version_tag']})
        current = conn.execute(select(instruments).where(instruments.c.code == data['code'],
            instruments.c.version_tag == data['version_tag'])).mappings().first()
        if current:
            if current['id'] != iid or current['schema_digest'] != digest or current['approval_state'] != 'AUTHORIZED':
                raise ValueError('Conflicting registered version; immutable source will not be overwritten.')
            stored = [dict(r) for r in conn.execute(select(items).where(items.c.instrument_id == iid).order_by(items.c.sort_order)).mappings()]
            if stored != rows:
                raise ValueError('Stored items do not match the adopted definition.')
        elif apply:
            conn.execute(instruments.insert().values(id=iid, code=data['code'], version_tag=data['version_tag'],
                approval_state='AUTHORIZED', schema_digest=digest))
            conn.execute(items.insert(), rows)
    return {'database': database, 'applied': apply, 'replayed': bool(current), 'instrument_id': str(iid),
        'version': data['version_tag'], 'schema_digest': digest, 'source_sha256': data['source_sha256'],
        'question_count': 11, 'action_count': 2, 'owner_adopted': True,
        'independent_scientific_review': 'NOT_VERIFIED', 'customer_fielding_authorized': False,
        'live_schema_changed': False}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--apply', action='store_true')
    p.add_argument('--adoption-receipt')
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    if args.apply and args.adoption_receipt != 'OWNER-ADOPTED-M2V1-20261114':
        p.error('Applying requires the exact Owner adoption receipt.')
    from sitewise.core.config import Settings
    from sqlalchemy import create_engine
    from sqlalchemy.engine import make_url
    settings = Settings(_env_file=str(ROOT / '.env'))
    raw = settings.m2_database_url.get_secret_value() or settings.database_url
    url = make_url(raw)
    if url.drivername != 'postgresql+psycopg2' or url.database != settings.m2_expected_database or url.database != 'Dss':
        raise ValueError('Existing dedicated M2 target guard is not satisfied.')
    engine = create_engine(raw, connect_args={'connect_timeout': 5})
    try:
        result = register(engine, apply=args.apply)
    finally:
        engine.dispose()
    args.output.write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
