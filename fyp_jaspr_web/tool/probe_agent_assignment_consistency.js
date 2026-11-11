// Verify that every Agent surface reads ONE authorized assignment dataset.
//
//   GET /api/v1/staff/me/listings  ->  { agent, listings: [...] }
//
// Checks, for N = 0, 3 and 6 real assignments:
//   - Dashboard 'Assigned listings' KPI == N, portfolio rows == N
//   - Assigned Listings header 'N of N assigned listings', rows == N
//   - BOTH pages link to the SAME operational listing ids
//     (/agent/property-detail?id=<listingId>)
//   - Search narrows the visible rows but never the global total
//   - N=0 renders the honest empty state on both pages
//   - An API failure renders an error state, never fabricated zeros
//   - Performance metrics derive from the same assignments (no suitability)
//
// Staff endpoints are answered from inline fixtures (probe-only). Run:
//   NODE_PATH=C:/Users/Lenovo/.workbuddy-ai/binaries/node/workspace/node_modules \
//   node tool/probe_agent_assignment_consistency.js
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness.js');

const BASE = process.env.BASE || 'http://127.0.0.1:8141';
const T0 = '2026-11-11T08:00:00Z';

function assignmentRow(listingId, name, city, status, rent, size, published) {
  return {
    listing_id: listingId,
    agent_id: 7,
    assigned_by_user_id: 'harness-admin',
    created_at: T0,
    updated_at: T0,
    name,
    address: `${listingId} Test Street`,
    city,
    state: 'Selangor',
    property_type: 'Shop lot',
    rental_price: rent,
    size_sqft: size,
    floor_level: null,
    availability: 'Immediate',
    is_published: published,
    verification_status: status,
    owner_user_id: 'harness-owner',
    property_exists: true,
  };
}

const THREE = [
  assignmentRow(201, 'Corner shoplot, SS15', 'Subang Jaya', 'approved', 4500, 1680, true),
  assignmentRow(202, 'Uptown retail unit', 'Petaling Jaya', 'pending', 5200, 1200, false),
  assignmentRow(203, 'Bistro space, Section 13', 'Shah Alam', 'pending', 6100, 2000, false),
];

const SIX = [
  ...THREE,
  assignmentRow(204, 'Kiosk, Damansara', 'Petaling Jaya', 'approved', 3800, 900, true),
  assignmentRow(205, 'Office lot, Kelana Jaya', 'Petaling Jaya', 'draft', 4200, 1100, false),
  assignmentRow(206, 'Warehouse frontage, Klang', 'Klang', 'rejected', 9000, 2500, false),
];

async function withFixtures(browser, rows, fn) {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const page = await context.newPage();
  const pageErrors = [];
  page.on('pageerror', (e) => pageErrors.push(e.message));
  await installHarnessSession(page, { role: 'agent' });
  await page.route('**/api/v1/staff/me/listings', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({
        agent: { agent_id: 7, user_id: 'harness-agent', full_name: 'Harness Agent' },
        listings: rows,
      }),
    }),
  );
  try {
    return await fn(page, pageErrors);
  } finally {
    await context.close();
  }
}

async function snapshot(page, path) {
  await page.goto(BASE + path, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1200);
  return page.evaluate(() => {
    const txt = (el) => (el?.textContent || '').trim().replace(/\s+/g, ' ');
    const kpis = {};
    for (const kpi of document.querySelectorAll('.bento-kpis .kpi')) {
      kpis[txt(kpi.querySelector('.k'))] = txt(kpi.querySelector('.v'));
    }
    const links = Array.from(
      document.querySelectorAll('a[href^="/agent/property-detail?id="]'),
    ).map((a) => a.getAttribute('href'));
    const rows = document.querySelectorAll('table tbody tr').length;
    return {
      bodyText: document.body.innerText,
      kpis,
      links,
      rows,
      overflow: document.scrollingElement.scrollWidth <= window.innerWidth + 1,
    };
  });
}

async function main() {
  const browser = await chromium.launch({ args: ['--no-proxy-server'] });
  const checks = [];
  const ok = (name, pass, extra = '') => {
    checks.push({ name, pass: !!pass });
    if (!pass) console.log(`  FAIL ${name} ${extra}`);
  };

  const cases = [
    { label: '0', rows: [] },
    { label: '3', rows: THREE },
    { label: '6', rows: SIX },
  ];

  for (const { label, rows } of cases) {
    await withFixtures(browser, rows, async (page, errors) => {
      const dash = await snapshot(page, '/agent');
      const list = await snapshot(page, '/agent/listings');
      const n = rows.length;

      ok(`[${label}] dashboard KPI total = ${n}`, dash.kpis['Assigned listings'] === `${n}`, dash.kpis['Assigned listings']);
      ok(`[${label}] listings header = "${n} of ${n}"`, list.bodyText.includes(`${n} of ${n} assigned listings`));
      ok(`[${label}] dashboard rows = ${n}`, dash.rows === n, `${dash.rows}`);
      ok(`[${label}] listings rows = ${n}`, list.rows === n, `${list.rows}`);

      const dashIds = new Set(dash.links);
      const listIds = new Set(list.links);
      ok(
        `[${label}] same property ids on both pages`,
        dashIds.size === n && listIds.size === n &&
          [...dashIds].every((href) => listIds.has(href)),
        `${[...dashIds].join(',')} vs ${[...listIds].join(',')}`,
      );
      ok(
        `[${label}] links use operational listing ids`,
        rows.every((r) => listIds.has(`/agent/property-detail?id=${r.listing_id}`)),
      );

      if (n === 0) {
        ok('[0] dashboard honest empty state', /No properties assigned yet/.test(dash.bodyText));
        ok('[0] listings honest empty state', /No listings are assigned to your account yet|No properties are assigned/.test(list.bodyText));
        ok('[0] KPI strip shows truthful zeros', dash.kpis['Active'] === '0' && dash.kpis['Pending review'] === '0', JSON.stringify(dash.kpis));
      }
      if (n === 3) {
        ok('[3] Active KPI = 1', dash.kpis['Active'] === '1', dash.kpis['Active']);
        ok('[3] Pending KPI = 2', dash.kpis['Pending review'] === '2', dash.kpis['Pending review']);
        ok('[3] Draft/suspended KPI = 0', dash.kpis['Draft or suspended'] === '0', dash.kpis['Draft or suspended']);
      }
      if (n === 6) {
        ok('[6] Active KPI = 2', dash.kpis['Active'] === '2', dash.kpis['Active']);
        ok('[6] Pending KPI = 2', dash.kpis['Pending review'] === '2', dash.kpis['Pending review']);
        ok('[6] Draft/suspended KPI = 2', dash.kpis['Draft or suspended'] === '2', dash.kpis['Draft or suspended']);
      }
      ok(`[${label}] no page errors (dashboard+listings)`, errors.length === 0, errors.join('; '));
    });
  }

  // Search narrows rows but never the global assigned count.
  await withFixtures(browser, THREE, async (page) => {
    await page.goto(BASE + '/agent/listings', { waitUntil: 'networkidle' });
    await page.waitForTimeout(1000);
    const input = page.locator('input[type="search"], input[placeholder*="Search"]').first();
    await input.fill('Uptown');
    await page.waitForTimeout(500);
    const after = await page.evaluate(() => ({
      text: document.body.innerText,
      rows: document.querySelectorAll('table tbody tr').length,
    }));
    ok('[search] visible rows narrowed to 1', after.rows === 1, `${after.rows}`);
    ok('[search] global total stays 3', after.text.includes('1 of 3 assigned listings'), '');
  });

  // Performance uses the same assignments; no suitability metric.
  await withFixtures(browser, THREE, async (page) => {
    const perf = await snapshot(page, '/agent/performance');
    ok('[perf] Listings held = 3', perf.kpis['Listings held'] === '3', perf.kpis['Listings held']);
    ok('[perf] Median rent = RM 5200', perf.kpis['Median rent'] === 'RM 5200', perf.kpis['Median rent']);
    ok('[perf] Average size = 1627 sqft', perf.kpis['Average size'] === '1627 sqft', perf.kpis['Average size']);
    ok('[perf] Live listings = 1', perf.kpis['Live listings'] === '1', perf.kpis['Live listings']);
    ok('[perf] no suitability metric', !/Mean suitability/.test(perf.bodyText));
  });

  // API failure must render an error state, never fabricated zeros. The
  // harness bridge does not expose HTTP status, so "unavailable" is simulated
  // at the network layer (the fetch itself fails).
  {
    const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
    const page = await context.newPage();
    await installHarnessSession(page, { role: 'agent' });
    await page.route('**/api/v1/staff/me/listings', (route) =>
      route.abort('failed'),
    );
    await page.goto(BASE + '/agent', { waitUntil: 'networkidle' });
    await page.waitForTimeout(1500);
    const dashText = await page.evaluate(() => document.body.innerText);
    ok('[error] dashboard shows failure', /Unable to load assigned properties/.test(dashText));
    ok('[error] dashboard shows no zero KPIs', !/Assigned listings\s*0/.test(dashText));
    await page.goto(BASE + '/agent/listings', { waitUntil: 'networkidle' });
    await page.waitForTimeout(1500);
    const listText = await page.evaluate(() => document.body.innerText);
    ok('[error] listings shows failure', /Could not load assignments/.test(listText));
    ok('[error] listings shows no "0 of 0"', !/0 of 0 assigned listings/.test(listText));
    await context.close();
  }

  // Narrow-viewport overflow on both pages (3 assignments).
  for (const width of [390]) {
    const context = await browser.newContext({ viewport: { width, height: 900 } });
    const page = await context.newPage();
    await installHarnessSession(page, { role: 'agent' });
    await page.route('**/api/v1/staff/me/listings', (route) =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ agent: { agent_id: 7 }, listings: THREE }),
      }),
    );
    for (const path of ['/agent', '/agent/listings']) {
      await page.goto(BASE + path, { waitUntil: 'networkidle' });
      await page.waitForTimeout(1000);
      const overflow = await page.evaluate(
        () => document.scrollingElement.scrollWidth <= window.innerWidth + 1,
      );
      ok(`[${width}] no overflow ${path}`, overflow);
    }
    await context.close();
  }

  await browser.close();
  const passed = checks.filter((c) => c.pass).length;
  console.log(`\nprobe_agent_assignment_consistency: ${passed}/${checks.length} checks passed`);
  const failed = checks.filter((c) => !c.pass);
  if (failed.length) {
    console.log('FAILED:', failed.map((f) => f.name).join(' | '));
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
