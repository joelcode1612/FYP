// Recommendations page audit — the Explore → Recommendations consolidation.
//
// What this proves, in a real browser against the BUILT client bundle:
//   1. the entrepreneur pill nav has a single "Recommendations" destination and
//      no "Explore" entry left behind;
//   2. `/entrepreneur/recommendations` renders the server's ranked page —
//      cards with an image, rent, floor area, rank and requirement chips —
//      plus the selected-property intelligence panel;
//   3. "Load more" asks for the next page and appends it;
//   4. the retired `/entrepreneur/explore` deep link redirects here and keeps
//      its query string.
//
// The API responses are the real FastAPI payloads captured from PostgreSQL
// (tool/session_harness.js + capture_recommendation_fixture.py), so the page is
// audited against the contract the server actually returns. The harness holds
// no credentials, which is why the calls are replayed rather than proxied.
//
// Usage: BASE=http://127.0.0.1:8090 node tool/probe_recommendations.js
// (NODE_PATH must expose playwright-core.)

const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness');

const BASE = process.env.BASE || 'http://127.0.0.1:8090';

const checks = [];
const ok = (name, pass, detail = '') =>
  checks.push({ name, pass: !!pass, detail });

(async () => {
  const browser = await chromium.launch({
    // The shell proxy intercepts loopback; force direct connections.
    args: ['--no-proxy-server'],
  });
  const page = await browser.newPage({ viewport: { width: 1440, height: 950 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push('console: ' + m.text());
  });
  const failedRequests = [];
  page.on('response', (r) => {
    if (r.status() >= 400) failedRequests.push(`${r.status()} ${r.url()}`);
  });

  await installHarnessSession(page, { role: 'entrepreneur' });

  // --- 1. Deep link: /entrepreneur/explore → /entrepreneur/recommendations ---
  await page.goto(`${BASE}/entrepreneur/explore?q=Coffee&id=map`, {
    waitUntil: 'load',
  });
  await page.waitForFunction(() => !!document.querySelector('.rec2'), null, {
    timeout: 25000,
  });
  const redirected = new URL(page.url());
  ok(
    'Retired /entrepreneur/explore redirects to /entrepreneur/recommendations',
    redirected.pathname === '/entrepreneur/recommendations',
    page.url(),
  );
  ok(
    'Redirect preserves the query string',
    redirected.searchParams.get('q') === 'Coffee' &&
      redirected.searchParams.get('id') === 'map',
    redirected.search,
  );

  // --- 2. Navigation: one Recommendations entry, no Explore entry -----------
  const nav = await page.evaluate(() => {
    const links = Array.from(
      document.querySelectorAll('.app-pill__nav a, .sidebar__nav a'),
    ).map((a) => ({
      text: (a.textContent || '').trim(),
      href: a.getAttribute('href') || '',
    }));
    return links;
  });
  // The layout renders the same destinations twice: the desktop pill nav and
  // the mobile drawer (hidden by CSS above 900px). Both are legitimate, so the
  // assertion is about distinct destinations, not anchor count.
  const recLinks = Array.from(
    new Set(
      nav
        .filter((l) => l.href.includes('/entrepreneur/recommendations'))
        .map((l) => l.href),
    ),
  );
  ok(
    'Nav exposes exactly one Recommendations destination',
    recLinks.length === 1,
    JSON.stringify(recLinks),
  );
  ok(
    'Nav has no Explore destination',
    !nav.some((l) => l.text.toLowerCase() === 'explore'),
    JSON.stringify(nav.map((l) => l.text)),
  );

  // --- 3. The ranked page renders -------------------------------------------
  const list = await page.evaluate(() => {
    const cards = Array.from(document.querySelectorAll('.rec2-card'));
    const first = cards[0];
    const img = first ? first.querySelector('img') : null;
    return {
      cards: cards.length,
      ranks: cards.map(
        (c) => (c.querySelector('.rec2-card__rank') || {}).textContent || '',
      ),
      title: first
        ? (first.querySelector('.rec2-card__title') || {}).textContent
        : null,
      imageSrc: img ? img.getAttribute('src') : null,
      imageLoaded: img ? img.naturalWidth > 0 : false,
      rent: first
        ? (first.querySelector('.rec2-fact') || {}).textContent
        : null,
      body: first ? first.textContent.replace(/\s+/g, ' ').slice(0, 260) : '',
      chips: cards.map(
        (c) => c.querySelectorAll('.rec2-chip').length,
      ),
      hasLoadMore: !!Array.from(document.querySelectorAll('.rec2__more button')).length,
      provenance: (
        (document.querySelector('.rec2__provenance') || {}).textContent || ''
      ).trim(),
    };
  });

  ok('Ranked list renders cards', list.cards >= 10, `${list.cards} cards`);
  ok(
    'Cards carry a rank badge',
    list.ranks[0] === '#1' && list.ranks[1] === '#2',
    list.ranks.slice(0, 3).join(','),
  );
  ok('First card has a title', !!list.title, String(list.title));
  ok(
    'First card has a real image URL',
    typeof list.imageSrc === 'string' && list.imageSrc.startsWith('http'),
    String(list.imageSrc),
  );
  ok(
    'Card shows rent and floor area',
    /RM/.test(list.body) && /sq ft/.test(list.body),
    list.body.slice(0, 120),
  );
  ok(
    'Cards carry requirement chips',
    list.chips.some((n) => n > 0),
    JSON.stringify(list.chips.slice(0, 5)),
  );
  ok(
    'Provenance line states the model is unavailable (no fake score)',
    /not a model score|not integrated/i.test(list.provenance),
    list.provenance,
  );

  // --- 4. Intelligence panel -------------------------------------------------
  const panel = await page.evaluate(() => {
    const el = document.querySelector('.rec2-panel');
    if (!el) return null;
    return {
      title: (el.querySelector('.rec2-panel__title') || {}).textContent || '',
      text: el.textContent.replace(/\s+/g, ' '),
    };
  });
  ok('Selected-property panel renders', !!panel, panel ? panel.title : 'missing');
  ok(
    'Panel reports requirement-level verdicts',
    !!panel && /Met|Not met|Cannot be verified/i.test(panel.text),
    panel ? panel.text.slice(0, 160) : '',
  );
  ok(
    'Panel keeps the PU research score separate',
    !!panel && /PU|research/i.test(panel.text),
    panel ? panel.text.slice(0, 200) : '',
  );

  // --- 5. Filters are fed by the catalogue facets ---------------------------
  const filters = await page.evaluate(() => {
    const root = document.querySelector('.rec2__filters');
    if (!root) return null;
    return {
      inputs: root.querySelectorAll('input').length,
      chips: root.querySelectorAll('.checkpill').length,
      buttons: Array.from(root.querySelectorAll('button')).map((b) =>
        (b.textContent || '').trim(),
      ),
    };
  });
  ok('Filter block renders inputs', !!filters && filters.inputs >= 4, JSON.stringify(filters));
  ok(
    'Filter chips come from the facets endpoint',
    !!filters && filters.chips > 0,
    filters ? `${filters.chips} chips` : '',
  );

  // --- 6. Load more appends the next server page ----------------------------
  const before = list.cards;
  const loadMore = page.locator('.rec2__more button').first();
  const hasControl = (await loadMore.count()) > 0;
  ok('Load more control is offered when more pages exist', hasControl);
  if (hasControl) {
    const paged = page.waitForResponse(
      (r) =>
        r.url().includes('/api/v1/recommendations/search') && r.status() === 200,
      { timeout: 15000 },
    );
    await loadMore.click();
    await paged.catch(() => null);
    await page.waitForTimeout(600);
  }
  const after = await page.evaluate(
    () => document.querySelectorAll('.rec2-card').length,
  );
  ok(
    'Load more appends the next page',
    after > before,
    `${before} → ${after}`,
  );

  ok(
    'No uncaught page errors',
    errors.length === 0,
    errors.slice(0, 4).join(' | '),
  );
  ok(
    'No failed API requests',
    !failedRequests.some((r) => r.includes('/api/')),
    failedRequests.slice(0, 5).join(' | '),
  );

  await browser.close();

  const failed = checks.filter((c) => !c.pass);
  for (const c of checks) {
    console.log(`${c.pass ? 'PASS' : 'FAIL'}  ${c.name}${c.detail ? ` — ${c.detail}` : ''}`);
  }
  console.log(
    `\n${checks.length - failed.length}/${checks.length} checks passed`,
  );
  process.exit(failed.length === 0 ? 0 : 1);
})().catch((e) => {
  console.error('probe crashed:', e);
  process.exit(2);
});
