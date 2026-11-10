# SiteWise — eliminate duplicate Supabase GETs on Admin Agent Management

## What the existing code does

A single load of `fyp_jaspr_web/lib/pages/admin/agents_page.dart` calls four FastAPI routes concurrently:

- `/api/v1/staff/agents`: `agent` 1, `company` 1, `staff_invitations` 1
- `/api/v1/staff/companies`: `company` 1
- `/api/v1/staff/invitations`: `staff_invitations` 1
- `/api/v1/staff/summary`: `agent` 1, `company` **2**, `staff_invitations` **2**

Total: **9 Supabase PostgREST GETs per page load** (2 agent, 3 company, 4 invitation), plus local database queries. Each can return HTTP 200; the log output by itself is not an error or an infinite loop.

## Solution

This narrowly scoped patch modifies 3 existing source files:

1. `backend/src/sitewise/api/v1/staff.py` — reuses supplied agent/company/invitation rows inside `_agent_records()` and adds an authenticated, admin-MFA-protected `GET /api/v1/staff/overview` endpoint; reads each table only once.
2. `fyp_jaspr_web/lib/data/admin_api.dart` — adds a typed `StaffOverviewSnapshot` and `overview()` method.
3. `fyp_jaspr_web/lib/pages/admin/agents_page.dart` — replaces four concurrent calls with one, prevents stale concurrent responses from overwriting a newer refresh, preserves prior data on failure, and adjusts the error message.

Existing routes, invite workflows, authorization checks and database tables remain unchanged.

## Installation (PowerShell)

Extract this folder anywhere. From the FYP root:

```powershell
cd C:\Users\Lenovo\AndroidStudioProjects\FYP
python C:\path\to\sitewise_staff_fetch_fix\apply_staff_fetch_fix.py --root .
# Inspect the preview. Only after it passes:
python C:\path\to\sitewise_staff_fetch_fix\apply_staff_fetch_fix.py --root . --apply
```

The installer makes `*.before-staff-fetch-fix.bak` copies alongside changed files. No migration, database write, or new dependency is introduced.

## Verify

```powershell
cd C:\Users\Lenovo\AndroidStudioProjects\FYP\backend
.\.venv\Scripts\python.exe -m compileall -q src\sitewise\api\v1\staff.py
.\.venv\Scripts\python.exe -m pytest tests\test_staff_admin_api.py -q
cd ..\fyp_jaspr_web
dart analyze lib\data\admin_api.dart lib\pages\admin\agents_page.dart
jaspr build
cd ..
.\run-sitewise.cmd
```

In browser DevTools (F12 > Network), navigate to `/admin/agents` with an admin MFA session. On one load you should see one `/api/v1/staff/overview` request from that page. On the FastAPI terminal, a single overview GET should trigger one each of Supabase `agent`, `company`, and `staff_invitations` GETs (other concurrently open pages may still issue their own calls). Test an agent invitation, refresh and verify it appears in the roster and invitation list; verify counts agree.

## Known limitations

- This patch was tested structurally against a representative snippet of the GitHub main branch, not compiled against the user's local workspace. If your local code differs and any patch anchor is missing, it fails without making changes.
- If users navigate away while a request remains pending, the authenticated request can still complete. The monotonic result guard ensures an older result cannot overwrite a newer one.
- This is not a Supabase-side caching change, and it does not remove legitimate reads from other admin pages or the login flow.
- Do **not** solve this by removing admin MFA, turning off the requests, or globally suppressing logging.
