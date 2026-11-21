# Live assessment save/update and disposable-record discard

Executed 2026-11-18 in the original checkout on `merge_main_jed`.
Evidence directory: `artifacts/assessment_cq_relationships_20261118/`.

The Owner chose **only the temporary test assessment** for discard. Neither
existing assessment was discarded. The temporary property was `EP-01051`,
Uptown Damansara Corner Mezzanine Shop Office to Let; its assessment was
`1396f6b6-28df-46f6-8b7a-adb48b935484`, owned by the account already signed into
normal Chrome (`32ef694a-69b0-4863-a77f-b9cf6c056b56`).

## Actual results

| Operation | Result | Evidence / limit |
|---|---|---|
| Open existing saved M2 workspace | PASS, read only | Actual normal Chrome showed MD-02521 → M2 `b438c959-dbb4-4f99-8322-0f841dbba755`, revision 14, 8/10 required answered; no existing answers changed |
| Save temporary property to shortlist | PASS, browser → FastAPI | `POST /api/v1/saved-properties/` HTTP 201 |
| Start temporary assessment | PASS, browser → FastAPI → PostgreSQL | `POST /api/v1/assessments/` HTTP 200; exact owner/property/ID read back in `Final_Location_Analysis.public.assessment` |
| Read M2 link for temporary assessment | Expected HTTP 404 | No M2 record existed. The UI offered Initialize M2 questionnaire. That action was **not** taken; no borrowed M2 answers or synthetic CQ binding |
| Save all five location-scoring preferences | PASS, browser → FastAPI → PostgreSQL | Two actual PATCH requests HTTP 200: requirements then existing Stage 2 completion; `temporary_assessment_saved.json` |
| Edit saved space preference compact → standard | PASS, browser → FastAPI → PostgreSQL | Updated requirements persisted as `standard_business_space`; `temporary_assessment_updated.json` |
| Full browser reload/resume after update | NOT VERIFIED | Computer Use stopped when it could not establish the current Windows browser URL with sufficient confidence. The reload call did not establish a successful result |
| Discard through browser button / authenticated DELETE | NOT EXECUTED | No claim of browser discard success; control stopped before this test |
| Discard temporary assessment through existing backend service | PASS, operator execution | Existing `AssessmentService.get_owned` and `delete_owned`; exact ID/owner/property and zero M2 links checked first; `temporary_assessment_discard_result.json` |
| Remove temporary shortlist entry | PASS, existing owner-scoped repository | Zero remaining entries for this owner + EP-01051 |
| Preserve originals | PASS | Both original marketplace assessment rows and both linked M2 rows have matching before/after SHA-256 hashes |

These five preferences are the existing property-scoring form, **not** the adopted
M2 instrument. This execution does not claim M2 answer save/revision/confirmation
coverage, BDJ/QJ/QG execution, CQ participation, research approval or report release.
The application authentication configuration was not changed and no JWT was minted
or credential bypass introduced. The cleanup is a locally authorized operator call,
not an authenticated HTTP result.

## Persisted test values

```json
{
  "fnb_concept": "cafe_coffee_shop",
  "service_model": "dine_in",
  "recommendation_priority": "high_nearby_population",
  "space_size_preference": "standard_business_space",
  "target_customers": ["nearby_residents"],
  "requirements_version": 3
}
```

The first save used `compact_business_space`; the second save changed that one
field to `standard_business_space`. These were explicitly disposable test values.
No entrepreneur confirmation, M2 assessment, customer campaign, customer answer or
research objective was created for this temporary record. A copy of the complete
temporary row was retained before deletion for audit/recovery; no private auth
headers or tokens were captured.

## Database queries for the cleanup result

Run in **Final_Location_Analysis**:

```sql
BEGIN READ ONLY;
SELECT assessment_id, property_id, status, requirements
FROM public.assessment
WHERE assessment_id IN (
 '1396f6b6-28df-46f6-8b7a-adb48b935484'::uuid,
 '0a79fba2-3a39-4bd1-96b0-f245a1b2c0a7'::uuid,
 'ffa8c0a3-fcd9-4e12-afa1-b7ce6392cc1b'::uuid
);
-- Actual: only the two original rows. No temporary row.
SELECT count(*) AS temporary_shortlist_rows
FROM public.favorite_property
WHERE user_id = '32ef694a-69b0-4863-a77f-b9cf6c056b56'::uuid
  AND property_id = 'EP-01051';
-- Actual: 0.
ROLLBACK;
```

Run in **Dss** as an authorized diagnostic operator:

```sql
BEGIN READ ONLY;
SELECT count(*) AS temporary_m2_links
FROM public.m2_assessment_links
WHERE marketplace_assessment_id = '1396f6b6-28df-46f6-8b7a-adb48b935484'::uuid;
-- Actual before and after discard: 0.
ROLLBACK;
```

## Remaining discard defect

The existing M2 editor deliberately disables Discard assessment because the legacy
DELETE removes only the marketplace row. The assessment listing still exposes
Remove assessment. Discarding a **linked** marketplace record through that legacy
path can leave an active Dss binding dangling; no native cross-database FK prevents
it. This test used an unlinked temporary record and therefore does **not** prove a
safe linked-M2 discard lifecycle. No linked assessment was deleted to reproduce
the risk. Safe revoke/archive/recovery semantics must be reconciled with the
existing link lifecycle before claiming that control complete.

## Runtime and scope

Port 8090 initially had no listener. Started the existing original-checkout FastAPI
application bound to `127.0.0.1:8090`; health HTTP 200. Startup logged schema
creation disabled and zero resumed explanation jobs. Normal Chrome used the existing
signed-in session; `/api/v1/auth/me` returned 200. Browser observations/screenshots
were returned directly by Computer Use. Server request/status logs are in the
evidence directory. Response bodies were not intercepted; SQL readback is separate
evidence and must not be presented as a captured HTTP body.

The browser also triggered an unrelated HTTP 500 on
`GET /api/v1/explore/analysis?ref=EP-01051`. Catalogue detail/evidence/insights
returned 200 and the bounded save/update test succeeded. The unrelated analysis
failure is recorded, not declared fixed by this workstream.

No database migration, live model inference, real customer activation, report
publication, Git merge or deployment was performed.
