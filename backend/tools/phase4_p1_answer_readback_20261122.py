"""Priority 1 -- does every persisted M2 answer render in the correct control?

The complaint is that the questionnaire shows a value the database does not
hold, so the check here is deliberately *rendered control vs stored row*, not
"the page mentions the answer somewhere". For each instrument item the harness
reads the option labels that are actually checked in the DOM and compares them
with the current answer for that item, then reports the conditional items
separately because those derive their options from another item's answer.

Read-only: navigating between question cards only moves ``_itemIndex``; it
never calls ``_scheduleAutoSave``. The harness asserts that too, by comparing
the assessment revision before and after the walk.

Run from ``backend/``::

    python tools/phase4_p1_answer_readback_20261122.py
"""
from __future__ import annotations

import json
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from cdp_20261122 import CDP, evaluate  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'var' / 'e2e' / 'p1_answer_readback.json'

ASSESSMENT_ID = '032d3dde-547f-49a6-9e0f-58fbc5f1a48f'

# Which items the instrument marks conditional, what they derive from, and how
# the derivation actually behaves. These are two different mechanisms and
# conflating them produced a false failure: derive_single narrows the choice set
# to the source answer, while requires_priority only gates whether the item is
# shown at all and keeps its own declared options.
DERIVED = {
    'M2V1-05': ('M2V1-04', 'derive_single, exclude UNDECIDED', 'subset'),
    'M2V1-10': ('M2V1-09', 'derive_single, exclude NONE', 'subset'),
    'M2V1-11': ('M2V1-10', 'requires_priority', 'presence'),
}


def query(sql: str) -> list[dict]:
    """Read the disposable database with the credentials the app itself uses."""
    import psycopg2

    text = (ROOT / '.env').read_text(encoding='utf-8')
    password = re.search(r'^DATABASE_URL=.*://[^:]+:([^@]+)@', text, re.M).group(1)
    conn = psycopg2.connect(host='127.0.0.1', port=5433, user='postgres',
                            password=password, dbname='project1_workflow_tests')
    conn.autocommit = True
    try:
        cur = conn.cursor()
        cur.execute(sql)
        cols = [d[0] for d in cur.description]
        return [dict(zip(cols, row)) for row in cur.fetchall()]
    finally:
        conn.close()


def stored_state() -> dict:
    """Current answer per item plus the instrument's option catalogue."""
    items = query("""
        SELECT iv.item_key, iv.requiredness, iv.answer_kind, iv.sort_order,
               iv.option_values::text AS options_json
        FROM public.m2_item_versions iv
        ORDER BY iv.sort_order
    """)
    answers = query(f"""
        SELECT item_key, answer_state, value_json::text AS value_json, assessment_revision
        FROM (
          SELECT iv.item_key, r.answer_state, r.value_json, r.assessment_revision,
                 ROW_NUMBER() OVER (PARTITION BY r.item_version_id
                                    ORDER BY r.assessment_revision DESC) rn
          FROM public.m2_answer_revisions r
          JOIN public.m2_item_versions iv ON iv.id = r.item_version_id
          WHERE r.assessment_id = '{ASSESSMENT_ID}'
        ) t WHERE rn = 1
    """)
    by_key = {a['item_key']: a for a in answers}

    # Conditional items declare no options of their own -- they derive their
    # choices from a source item -- so their codes have to be labelled with the
    # source item's catalogue or the comparison is code-vs-label and always
    # "fails" for the wrong reason.
    label_of_all: dict[str, str] = {}
    for item in items:
        spec = json.loads(item['options_json'] or '{}')
        for opt in spec.get('options', []):
            label_of_all.setdefault(opt['code'], opt['label'])

    out = {}
    for item in items:
        key = item['item_key']
        spec = json.loads(item['options_json'] or '{}')
        answer = by_key.get(key)
        state = answer['answer_state'] if answer else None
        raw = json.loads(answer['value_json']) if answer and answer['value_json'] else None
        codes: list[str] = []
        if isinstance(raw, str):
            codes = [raw]
        elif isinstance(raw, list):
            codes = [str(v) for v in raw]
        label_of = {o['code']: o['label'] for o in spec.get('options', [])}
        out[key] = {
            'requiredness': item['requiredness'],
            'answer_kind': item['answer_kind'],
            'sort_order': item['sort_order'],
            'state': state,
            'codes': codes,
            'labels': [label_of.get(c) or label_of_all.get(c, c) for c in codes],
            'revision': answer['assessment_revision'] if answer else None,
            'declared_options': list(label_of.values()),
            'declares_own_options': bool(label_of),
            'rules': spec.get('rules', {}),
        }
    return out


# Reading one question card. The option inputs are the only controls that carry
# the item key in their name, which is what makes the mapping trustworthy.
READ_CARD = r"""
(() => {
  const card = document.querySelector('.asw-qcard');
  if (!card) return JSON.stringify({error: 'no card'});
  const inputs = [...card.querySelectorAll('input[name^="m2-"]')];
  const key = inputs.length ? inputs[0].name.slice(3) : null;
  const options = inputs.map(i => {
    const label = i.closest('label') || i.parentElement;
    const text = (label ? label.innerText : '').trim().split('\n')[0];
    return {label: text, checked: i.checked, disabled: i.disabled};
  });
  const lines = card.innerText.split('\n').map(s => s.trim()).filter(Boolean);
  const meta = lines.find(l => l.startsWith('Requiredness')) || '';
  const stateLine = lines.find(l => l.startsWith('Required') || l.startsWith('Optional')) || '';
  const qIndex = lines.findIndex(l => /^Question \d+ of \d+$/.test(l));
  return JSON.stringify({
    key,
    position: qIndex >= 0 ? lines[qIndex] : null,
    question: qIndex >= 0 ? (lines[qIndex + 1] || null) : null,
    meta,
    state_line: stateLine,
    options,
    text_inputs: [...card.querySelectorAll('input[type="text"], textarea')].length,
  });
})()
"""


# The Flutter build renders the Material icon as a ligature *inside* the
# button's text, so the label arrives as "arrow_forward\nNext question". An
# exact match therefore never fires; match on containment and take the
# shortest candidate so the icon does not make a wrapper button win.
CLICK_BY_TEXT = r"""
(() => {
  const want = %s;
  const norm = s => (s || '').replace(/\s+/g, ' ').trim().toLowerCase();
  const hits = [...document.querySelectorAll('button')]
    .map(b => ({b, t: norm(b.innerText)}))
    .filter(x => x.t.includes(want))
    .sort((a, c) => a.t.length - c.t.length);
  if (!hits.length) return JSON.stringify({clicked: false, reason: 'not found'});
  const btn = hits[0].b;
  if (btn.disabled) return JSON.stringify({clicked: false, reason: 'disabled'});
  btn.click();
  return JSON.stringify({clicked: true, matched: hits[0].t});
})()
"""


def read_card(cdp: CDP) -> dict:
    return json.loads(evaluate(cdp, READ_CARD)['value'])


def press_button(cdp: CDP, text: str) -> dict:
    return json.loads(evaluate(cdp, CLICK_BY_TEXT % json.dumps(text))['value'])


def advance(cdp: CDP, text: str, current_key: str | None, tries: int = 8) -> str | None:
    """Press a navigation button and wait until the visible card actually changes.

    A fixed sleep is not enough: the canvas repaint lands after the click, so
    reading immediately returns the previous card and every item looks
    unanswered. Wait for the item key to differ instead.
    """
    if not press_button(cdp, text)['clicked']:
        return current_key
    for _ in range(tries):
        time.sleep(0.3)
        card = read_card(cdp)
        key = card.get('key')
        if key and key != current_key:
            return key
    return current_key


def revision(cdp: CDP) -> int | None:
    """The revision the page is showing, read from the card footer text."""
    raw = evaluate(cdp, "document.body.innerText.match(/revision (\\d+)/)?.[1] ?? null")['value']
    return int(raw) if raw is not None else None


def main() -> int:
    expected = stored_state()
    order = sorted(expected, key=lambda k: expected[k]['sort_order'])
    order = [k for k in order if expected[k]['answer_kind'] != 'ACTION']

    cdp = CDP()
    report: dict = {'assessment_id': ASSESSMENT_ID, 'items': [], 'checks': []}
    try:
        before = revision(cdp)

        # Rewind to the first card so the walk starts from a known position.
        for _ in range(14):
            key = read_card(cdp).get('key')
            if advance(cdp, 'previous', key) == key:
                break

        seen: list[dict] = []
        for step in range(len(order)):
            card = read_card(cdp)
            card['step'] = step
            seen.append(card)
            if step < len(order) - 1:
                if advance(cdp, 'next question', card.get('key')) == card.get('key'):
                    break

        after = revision(cdp)

        by_key = {c['key']: c for c in seen if c.get('key')}
        for key in order:
            exp = expected[key]
            card = by_key.get(key)
            rendered = [o['label'] for o in card['options'] if o['checked']] if card else []
            all_rendered = [o['label'] for o in card['options']] if card else []
            entry = {
                'item_key': key,
                'requiredness': exp['requiredness'],
                'answer_kind': exp['answer_kind'],
                'stored_state': exp['state'],
                'stored_codes': exp['codes'],
                'stored_labels': exp['labels'],
                'rendered_checked_labels': rendered,
                'rendered_option_labels': all_rendered,
                'card_found': card is not None,
                'meta': card['meta'] if card else None,
                'state_line': card['state_line'] if card else None,
                'option_count_rendered': len(card['options']) if card else 0,
                'option_count_declared': len(exp['declared_options']),
            }

            notes: list[str] = []

            if exp['answer_kind'] == 'GEO' and exp['codes'] == ['UNDECIDED']:
                # The GEO item declares five areas, but the instrument's own
                # rules mark the geography catalogue AUTHORITY_UNVERIFIED with
                # no areas, so the card may only offer the "not decided"
                # affordance. The value still has to round-trip, and the
                # suppression is recorded rather than hidden.
                ok = (len(rendered) == 1 and 'not decided' in rendered[0].lower())
                entry['verdict'] = 'PASS' if ok else 'FAIL'
                entry['expectation'] = 'only the not-decided affordance is offerable'
                entry['geo_catalogue_suppressed'] = True
                if ok and exp['declared_options'] and rendered[0] not in exp['declared_options']:
                    notes.append(
                        'Declared GEO labels are not rendered while the catalogue is '
                        f'AUTHORITY_UNVERIFIED; stored UNDECIDED shows as "{rendered[0]}" '
                        f'instead of the declared "{exp["labels"][0] if exp["labels"] else "?"}".'
                    )
            elif exp['state'] in (None, 'NOT_PROVIDED', 'NOT_APPLICABLE'):
                # An unanswered item must show nothing selected, and the card
                # must say so rather than silently rendering a default.
                entry['verdict'] = 'PASS' if not rendered else 'FAIL'
                entry['expectation'] = 'no option selected'
            else:
                entry['verdict'] = 'PASS' if rendered == exp['labels'] else 'FAIL'
                entry['expectation'] = f'selected == {exp["labels"]}'

            if not exp['declares_own_options']:
                notes.append(
                    'Conditional item: declares no options of its own; the rendered '
                    'choices are derived from ' + DERIVED.get(key, ('?',))[0] + '.'
                )
            if exp['answer_kind'] == 'MULTI' and len(exp['codes']) > 1:
                notes.append('Multi-select: every stored code must be checked simultaneously.')

            entry['notes'] = notes
            report['items'].append(entry)

        # Conditional items must render the derived subset, not the full list.
        for key, (source, rule, mode) in DERIVED.items():
            entry = next((e for e in report['items'] if e['item_key'] == key), None)
            if not entry:
                continue
            source_codes = expected[source]['codes']
            entry['derived_from'] = source
            entry['derivation_rule'] = rule
            entry['derivation_mode'] = mode
            entry['source_codes'] = source_codes
            if mode == 'subset':
                ok = bool(entry['stored_codes']) and all(
                    c in source_codes or c == 'UNDECIDED' for c in entry['stored_codes'])
                entry['derivation_expectation'] = (
                    f'stored codes are drawn from {source} = {source_codes}')
            else:
                # requires_priority: the item is offered because a priority
                # exists, and it keeps its own declared options.
                ok = bool(source_codes) and entry['card_found'] and \
                    entry['option_count_rendered'] == entry['option_count_declared']
                entry['derivation_expectation'] = (
                    f'offered with its own {entry["option_count_declared"]} options '
                    f'because {source} is answered')
            entry['derivation_verdict'] = 'PASS' if ok else 'FAIL'

        report['checks'].append({
            'check': 'page navigation wrote nothing',
            'revision_before': before,
            'revision_after': after,
            'verdict': 'PASS' if before == after else 'FAIL',
        })

        fails = [i for i in report['items'] if i['verdict'] != 'PASS']
        d_fails = [i for i in report['items'] if i.get('derivation_verdict') == 'FAIL']
        report['summary'] = {
            'items_checked': len(report['items']),
            'render_failures': len(fails),
            'derivation_failures': len(d_fails),
            'verdict': 'PASS' if not fails and not d_fails and before == after else 'FAIL',
        }
    finally:
        cdp.close()

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(report, indent=2), encoding='utf-8')

    print(f'{"item":9} {"req":11} {"kind":6} {"stored":14} {"rendered":34} verdict')
    for i in report['items']:
        print(f'{i["item_key"]:9} {i["requiredness"]:11} {i["answer_kind"]:6} '
              f'{str(i["stored_codes"]):14.14} {str(i["rendered_checked_labels"]):34.34} '
              f'{i["verdict"]}')
    print()
    for c in report['checks']:
        print(f'{c["check"]}: rev {c["revision_before"]} -> {c["revision_after"]}  {c["verdict"]}')
    print(json.dumps(report['summary'], indent=2))
    print(f'wrote {OUT}')
    return 0 if report['summary']['verdict'] == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
