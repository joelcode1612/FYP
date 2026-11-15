"""Source-faithful TEST_ONLY / NOT_ADOPTED data; never a production importer."""
from pathlib import Path
import hashlib
import re

SOURCE = Path(__file__).parent / 'fixtures/hellop_TEST_ONLY_NOT_ADOPTED.txt'
SOURCE_SHA256 = '5a1e0d0874d52adfe820a56d15c57efa776795a5d8f0abeee33d03d2763e2829'


def load_hellop():
    raw = SOURCE.read_bytes()
    assert hashlib.sha256(raw).hexdigest() == SOURCE_SHA256
    # CRLF and Markdown hard-break markers are formatting, not questionnaire
    # wording. The original bytes and blocks remain available for comparison.
    content = raw.decode('utf-8-sig').replace('\r\n', '\n')
    matches = list(re.finditer(r'^(M2-(?:O-)?\d{2})\. (.+)$', content, re.M))
    records = []
    for index, match in enumerate(matches):
        key, heading = match.groups()
        block = content[match.start():matches[index + 1].start() if index + 1 < len(matches) else len(content)]
        lines = [line.strip().removesuffix('\\').rstrip() for line in block.splitlines()]
        options = [line for line in lines if re.match(r'^[A-G]\. ', line)]
        instructions = [line for line in lines[1:] if line and not re.match(r'^[A-G]\. |^### ', line)]
        # The final source disclaimer and appended redesign request are data,
        # never instructions executed by the test. Actions are not answer fields.
        if key in ('M2-20', 'M2-21'):
            instructions = []
        kind = ('ACTION' if key in ('M2-20', 'M2-21') else 'TEXT' if key == 'M2-04'
                else 'MULTI' if key in ('M2-06', 'M2-07', 'M2-09', 'M2-13', 'M2-16', 'M2-17') else 'SINGLE')
        records.append({'item_key': key, 'heading': heading, 'question_text': '\n\n'.join([heading, *instructions]),
            'options': options, 'source_block': block, 'source_line': content[:match.start()].count('\n') + 1,
            'answer_kind': kind, 'requiredness': 'REQUIRED' if '(Required' in heading else 'RECOMMENDED' if '(Recommended' in heading else 'OPTIONAL',
            'lifecycle': 'DEFERRED' if key == 'M2-11' else 'ACTIVE',
            'privacy_review_pending': key == 'M2-15', 'max_selected': 2 if key == 'M2-09' else 3 if key == 'M2-13' else None})
    assert len(records) == 23 and len({r['item_key'] for r in records}) == 23
    assert sum(r['answer_kind'] == 'ACTION' for r in records) == 2
    return {'label': 'TEST_ONLY / NOT_ADOPTED', 'production_authority': 'M2_INSTRUMENT_AUTHORITY_UNVERIFIED',
        'source_sha256': SOURCE_SHA256, 'items': records,
        'option_storage_convention': 'Exact printed code plus wording used as the test value; no adopted semantic code mapping is inferred.',
        'known_representation_gaps': ['M2-07 separate primary group', 'Other specify text',
            'M2-09 max two', 'M2-13 max three', 'M2-16/M2-17 printed-option exclusivity',
            'Exact M2-20/21 action wording is retained in source; existing UI action labels differ.']}


def sample_answers(source):
    """Clearly fictional inputs; not entrepreneur-authored production answers."""
    result = []
    for item in source['items']:
        if item['lifecycle'] != 'ACTIVE' or item['answer_kind'] == 'ACTION':
            continue
        state = 'SKIPPED_OPTIONAL' if item['privacy_review_pending'] else 'ANSWERED'
        value = None if state != 'ANSWERED' else (
            'TEST_ONLY fictional declaration: We guarantee profit.' if item['answer_kind'] == 'TEXT'
            else [item['options'][0]] if item['answer_kind'] == 'MULTI' else item['options'][0])
        result.append({'item_key': item['item_key'], 'question_text': item['question_text'],
            'kind': item['answer_kind'], 'options': item['options'], 'answer_state': state, 'value': value})
    assert len(result) == 20
    return result
