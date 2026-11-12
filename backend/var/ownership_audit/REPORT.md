# SiteWise — Property Ownership & Agent Management Audit (read-only)

**Date:** 2026-11-12 · **Branch:** `joel` · **HEAD:** `698a1cc` ("joel1")
**Database audited:** `Final_Location_Analysis` @ localhost:5432 — the **active** FastAPI target.
`backend/.env:1` overrides `DATABASE_URL` to `Final_Location_Analysis`; the code default
(`backend/src/sitewise/core/config.py:12`, database `Dss`) is **not** what runs. All operational
tables (`fyp.rental_properties`, `public.agent_listing_assignment`, `public.users`) live in
`Final_Location_Analysis`. No project instructions (AGENTS.md/QODER.md) exist at root or backend.

**Read-only guarantee:** every local query ran in a session forced
`SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY`; only SELECTs were issued. Supabase was
read via service-role **GET** requests (PostgREST + GoTrue admin) using the backend's own
credentials — the same mechanism as `SupabaseAdminService`
(`backend/src/sitewise/core/supabase_admin.py:638-662`). No INSERT/UPDATE/DELETE, no migration,
no schema change, no reassignment. The Supabase MCP server failed twice
(`MCP tool invocation did not complete`); supabase-py client construction also fails in this
shell (httpx `Invalid port: ':1]'` from a malformed proxy env pattern), so direct REST GETs were
used. The API server was not running on :8000 during the audit (connection refused); backend
findings are from code + data, not live HTTP.

---

## Report A — Actual property management results

**Per-property export:** `report_a_properties.csv` (1,187 rows, same folder). Columns:
`property_id | property_title | owner_uuid | agent_id | management_type | assignment_status |
validation_result | legacy_owner_id | owner_email | owner_account_status | verification_status |
is_published | catalogue_ref | provenance | created_at`.

### Counts (queried, not estimated)

| Category | Count |
|---|---|
| Total operational properties (`fyp.rental_properties`) | **1187** |
| With current owner UUID (`owner_user_id`, resolves to active mirror user) | **3** |
| With legacy owner only (`owner_id` → `fyp.users`) | **227** |
| With no owner at all (both columns NULL) | **957** |
| Agent-managed (AGENT_MANAGED) | **0** |
| Owner-managed (OWNER_MANAGED, derived — see rule below) | **3** |
| Unassigned (UNASSIGNED) | **227** |
| Unknown owner (UNKNOWN_OWNER) | **957** |
| Invalid Agent assignments (INVALID_ASSIGNMENT) | **0** |
| Conflicting assignments (CONFLICTING_ASSIGNMENTS) | **0** (structurally impossible) |
| Draft properties | **5** |
| Pending properties | **955** |
| Approved properties | **227** (all 227 also `is_published = true`) |

**Overlap:** the management classes partition all 1187 rows (0+3+227+957). The status classes
also partition (5+955+227). Owner-coverage categories partition (3+227+957). They cross-cut:
all 3 UUID-owned rows are drafts; all 227 legacy-owned rows are approved+published; all 955
research imports are pending+unpublished; 2 of the 5 drafts are ownerless test artifacts.

**`public.agent_listing_assignment` is EMPTY (0 rows).** No property is agent-managed.
`listing_id` is the PRIMARY KEY (single assignment per property, FK → `fyp.rental_properties(id)`
ON DELETE CASCADE — `backend/alembic/versions/20261111_0004_agent_listing_assignments.py:52-85`),
so multiple/conflicting effective assignments cannot exist. There is no status column: a row's
existence *is* the active assignment. No seed INSERT for assignments exists anywhere in the repo
(migration is DDL-only; `backend/supabase/migrations/*` are identity/role files) — **the
previously discussed Agent 2/3 seed was never committed; assignments could only ever have been
created through `POST /api/v1/staff/listings/{id}/assign`, and none were.**

### Classification rule used (and its honest caveat)

The repository defines **no** `management_type` field and **no** documented owner-managed rule
(grep across `backend/src`, `backend/docs`, `fyp_jaspr_web/lib`: zero hits). Classification was
derived from the authorization code:

- **AGENT_MANAGED** — an assignment row exists whose `agent_id` resolves to a Supabase agent
  profile. (0 rows.)
- **OWNER_MANAGED** — `owner_user_id` resolves to an **active** `public.users` mirror row and no
  assignment exists. The code rule that owners manage their own listings is explicit
  (`dependencies.py:254-266` `require_property_owner`: "entrepreneurs manage the properties they
  own"; `properties.py:256-266` `_owned_listing_or_error`). **Caveat:** this is a code-derived
  designation, not a stored business rule; under the brief's strictest reading these 3 would be
  UNASSIGNED. Both readings are reported; making the rule explicit is Report F item 2.
- **UNASSIGNED** — an owner record exists but no usable current designation: the 227 rows whose
  only owner is legacy `owner_id = 8` (`owner@fyp.demo`). The current backend authorizes against
  `owner_user_id` **only**, so that legacy owner cannot manage them today (admin-only).
- **UNKNOWN_OWNER** — both owner columns NULL (955 research imports + 2 test drafts).

### The three provenance populations

| Provenance | Rows | Status | Owner | Catalogue link |
|---|---|---|---|---|
| `demo_seed` | 227 | approved + published | legacy `fyp.users` id 8 (`owner@fyp.demo`, active) | numeric external-portal refs (e.g. `501493880`); **no** join to `sitewise_app.properties` |
| `research_import` | 955 | pending, unpublished | none | `listing_id` = EP-/MD- catalogue id; 1:1 join to `sitewise_app.properties` (955/955) and `fyp.property_subject_links` (955, all `match_verified = true`) |
| `owner_draft` | 5 | draft | 3 rows: 2 active entrepreneur UUIDs; 2 rows: none (`persist-check-*` test artifacts) | none |

The 3 UUID-owned drafts: id 1961 "property qwe" + id 2218 "djdnd" →
`f56fa3fa-6dde-4176-92e5-d8a460aafd01` (jedthj-wm23@student.tarc.edu.my, entrepreneur, active);
id 5216 "eerff" → `f69be94e-fc0e-46ff-adc4-99567a5d916d` (joelthj-wm23@student.tarc.edu.my,
entrepreneur, active).

---

## Report B — Agent workload

Supabase `public.agent` (authoritative, read via service role) has **exactly 2 rows**:

| Agent ID | User UUID | Name | Company | Account (Supabase `public.users`) | GoTrue state | Assigned properties | Active assignments | Invalid assignments |
|---|---|---|---|---|---|---|---|---|
| 2 | `8de9ed3b-1431-4603-b680-731e40f53628` | Joel Personal (joelstrengthpersonal@gmail.com) | 1 | agent / active | confirmed 2026-11-10, `banned_until` NULL, last sign-in 2026-11-11 | **0** | 0 | 0 |
| 3 | `dcbc87df-0911-49ed-806c-02305441439f` | Joel (joeltanhoujun@gmail.com) | 1 | agent / active | confirmed 2026-11-11, `banned_until` NULL, last sign-in 2026-11-11 | **0** | 0 | 0 |

The brief's UUID↔integer mapping is **verified correct**. Both agents are valid and active;
neither manages anything because the assignment table is empty. `GET /api/v1/staff/me/listings`
(`staff.py:911-931`) correctly returns `{"agent": profile, "listings": []}` for them.

A **third** local mirror "agent" exists — `4ce62dfc-…` `mfa-repro@sitewise-test.invalid` — with
**no** Supabase identity or agent profile: pytest residue (Report C).

---

## Report C — Missing / invalid management records

1. **957 properties with no owner** (955 research imports + 2 test drafts). Research imports are
   *not* invalid operational rows — they are verified catalogue-linked research subjects
   awaiting the ownership/verification workflow; they must not be auto-labelled defective.
2. **227 published properties with an unusable owner.** `owner_id = 8` points at a legacy
   `fyp.users` demo account that cannot authenticate through Supabase; `owner_user_id` is NULL,
   so `_owned_listing_or_error` (`properties.py:256-266`) denies every non-admin. These live
   listings have **no reachable manager** today.
3. **0 invalid / 0 conflicting / 0 orphaned assignments** — the table is empty; the FK + PK make
   orphans and conflicts structurally impossible.
4. **Test residue in the live database:**
   - 2 ownerless drafts `persist-check-e4847460…` (id 5184) and `persist-check-2ae7e700…` (id 5185)
     in `fyp.rental_properties` — pytest wrote to the operational DB.
   - 5 mirror-only staff identities in `public.users`: 1 "agent"
     (`mfa-repro@sitewise-test.invalid`) and 4 "admins"
     (`verify-admin-*@jwks-test.example`), all `active`, none present in Supabase. They inflate
     the local staff roster (mirror: 110 users / 3 agents / 5 admins vs authoritative Supabase:
     11 users / 2 agents / 3 admins).
5. **`public.property_verification` is empty (0 rows).** The unified verification workflow has
   never been exercised on this DB; the 227 approved rows were seeded directly, not approved
   through the workflow. No orphan verification rows.
6. **Mirror drift (benign direction):** 4 Supabase entrepreneurs have no local mirror row yet
   (mirror provisions on first sign-in via `get_or_sync_current`, `dependencies.py:130-149`).
7. **Research mapping is sound:** `fyp.property_subject_links` — 955 rows, all
   `match_verified = true`, method `WORKBOOK_EXACT_CANONICAL_ID`. Brief's examples verified:
   `MD-00510` → operational id **316**, `MD-01755` → operational id **1139**. Research ids are
   never used as assignment FKs (the FK targets the numeric operational PK only).
8. **Frontend contract gap (in-flight WIP, not modified):** `AdminApi.listOwnershipRequests()`
   (`fyp_jaspr_web/lib/data/admin_api.dart:577-592`) calls `GET /api/v1/properties/` — **that
   route does not exist** (`router.py:31-40` mounts only `/listings*` and per-property
   verification routes under `/properties`; no root GET anywhere). The ownership queue would
   404. Its `OwnershipRequest` fields (`user_id`, `status`, `district_id`) also match no current
   table (`sitewise_app.properties` has none of them).

---

## Report D — Backend functionality (what works / what is incomplete)

### Works (code-verified, with test coverage)

| Function | Flow | Evidence |
|---|---|---|
| Create owner listing | `POST /api/v1/properties/listings` → `require_property_owner` → `FypPropertyRepository.create_owner_listing(owner_user_id=current.user_id)` → `fyp.rental_properties` (pending, unpublished) | `properties.py:172-210`; repo `fyp_property_repository.py:880` |
| Owner drafts | `POST /listings/drafts`, `GET/PATCH /listings/{id}`; edit locked while pending/under_review/verified | `properties.py:269-343` |
| Owner retrieves own | `GET /listings/mine` → `owner_listings(current.user_id)` | `properties.py:213-219`; repo `:949` |
| Owner isolation | `_owned_listing_or_error`: non-admin + (owner NULL or ≠ caller) → 403 | `properties.py:256-266` |
| Assign / reassign | `POST /api/v1/staff/listings/{id}/assign` (admin+aal2) → resolve Supabase agent profile by UUID → upsert `ON CONFLICT (listing_id)` → audit `listing.assigned` | `staff.py:1010-1042`; repo `:97-136` |
| Unassign | `DELETE …/assign` (admin+aal2); property untouched | `staff.py:1045-1055`; repo `:138-144` |
| Agent assigned listings | `GET /api/v1/staff/me/listings` → profile → `list_for_agent(agent_id)`; empty is truthful | `staff.py:911-931`; repo `:72-77` |
| Agent scope enforcement | `_require_listing_access`: no assignment → 404; other agent's → 403; admin passes on real properties only | `staff.py:934-970` |
| Admin assignment overview | `GET /api/v1/staff/assignments` | `staff_listings.py:805` |
| Agent listing ops | detail `:295`, proposal PATCH `:371`, review-request `:456`, notes `:520`, photos `:838+` — all through the one access helper | `staff_listings.py` |
| Verification workflow | submitter submit/documents; admin queue `GET /staff/properties/`, start-review/approve/reject/request-information | `property_verification.py:95-337` |
| Identity resolution | integer `agent_id` ↔ UUID via Supabase `public.agent.user_id`; role/status always from local mirror, never token metadata | `supabase_admin.py:638-662`; `dependencies.py:1-19,130-160` |
| AuthZ baseline | active account + staff role + signed `aal2`; admin ops additionally admin role | `dependencies.py:152-240` |

Existing tests already cover the assignment contract:
`backend/tests/api/test_agent_listing_assignments.py` — agent sees only own assignment, other
agent 403, missing assignment 404, FK-backed assign, admin read, draft never touches operational
row, submit/approve/reject, stale proposal 409, duplicate pending refused, queue admin+MFA,
photo scope, proposer cannot decide own request. Plus `tests/test_staff_authorization.py`,
`tests/test_staff_admin_api.py`.

### Incomplete / missing

1. **No management projection anywhere.** No endpoint returns `management_type`, manager
   identity or assignment status alongside a property. `AgentAssignmentRepository._LIST_SELECT`
   (`agent_assignment_repository.py:29-51`) is the only join, and it serves the agent/admin
   assignment screens only — owner pages, admin review detail and explore detail never see it.
2. **No explicit owner-managed rule** (Report A caveat) — behavior is implicit in authZ code.
3. **Legacy-owned 227 are unmanageable by their owner** (Report C.2); no reconciliation path.
4. **No assignment history / status.** Reassign overwrites the single row (previous agent lost);
   the only trace is Supabase `role_change_audit` (`listing.assigned`). Unassign leaves no local
   record. No `terminated_at`, no history table.
5. **Agent deactivation does not touch assignments.** Suspending an agent
   (`staff.py:764-804`) blocks their login (`get_active_user`) but their assignment rows remain
   "active" in admin views; nothing flags or reclaims them.
6. **Enquiries have no backing** — no table, no endpoint; the agent enquiries screen is declared
   prototype data (`fyp_jaspr_web/lib/data/agent_records.dart:90-130`).
7. **Ownership review queue endpoint missing** (Report C.8) — WIP frontend calls a 404 route.
8. **Verification workflow unused on this DB** (0 rows) while 227 rows are already published.

### Frontend manager display (verified absent)

No page renders "Managed by Owner" / "Managed by Agent — [name]"; no hard-coded agent names;
no assumption that the logged-in user is the manager. Admin listings/review
(`listings_page.dart`, `verification_detail_view.dart`), agent workspace
(`agent/listings_page.dart` via `AgentRecords.assignedListings()`), owner pages
(`owner/properties_page.dart`, `owner/property_detail_page.dart`) and entrepreneur detail show
verification/publication state only. The web client **already has** assignment transport
(`admin_api.dart:505-530`: `listAssignments`, `assignListing`, `unassignListing`) — the missing
piece is a backend management projection plus a badge, not new plumbing.

---

## Report E — Recommended architecture (owner vs manager)

- **Property owner** — the identity legally/accountably associated with the listing. Canonical
  key: `fyp.rental_properties.owner_user_id` (Supabase UUID, stamped from the verified token at
  creation, never client-settable). `owner_id` → `fyp.users` is a **legacy** column from the
  pre-Supabase demo era and should be treated as historical provenance, not authorization.
- **Property manager** — the owner **or** an explicitly assigned agent responsible for
  operational management. Canonical key: the single `public.agent_listing_assignment` row
  (PK `listing_id`), whose `agent_id` resolves through Supabase `public.agent.user_id`.
- **Expected behavior for a listing with no agent:** it is **owner-managed by default** *once
  the owner is a verified current identity* — the owner exercises management through the
  existing owner endpoints; agents have no access (404). With no usable owner it is
  **unassigned/unknown-owner** and only administrators may act. This rule must be written down
  and exposed, not left implicit in authZ code.
- **Derived management type (no new column required initially):**
  `assignment row exists → AGENT_MANAGED; else owner_user_id resolves active → OWNER_MANAGED;
  else owner record exists → UNASSIGNED; else UNKNOWN_OWNER`. A stored `management_type` column
  is optional later (requires approval); derivation avoids dual-write drift.
- **One manager invariant** is already enforced by the PK — keep it. Reassignment should preserve
  history (audit or history table) instead of silently overwriting.

---

## Report F — Proposed implementation changes (NOT executed; approval required)

### Backend

1. **Management projection (minimal, reuse schema).**
   - `backend/src/sitewise/repositories/fyp_property_repository.py` (`FypPropertyRepository`,
     class at `:195`): add a read that LEFT JOINs `public.agent_listing_assignment` and returns
     `management: {type, agent_id, agent_user_id, agent_name, assignment_status, assigned_at,
     owner_user_id, owner_display}`. Agent name/company come from the Supabase profile via the
     existing `SupabaseAdminService.get_agent_profile` / `list_agent_profiles`
     (`supabase_admin.py:638-662`) — never a local join on integer↔UUID.
   - Expose in: `GET /api/v1/properties/listings/{id}` (`properties.py:296`),
     `GET /api/v1/staff/properties/` queue rows (`property_verification.py:247`),
     `GET /api/v1/staff/listings/{id}` (`staff_listings.py:295`). Owner contact details stay
     admin/owner-scoped; public/explore responses get `management.type` + agent display name
     only where authorized.
2. **Explicit rule.** New `backend/src/sitewise/domain/management.py` implementing the Report E
   derivation + a doc entry in `backend/docs`; unit-test the four branches. No DB change.
3. **Legacy owner reconciliation (data change — needs approval).** For the 227 `owner_id = 8`
   rows: either stamp a real verified `owner_user_id` (e.g. the demo owner's Supabase identity)
   or mark them platform-managed. Proposed as a reviewed, reversible script under
   `backend/scripts/` following the existing apply-script convention; **not run**.
4. **Assignment lifecycle (schema change — needs approval).** Option A (no schema): keep the
   single row, write `listing.unassigned` / `listing.reassigned` audit entries (extend
   `staff.py:1045-1055` to audit, mirroring `:1034-1041`). Option B: add `status`,
   `terminated_at` + `agent_assignment_history` table via a new apply script. Recommend A first.
5. **Deactivation handling (read-time, no writes).** In the management projection, join the
   agent's mirror `account_status`; surface `assignment_status = "agent_suspended"` when the
   assigned agent is suspended, and flag it in the admin queue. Optionally auto-unassign on
   suspend (data change — approval).
6. **Ownership queue endpoint.** Either add the missing `GET /api/v1/properties/` projection
   (operational rows + owner + management) or repoint the WIP client to
   `GET /api/v1/staff/properties/`. Coordinate with the other session owning
   `ownership_page.dart` / `admin_api.dart` — **not modified here**.
7. **Enquiries** remain prototype until a product decision; if wanted: `enquiry` table +
   owner/agent-scoped endpoints (separate approved migration).

### Frontend

8. Manager badge ("Managed by Owner" / "Managed by Agent — {name}") from the new projection in
   `fyp_jaspr_web/lib/components/verification_detail_view.dart`,
   `pages/owner/property_detail_page.dart`, `pages/agent/listings_page.dart`, and the admin
   review split. Transport already exists (`admin_api.dart:505-530`); add a `management` field
   to the relevant response models. No hard-coded names.

### Tests (propose; existing suite already covers scope enforcement)

- Management projection: agent-managed / owner-managed / unassigned / unknown-owner branches.
- Owner fallback: after `DELETE …/assign`, the owner regains management and the type flips to
  OWNER_MANAGED; agent access becomes 404.
- Reassignment: previous agent loses access (403), new agent gains it, audit recorded.
- Suspended agent: projection flags `agent_suspended`; suspended agent cannot call
  `me/listings` (403 via `get_active_user`).
- Legacy owner: non-admin cannot PATCH the 227 rows (403); admin can.
- Ownership authorization: owner A cannot read/patch owner B's draft (already covered for
  assignments; add the owner-listing equivalents).
- Management display: widget/component test that the badge renders the backend value and never
  the logged-in user by default.

### Cleanup (data changes — approval required)

- Remove the 2 `persist-check-*` drafts and the 5 test mirror identities; point pytest at an
  isolated database (the residue proves tests currently write to the live DB).

---

## Acceptance criteria — direct answers

1. **Who owns property X?** 3 drafts → the two entrepreneur UUIDs above; 227 published → legacy
   demo account `owner@fyp.demo` (id 8, not a Supabase identity); 957 → nobody.
2. **Who currently manages X?** No agents manage anything. The 3 draft owners manage their own
   rows; administrators can manage all; the 227 published rows have no reachable owner-manager.
3. **Owner- or agent-managed?** 0 agent-managed; 3 owner-managed (code-derived); 227 unassigned;
   957 unknown-owner.
4. **Which agent?** None — assignment table empty.
5. **Does that agent really have access?** Agents 2/3 are valid/active but have zero
   assignments; every listing route returns 404 for them (correct).
6. **Can an owner retrieve all their properties?** Yes via `GET /properties/listings/mine` for
   the UUID owners; the legacy demo owner cannot authenticate at all.
7. **Can an agent retrieve only assigned properties?** Yes — enforced server-side
   (`staff.py:911-970`), test-covered.
8. **Invalid/missing assignments?** 0 invalid, 0 conflicting, 0 orphaned; 957 missing owners,
   227 legacy-only owners, plus test residue.
9. **Does the frontend display the correct manager?** No — the display does not exist anywhere,
   and no API supplies management type.
10. **What is needed?** Report F: a management projection + explicit rule + lifecycle audit +
    legacy-owner reconciliation + the badge; schema/data changes only with approval.

## Unresolved ambiguity (separated from facts)

- Whether `DATABASE_URL` pointing at `Final_Location_Analysis` (vs the `Dss` default) is
  intentional consolidation or drift — the apply script's "analytics" name guard
  (`apply_agent_listing_assignments_migration.py:33`) does **not** catch this database name.
- Whether the 227 demo-seeded published listings should ever have a real owner, or remain
  platform-managed samples.
- Whether research imports (955) are intended to enter the ownership workflow at all.
- The strict vs derived reading of OWNER_MANAGED for the 3 drafts (Report A caveat).
- The in-flight ownership page's intended endpoint (other session's WIP).

## Audit artifacts (this folder)

- `report_a_properties.csv` — 1,187 classified rows.
- `../_audit_schema.json`, `../_audit_data.json`, `../_audit_supabase.json` — raw read-only dumps.
- `../_audit_schema_probe.py`, `../_audit_data_probe.py`, `../_audit_supabase_probe.py`,
  `../_audit_build_csv.py` — the read-only scripts (re-runnable).