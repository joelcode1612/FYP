# PROJECT1 trace-back query pack

Generated: 2026-11-22T15:50:48.718643+00:00

Walk the chain **assessment → BCB → BDJ → admission → measurement → QG candidate** with read-only SQL. Every statement below was executed against the disposable cluster when this file was generated, and the observed row count is printed with it, so a mismatch tells you the chain broke.

## 1. Connect

Disposable cluster only — **never** point this at port 5432.

```bash
# psql (three least-privilege roles; use the one named per query)
psql "postgresql://p1_m2_runtime:m2_runtime_dev_only@127.0.0.1:5433/project1_workflow_tests"
psql "postgresql://p1ai_engine:p1ai_engine_dev_only@127.0.0.1:5433/project1_workflow_tests"
```

> **Row-level security is on.** Every M2 table filters on `owner_user_id = project1_actor()`. If you forget the actor, the policy matches nothing and `count(*)` returns **0** — which looks exactly like "no data". Set it first, in the same session:

```sql
SELECT set_config('project1.actor_id', 'b9e62014-b7bc-426e-a950-a95b25965639', false);
```

Verify the binding took:

```sql
SELECT current_setting('project1.actor_id', true) AS actor;
```

## 2. Identifiers used below

| Item | Value |
|---|---|
| Assessment | `053b3768-145b-4d4a-a880-e98174adcd94` |
| Assessment revision | `20` |
| Confirmation snapshot | `d2453af1-70e8-4be6-9fbe-20fe5e41b357` |
| BCB context | `fa3cb714-5145-57e9-97cd-0af92da80f46` |
| Owner (RLS actor) | `b9e62014-b7bc-426e-a950-a95b25965639` |

## 3. Stage-by-stage queries

### Q01 — Assessment identity

Role: `m2`

```sql
SELECT id, owner_user_id, instrument_id, revision, confirmed_revision, created_at
FROM m2_assessments
WHERE id = '053b3768-145b-4d4a-a880-e98174adcd94';
```

**Observed: 1 row(s).**

| id | owner_user_id | instrument_id | revision | confirmed_revision | created_at |
|---|---|---|---|---|---|
| 053b3768-145b-4d4a-a880-e98174adcd94 | b9e62014-b7bc-426e-a950-a95b25965639 | 42ee86eb-3b5a-5f2c-be4d-be88e5f6f2f6 | 20 | 20 | 2026-11-22 19:21:25.729069+08:00 |

### Q02 — Item versions used by this assessment

Role: `m2`

```sql
SELECT i.item_key, i.id AS item_version_id, i.answer_kind, i.requiredness,
       i.lifecycle, i.sort_order
FROM m2_item_versions i
WHERE i.instrument_id = (
  SELECT instrument_id FROM m2_assessments WHERE id = '053b3768-145b-4d4a-a880-e98174adcd94')
ORDER BY i.sort_order;
```

**Observed: 19 row(s).**

| item_key | item_version_id | answer_kind | requiredness | lifecycle | sort_order |
|---|---|---|---|---|---|
| M2V2-01 | 77f5b867-8cd1-5c7e-80d5-594de4dd945d | GEO | REQUIRED | ACTIVE | 0 |
| M2V2-02 | 27d21f9d-0842-5952-b1fc-f1d292445422 | SINGLE | REQUIRED | ACTIVE | 1 |
| M2V2-03 | 3ac94edd-1d64-5f28-9d23-51b3545c16cb | MULTI | REQUIRED | ACTIVE | 2 |
| M2V2-04 | cb763517-4535-57b7-9ee2-43248d5bdd71 | MULTI | REQUIRED | ACTIVE | 3 |
| M2V2-05 | 321987e3-9ca1-54fd-a713-1ab9d6e1eb57 | SINGLE | CONDITIONAL | ACTIVE | 4 |

_(14 more row(s) not shown)_

### Q03 — Answer revisions (structured codes and free text)

Role: `m2`

```sql
SELECT a.id AS answer_revision_id, i.item_key, a.assessment_revision,
       a.answer_state, a.value_json
FROM m2_answer_revisions a
JOIN m2_item_versions i ON i.id = a.item_version_id
WHERE a.assessment_id = '053b3768-145b-4d4a-a880-e98174adcd94'
ORDER BY i.sort_order, a.assessment_revision;
```

**Observed: 20 row(s).**

| answer_revision_id | item_key | assessment_revision | answer_state | value_json |
|---|---|---|---|---|
| 43b2a5f5-3265-41b2-b5f7-5e6037a3964f | M2V2-01 | 1 | ANSWERED | UNDECIDED |
| 712a7234-8a3e-4fab-a4c2-f3e9a3a8ddbe | M2V2-02 | 2 | ANSWERED | DINE_IN |
| 13c5b55d-49cd-4c79-b391-aaa9f08c3d1b | M2V2-03 | 3 | ANSWERED | ['COFFEE', 'NON_COFFEE'] |
| 5b8c929e-6f24-44db-908e-64b21bd33ab0 | M2V2-04 | 4 | ANSWERED | ['STUDENTS', 'OFFICE_WORKERS'] |
| 02c87ed2-a04d-48b0-b901-9802335a81cd | M2V2-05 | 5 | ANSWERED | STUDENTS |

_(15 more row(s) not shown)_

### Q04 — Confirmation snapshot (the frozen source)

Role: `m2`

```sql
SELECT id, assessment_revision, actor_user_id, snapshot_digest, created_at
FROM m2_confirmation_snapshots
WHERE id = 'd2453af1-70e8-4be6-9fbe-20fe5e41b357';
```

**Observed: 1 row(s).**

| id | assessment_revision | actor_user_id | snapshot_digest | created_at |
|---|---|---|---|---|
| d2453af1-70e8-4be6-9fbe-20fe5e41b357 | 20 | b9e62014-b7bc-426e-a950-a95b25965639 | d472f36176307e4ee023ed33a66899e113a27986f74cc4e00b6b6b832... | 2026-11-22 19:22:04.523605+08:00 |

### Q05 — BCB context packet (hash + lifecycle)

Role: `m2`

```sql
SELECT context_id, assessment_id, confirmation_id, assessment_revision,
       lifecycle_status, packet_hash, schema_version,
       packet_json->>'confirmed_uncertainty' AS confirmed_uncertainty
FROM m2_business_contexts
WHERE context_id = 'fa3cb714-5145-57e9-97cd-0af92da80f46';
```

**Observed: 1 row(s).**

| context_id | assessment_id | confirmation_id | assessment_revision | lifecycle_status | packet_hash |
|---|---|---|---|---|---|
| fa3cb714-5145-57e9-97cd-0af92da80f46 | 053b3768-145b-4d4a-a880-e98174adcd94 | d2453af1-70e8-4be6-9fbe-20fe5e41b357 | 20 | PERSISTED | 26f243be294d27ab5b37fe4ba9100c816ca9439e70b8046dc8ccd9e89... |

### Q06 — BCB build lineage

Role: `m2`

```sql
SELECT confirmation_id, assessment_id, assessment_revision, status,
       last_code, context_id, attempt_count, created_at, updated_at
FROM m2_business_context_builds
WHERE context_id = 'fa3cb714-5145-57e9-97cd-0af92da80f46'
ORDER BY created_at;
```

**Observed: 1 row(s).**

| confirmation_id | assessment_id | assessment_revision | status | last_code | context_id |
|---|---|---|---|---|---|
| d2453af1-70e8-4be6-9fbe-20fe5e41b357 | 053b3768-145b-4d4a-a880-e98174adcd94 | 20 | PERSISTED | NULL | fa3cb714-5145-57e9-97cd-0af92da80f46 |

### Q07 — AI run bound to this source

Role: `runtime`

```sql
SELECT id, work_identity, assessment_id, assessment_revision,
       source_fingerprint, policy_fingerprint, created_at
FROM project1_ai.runs
WHERE assessment_id = '053b3768-145b-4d4a-a880-e98174adcd94' AND assessment_revision = 20
ORDER BY created_at DESC;
```

**Observed: 8 row(s).**

| id | work_identity | assessment_id | assessment_revision | source_fingerprint | policy_fingerprint |
|---|---|---|---|---|---|
| b99214fe-0c16-4596-a27d-7a582a5121c1 | 5cd37ed243a47aeb60da44c2a6d766f87336181e8eaac1c34604313ca... | 053b3768-145b-4d4a-a880-e98174adcd94 | 20 | cde91d92ff781e028414992cc90b6b20ffdcee08186e851275eb4b405... | 6b5c5cab24a46e6af647025b16d9fdda3aed47f47f4a04ceb122ff0df... |
| e946d74f-1068-42ef-a795-9ab2d9e7d54e | 0e6a209c9150aa94ccc469dcd9556a0f7a6ab80ffd0e5b66f50755b64... | 053b3768-145b-4d4a-a880-e98174adcd94 | 20 | cde91d92ff781e028414992cc90b6b20ffdcee08186e851275eb4b405... | 6b5c5cab24a46e6af647025b16d9fdda3aed47f47f4a04ceb122ff0df... |
| 93953693-d394-47b8-901a-347d3e945171 | efcab7dd956b5b6f34be572187573c0d8f0850479eeef14219f5380f8... | 053b3768-145b-4d4a-a880-e98174adcd94 | 20 | cde91d92ff781e028414992cc90b6b20ffdcee08186e851275eb4b405... | 6b5c5cab24a46e6af647025b16d9fdda3aed47f47f4a04ceb122ff0df... |
| adabaf11-f513-493a-ad95-a0a989ff7d93 | da9a801a80842f303a153fd228d29720e9439345d0b725c6f51cba8f4... | 053b3768-145b-4d4a-a880-e98174adcd94 | 20 | cde91d92ff781e028414992cc90b6b20ffdcee08186e851275eb4b405... | 6b5c5cab24a46e6af647025b16d9fdda3aed47f47f4a04ceb122ff0df... |
| c2762f7d-9009-4e8a-bcaf-75241cce920a | 3763c802730ae1a23e4e3313ec91c6818495c9c7f7a88e9593c3b71d5... | 053b3768-145b-4d4a-a880-e98174adcd94 | 20 | cde91d92ff781e028414992cc90b6b20ffdcee08186e851275eb4b405... | 6b5c5cab24a46e6af647025b16d9fdda3aed47f47f4a04ceb122ff0df... |

_(3 more row(s) not shown)_

### Q08 — Attempts and receipts for the run

Role: `runtime`

```sql
SELECT a.run_id, a.attempt_no, a.stage, a.prompt_version, a.prompt_hash,
       a.request_hash, r.outcome, r.output_digest
FROM project1_ai.attempts a
LEFT JOIN project1_ai.attempt_receipts r
  ON r.run_id = a.run_id AND r.attempt_no = a.attempt_no
WHERE a.run_id IN (
  SELECT id FROM project1_ai.runs
  WHERE assessment_id = '053b3768-145b-4d4a-a880-e98174adcd94'
)
ORDER BY a.run_id, a.attempt_no;
```

**Observed: 6 row(s).**

| run_id | attempt_no | stage | prompt_version | prompt_hash | request_hash |
|---|---|---|---|---|---|
| 23c5d14d-3694-4698-9550-7696e24460d3 | 1 | BDJ | BDJ-OBJECTIVE-3-M2V2-CAND | 47b7c2c5516f37f1e658dad620a62ac22968e937eeca138fed5a4e443... | 44ba64e81260c05323d7337982deebe7761f9ebe8781fb5389ab2b9b4... |
| 93953693-d394-47b8-901a-347d3e945171 | 1 | BDJ | BDJ-OBJECTIVE-3-M2V2-CAND | 47b7c2c5516f37f1e658dad620a62ac22968e937eeca138fed5a4e443... | 93aef4c557cf8add28d0a98347186d71d8f59ba844a1e7188c4be57ca... |
| adabaf11-f513-493a-ad95-a0a989ff7d93 | 1 | BDJ | BDJ-OBJECTIVE-3-M2V2-CAND | 47b7c2c5516f37f1e658dad620a62ac22968e937eeca138fed5a4e443... | 93aef4c557cf8add28d0a98347186d71d8f59ba844a1e7188c4be57ca... |
| b99214fe-0c16-4596-a27d-7a582a5121c1 | 1 | BDJ | BDJ-OBJECTIVE-3-M2V2-CAND | 47b7c2c5516f37f1e658dad620a62ac22968e937eeca138fed5a4e443... | 93aef4c557cf8add28d0a98347186d71d8f59ba844a1e7188c4be57ca... |
| c2762f7d-9009-4e8a-bcaf-75241cce920a | 1 | BDJ | BDJ-OBJECTIVE-3-M2V2-CAND | 47b7c2c5516f37f1e658dad620a62ac22968e937eeca138fed5a4e443... | 44ba64e81260c05323d7337982deebe7761f9ebe8781fb5389ab2b9b4... |

_(1 more row(s) not shown)_

### Q09 — BDJ objective proposals

Role: `m2`

```sql
SELECT proposal_id, confirmation_revision, recommendation_status,
       problem_type, research_objective, validation_status, review_state,
       execution_mode, model_provider, source_fingerprint, created_at
FROM m2_bdj_objective_proposals
WHERE assessment_id = '053b3768-145b-4d4a-a880-e98174adcd94'
ORDER BY created_at;
```

**Observed: 3 row(s).**

| proposal_id | confirmation_revision | recommendation_status | problem_type | research_objective | validation_status |
|---|---|---|---|---|---|
| 377ec98c-df9e-5030-8890-8c71723cb44f | 20 | MOST_SUGGESTED | SOURCE_CONFIRMED_INFORMATION_GAP | To investigate what the confirmed M2V2-11 declaration lea... | VALID |
| d20808b4-55a2-5376-b78b-a14370eb06de | 20 | MOST_SUGGESTED | SOURCE_CONFIRMED_INFORMATION_GAP | To investigate what the confirmed M2V2-01 declaration lea... | VALID |
| 662b8518-89a2-56a5-940f-5d44adcc86d4 | 20 | SUGGESTED | EXPLORATORY_RESEARCH_NEED | To investigate customer interest in the concept of the co... | VALID |

### Q10 — Owner decisions on proposals (approval is not admission)

Role: `m2`

```sql
SELECT decision_id, proposal_id, decision, decided_by, decided_at, note
FROM m2_bdj_objective_decisions
WHERE proposal_id IN (
  SELECT proposal_id FROM m2_bdj_objective_proposals
  WHERE assessment_id = '053b3768-145b-4d4a-a880-e98174adcd94')
ORDER BY decided_at;
```

**Observed: 3 row(s).**

| decision_id | proposal_id | decision | decided_by | decided_at | note |
|---|---|---|---|---|---|
| 1966643d-4ab6-4333-9f1f-5d4404815a28 | 377ec98c-df9e-5030-8890-8c71723cb44f | APPROVED | b9e62014-b7bc-426e-a950-a95b25965639 | 2026-11-22 22:39:11.641926+08:00 | Phase 3B synthetic engineering verification. |
| 5bc9d571-c838-42aa-942d-f7781c611d61 | d20808b4-55a2-5376-b78b-a14370eb06de | APPROVED | b9e62014-b7bc-426e-a950-a95b25965639 | 2026-11-22 22:39:11.768329+08:00 | Phase 3B synthetic engineering verification. |
| 8fe15bcf-fa9a-4743-9b79-e102034a3900 | 662b8518-89a2-56a5-940f-5d44adcc86d4 | APPROVED | b9e62014-b7bc-426e-a950-a95b25965639 | 2026-11-22 22:39:12.985433+08:00 | Owner approves the exploratory objective. |

### Q11 — Admissions (the governed gate)

Role: `m2`

```sql
SELECT admission_id, proposal_id, objective_id, decision,
       policy_version, policy_classification, policy_disposition,
       policy_resolution, source_fingerprint, created_at
FROM m2_bdj_objective_admissions
WHERE assessment_id = '053b3768-145b-4d4a-a880-e98174adcd94'
ORDER BY created_at;
```

**Observed: 2 row(s).**

| admission_id | proposal_id | objective_id | decision | policy_version | policy_classification |
|---|---|---|---|---|---|
| b1176785-ceed-4c54-8e7b-8d99be4bdda7 | 377ec98c-df9e-5030-8890-8c71723cb44f | NULL | WORTH_RESEARCHING | P1-BDJ-ISSUE-0.1-CAND | EXPLICIT_UNCERTAINTY |
| ea8d9d6b-70b6-4bfc-b882-a0fa95a6e97e | 662b8518-89a2-56a5-940f-5d44adcc86d4 | O1 | WORTH_RESEARCHING | P1-BDJ-ISSUE-0.1-CAND | NULL |

### Q12 — Measurement specifications and their approval decisions

Role: `m2`

```sql
SELECT s.measurement_id, s.measurement_version, s.objective_id,
       s.construct, s.status, s.response_format, s.content_digest
FROM m2_measurement_specs s
ORDER BY s.measurement_id, s.measurement_version;
```

**Observed: 1 row(s).**

| measurement_id | measurement_version | objective_id | construct | status | response_format |
|---|---|---|---|---|---|
| P1-MEAS-O1-CONCEPT-INTEREST | 0.1-CAND | O1 | Stated interest in the confirmed café concept | CANDIDATE_REVIEW | SINGLE_CHOICE |

### Q13 — Measurement decisions (who approved what, at which scope)

Role: `m2`

```sql
SELECT d.measurement_id, d.measurement_version, d.decision, d.authority,
       d.scope, d.decided_at
FROM m2_measurement_decisions d
ORDER BY d.measurement_id, d.decided_at;
```

**Observed: 2 row(s).**

| measurement_id | measurement_version | decision | authority | scope | decided_at |
|---|---|---|---|---|---|
| P1-MEAS-O1-CONCEPT-INTEREST | 0.1-CAND | APPROVE | SCIENTIFIC_REVIEWER | SYNTHETIC_TEST | 2026-11-22 22:39:13.108826+08:00 |
| P1-MEAS-O1-CONCEPT-INTEREST | 0.1-CAND | APPROVE | OWNER_APPROVER | SYNTHETIC_TEST | 2026-11-22 22:39:13.108826+08:00 |

### Q14 — QG authorizations (single-use, narrowly bound)

Role: `m2`

```sql
SELECT authorization_id, objective_id, objective_admission_id,
       measurement_id, measurement_version, source_fingerprint,
       context_packet_hash, issued_at, expires_at, consumed_at
FROM m2_qg_authorizations
WHERE assessment_id = '053b3768-145b-4d4a-a880-e98174adcd94'
ORDER BY issued_at;
```

**Observed: 36 row(s).**

| authorization_id | objective_id | objective_admission_id | measurement_id | measurement_version | source_fingerprint |
|---|---|---|---|---|---|
| 386feebe-a6c0-4057-89fa-61363dd2caec | O1 | ea8d9d6b-70b6-4bfc-b882-a0fa95a6e97e | P1-MEAS-O1-CONCEPT-INTEREST | 0.1-CAND | cde91d92ff781e028414992cc90b6b20ffdcee08186e851275eb4b405... |
| 5615ae91-d1ba-4c45-a779-0d25a84f0784 | O1 | ea8d9d6b-70b6-4bfc-b882-a0fa95a6e97e | P1-MEAS-O1-CONCEPT-INTEREST | 0.1-CAND | cde91d92ff781e028414992cc90b6b20ffdcee08186e851275eb4b405... |
| a4ef66d2-666f-4ac3-bf0a-3e91856776fe | O1 | ea8d9d6b-70b6-4bfc-b882-a0fa95a6e97e | P1-MEAS-O1-CONCEPT-INTEREST | 0.1-CAND | cde91d92ff781e028414992cc90b6b20ffdcee08186e851275eb4b405... |
| 4976fa14-cfe5-4d15-ba07-11ff2e0b4f8a | O1 | ea8d9d6b-70b6-4bfc-b882-a0fa95a6e97e | P1-MEAS-O1-CONCEPT-INTEREST | 0.1-CAND | cde91d92ff781e028414992cc90b6b20ffdcee08186e851275eb4b405... |
| b12df9da-e2c4-4546-9285-4d3e8a1a8723 | O1 | ea8d9d6b-70b6-4bfc-b882-a0fa95a6e97e | P1-MEAS-O1-CONCEPT-INTEREST | 0.1-CAND | cde91d92ff781e028414992cc90b6b20ffdcee08186e851275eb4b405... |

_(31 more row(s) not shown)_

### Q15 — QG candidates (the end of the chain)

Role: `m2`

```sql
SELECT candidate_id, objective_id, response_format, candidate_state,
       structural_status, semantic_status, provenance_status,
       execution_mode, qg_authorization_id, output_sha256, created_at
FROM m2_qg_candidates
WHERE assessment_id = '053b3768-145b-4d4a-a880-e98174adcd94'
ORDER BY created_at;
```

**Observed: 1 row(s).**

| candidate_id | objective_id | response_format | candidate_state | structural_status | semantic_status |
|---|---|---|---|---|---|
| 632e67d1-0165-549e-a382-c6368fb115b5 | O1 | SINGLE_CHOICE | VALIDATED | STRUCTURALLY_VALID | UNDER_REVIEW |

## 4. One-shot trace

Single query that walks assessment → BCB → proposal → admission → QG candidate. Empty columns show exactly where the chain stops.

```sql
SELECT
  a.id                      AS assessment_id,
  a.revision                AS revision,
  c.context_id,
  left(c.packet_hash, 16)   AS bcb_hash,
  p.proposal_id,
  p.recommendation_status   AS proposal_status,
  p.review_state            AS proposal_review,
  ad.admission_id,
  ad.objective_id           AS admitted_objective,
  ad.policy_disposition,
  q.candidate_id,
  q.response_format,
  q.candidate_state         AS qg_state
FROM m2_assessments a
LEFT JOIN m2_business_contexts c
       ON c.assessment_id = a.id
LEFT JOIN m2_bdj_objective_proposals p
       ON p.assessment_id = a.id
LEFT JOIN m2_bdj_objective_admissions ad
       ON ad.proposal_id = p.proposal_id
LEFT JOIN m2_qg_candidates q
       ON q.assessment_id = a.id AND q.objective_id = ad.objective_id
WHERE a.id = '053b3768-145b-4d4a-a880-e98174adcd94'
ORDER BY p.created_at, q.created_at;
```

**Observed: 3 row(s).**

| assessment_id | revision | context_id | bcb_hash | proposal_id | proposal_status | proposal_review | admission_id | admitted_objective | policy_disposition | candidate_id | response_format | qg_state |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 053b3768-145b-4d4a-a880-e98174adcd94 | 20 | fa3cb714-5145-57e9-97cd-0af92da80f46 | 26f243be294d27ab | 377ec98c-df9e-5030-8890-8c71723cb44f | MOST_SUGGESTED | APPROVED | b1176785-ceed-4c54-8e7b-8d99be4bdda7 | NULL | ENTREPRENEUR_CLARIFICATION | NULL | NULL | NULL |
| 053b3768-145b-4d4a-a880-e98174adcd94 | 20 | fa3cb714-5145-57e9-97cd-0af92da80f46 | 26f243be294d27ab | d20808b4-55a2-5376-b78b-a14370eb06de | MOST_SUGGESTED | APPROVED | NULL | NULL | NULL | NULL | NULL | NULL |
| 053b3768-145b-4d4a-a880-e98174adcd94 | 20 | fa3cb714-5145-57e9-97cd-0af92da80f46 | 26f243be294d27ab | 662b8518-89a2-56a5-940f-5d44adcc86d4 | SUGGESTED | APPROVED | ea8d9d6b-70b6-4bfc-b882-a0fa95a6e97e | O1 | NULL | 632e67d1-0165-549e-a382-c6368fb115b5 | SINGLE_CHOICE | VALIDATED |

## 5. Reading the result

| Symptom | Cause | Fix |
|---|---|---|
| `count(*)` is 0 but rows exist | RLS actor not set | run the `set_config` above |
| `permission denied for table …` | wrong role for that table | use the role named on the query |
| proposal exists, no admission | admission never granted (or refused) | check `policy_disposition` on Q11 |
| admission exists, `objective_id` NULL | admitted without a fixed objective | cannot authorise a QG candidate by design |
| no QG candidate | no valid authorization, or no approved measurement | Q12/Q13/Q14 |
| `QG_FIXED_OPTION_ADMISSION_UNAVAILABLE` | fixed-option admission is unavailable | safety behaviour, not a bug |

## 6. Column reference

Auto-read from `information_schema` at generation time.

### `m2_assessments`

| Column | Type |
|---|---|
| `id` | uuid |
| `owner_user_id` | uuid |
| `instrument_id` | uuid |
| `revision` | integer |
| `confirmed_revision` | integer |
| `created_at` | timestamp with time zone |

### `m2_item_versions`

| Column | Type |
|---|---|
| `id` | uuid |
| `instrument_id` | uuid |
| `item_key` | character varying |
| `question_text` | text |
| `requiredness` | character varying |
| `answer_kind` | character varying |
| `option_values` | json |
| `allowed_states` | json |
| `lifecycle` | character varying |
| `sort_order` | integer |

### `m2_answer_revisions`

| Column | Type |
|---|---|
| `id` | uuid |
| `assessment_id` | uuid |
| `item_version_id` | uuid |
| `assessment_revision` | integer |
| `answer_state` | character varying |
| `value_json` | json |
| `created_at` | timestamp with time zone |

### `m2_confirmation_snapshots`

| Column | Type |
|---|---|
| `id` | uuid |
| `assessment_id` | uuid |
| `assessment_revision` | integer |
| `actor_user_id` | uuid |
| `snapshot_json` | json |
| `snapshot_digest` | character varying |
| `acknowledged_issue_ids` | json |
| `created_at` | timestamp with time zone |

### `m2_business_contexts`

| Column | Type |
|---|---|
| `context_id` | uuid |
| `assessment_id` | uuid |
| `owner_user_id` | uuid |
| `confirmation_id` | uuid |
| `assessment_revision` | integer |
| `schema_version` | character varying |
| `builder_version` | character varying |
| `purpose` | character varying |
| `tenant_id` | character varying |
| `concept_version` | character varying |
| `snapshot_digest` | character varying |
| `packet_hash` | character varying |
| `canonical_body` | text |
| `packet_json` | jsonb |
| `lifecycle_status` | character varying |
| `created_at` | timestamp with time zone |

### `m2_business_context_builds`

| Column | Type |
|---|---|
| `confirmation_id` | uuid |
| `assessment_id` | uuid |
| `owner_user_id` | uuid |
| `assessment_revision` | integer |
| `status` | character varying |
| `last_code` | character varying |
| `context_id` | uuid |
| `attempt_count` | integer |
| `created_at` | timestamp with time zone |
| `updated_at` | timestamp with time zone |

### `m2_bdj_objective_proposals`

| Column | Type |
|---|---|
| `proposal_id` | uuid |
| `evaluation_id` | uuid |
| `assessment_id` | uuid |
| `confirmation_id` | uuid |
| `confirmation_revision` | integer |
| `source_fingerprint` | character |
| `context_id` | character varying |
| `context_packet_hash` | character |
| `recommendation_status` | character varying |
| `problem_type` | character varying |
| `problem` | text |
| `research_objective` | character varying |
| `reason` | character varying |
| `evidence_limitation` | character varying |
| `source_refs` | jsonb |
| `contract_version` | character varying |
| `prompt_version` | character varying |
| `execution_mode` | character varying |
| `model_provider` | character varying |
| `model_requested` | character varying |
| `model_returned` | character varying |
| `validation_status` | character varying |
| `review_state` | character varying |
| `owner_user_id` | uuid |
| `created_at` | timestamp with time zone |

### `m2_bdj_objective_decisions`

| Column | Type |
|---|---|
| `decision_id` | uuid |
| `proposal_id` | uuid |
| `decision` | character varying |
| `decided_by` | uuid |
| `decided_at` | timestamp with time zone |
| `source_fingerprint` | character |
| `confirmation_id` | uuid |
| `context_packet_hash` | character |
| `note` | character varying |

### `m2_bdj_objective_admissions`

| Column | Type |
|---|---|
| `admission_id` | uuid |
| `proposal_id` | uuid |
| `assessment_id` | uuid |
| `confirmation_id` | uuid |
| `confirmation_revision` | integer |
| `source_fingerprint` | character |
| `context_packet_hash` | character |
| `actor_user_id` | uuid |
| `decision` | character varying |
| `proposal_hash` | character |
| `request_id` | uuid |
| `created_at` | timestamp with time zone |
| `objective_id` | character varying |
| `policy_version` | character varying |
| `policy_classification` | character varying |
| `policy_disposition` | character varying |
| `policy_resolution` | character varying |

### `m2_measurement_specs`

| Column | Type |
|---|---|
| `measurement_id` | character varying |
| `measurement_version` | character varying |
| `objective_id` | character varying |
| `construct` | character varying |
| `population` | character varying |
| `status` | character varying |
| `response_format` | character varying |
| `allowed_parameter_names` | ARRAY |
| `spec_json` | jsonb |
| `content_digest` | character |
| `owner_user_id` | uuid |
| `created_at` | timestamp with time zone |

### `m2_measurement_decisions`

| Column | Type |
|---|---|
| `decision_id` | uuid |
| `measurement_id` | character varying |
| `measurement_version` | character varying |
| `decision` | character varying |
| `authority` | character varying |
| `actor_user_id` | uuid |
| `scope` | character varying |
| `content_digest` | character |
| `rationale` | character varying |
| `decided_at` | timestamp with time zone |

### `m2_qg_authorizations`

| Column | Type |
|---|---|
| `authorization_id` | uuid |
| `assessment_id` | uuid |
| `confirmation_id` | uuid |
| `assessment_revision` | integer |
| `source_fingerprint` | character |
| `context_id` | uuid |
| `context_packet_hash` | character |
| `objective_id` | character varying |
| `objective_admission_id` | uuid |
| `measurement_id` | character varying |
| `measurement_version` | character varying |
| `prompt_version` | character varying |
| `prompt_sha256` | character |
| `issued_by` | uuid |
| `issued_at` | timestamp with time zone |
| `expires_at` | timestamp with time zone |
| `consumed_at` | timestamp with time zone |
| `consumed_candidate_id` | uuid |
| `request_id` | uuid |

### `m2_qg_candidates`

| Column | Type |
|---|---|
| `candidate_id` | uuid |
| `assessment_id` | uuid |
| `confirmation_id` | uuid |
| `assessment_revision` | integer |
| `source_fingerprint` | character |
| `context_id` | uuid |
| `context_packet_hash` | character |
| `objective_id` | character varying |
| `objective_admission_id` | uuid |
| `measurement_id` | character varying |
| `measurement_version` | character varying |
| `qg_authorization_id` | uuid |
| `run_id` | uuid |
| `attempt_no` | integer |
| `prompt_version` | character varying |
| `prompt_sha256` | character |
| `request_sha256` | character |
| `output_sha256` | character |
| `execution_mode` | character varying |
| `model_provider` | character varying |
| `model_requested` | character varying |
| `model_returned` | character varying |
| `response_format` | character varying |
| `candidate_state` | character varying |
| `structural_status` | character varying |
| `semantic_status` | character varying |
| `provenance_status` | character varying |
| `contract_version` | character varying |
| `adapter_version` | character varying |
| `candidate_json` | jsonb |
| `owner_user_id` | uuid |
| `created_at` | timestamp with time zone |
