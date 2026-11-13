#!/usr/bin/env python3
"""SiteWise property detail: focused, idempotent local Jaspr layout update.

Run from the FYP repository root:
    py sitewise_property_detail_layout_fix.py

Changes only:
  fyp_jaspr_web/lib/pages/entrepreneur/property_detail_page.dart
  fyp_jaspr_web/web/property_detail_upgrade.css

Does not alter verification state, data, routing, auth, or backend queries.
"""
from pathlib import Path
import re
import sys

MARKER = "/* SiteWise property-detail header and summary refinement (2026-11) */"
TITLE_START = "  Component _titleRow() => div(classes: 'sw-pd__top', ["
SUMMARY_START = "  Component _summaryCard() {"
TITLE_PATTERN = re.compile(r"  Component _titleRow\(\) => div\(classes: 'sw-pd__top', \[.*?(?=  // ----------------------------------------------------------------- summary)", re.S)
SUMMARY_PATTERN = re.compile(r"  Component _summaryCard\(\) \{.*?(?=  // ----------------------------------------------------------------- details)", re.S)

TITLE = '''  Component _titleRow() => div(classes: 'sw-pd__top', [
        div(classes: 'sw-pd__top-nav', [
          ActionLink(
            'Back to recommendations',
            href: '/entrepreneur/recommendations',
            variant: 'ghost',
            icon: 'arrow_back',
          ),
          if (property.availability != null)
            StatusBadge(property.availability!, tone: 'neutral'),
        ]),
        div(classes: 'sw-pd__top-main', [
          span(classes: 'sw-pd__eyebrow', [
            Component.text('Commercial property'),
          ]),
          h1(classes: 'sw-pd__title', [Component.text(property.title)]),
          if (_addressLine.isNotEmpty)
            p(classes: 'sw-pd__addr', [Component.text(_addressLine)]),
        ]),
      ]);

'''

SUMMARY = '''  Component _summaryCard() {
    final facilities = _facilities;
    final management = property.managerName == null ||
            property.managerName!.trim().isEmpty
        ? property.managementLabel
        : '${property.managementLabel} — ${property.managerName}';
    final description = property.description?.trim() ?? '';

    return div(classes: 'sw-pd__summary', [
      div(classes: 'sw-pd__summary-intro', [
        span(classes: 'sw-pd__eyebrow', [Component.text('Monthly rent')]),
        div(classes: 'sw-pd__price', [
          strong([Component.text(property.rentalDisplay)]),
          span([Component.text('/ month')]),
        ]),
      ]),
      div(classes: 'sw-pd__facts', [
        _fact('Floor area', '${property.sizeSqft.toStringAsFixed(0)} sq ft'),
        _fact('Property type', property.propertyType),
        _fact(
          'Rent per sq ft',
          'RM${property.rentalPerSqft.toStringAsFixed(2)} / sq ft',
        ),
        if (property.floorLevel != null && property.floorLevel!.trim().isNotEmpty)
          _fact('Floor level', property.floorLevel),
      ]),
      div(classes: 'sw-pd__management', [
        span(classes: 'sw-pd__management-label', [
          Component.text('Property management'),
        ]),
        strong(classes: 'sw-pd__management-value', [Component.text(management)]),
      ]),
      if (facilities.isNotEmpty) ...[
        h3(classes: 'sw-pd__section-label', [Component.text('Property features')]),
        div(classes: 'sw-pd__chips', [
          for (final facility in facilities.take(10))
            span(classes: 'sw-pd__chip', [Component.text(facility)]),
        ]),
      ],
      // Do not synthesize a repetitive description from the title.
      if (description.isNotEmpty)
        p(classes: 'sw-pd__desc', [Component.text(description)]),
      div(classes: 'sw-pd__actions', [
        div(classes: 'sw-pd__primary-action', [
          ActionLink(
            'Check this property',
            href: '/entrepreneur/assessment?id=${property.id}',
            variant: 'primary',
            icon: 'fact_check',
          ),
        ]),
        div(classes: 'sw-pd__secondary-actions', [
          ActionButton(
            saved ? 'Saved' : 'Save property',
            variant: 'secondary',
            icon: saved ? 'bookmark' : 'bookmark_border',
            onClick: onToggleSaved,
          ),
          ActionButton(
            compared ? 'In compare' : 'Add to compare',
            variant: 'secondary',
            icon: 'compare_arrows',
            onClick: onToggleCompared,
          ),
          ActionButton(
            'Copy summary',
            variant: 'ghost',
            icon: 'content_copy',
            onClick: _copySummary,
          ),
        ]),
      ]),
      if (saveMessage != null)
        span(classes: 'small text-success', [Component.text(saveMessage!)]),
      if (_copyMessage != null)
        span(classes: 'small', [Component.text(_copyMessage!)]),
      if (compareLinkShown && compared)
        ActionLink('Open compare', href: '/entrepreneur/compare', variant: 'ghost'),
    ]);
  }

'''

CSS = r'''

/* SiteWise property-detail header and summary refinement (2026-11) */
/* Scoped to the existing detail page; no global theme or other route changes. */
.sw-pd {
  max-width: 1300px;
  gap: 24px;
}
.sw-pd__top {
  display: flex;
  flex-direction: column;
  align-items: stretch;
  gap: 12px;
  padding: 4px 0 2px;
}
.sw-pd__top-nav {
  display: flex;
  justify-content: space-between;
  align-items: center;
  flex-wrap: wrap;
  gap: 12px;
}
.sw-pd__top-nav .btn,
.sw-pd__top-nav a {
  min-height: 36px;
}
.sw-pd__top-main { flex: none; width: 100%; min-width: 0; }
.sw-pd__top .sw-pd__eyebrow {
  font-size: 11px;
  letter-spacing: .09em;
  color: #2459bd;
  font-weight: 800;
  margin-bottom: 6px;
}
.sw-pd__title {
  max-width: 1000px;
  margin: 0 0 8px;
  font-size: clamp(25px, 2.3vw, 34px);
  line-height: 1.22;
  letter-spacing: -.03em;
  overflow-wrap: anywhere;
}
.sw-pd__addr {
  font-size: 14px;
  line-height: 1.5;
  color: #475569;
  max-width: 90ch;
}
.sw-pd__hero {
  grid-template-columns: minmax(0, 1.55fr) minmax(340px, .95fr);
  gap: 22px;
  align-items: start;
}
.sw-pd__hero > .sw-gallery {
  min-width: 0;
  border-radius: 18px;
}
.sw-pd__summary {
  min-width: 0;
  border-radius: 18px;
  padding: 24px;
  gap: 18px;
  border-color: #e0e7f1;
  box-shadow: 0 4px 22px rgba(20, 39, 72, .045);
}
.sw-pd__summary-intro {
  display: grid;
  gap: 3px;
}
.sw-pd__summary-intro .sw-pd__eyebrow {
  font-size: 10.5px;
  color: #52647d;
  font-weight: 800;
  text-transform: uppercase;
  letter-spacing: .085em;
}
.sw-pd__price { gap: 8px; flex-wrap: wrap; }
.sw-pd__price strong { font-size: clamp(28px, 2.2vw, 34px); letter-spacing: -.045em; }
.sw-pd__price span { font-size: 13px; color: #52647d; }
.sw-pd__facts {
  gap: 16px 18px;
  padding-top: 18px;
  border-top: 1px solid #e8edf5;
}
.sw-pd__fact { gap: 4px; }
.sw-pd__fact-label { font-size: 11px; line-height: 1.35; color: #53667f; }
.sw-pd__fact-value { font-size: 14px; font-weight: 750; line-height: 1.5; overflow-wrap: anywhere; }
.sw-pd__management {
  padding: 16px;
  border: 1px solid #dfe8f8;
  border-radius: 12px;
  background: #f6f9ff;
  display: grid;
  gap: 6px;
}
.sw-pd__management-label {
  font-size: 11px;
  font-weight: 800;
  color: #52647d;
  letter-spacing: .06em;
  text-transform: uppercase;
}
.sw-pd__management-value {
  font-size: 13px;
  line-height: 1.5;
  font-weight: 750;
  color: #18365d;
  overflow-wrap: anywhere;
}
.sw-pd__section-label { font-size: 11px; }
.sw-pd__desc {
  padding-top: 14px;
  border-top: 1px solid #edf1f7;
  font-size: 13px;
  line-height: 1.65;
}
.sw-pd__actions {
  display: grid;
  gap: 10px;
  padding-top: 16px;
  border-top: 1px solid #e8edf5;
}
.sw-pd__primary-action,
.sw-pd__secondary-actions { min-width: 0; }
.sw-pd__primary-action > * {
  width: 100%;
  min-height: 46px;
  display: flex;
  align-items: center;
  justify-content: center;
}
.sw-pd__secondary-actions {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 9px;
}
.sw-pd__secondary-actions > * {
  min-width: 0;
  min-height: 42px;
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
}
.sw-pd__secondary-actions > :last-child {
  grid-column: 1 / -1;
}
.sw-pd__summary a:focus-visible,
.sw-pd__summary button:focus-visible,
.sw-pd__top a:focus-visible {
  outline: 3px solid #1d4ed8;
  outline-offset: 3px;
}
@media (max-width: 1060px) {
  .sw-pd__hero { grid-template-columns: minmax(0, 1fr); }
  .sw-pd__summary { order: 0; }
}
@media (max-width: 640px) {
  .sw-pd { gap: 18px; }
  .sw-pd__title { font-size: clamp(23px, 6vw, 29px); }
  .sw-pd__summary { padding: 19px 17px; gap: 16px; }
  .sw-pd__facts { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px; }
  .sw-pd__secondary-actions { grid-template-columns: minmax(0, 1fr); }
  .sw-pd__secondary-actions > :last-child { grid-column: auto; }
  .sw-pd__hero > .sw-gallery { border-radius: 14px; }
}
'''


def find_root() -> Path:
    here = Path.cwd()
    for candidate in (here, Path(__file__).resolve().parent):
        for base in [candidate, *candidate.parents]:
            if (base / 'fyp_jaspr_web/lib/pages/entrepreneur/property_detail_page.dart').is_file():
                return base
    raise SystemExit('Run this script from your FYP project root (it could not find fyp_jaspr_web).')


def replace_unique(text: str, pattern: re.Pattern, replacement: str, label: str) -> str:
    updated, n = pattern.subn(lambda m: replacement, text)
    if n != 1:
        raise RuntimeError(f'{label}: expected one matching section, found {n}; no changes saved.')
    return updated


def main() -> None:
    root = find_root()
    page = root / 'fyp_jaspr_web/lib/pages/entrepreneur/property_detail_page.dart'
    css = root / 'fyp_jaspr_web/web/property_detail_upgrade.css'
    original = page.read_text(encoding='utf-8')
    original_css = css.read_text(encoding='utf-8')
    if MARKER in original_css:
        print('Already applied. No changes made.')
        return
    if 'Component _titleRow()' not in original or SUMMARY_START not in original:
        raise RuntimeError('Property detail page structure differs from inspected joel branch. No changes made.')
    updated = replace_unique(original, TITLE_PATTERN, TITLE, 'title header')
    updated = replace_unique(updated, SUMMARY_PATTERN, SUMMARY, 'summary card')
    # Verify target badge no longer appears and state is otherwise unchanged.
    if 'Verification pending' in updated[updated.index('Component _titleRow()'):updated.index('// ----------------------------------------------------------------- summary')]:
        raise RuntimeError('Verification badge was not removed; no changes saved.')
    if "href: '/entrepreneur/assessment?id=${property.id}'" not in updated:
        raise RuntimeError('Assessment deep link unexpectedly changed; no changes saved.')
    if 'CombinedMediaGallery(' not in updated or '_mapPanel()' not in updated:
        raise RuntimeError('Gallery or map was lost; no changes saved.')
    page.write_text(updated, encoding='utf-8')
    css.write_text(original_css.rstrip() + '\n' + CSS.strip() + '\n', encoding='utf-8')
    print('Updated:', page.relative_to(root))
    print('Updated:', css.relative_to(root))
    print('Verification pending badge removed from this page; backend verification unchanged.')
    print('Rebuild/restart Jaspr to view the new layout.')

if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError) as e:
        print('ERROR:', e, file=sys.stderr)
        raise SystemExit(1)
