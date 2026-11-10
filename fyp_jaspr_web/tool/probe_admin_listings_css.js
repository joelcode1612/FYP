/// Admin Listings CSS legibility probe (fixture-based, no auth, no build).
///
/// Builds a representative admin-shell DOM (toolbar, status tabs, review
/// queue with one active row, status pills, pager), inlines the CURRENT
/// `web/styles.css`, serves it from an isolated throwaway HTTP server on
/// :8091 (root: build/_css_probe — additive, never touches build/jaspr),
/// and reports computed styles + WCAG contrast ratios via headless Chromium.
///
/// Run:  NODE_PATH=C:/Users/Lenovo/.workbuddy-ai/binaries/node/workspace/node_modules \
///       node tool/probe_admin_listings_css.js
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const ROOT = path.resolve(__dirname, '..');
const CSS = fs.readFileSync(path.join(ROOT, 'web', 'styles.css'), 'utf8');
const PROBE_DIR = path.join(ROOT, 'build', '_css_probe');
const PORT = 8091;
const EXE =
  'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');

const pill = (cls, label) =>
  `        <span class="st ${cls}">${label}</span>`;

const queueItem = (active, title, company, city, rent, pills) => `
      <button type="button" class="queue-item${active ? ' is-active' : ''}">
        <div class="shot"><span class="ms" style="font-size:20px">apartment</span></div>
        <div>
          <h4>${esc(title)}</h4>
          <p>${company ? esc(company) : ''}${city ? '<span class="queue-item__sep">&middot;</span>' + esc(city) : ''}${rent ? '<span class="queue-item__sep">&middot;</span><span class="queue-item__rent">RM' + rent + '</span>' : ''}</p>
        </div>
        <div class="queue-item__meta stack">
${pills.map(([c, l]) => pill(c, l)).join('\n')}
        </div>
      </button>`;

const fixture = `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>admin listings css probe</title>
<style>${CSS}</style>
</head>
<body>
<div class="app-shell app-shell--admin">
  <div class="app-main">
    <div class="app-content">
      <div class="app-content__inner">
        <div class="stack stack--sections">
          <div class="stack">
            <div class="toolbar row">
              <div class="grow"><input type="search" placeholder="Search title, address or company…" aria-label="Search the review queue"></div>
              <select aria-label="Sort by"><option>Submission date</option><option>Rent</option></select>
              <button type="button" class="btn btn--secondary"><span class="ms">arrow_downward</span>Descending</button>
              <button type="button" class="btn btn--primary"><span class="ms">search</span>Search</button>
            </div>
            <div class="tabs row" role="tablist">
              <button type="button" class="tab is-active" role="tab" aria-selected="true">Listing</button>
              <button type="button" class="tab" role="tab" aria-selected="false">Ownership</button>
              <span class="grow"></span>
              <button type="button" class="tab is-active" role="tab" aria-selected="true">All (128)</button>
              <button type="button" class="tab" role="tab" aria-selected="false">Awaiting review (41)</button>
              <button type="button" class="tab" role="tab" aria-selected="false">Verified (63)</button>
              <button type="button" class="tab" role="tab" aria-selected="false">Rejected (9)</button>
            </div>
            <div class="split">
              <div class="panel">
                <h2>128 listings &middot; showing 1&ndash;20</h2>
                <div class="queue">
${queueItem(true, 'Corner shoplot, Taman Desa', 'Kopi Tiap Sdn Bhd', 'Kuala Lumpur', '3200', [['st-det', 'Verified'], ['st-det', 'Verified']])}
${queueItem(false, 'Ground floor retail, Jalan Ampang', 'Makan Group', 'Kuala Lumpur', '5400', [['st-warn', 'Awaiting review'], ['st-muted', 'Not submitted']])}
${queueItem(false, 'Food court unit 12, Seberang Jaya', 'Warung Kita Co', 'Butterworth', '1850', [['st-danger', 'Rejected'], ['st-warn', 'Information requested']])}
                </div>
                <div class="row">
                  <button type="button" class="btn btn--secondary">Previous</button>
                  <button type="button" class="btn btn--secondary">Next</button>
                </div>
              </div>
              <div><div class="panel"><h2>Detail</h2><p class="body muted">Verification detail placeholder.</p></div></div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</div>
</body></html>`;

const lum = (rgb) => {
  const [r, g, b] = rgb.map((v) => {
    const c = v / 255;
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};
const contrast = (fg, bg) => {
  const [a, b] = [lum(fg), lum(bg)].sort((x, y) => y - x);
  return (a + 0.05) / (b + 0.05);
};
const parse = (cs) =>
  cs
    .match(/rgba?\(([^)]+)\)/)
    ?.[1]
    .split(',')
    .slice(0, 3)
    .map(Number) ?? null;

(async () => {
  fs.mkdirSync(PROBE_DIR, { recursive: true });
  const file = path.join(PROBE_DIR, 'fixture.html');
  fs.writeFileSync(file, fixture);
  const server = http.createServer((req, res) => {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(fs.readFileSync(file));
  });
  await new Promise((r) => server.listen(PORT, '127.0.0.1', r));
  try {
    const browser = await chromium.launch({
      executablePath: EXE,
      args: ['--no-proxy-server'],
    });
    const page = await browser.newPage({ viewport: { width: 1440, height: 960 } });
    await page.goto(`http://127.0.0.1:${PORT}/fixture.html`);
    await page.waitForTimeout(250);

    const out = await page.evaluate(() => {
      const cs = (sel, props) => {
        const el = document.querySelector(sel);
        if (!el) return null;
        const s = getComputedStyle(el);
        return Object.fromEntries(props.map((p) => [p, s[p]]));
      };
      return {
        toolbar: cs('.toolbar', ['columnGap', 'marginBottom']),
        pagerRow: cs('.panel > .row', ['columnGap']),
        queueItem: cs('.queue-item', [
          'backgroundColor',
          'borderTopColor',
          'paddingTop',
          'paddingLeft',
          'columnGap',
        ]),
        queueHoverItem: cs('.queue-item:not(.is-active)', ['backgroundColor']),
        activeItem: cs('.queue-item.is-active', [
          'backgroundColor',
          'borderTopColor',
          'boxShadow',
        ]),
        title: cs('.queue-item h4', ['fontSize', 'color']),
        meta: cs('.queue-item p', ['fontSize', 'color']),
        rent: cs('.queue-item__rent', ['color', 'fontWeight']),
        pillWarn: cs('.st-warn', ['color', 'backgroundColor', 'fontSize']),
        pillDet: cs('.st-det', ['color', 'backgroundColor']),
        pillDanger: cs('.st-danger', ['color', 'backgroundColor']),
        pillMuted: cs('.st-muted', ['color', 'backgroundColor']),
        tab: cs('.tab:not(.is-active)', [
          'color',
          'backgroundColor',
          'borderTopColor',
        ]),
        tabActive: cs('.tab.is-active', ['color', 'backgroundColor']),
        panelH2: cs('.panel > h2', ['fontSize', 'color']),
      };
    });

    // Contrast ratios against the surfaces they actually sit on.
    const itemBg = parse(out.queueItem.backgroundColor);
    const activeBg = parse(out.activeItem.backgroundColor);
    const panelBg = parse(
      await page.evaluate(() => getComputedStyle(document.querySelector('.panel')).backgroundColor),
    );
    const ratios = {
      title_on_item: contrast(parse(out.title.color), itemBg),
      meta_on_item: contrast(parse(out.meta.color), itemBg),
      rent_on_item: contrast(parse(out.rent.color), itemBg),
      title_on_active: contrast(parse(out.title.color), activeBg),
      meta_on_active: contrast(parse(out.meta.color), activeBg),
      itemBg_vs_panel: contrast(itemBg, panelBg),
      activeBg_vs_panel: contrast(activeBg, panelBg),
      pillWarn: contrast(parse(out.pillWarn.color), parse(out.pillWarn.backgroundColor)),
      pillDet: contrast(parse(out.pillDet.color), parse(out.pillDet.backgroundColor)),
      pillDanger: contrast(parse(out.pillDanger.color), parse(out.pillDanger.backgroundColor)),
      pillMuted: contrast(parse(out.pillMuted.color), parse(out.pillMuted.backgroundColor)),
      tabIdle: contrast(parse(out.tab.color), parse(out.tab.backgroundColor)),
      tabActive: contrast(parse(out.tabActive.color), parse(out.tabActive.backgroundColor)),
    };

    console.log(JSON.stringify({ styles: out, ratios }, null, 2));
    await browser.close();
  } finally {
    await new Promise((r) => server.close(r));
    fs.rmSync(PROBE_DIR, { recursive: true, force: true });
  }
})().catch((e) => {
  console.error('PROBE FAILED:', e.message);
  process.exit(1);
});
