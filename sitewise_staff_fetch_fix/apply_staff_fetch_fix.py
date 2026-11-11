#!/usr/bin/env python3
"""Patch SiteWise Admin Agent Management to use one aggregated backend request.

No migrations and no database changes. Backs up each changed file.
Run without --apply for a full read-only preflight.
"""
from __future__ import annotations

import argparse
import ast
import difflib
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent
BACKEND = Path('backend/src/sitewise/api/v1/staff.py')
API = Path('fyp_jaspr_web/lib/data/admin_api.dart')
PAGE = Path('fyp_jaspr_web/lib/pages/admin/agents_page.dart')


def replace_once(src: str, old: str, new: str, label: str) -> str:
    count = src.count(old)
    if count != 1:
        raise ValueError(f'{label}: expected exactly one match, found {count}. Refusing to patch.')
    return src.replace(old, new, 1)


def update_backend(src: str) -> str:
    if '@router.get("/overview")' in src:
        return src
    src = replace_once(
        src,
        'def _latest_invitations(service: SupabaseAdminService) -> dict[str, dict]:',
        'def _latest_invitations(\n'
        '    service: SupabaseAdminService, rows: list[dict] | None = None\n'
        ') -> dict[str, dict]:',
        '_latest_invitations signature',
    )
    src = replace_once(
        src,
        '    rows = service.list_invitations()\n    ordered = sorted(rows,',
        '    if rows is None:\n        rows = service.list_invitations()\n    ordered = sorted(rows,',
        '_latest_invitations data source',
    )
    src = replace_once(
        src,
        'def _company_index(service: SupabaseAdminService) -> dict[int, str]:',
        'def _company_index(\n'
        '    service: SupabaseAdminService, rows: list[dict] | None = None\n'
        ') -> dict[int, str]:',
        '_company_index signature',
    )
    src = replace_once(
        src,
        '    for company in service.list_companies()\n        if company.get("company_id") is not None',
        '    for company in (rows if rows is not None else service.list_companies())\n'
        '        if company.get("company_id") is not None',
        '_company_index data source',
    )
    src = replace_once(
        src,
        'def _agent_records(session: Session, service: SupabaseAdminService) -> list[dict]:',
        'def _agent_records(\n'
        '    session: Session,\n'
        '    service: SupabaseAdminService,\n'
        '    *,\n'
        '    agent_profiles: list[dict] | None = None,\n'
        '    company_rows: list[dict] | None = None,\n'
        '    invitation_rows: list[dict] | None = None,\n'
        ') -> list[dict]:',
        '_agent_records signature',
    )
    src = replace_once(
        src,
        '    for agent in service.list_agent_profiles():\n'
        '        uid = agent.get("user_id")',
        '    for agent in (agent_profiles if agent_profiles is not None else service.list_agent_profiles()):\n'
        '        uid = agent.get("user_id")',
        '_agent_records agent data source',
    )
    src = replace_once(
        src,
        '    companies = _company_index(service)\n    invitations = _latest_invitations(service)',
        '    companies = _company_index(service, company_rows)\n'
        '    invitations = _latest_invitations(service, invitation_rows)',
        '_agent_records company and invitation data',
    )

    marker = '# ---------------------------------------------------------------------------\n# Suspension / reactivation (Step: assign and suspend agent permissions)'
    new_endpoint = '''@router.get("/overview")
def staff_overview(
    admin: AdminMfaUser,
    session: Session = Depends(get_db),
) -> dict:
    """Agent management snapshot: read each Supabase table only once.

    Keep /agents, /companies, /invitations and /summary for existing callers.
    Authentication/role/MFA checks remain the same as those endpoints.
    """
    service = _admin_service()
    agent_profiles = service.list_agent_profiles()
    company_rows = service.list_companies()
    invitation_rows = service.list_invitations()
    agents = _agent_records(
        session, service,
        agent_profiles=agent_profiles,
        company_rows=company_rows,
        invitation_rows=invitation_rows,
    )
    summary = {
        "total_agents": len(agents),
        "active_agents": sum(
            1 for row in agents if row["account_status"] == rbac.STATUS_ACTIVE
        ),
        "pending_agents": sum(
            1 for row in agents if row["account_status"] == rbac.STATUS_PENDING
        ),
        "suspended_agents": sum(
            1 for row in agents if row["account_status"] == rbac.STATUS_SUSPENDED
        ),
        "open_invitations": sum(
            1 for row in invitation_rows
            if _invitation_state(row) in _OPEN_INVITATION_STATES
        ),
        "invitations": len(invitation_rows),
        "companies": len(company_rows),
    }
    return {
        "agents": agents,
        "companies": company_rows,
        "invitations": invitation_rows,
        "summary": summary,
    }


'''
    src = replace_once(src, marker, new_endpoint + marker, 'overview endpoint insertion')
    ast.parse(src)
    return src


def update_api(src: str) -> str:
    if 'Future<StaffOverviewSnapshot> overview()' in src:
        return src
    marker = '/// Reads/writes for the operations pages. Instances are cheap; `AppLocator`\n'
    # Keep Dart 3 record handling away from older callers; explicit value object.
    cls = '''/// Single consistent snapshot for Agent Management. No duplicate reads.
class StaffOverviewSnapshot {
  final List<StaffAgent> agents;
  final List<CompanyRecord> companies;
  final List<StaffInvitation> invitations;
  final StaffSummary summary;

  const StaffOverviewSnapshot({
    required this.agents,
    required this.companies,
    required this.invitations,
    required this.summary,
  });
}

'''
    src = replace_once(src, marker, cls + marker, 'StaffOverviewSnapshot insertion')
    method = '''  /// One server request, three Supabase reads for the full Agent Management page.
  /// This endpoint uses the same admin + aal2 authorization as the old routes.
  Future<StaffOverviewSnapshot> overview() async {
    final payload = _object(await WebAuth.request('/api/v1/staff/overview'));
    return StaffOverviewSnapshot(
      agents: _rows(payload['agents']).map(StaffAgent.fromJson).toList(growable: false),
      companies: _rows(payload['companies']).map(CompanyRecord.fromJson).toList(growable: false),
      invitations: _rows(payload['invitations']).map(StaffInvitation.fromJson).toList(growable: false),
      summary: StaffSummary.fromJson(_object(payload['summary'])),
    );
  }

'''
    src = replace_once(src, '  // --- Agent management -----------------------------------------------------\n',
                       '  // --- Agent management -----------------------------------------------------\n\n'+method,
                       'AdminApi overview insertion')
    return src


def update_page(src: str) -> str:
    if 'AppLocator.adminApi.overview()' in src:
        return src
    marker_start = '  /// One failing endpoint must not blank the rest of the page:'
    marker_end = '  // --- Derived values -------------------------------------------------------'
    if src.count(marker_start) != 1 or src.count(marker_end) != 1:
        raise ValueError('agents_page.dart method anchors changed, refusing to patch')
    first=src.index(marker_start)
    last=src.index(marker_end,first)
    body='''  /// Monotonic sequence prevents an older refresh from overwriting a newer one.
  int _loadSequence = 0;

  /// A single backend snapshot avoids repeated PostgREST reads and inconsistent
  /// KPIs. On failure, keep last good data and display a visible error.
  Future<void> _load({bool silent = false}) async {
    final sequence = ++_loadSequence;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final snapshot = await AppLocator.adminApi.overview();
      if (!mounted || sequence != _loadSequence) return;
      setState(() {
        _agents = snapshot.agents;
        _invitations = snapshot.invitations;
        _companies = snapshot.companies;
        _summary = snapshot.summary;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || sequence != _loadSequence) return;
      setState(() {
        _loading = false;
        _error = AdminApi.message(error);
      });
    }
  }

'''
    src = src[:first]+body+src[last:]
    old_error = ("            'Some live data could not be read: $_error. The records that did '\n"
                 "            'load are shown below; use Refresh to retry.',")
    new_error = ("            'Could not refresh agent management: $_error. Previously loaded '\n"
                 "            'records are preserved. Use Refresh to retry.',")
    src = replace_once(src, old_error, new_error, 'Error callout copy')
    return src


def main() -> int:
    parser=argparse.ArgumentParser()
    parser.add_argument('--root',type=Path,default=Path.cwd(), help='FYP workspace root')
    parser.add_argument('--apply',action='store_true',help='Apply patch; without this only preview')
    args=parser.parse_args()
    target=args.root.resolve()
    transforms={BACKEND:update_backend,API:update_api,PAGE:update_page}
    plans=[]
    for relative,transform in transforms.items():
        path=target/relative
        if not path.is_file():
            parser.error(f'Missing {path}: use the FYP workspace root')
        before=path.read_text(encoding='utf-8')
        after=transform(before)
        plans.append((path,before,after))
        print(('UPDATE' if before!=after else 'ALREADY PATCHED'),relative)
        if not args.apply and before!=after:
            diff=list(difflib.unified_diff(before.splitlines(),after.splitlines(),fromfile=str(relative),tofile=str(relative)))
            print(f'   {len(diff)} lines in patch preview')
    if not args.apply:
        print('READ-ONLY PREFLIGHT OK. Run with --apply to change the 3 files.')
        return 0
    backups=[]
    try:
        for path,before,after in plans:
            if before==after:
                continue
            backup=path.with_name(path.name+'.before-staff-fetch-fix.bak')
            if backup.exists():
                raise FileExistsError(f'Backup already exists: {backup}. Refusing overwrite.')
            backup.write_text(before,encoding='utf-8')
            backups.append((path,backup))
            path.write_text(after,encoding='utf-8')
        print('Applied. Backup copies created next to each changed file.')
        return 0
    except Exception:
        for path,backup in backups:
            if backup.exists():
                path.write_text(backup.read_text(encoding='utf-8'), encoding='utf-8')
        raise

if __name__ == '__main__':
    raise SystemExit(main())
