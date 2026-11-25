#!/usr/bin/env python
"""Read-only shadow inference for the SiteWise Operational25 candidate."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import time

HERE = Path(__file__).resolve().parent
# Repository copy keeps the original quick-start logic but resolves the
# artifact and contract from their tracked locations.
MODEL_PATH = HERE.parent / 'src' / 'sitewise' / 'ml' / 'sitewise_pu_operational25.joblib'
CONTRACT = json.loads((HERE / 'operational25_feature_contracts.json').read_text(encoding='utf-8'))['no_routing_no_age25']
FEATURES = CONTRACT['feature_names']
IMPUTABLE = set(CONTRACT['imputable_features'])
EXPECTED_HASH = '6361d0bcff25b23468a2c101df96679c783258ded86e61a34f139bebfef4b262'
GROUPS = {'population_rings': FEATURES[:2], 'demand_generator_pois': FEATURES[2:16],
          'road_geometry': FEATURES[16:17], 'residential_density': FEATURES[17:]}
assert len(FEATURES) == 25 and len(IMPUTABLE) == 8


def load_model():
    import joblib, sklearn
    path = MODEL_PATH
    if hashlib.sha256(path.read_bytes()).hexdigest() != EXPECTED_HASH:
        raise ValueError('Model checksum mismatch; use original trusted package')
    if sklearn.__version__ != CONTRACT['trained_sklearn']:
        raise ValueError(f"scikit-learn {CONTRACT['trained_sklearn']} required; found {sklearn.__version__}")
    obj = joblib.load(path)
    if obj['model_info']['feature_names'] != FEATURES or not obj['estimators']:
        raise ValueError('Model feature contract mismatch')
    if not all('imputer' in m.named_steps and m.n_features_in_ == 25 for m in obj['estimators']):
        raise ValueError('Unexpected estimator or imputation contract')
    return obj['estimators']


def clean_value(name, v):
    if v is None or isinstance(v, bool):
        return None
    try:
        f = float(v)
    except (ValueError, TypeError):
        return None
    return f if math.isfinite(f) and f >= 0 and (not name.endswith('_pct') or f <= 100) else None


def collect(groups):
    values = dict.fromkeys(FEATURES)
    sources, blockers, diagnostics = {}, [], {}
    for group, names in GROUPS.items():
        obs = groups.get(group)
        if obs is None:
            blockers.append(f'{group}: no extraction result')
            continue
        diagnostics[group] = {'status': obs.status, 'reason': obs.reason, 'notes': obs.notes}
        if group == 'residential_density':
            # _residential_radius can swallow a database failure. Only permit the
            # trained imputation policy if both queries actually returned evidence.
            if not all(k in obs.notes for k in ('any_building_count_500m', 'any_building_count_1000m')):
                blockers.append('residential_density: both radius queries must return coverage evidence')
        if obs.status not in ('ready', 'partial'):
            if group != 'residential_density' or obs.status != 'unavailable':
                blockers.append(f'{group}: {obs.status}')
            continue
        for name in names:
            v = clean_value(name, obs.values.get(name))
            if v is not None and obs.sources.get(name):
                values[name] = v
                sources[name] = obs.sources[name]
    required = [k for k, v in values.items() if v is None and k not in IMPUTABLE]
    missing_res = [k for k in FEATURES if k in IMPUTABLE and values[k] is None]
    if required:
        blockers.append('missing required features: ' + ', '.join(required))
    return values, sources, missing_res, blockers, diagnostics


def score(models, values):
    import numpy as np
    if any(values.get(k) is None for k in FEATURES if k not in IMPUTABLE):
        raise ValueError('Required inputs missing')
    x = np.array([[float('nan') if values.get(k) is None else values[k] for k in FEATURES]], dtype=float)
    predictions = np.array([m.predict_proba(x)[0, list(m.classes_).index(1)] for m in models])
    result = float(predictions.mean())
    if not math.isfinite(result) or not 0 <= result <= 1:
        raise ValueError('Invalid model output')
    return result


def validate_coords(lat, lon):
    if not (math.isfinite(lat) and math.isfinite(lon) and -90 <= lat <= 90 and -180 <= lon <= 180):
        raise ValueError('Invalid coordinates')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, help='FYP repository root')
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument('--property-id', type=int)
    mode.add_argument('--coordinates', type=float, nargs=2, metavar=('LAT', 'LON'))
    mode.add_argument('--self-check', action='store_true', help='Historical example; no database connection')
    p.add_argument('--out', type=Path, help='Optional JSON output path (outside DB)')
    a = p.parse_args()
    started = time.perf_counter()
    model = load_model()
    result = {'model_version': CONTRACT['version'], 'model_sha256': EXPECTED_HASH, 'research_only': True,
              'production_ready': False, 'score_meaning': CONTRACT['score_meaning'], 'feature_count': 25}
    if a.self_check:
        example = json.loads((HERE / 'operational25_example_features.json').read_text(encoding='utf-8'))
        raw = example.get('features', example)
        values = {n: clean_value(n, raw.get(n)) for n in FEATURES}
        result.update(mode='historical_self_check', available=True, score_0_100=score(model, values)*100,
                      values=values, observed_features=sum(v is not None for v in values.values()))
    else:
        if a.root is None:
            p.error('--root is required for live coordinates/property-id')
        backend = a.root.resolve() / 'backend'
        if not (backend / 'src' / 'sitewise').is_dir():
            p.error('Cannot find backend/src/sitewise under --root')
        os.chdir(backend)
        sys.path.insert(0, str(backend / 'src'))
        from sqlmodel import Session
        from sqlalchemy import text
        from sitewise.db.analytics_session import analytics_engine
        from sitewise.ml.expanded64_network import Expanded64CoordinateExtractor
        if a.property_id is not None:
            from sitewise.db.session import engine
            with Session(engine) as session:
                session.connection().exec_driver_sql('SET TRANSACTION READ ONLY')
                row = session.execute(text('SELECT latitude, longitude FROM fyp.rental_properties WHERE id = :id'), {'id': a.property_id}).one_or_none()
            if row is None or row.latitude is None or row.longitude is None:
                raise ValueError('Property not found or coordinates missing in application DB')
            lat, lon = float(row.latitude), float(row.longitude)
        else:
            lat, lon = a.coordinates
        validate_coords(lat, lon)
        with Session(analytics_engine) as session:
            session.connection().exec_driver_sql('SET TRANSACTION READ ONLY')
            session.connection().exec_driver_sql("SET LOCAL statement_timeout = '30s'")
            observations = Expanded64CoordinateExtractor(session).extract(lat, lon, selected=set(GROUPS))
        values, sources, missing_res, blockers, diagnostics = collect(observations)
        result.update(mode='current_coordinate_shadow', property_id=a.property_id,
                      coordinates={'latitude': lat, 'longitude': lon}, observed_features=len(sources),
                      values=values, value_sources=sources, imputable_missing=missing_res,
                      blockers=blockers, groups=diagnostics, available=not blockers,
                      score_0_100=score(model, values)*100 if not blockers else None,
                      source_permission_and_parity_verified=False)
    result['elapsed_seconds'] = round(time.perf_counter()-started, 3)
    output = json.dumps(result, indent=2, allow_nan=False, default=str)
    print(output)
    if a.out:
        a.out.write_text(output+'\n', encoding='utf-8')
    return 0 if result['available'] else 2


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as exc:
        # Avoid emitting connection URIs or credentials from a driver exception.
        print(f'ERROR: {type(exc).__name__}: {exc}' if isinstance(exc, (ValueError, FileNotFoundError, ImportError)) else f'ERROR: {type(exc).__name__}; check local configuration and backend dependencies', file=sys.stderr)
        raise SystemExit(2)
