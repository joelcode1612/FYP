"""Structural regression tests for the SiteWise admin fetch patch script.
Not a substitute for running Dart analyzer / FastAPI tests in the FYP workspace.
"""
from pathlib import Path
from tempfile import TemporaryDirectory
import subprocess
import sys
from apply_staff_fetch_fix import update_api, update_backend, update_page

backend='''
from __future__ import annotations
from fastapi import APIRouter, Depends
from sqlmodel import Session
router = APIRouter()
def _latest_invitations(service: SupabaseAdminService) -> dict[str, dict]:
    """Newest invitation per email, keyed by the lower-cased address."""
    rows = service.list_invitations()
    ordered = sorted(rows, key=lambda row: str(row.get("created_at") or ""), reverse=True)
    latest: dict[str, dict] = {}
    for row in ordered:
        email = str(row.get("invited_email") or "").lower()
        if email and email not in latest:
            latest[email] = row
    return latest

def _company_index(service: SupabaseAdminService) -> dict[int, str]:
    """``company_id -> company_name`` for the existing company rows."""
    return {
        int(company["company_id"]): str(company.get("company_name") or "")
        for company in service.list_companies()
        if company.get("company_id") is not None
    }

def _agent_records(session: Session, service: SupabaseAdminService) -> list[dict]:
    by_user: dict[str, dict] = {}
    for agent in service.list_agent_profiles():
        uid = agent.get("user_id")
        if uid:
            by_user[str(uid)] = agent
    companies = _company_index(service)
    invitations = _latest_invitations(service)
    records=[]
    return records

# ---------------------------------------------------------------------------
# Suspension / reactivation (Step: assign and suspend agent permissions)
'''
api='''class StaffSummary:
    pass

/// Reads/writes for the operations pages. Instances are cheap; `AppLocator`
/// exposes one shared instance.
class AdminApi {
  // --- Agent management -----------------------------------------------------
}
'''
page='''class State<T> {}
  /// One failing endpoint must not blank the rest of the page: each read is
  /// individually guarded, all four start concurrently, and the errors are
  /// reported together while successful data is still rendered.
  old functions
  // --- Derived values -------------------------------------------------------
        if (_error != null)
          Callout(
            'Some live data could not be read: $_error. The records that did '
            'load are shown below; use Refresh to retry.',
            tone: 'warning',
            icon: 'warning',
          ),
'''
assert 'staff_overview' in update_backend(backend)
assert update_backend(update_backend(backend))==update_backend(backend)
assert "StaffOverviewSnapshot" in update_api(api)
assert update_api(update_api(api))==update_api(api)
assert '_loadSequence' in update_page(page)
assert update_page(update_page(page))==update_page(page)
with TemporaryDirectory() as tmp:
    root=Path(tmp)
    for path,content in {
        'backend/src/sitewise/api/v1/staff.py':backend,
        'fyp_jaspr_web/lib/data/admin_api.dart':api,
        'fyp_jaspr_web/lib/pages/admin/agents_page.dart':page,
    }.items():
        p=root/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(content,encoding='utf-8')
    script=Path(__file__).with_name('apply_staff_fetch_fix.py')
    subprocess.run([sys.executable,str(script),'--root',str(root)],check=True,capture_output=True,text=True)
    assert (root/'backend/src/sitewise/api/v1/staff.py').read_text()==backend
    subprocess.run([sys.executable,str(script),'--root',str(root),'--apply'],check=True,capture_output=True,text=True)
    assert 'staff_overview' in (root/'backend/src/sitewise/api/v1/staff.py').read_text()
    assert (root/'backend/src/sitewise/api/v1/staff.py.before-staff-fetch-fix.bak').read_text()==backend
    subprocess.run([sys.executable,str(script),'--root',str(root)],check=True,capture_output=True,text=True)
print('PATCH STRUCTURAL TESTS PASSED')
