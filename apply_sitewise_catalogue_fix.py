"""Apply the SiteWise published-property → saved-list → assessment integration.

Run once from FYP repository root, or pass --root PATH. --check validates
expected upstream anchors without writing. The script is idempotent and saves
originals under .sitewise_catalogue_fix_backups before editing.

It NEVER modifies research ranking, PU models, training data, migrations, or
feature refresh and does NOT publish or approve any listing.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import sys

SERVICE = Path('backend/src/sitewise/services/assessment_service.py')
ASSES = Path('backend/src/sitewise/api/v1/assessments.py')
CATALOG = Path('backend/src/sitewise/api/v1/catalog.py')
SAVED = Path('backend/src/sitewise/api/v1/saved_properties.py')
MAPPER = Path('shared_logic/lib/src/data/mappers/catalog_property_mapper.dart')
WEB_DETAIL = Path('fyp_jaspr_web/lib/pages/entrepreneur/property_detail_page.dart')
MODULE = Path('backend/src/sitewise/services/assessment_property_catalog.py')


def swap(text: str, before: str, after: str, label: str, *, count: int = 1) -> str:
    """Exact replacements, safely repeatable against an already patched repo."""
    if before == after:
        return text
    if after and after in text:
        return text
    if not after and before not in text:
        return text
    occurrences = text.count(before)
    if occurrences != count:
        raise RuntimeError(f'{label}: expected {count} occurrence(s) of an upstream code block, found {occurrences}. '
                           'Repository may have changed; inspect and merge manually.')
    return text.replace(before, after, count)


def replace_section(text: str, start: str, end: str, *, changes: list[tuple[str, str]], label: str) -> str:
    i = text.find(start)
    j = text.find(end, i + len(start)) if i >= 0 else -1
    if i < 0 or j < 0:
        raise RuntimeError(f'{label}: could not identify endpoint section')
    chunk = text[i:j]
    for a, b in changes:
        chunk = swap(chunk, a, b, label)
    return text[:i] + chunk + text[j:]


def transform_service(s: str) -> str:
    s = swap(s, 'from sitewise.repositories.catalog_repository import CatalogRepository\n',
             'from sitewise.services.assessment_property_catalog import (\n'
             '    AssessmentPropertyCatalog, operational_property_id,\n)\n', 'assessment service imports')
    s = swap(s, 'self.catalog = CatalogRepository(analytics_session)',
             'self.catalog = AssessmentPropertyCatalog(session, analytics_session)', 'assessment source wiring')
    needle = '''    """Availability of the two stages that need real model output."""\n    model = _model_capability()'''
    replacement = '''    """Availability of the two stages that need real model output."""\n    # Operational listings have no verified EP-/MD- 47-feature PU vector by\n    # default. Avoid claiming that the model/SHAP stages are available merely\n    # because a research model artifact is installed on the server.\n    if operational_property_id(property_id) is not None:\n        reason = (\n            "This published property does not have a verified, compatible "\n            "47-feature research PU input. Location evidence and saved "\n            "requirements remain available, but model explanation is not."\n        )\n        return {\n            "model": {"available": False, "reason": reason},\n            "explanation": {"available": False, "reason": reason},\n            "report": {"available": False, "reason": reason},\n        }\n    model = _model_capability()'''
    s = swap(s, needle, replacement, 'assessment capability guard')
    # A mixed research/operational history must not give every property the
    # capability verdict of the first row. Cache once per inventory type.
    old_history = '''        # Model availability is a server-wide property, so probe it once for the
        # page rather than once per row.
        capabilities = decision_support_capabilities(
            records[0].property_id if records else "", self.session
        )
        return {
            "data": [
                self.payload(
                    r,
                    prop=properties.get(r.property_id),
                    capabilities=capabilities,
                )
                for r in records
            ],'''
    new_history = '''        # Cache a verdict per inventory. Published operational listings lack
        # the research-model feature vector even if a research row can run SHAP.
        capability_cache: dict[str, dict] = {}

        def capabilities_for(reference: str) -> dict:
            scope = "operational" if operational_property_id(reference) is not None else "research"
            if scope not in capability_cache:
                capability_cache[scope] = decision_support_capabilities(reference, self.session)
            return capability_cache[scope]

        return {
            "data": [
                self.payload(
                    r,
                    prop=properties.get(r.property_id),
                    capabilities=capabilities_for(r.property_id),
                )
                for r in records
            ],'''
    return swap(s, old_history, new_history, 'assessment mixed history capability')


def transform_assessments(s: str) -> str:
    s = swap(s, 'from sitewise.repositories.catalog_repository import CatalogRepository\n', '', 'assessments unused import')
    s = swap(s, 'evidence = CatalogRepository(analytics).get_evidence(assessment.property_id)',
             'evidence = service.catalog.get_evidence(assessment.property_id)', 'assessment report evidence source')
    return s


def transform_catalog(s: str) -> str:
    s = swap(s, 'from sitewise.db.analytics_session import get_analytics_db\n',
             'from sitewise.db.analytics_session import get_analytics_db\n'
             'from sitewise.db.session import get_db\n'
             'from sitewise.services.assessment_property_catalog import AssessmentPropertyCatalog\n',
             'catalogue imports')
    s = swap(s, 'AnalyticsSession = Annotated[Session, Depends(get_analytics_db)]\n',
             'AnalyticsSession = Annotated[Session, Depends(get_analytics_db)]\n'
             'AppSession = Annotated[Session, Depends(get_db)]\n', 'catalogue app session')
    # Only individual lookups become dual-source. Research browsing and facets
    # intentionally remain the 955-row imported research catalogue.
    s = replace_section(s, '@router.get("/properties/{property_id}")',
        '@router.get("/properties/{property_id}/evidence")', changes=[
            ('    session: AnalyticsSession,\n    _user: CurrentUser,',
             '    session: AnalyticsSession,\n    app_session: AppSession,\n    _user: CurrentUser,'),
            ('prop = CatalogRepository(session).get_property(property_id)',
             'prop = AssessmentPropertyCatalog(app_session, session).get_property(property_id)'),
        ], label='catalogue detail')
    start = '@router.get("/properties/{property_id}/evidence")'
    if start not in s:
        raise RuntimeError('catalogue evidence route not found')
    i = s.index(start)
    block = s[i:]
    block = swap(block, '    session: AnalyticsSession,\n    _user: CurrentUser,',
                 '    session: AnalyticsSession,\n    app_session: AppSession,\n    _user: CurrentUser,',
                 'catalogue evidence session')
    block = swap(block, 'repo = CatalogRepository(session)',
                 'repo = AssessmentPropertyCatalog(app_session, session)', 'catalogue evidence repo')
    return s[:i] + block


def transform_saved(s: str) -> str:
    s = swap(s, 'from sitewise.db.session import get_db\n',
             'from sitewise.db.session import get_db\n'
             'from sitewise.db.analytics_session import get_analytics_db\n', 'saved imports db')
    s = swap(s, 'from sitewise.repositories.catalog_repository import CatalogRepository\n',
             'from sitewise.services.assessment_property_catalog import AssessmentPropertyCatalog\n',
             'saved imports source')
    s = swap(s, 'AppSession = Annotated[Session, Depends(get_db)]\n',
             'AppSession = Annotated[Session, Depends(get_db)]\n'
             'AnalyticsSession = Annotated[Session, Depends(get_analytics_db)]\n', 'saved analytics session')
    s = swap(s,
        '''def _catalogue_exists(session: Session, property_ref: str) -> bool:\n    return CatalogRepository(session).get_property(property_ref) is not None''',
        '''def _catalogue_exists(app_session: Session, analytics_session: Session, property_ref: str) -> bool:\n    return AssessmentPropertyCatalog(app_session, analytics_session).get_property(property_ref) is not None''',
        'saved validation')
    s = swap(s, 'def list_own_saved(session: AppSession, current: ActiveIdentity) -> dict:',
             'def list_own_saved(session: AppSession, analytics: AnalyticsSession, current: ActiveIdentity) -> dict:',
             'saved list signature')
    s = swap(s, '_catalogue_exists(session, row.property_id)',
             '_catalogue_exists(session, analytics, row.property_id)', 'saved list lookup')
    s = swap(s,
        '''    response: Response,\n    session: AppSession,\n    current: ActiveIdentity,''',
        '''    response: Response,\n    session: AppSession,\n    analytics: AnalyticsSession,\n    current: ActiveIdentity,''',
        'saved write signature')
    s = swap(s, '_catalogue_exists(session, property_ref)',
             '_catalogue_exists(session, analytics, property_ref)', 'saved write lookup')
    return s


def transform_mapper(s: str) -> str:
    s = swap(s,
        "    final score = (row['suitability_score'] as num?)?.toDouble();",
        "    final score = (row['suitability_score'] as num?)?.toDouble();\n"
        "    final isOperational = row['property_source'] == 'fyp';",
        'Dart mapper source')
    s = swap(s,
        '      verification: VerificationStatus.pending,',
        "      verification: isOperational && row['verification_status'] == 'approved' &&\n"
        "              row['is_published'] == true\n"
        "          ? VerificationStatus.verified\n"
        "          : VerificationStatus.pending,",
        'Dart mapper verification')
    s = swap(s,
        "        'Imported dataset',\n        if (row['dataset_validation'] != null)",
        "        if (isOperational) 'Published SiteWise listing' else 'Imported dataset',\n"
        "        if (!isOperational && row['dataset_validation'] != null)",
        'Dart mapper tags')
    return s


def transform_web_detail(s: str) -> str:
    # The shared catalogue API now resolves published numeric refs for the
    # assessment workspace. The rich property-detail page must still read the
    # operational Explore endpoint first, to retain real photos + metadata.
    before = '''  Future<PropertyDetailLoad?> _load(String id) async {
    final catalog = await AppLocator.properties.detail(id);
    if (catalog != null) {
      return PropertyDetailLoad(
        property: catalog,
        imageUrls: catalog.imageUrls,
        source: 'catalog',
      );
    }
    if (int.tryParse(id) != null) {
      try {
        final detail = await AppLocator.exploreRepo.detail(id);
        return PropertyDetailLoad(
          property: detail.property,
          imageUrls: [for (final photo in detail.photos) photo.url],
          source: 'explore',
        );
      } on Object {
        return null; // Unknown or unpublished numeric id → not found.
      }
    }
    return null;
  }'''
    after = '''  Future<PropertyDetailLoad?> _load(String id) async {
    // Numeric references belong to approved/published operational properties.
    // Prefer the full Explore detail (including real photos) to the generic
    // catalogue-shaped projection used by the assessment workspace.
    if (int.tryParse(id) != null) {
      try {
        final detail = await AppLocator.exploreRepo.detail(id);
        return PropertyDetailLoad(
          property: detail.property,
          imageUrls: [for (final photo in detail.photos) photo.url],
          source: 'explore',
        );
      } on Object {
        return null; // Not approved/published, missing, or unavailable.
      }
    }
    final catalog = await AppLocator.properties.detail(id);
    if (catalog != null) {
      return PropertyDetailLoad(
        property: catalog,
        imageUrls: catalog.imageUrls,
        source: 'catalog',
      );
    }
    return null;
  }'''
    return swap(s, before, after, 'web property detail resolution')


EDITORS = {
    WEB_DETAIL: transform_web_detail,
    SERVICE: transform_service,
    ASSES: transform_assessments,
    CATALOG: transform_catalog,
    SAVED: transform_saved,
    MAPPER: transform_mapper,
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path('.'), help='FYP root, containing backend/')
    parser.add_argument('--check', action='store_true', help='validate without writing')
    args = parser.parse_args()
    root = args.root.resolve()
    module_src = Path(__file__).parent / MODULE
    if not module_src.exists():
        raise FileNotFoundError(f'new module not alongside patch script: {module_src}')
    edits: dict[Path, str] = {}
    for rel, editor in EDITORS.items():
        path = root / rel
        if not path.is_file():
            raise FileNotFoundError(f'expected repository file missing: {path}')
        old = path.read_text(encoding='utf-8')
        new = editor(old)
        # Validate the resulting backend source syntax before writing.
        if path.suffix == '.py':
            compile(new, str(path), 'exec')
        edits[path] = new
    dest = root / MODULE
    if dest.is_file() and dest.read_bytes() != module_src.read_bytes():
        raise RuntimeError(f'{dest} exists with different contents; merge manually')
    if args.check:
        print('PASS: target files and exact code anchors are compatible; nothing written.')
        return 0
    backup = root / '.sitewise_catalogue_fix_backups'
    backup.mkdir(exist_ok=True)
    for path, new in edits.items():
        old = path.read_text(encoding='utf-8')
        if old != new:
            bak = backup / (str(path.relative_to(root)).replace('/', '__').replace('\\', '__') + '.bak')
            if not bak.exists():
                shutil.copy2(path, bak)
            path.write_text(new, encoding='utf-8')
            print(f'PATCHED {path.relative_to(root)}')
        else:
            print(f'ALREADY PATCHED {path.relative_to(root)}')
    dest.parent.mkdir(parents=True, exist_ok=True)
    if not dest.exists():
        shutil.copy2(module_src, dest)
        print(f'CREATED {dest.relative_to(root)}')
    print('Completed. Original files preserved under .sitewise_catalogue_fix_backups/')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, FileNotFoundError) as exc:
        print(f'NOT APPLIED: {exc}', file=sys.stderr)
        sys.exit(1)
