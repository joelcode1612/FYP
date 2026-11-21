from sitewise.project1.result_store import _project_payload


def test_current_result_keeps_each_findings_refs_without_quotes():
    payload = {'findings': [
        {'rule_id': 'one', 'source_refs': [
            {'item_key': 'M2V1-09', 'answer_revision_id': 'a1',
             'item_version_id': 'v1', 'quote': 'private answer'}]},
        {'rule_id': 'two', 'source_refs': [
            {'item_key': 'M2V1-10', 'answer_revision_id': 'a2',
             'item_version_id': 'v2', 'quote': 'another private answer'}]},
    ]}
    findings, refs = _project_payload(payload, include_finding_refs=True)
    assert findings[0]['source_refs'] == [refs[0]]
    assert findings[1]['source_refs'] == [refs[1]]
    assert refs[0]['item_key'] == 'M2V1-09'
    assert refs[1]['item_key'] == 'M2V1-10'
    assert 'quote' not in str(findings)
    assert 'private answer' not in str(findings)
    legacy, _ = _project_payload(payload)
    assert 'source_refs' not in legacy[0]
