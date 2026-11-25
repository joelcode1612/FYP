"""CP-05 (partial) — benchmark from already-recorded live dispatches.

This does NOT make a cloud request. It re-reads
``deliverables/phase2/CLOUD_AB_EVALUATION_RESULTS.json``, a prior authorised
synthetic A/B run (14 dispatches, budget 14, retries 0), and reports the
performance and usage it recorded.

Two honesty constraints, both enforced in the output:

1. The prompt versions in that run are **not** the V4/V5 pair under evaluation
   here. Every table states which version produced each number.
2. A latency percentile is not computed. n is 6 and 8; a P95 from 8 samples is
   an artefact of sample size, so the maximum and the median are reported and
   the percentile is explicitly withheld.

Usage is taken from ``execution.usage``. ``max_tokens = 4000`` is never reported
as consumption — it is a cap.

Usage (from repo root):
    backend/.venv/Scripts/python.exe prompt_eval/scripts/benchmark_existing_evidence.py
"""
from __future__ import annotations

import json
import pathlib
import statistics
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'deliverables' / 'phase2' / 'CLOUD_AB_EVALUATION_RESULTS.json'
OUT_DIR = ROOT / 'prompt_eval' / 'results'

#: Proposed acceptance targets from the brief. Recorded, not adopted.
TARGETS = {
    'bdj': {'median_ms': 15_000, 'p95_ms': 30_000},
    'qg': {'median_ms': 10_000, 'p95_ms': 25_000},
}


def summarise(rows: list[dict]) -> dict:
    latencies = [r['latency_ms'] for r in rows if isinstance(r.get('latency_ms'), int)]
    usage = {'prompt_tokens': 0, 'completion_tokens': 0, 'total_tokens': 0}
    without_usage = 0
    for row in rows:
        reported = (row.get('execution') or {}).get('usage') or {}
        if not reported:
            without_usage += 1
        for key in usage:
            usage[key] += reported.get(key) or 0

    statuses: dict[str, int] = {}
    for row in rows:
        statuses[row['status']] = statuses.get(row['status'], 0) + 1

    return {
        'dispatches': len(rows),
        'returned': statuses.get('RETURNED', 0),
        'held_or_failed': len(rows) - statuses.get('RETURNED', 0),
        'status_counts': statuses,
        'latency_ms': {
            'n': len(latencies),
            'min': min(latencies) if latencies else None,
            'median': round(statistics.median(latencies), 1) if latencies else None,
            'mean': round(statistics.mean(latencies), 1) if latencies else None,
            'max': max(latencies) if latencies else None,
            'p95': 'WITHHELD — n too small for a reliable percentile',
        },
        'usage_tokens': usage,
        'dispatches_without_usage': without_usage,
        'max_tokens_cap': 4_000,
        'note': 'max_tokens is a configured cap, not observed consumption.',
    }


def target_check(summary: dict, family: str) -> dict:
    target = TARGETS[family]
    median = summary['latency_ms']['median']
    worst = summary['latency_ms']['max']
    return {
        'target_median_ms': target['median_ms'],
        'observed_median_ms': median,
        'median_met': (median is not None and median <= target['median_ms']),
        'target_p95_ms': target['p95_ms'],
        'observed_worst_case_ms': worst,
        'p95_verdict': 'NOT_ASSESSABLE — sample too small; worst case reported instead',
        'worst_case_within_target': (worst is not None and worst <= target['p95_ms']),
    }


def per_run(rows: list[dict]) -> list[dict]:
    out = []
    for row in rows:
        execution = row.get('execution') or {}
        usage = execution.get('usage') or {}
        out.append({
            'case': row['case'],
            'prompt_version': row['prompt_version'],
            'prompt_fingerprint': row['prompt_fingerprint'],
            'status': row['status'],
            'code': row.get('code'),
            'http_status': execution.get('http_status'),
            'latency_ms': row.get('latency_ms'),
            'prompt_tokens': usage.get('prompt_tokens'),
            'completion_tokens': usage.get('completion_tokens'),
            'total_tokens': usage.get('total_tokens'),
            'usage_reported': bool(usage),
            'finish_reason': execution.get('finish_reason'),
            'identity_verified': execution.get('identity_verified'),
        })
    return out


def to_markdown(payload: dict) -> str:
    lines = [
        '# CP-05 — performance from already-recorded dispatches',
        '',
        'Source: `deliverables/phase2/CLOUD_AB_EVALUATION_RESULTS.json`',
        f"Recorded at: `{payload['source_recorded_at']}`",
        f"Mode: `{payload['source_mode']}` · budget {payload['source_budget']} · "
        f"dispatched {payload['source_dispatched']} · retries {payload['source_retries']}",
        f"Model: `{payload['model_requested']}` · "
        f"temperature {payload['generation_settings']['temperature']} · "
        f"max_tokens {payload['generation_settings']['max_tokens']} (cap) · "
        f"structured `{payload['structured_mode']}`",
        '',
        '> **Scope limit.** These dispatches used the *previous* prompt pair',
        '> (`BDJ-OBJECTIVE-3-CAND` / `4-CAND` and `QG-PROPOSE-6-CAND` / `7-CAND`),',
        '> not `BDJ-OBJECTIVE-4-M2V2-CAND` / `QG-FIXED-OPTION-4-CAND`. They are a',
        '> performance baseline for the same model and the same task shape, not a',
        '> measurement of the V4/V5 pair. CP-05 for V4/V5 requires a new authorised',
        '> pilot.',
        '',
        '> **P95 is withheld.** n = 6 (BDJ) and n = 8 (Direct-QG). A percentile',
        '> computed from eight samples is a property of the sample, not of the',
        '> system. The maximum is reported instead.',
        '',
    ]
    for family in ('bdj', 'qg'):
        block = payload['families'][family]
        summary = block['summary']
        check = block['target_check']
        lines += [
            f"## {'BDJ — research objectives' if family == 'bdj' else 'Direct-QG — question generation'}",
            '',
            f"Dispatches: **{summary['dispatches']}** "
            f"(returned {summary['returned']}, held/failed {summary['held_or_failed']})",
            '',
            '| Metric | Value |',
            '|---|---|',
            f"| Latency median | **{summary['latency_ms']['median']} ms** |",
            f"| Latency mean | {summary['latency_ms']['mean']} ms |",
            f"| Latency min / max | {summary['latency_ms']['min']} / **{summary['latency_ms']['max']}** ms |",
            f"| Latency P95 | {summary['latency_ms']['p95']} |",
            f"| Prompt tokens (total) | {summary['usage_tokens']['prompt_tokens']} |",
            f"| Completion tokens (total) | {summary['usage_tokens']['completion_tokens']} |",
            f"| Total tokens | {summary['usage_tokens']['total_tokens']} |",
            f"| Dispatches without usage metadata | {summary['dispatches_without_usage']} |",
            f"| `max_tokens` cap | {summary['max_tokens_cap']} (a cap, not consumption) |",
            '',
            '| Proposed target | Value | Observed | Verdict |',
            '|---|---|---|---|',
            f"| Median | ≤ {check['target_median_ms']} ms | "
            f"{check['observed_median_ms']} ms | "
            f"{'**MET**' if check['median_met'] else '**NOT MET**'} |",
            f"| P95 | ≤ {check['target_p95_ms']} ms | worst case "
            f"{check['observed_worst_case_ms']} ms | {check['p95_verdict']} |",
            f"| Worst case vs P95 target | ≤ {check['target_p95_ms']} ms | "
            f"{check['observed_worst_case_ms']} ms | "
            f"{'within' if check['worst_case_within_target'] else '**EXCEEDS**'} |",
            '',
            '| Case | Prompt | Status | Latency | Completion tokens |',
            '|---|---|---|---|---|',
        ]
        for run in block['runs']:
            tokens = run['completion_tokens'] if run['usage_reported'] else '—'
            lines.append(
                f"| `{run['case']}` | `{run['prompt_version']}` | {run['status']}"
                f"{' (`' + run['code'] + '`)' if run['code'] else ''} "
                f"| {run['latency_ms']} ms | {tokens} |")
        lines.append('')

    lines += [
        '## What this establishes',
        '',
        '- The **BDJ** task shape meets both proposed targets comfortably: median',
        '  ≈ 5.6 s against a 15 s target, worst case ≈ 9.7 s against a 30 s target.',
        '- The **Direct-QG** task shape does **not** meet its targets. Median ≈ 20.1 s',
        '  against a 10 s target; worst case ≈ 30.0 s, which is the configured',
        '  timeout and was recorded as `E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN`.',
        '- Completion tokens track latency closely across the QG runs (1 065 tokens',
        '  → 10.9 s; 3 818 tokens → 27.3 s). Output volume, not prompt length, is the',
        '  dominant term. This is the lever CP-06 should pull.',
        '',
        '## What this does not establish',
        '',
        '- Nothing about V4 or V5 quality, validity or research merit.',
        '- No reliable P95, and therefore no basis for a percentile-based claim.',
        '- No cost figure: `provider_reported_cost` was absent from every recorded',
        '  run, so actual spend is **not available** and is not estimated here.',
    ]
    return '\n'.join(lines) + '\n'


def main() -> int:
    if not SOURCE.exists():
        print(f'missing source: {SOURCE}', file=sys.stderr)
        return 1
    source = json.loads(SOURCE.read_text(encoding='utf-8'))
    payload = {
        'checkpoint': 'CP-05-PERF-BASELINE',
        'generated_at': '2026-11-25',
        'evidence_class': 'RECORDED_PRIOR_RUN_NOT_REMEASURED',
        'source_recorded_at': source.get('executed_at'),
        'source_mode': source.get('mode'),
        'source_budget': source.get('budget'),
        'source_dispatched': source.get('dispatched'),
        'source_retries': source.get('retries'),
        'model_requested': source.get('model_requested'),
        'structured_mode': source.get('structured_mode'),
        'generation_settings': source.get('generation_settings'),
        'data_classification': source.get('data_classification'),
        'families': {},
    }
    for family in ('bdj', 'qg'):
        rows = source['results'][family]
        summary = summarise(rows)
        payload['families'][family] = {
            'prompt_versions_observed': sorted({r['prompt_version'] for r in rows}),
            'summary': summary,
            'target_check': target_check(summary, family),
            'runs': per_run(rows),
        }

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    (OUT_DIR / 'EXISTING_EVIDENCE_BENCHMARK_20261125.json').write_text(
        json.dumps(payload, indent=2) + '\n', encoding='utf-8')
    (OUT_DIR / 'EXISTING_EVIDENCE_BENCHMARK_20261125.md').write_text(
        to_markdown(payload), encoding='utf-8')

    for family in ('bdj', 'qg'):
        s = payload['families'][family]['summary']
        c = payload['families'][family]['target_check']
        print(f'{family:4s} n={s["dispatches"]} median={s["latency_ms"]["median"]}ms '
              f'max={s["latency_ms"]["max"]}ms median_met={c["median_met"]} '
              f'worst_within_p95_target={c["worst_case_within_target"]}')
    print(f'\nwrote -> {OUT_DIR}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
