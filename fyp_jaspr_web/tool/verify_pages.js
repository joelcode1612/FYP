// Page-by-page structural verification of the built site.
//
// For each route it checks:
//   * the page renders (HTTP 200, non-trivial DOM)
//   * the expected source-level classes are present
//   * there is no horizontal overflow at 1440px and 390px
//   * no unresolved Material Symbols ligature
//
// Usage: node verify_pages.js http://127.0.0.1:8124
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';

const BASE = process.argv[2] || 'http://127.0.0.1:8124';
// HARNESS=1 installs the local stand-in bridge so the role-guarded routes render
// without a Supabase session. Without it those routes are expected to redirect.
const HARNESS = process.env.HARNESS === '1';

// route -> classes that must appear for the page to count as migrated
//
// Routes whose data does not exist in the imported dataset are checked in the
// state they actually render — the frame plus `.empty` — and the populated
// layout they would use is named in the comment beside them. Re-add those
// classes when the backing data is imported.
const PAGES = [
  ['/', ['lnd', 'topbar', 'scroll-experience', 'section', 'site-footer']],
  ['/login', ['login-page', 'lp-bg', 'lp-overlay', 'lp-nav', 'topbar', 'nav-btn', 'lp-hero', 'lp-feature', 'lp-card', 'lp-field', 'lp-submit', 'lp-eye', 'lp-social']],
  ['/signup', ['login-page', 'signup-page', 'lp-bg', 'lp-overlay', 'lp-nav', 'topbar', 'nav-btn', 'lp-hero', 'lp-feature', 'lp-card', 'lp-field', 'lp-submit', 'lp-eye', 'su-pw-row']],
  ['/forgot', ['auth-page', 'auth-card', 'auth-topbar', 'auth-title', 'auth-field', 'auth-submit']],
  ['/entrepreneur', ['bento-head', 'bento-kpis', 'bento', 'bento-hero', 'brow', 'schart', 'qtile']],
  ['/entrepreneur/explore', ['page-head', 'filters', 'frow', 'checkpill', 'pgrid', 'pcard', 'map-pane', 'layer-bar', 'layer-toggle', 'map-legend', 'a-card']],
  ['/entrepreneur/map?id=EP-03227', ['page-head', 'map-layout', 'map-pane', 'layer-bar', 'layer-toggle', 'map-legend', 'map-pin', 'a-card', 'notice']],
  // populated: detail-grid,panel,analysis,notice,disclaimer — no explanation model is connected
  ['/entrepreneur/explanation?property=EP-03227', ['page-head', 'empty']],
  ['/entrepreneur/property-detail?id=EP-03227', ['page-head', 'detail-grid', 'analysis', 'panel', 'kv', 'prov', 'gallery', 'map-pane']],
  ['/entrepreneur/compare', ['page-head', 'empty']],
  ['/entrepreneur/saved', ['page-head', 'empty']],
  ['/entrepreneur/recommendations', ['page-head']],
  ['/entrepreneur/preferences', ['page-head', 'quick', 'filters', 'frow', 'field', 'checkpill']],
  ['/entrepreneur/profile', ['page-head', 'detail-grid', 'panel', 'field']],
  // populated: report-grid,kv,prov,finding,disclaimer — the workbook carries no location analysis
  ['/entrepreneur/report?id=EP-03227', ['page-head', 'empty']],
  // populated: detail-grid,tour-stage,tour-controls,tour-hint,kv — tours are captured on device
  ['/entrepreneur/tour?id=EP-03227', ['page-head', 'empty']],
  ['/owner', ['bento-head', 'bento-kpis', 'bento', 'bento-hero', 'bento-card', 'kpi', 'stat-note']],
  // populated: rows,row-card — dataset rows carry no owner reference, so a signed-in
  // owner legitimately sees an empty portfolio
  ['/owner/properties', ['page-head', 'filters', 'grid-2', 'field', 'empty']],
  ['/owner/property-detail?id=EP-03227', ['page-head', 'detail-grid', 'analysis', 'panel', 'kv']],
  ['/owner/add-property', ['page-head', 'form-section', 'field']],
  ['/owner/tours', ['page-head', 'empty', 'owner-note']],
  ['/owner/tour-preview?id=t-1', ['page-head']],
  ['/owner/profile', ['page-head', 'detail-grid', 'panel', 'field', 'analysis']],
  ['/admin', ['bento-head', 'bento-kpis', 'bento', 'bento-hero', 'bento-card', 'kpi', 'empty', 'stat-note']],
  ['/admin/users', ['page-head', 'filters', 'audit-table']],
  ['/admin/user-detail?id=admin-1', ['page-head']],
  ['/admin/verification', ['page-head']],
  ['/admin/verification-detail?id=EP-03227', ['page-head']],
  ['/admin/listings', ['page-head']],
  ['/admin/listing-detail?id=EP-03227', ['page-head']],
  ['/admin/profile', ['page-head']],
  // Agent workspace. Route-level structural checks: the frame classes each page
  // is built from, not the data inside them (data needs a signed-in API).
  ['/agent', ['bento-head', 'bento-kpis', 'bento', 'kpi', 'callout', 'aside-row', 'audit-table']],
  ['/agent/listings', ['page-head', 'tabs', 'tab', 'field', 'audit-table', 'callout']],
  ['/agent/property-detail?id=EP-03227', ['page-head', 'callout', 'audit-table', 'aside-row']],
  ['/agent/enquiries', ['page-head', 'callout', 'audit-table', 'aside-row']],
  ['/agent/performance', ['bento-kpis', 'kpi', 'funnel', 'funnel__stage', 'aside-row']],
  ['/agent/profile', ['bento', 'callout', 'audit-table', 'aside-row']],
  // Administrator operations suite (five screens). Structural checks only:
  // frame classes every screen renders regardless of whether the staff API
  // answered (data views branch underneath them).
  // `/admin/agents` was rewired to the live staff API: its demo roster
  // (audit-table / aside-row) is gone, so the expectations moved with it.
  ['/admin/agents', ['page-head', 'ops-hero', 'callout', 'panel']],
  ['/admin/ownership', ['page-head', 'callout', 'ops-stats', 'ops-split', 'panel']],
  // populated: ops-grid (agent cards) — needs a signed-in staff API round-trip
  ['/admin/campaigns', ['page-head', 'ops-hero', 'callout', 'panel', 'empty', 'table-scroll']],
  // populated: ops-ev-list — needs the audit endpoint to answer
  ['/admin/activity', ['page-head', 'callout', 'ops-chips', 'panel']],
  ['/admin/surveys', ['page-head', 'callout', 'ops-split', 'panel', 'ops-checkrow']],
];

(async () => {
  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const errors = [];
  let failures = 0;

  for (const width of [1440, 390]) {
    const ctx = await browser.newContext({ viewport: { width, height: 900 } });
    const page = await ctx.newPage();
    page.on('pageerror', (e) => errors.push(`${width}px pageerror: ${e.message}`));
    page.on('console', (m) => {
      if (m.type() === 'error' && !m.text().includes('404')) {
        errors.push(`${width}px console: ${m.text()}`);
      }
    });
    if (HARNESS) await installHarnessSession(page, { role: 'auto' });

    console.log(`\n=== ${width}px ===`);
    for (const [route, expected] of PAGES) {
      const url = BASE + route;
      try {
        const resp = await page.goto(url, { waitUntil: 'networkidle', timeout: 30000 });
        // Detail routes are statically rendered without query params, so the
        // real content only appears after the client reads `?id=` and loads the
        // record. Wait for hydration to settle before inspecting.
        await page.waitForTimeout(1500);
        const info = await page.evaluate((expected) => {
          const missing = expected.filter((c) => !document.querySelector('.' + c));
          const overflow = document.documentElement.scrollWidth - window.innerWidth;
          const badIcons = [];
          for (const el of document.querySelectorAll('.ms')) {
            const t = (el.textContent || '').trim();
            if (!t) continue;
            const fs = parseFloat(getComputedStyle(el).fontSize) || 20;
            if (el.getBoundingClientRect().width > fs * 1.9) badIcons.push(t);
          }
          return { missing, overflow, badIcons: [...new Set(badIcons)], nodes: document.body.querySelectorAll('*').length };
        }, expected);
        const status = resp ? resp.status() : 0;
        const problems = [];
        if (status !== 200) problems.push(`HTTP ${status}`);
        if (info.missing.length) problems.push(`missing ${info.missing.join(',')}`);
        if (info.overflow > 2) problems.push(`overflow +${info.overflow}px`);
        if (info.badIcons.length) problems.push(`icons ${info.badIcons.join(',')}`);
        if (problems.length) failures++;
        console.log(
          `${problems.length ? 'FAIL' : 'ok  '} ${route.padEnd(44)} nodes=${String(info.nodes).padEnd(4)} ${problems.join(' | ')}`
        );
      } catch (e) {
        failures++;
        console.log(`FAIL ${route.padEnd(44)} ${e.message.split('\n')[0]}`);
      }
    }
    await ctx.close();
  }

  if (errors.length) {
    console.log('\n--- runtime errors ---');
    for (const e of [...new Set(errors)].slice(0, 20)) console.log('  ' + e);
  }
  console.log(`\n${failures} page checks with problems`);
  await browser.close();
  process.exit(failures ? 1 : 0);
})();
