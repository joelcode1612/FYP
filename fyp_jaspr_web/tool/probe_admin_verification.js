// Verify the Admin two-tab verification detail converted from
// `sitewise_admin_two_tab_review.html`:
//   - Property hero + EXACTLY two content tabs (Property Overview /
//     Location Intelligence), keyboard-navigable per the prototype's ARIA
//     tabs pattern
//   - Overview renders the fixture's REAL detail payload (photos, info
//     rows, honest "Not provided" for missing fields)
//   - Location Intelligence renders the geospatial feature row when present
//     and the honest "Not calculated for this property" state when not
//   - Review decisions live OUTSIDE the tabs in the decision sidebar;
//     ownership stays "Not submitted" through a listing-only approval and
//     publication stays blocked
//   - The approve action is gated on the reviewer checklist
//   - Reject / request-information require a note (>= 8 chars)
//   - The selected tab stays stable across state refreshes
//   - Dark Admin Blue theme + no horizontal overflow at 1440 / 800 / 390
//
// Staff endpoints are answered from inline fixtures (probe-only — the
// production page keeps calling the live FastAPI service). Run:
//   NODE_PATH=C:/Users/Lenovo/.workbuddy-ai/binaries/node/workspace/node_modules \
//   node tool/probe_admin_verification.js
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness.js');

const BASE = process.env.BASE || 'http://127.0.0.1:8141';

const T0 = '2026-11-10T09:00:00Z';

// Photo as an inline SVG data URI: rendering is verified without touching
// any network resource.
const PHOTO_URI =
  'data:image/svg+xml;base64,' +
  Buffer.from(
    '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="200">' +
      '<rect width="320" height="200" fill="#1d4ed8"/><text x="160" y="105" ' +
      'fill="#fff" font-family="Arial" font-size="20" text-anchor="middle">' +
      'Fixture photo</text></svg>',
  ).toString('base64');

function detailPayload(overrides = {}) {
  const verification = {
    verification_id: 'v-1184',
    property_id: 1184,
    listing_status: 'pending',
    ownership_status: 'not_submitted',
    publication_eligible: false,
    submitted_by: 'harness-owner',
    reviewed_by: null,
    latest_note: null,
    version: 1,
    submitted_at: T0,
    updated_at: T0,
    ...overrides,
  };
  return {
    property: {
      property_id: 1184,
      title: 'Corner shoplot, Section 13',
      description: 'Corner unit with main-road frontage, suitable for a cafe.',
      property_type: 'Shop lot',
      monthly_rent: 4500,
      built_up_area_sqft: 1680,
      land_area_sqft: null,
      address: 'Jalan 13/1, Section 13',
      city: 'Shah Alam',
      state: 'Selangor',
      postcode: '40460',
      latitude: 3.0722,
      longitude: 101.6065,
      availability: 'Immediate',
      floor_level: null,
      frontage_ft: 24,
      has_parking: true,
      is_fnb_suitable: true,
      is_published: false,
      address_formatted: 'Jalan 13/1, 40460 Shah Alam, Selangor',
      address_validation_status: 'validated',
      status: 'pending',
      company_name: null,
      user_id: 'harness-owner',
    },
    owner: {
      user_id: 'harness-owner',
      full_name: 'Sarah Lim',
      email: 'sarah@nasihouse.my',
    },
    verification,
    documents: [],
    history: [
      {
        audit_id: 'a-1',
        property_id: 1184,
        verification_id: 'v-1184',
        verification_type: 'listing',
        previous_status: null,
        new_status: 'pending',
        action: 'listing_submitted',
        admin_user_id: null,
        reason: null,
        created_at: T0,
      },
    ],
    photos: [
      {
        id: 'p-1',
        url: PHOTO_URI,
        caption: 'Shopfront',
        is_primary: true,
        created_at: T0,
      },
    ],
    amenities: {
      suitable_for: 'F&B, retail',
      nearby_landmarks: 'Plaza Alam Sentral',
      amenities: null,
      remarks: 'High evening footfall.',
    },
    geo_features: {
      property_id: 1184,
      competitor_count_500m: 12,
      competitor_count_1km: 37,
      demand_generator_count_500m: 9,
      demand_generator_count_1km: 28,
      population_500m: null,
      population_1km: null,
      accessibility_road_km_1km: 3.4,
      nearest_major_road_m: 140,
      last_calculated_at: '2026-11-10T08:00:00Z',
    },
    demand_generators: [
      {
        subject_id: 'dg-1',
        subject_name: 'Plaza Alam Sentral',
        subject_category: 'Shopping mall',
        latitude: 3.074,
        longitude: 101.601,
        distance_m: 640.2,
      },
    ],
    population: null,
  };
}

const SPARSE = (() => {
  const payload = detailPayload();
  payload.property = {
    ...payload.property,
    floor_level: null,
    frontage_ft: null,
    latitude: null,
    longitude: null,
    description: null,
  };
  payload.verification = {
    ...payload.verification,
    property_id: 1185,
    verification_id: 'v-1185',
  };
  payload.history = [];
  payload.photos = [];
  payload.geo_features = null;
  payload.amenities = null;
  payload.demand_generators = [];
  return payload;
})();

// Minimal per-id state machine so POST decisions return the updated payload
// exactly like the real service would (probe-only).
const states = {};

async function main() {
  const browser = await chromium.launch({ args: ['--no-proxy-server'] });
  const checks = [];
  const ok = (name, pass, extra = '') => {
    checks.push({ name, pass: !!pass });
    if (!pass) console.log(`  FAIL ${name} ${extra}`);
  };

  for (const viewport of [
    { width: 1440, height: 900 },
    { width: 800, height: 900 },
    { width: 390, height: 844 },
  ]) {
    const context = await browser.newContext({ viewport });
    const page = await context.newPage();
    const pageErrors = [];
    page.on('pageerror', (e) => pageErrors.push('pageerror: ' + e.message));
    await installHarnessSession(page, { role: 'admin' });

    // Staff endpoints — registered AFTER the harness so they win (LIFO).
    await page.route('**/api/v1/staff/properties/**', (route) => {
      const req = route.request();
      const url = new URL(req.url());
      const method = req.method();
      const m = /^\/api\/v1\/staff\/properties\/(\d+)(\/.*)?$/.exec(url.pathname);
      if (!m) {
        return route.fulfill({
          status: 404,
          contentType: 'application/json',
          body: JSON.stringify({ error: { message: `no fixture ${url.pathname}` } }),
        });
      }
      const id = Number(m[1]);
      const action = m[2] || '';
      const current = states[id] || {};
      if (method === 'GET' && !action) {
        // Serve a fresh payload whose ids match the requested property —
        // the page stale-guards on `detail.property.propertyId == id`.
        const payload = id === 1185 ? SPARSE : detailPayload(current);
        payload.property = { ...payload.property, property_id: id };
        payload.verification = { ...payload.verification, property_id: id };
        payload.verification.verification_id = `v-${id}`;
        if (current.history) payload.history = current.history;
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify(payload),
        });
      }
      if (method === 'POST') {
        const body = req.postDataJSON() || {};
        const dimension = body.dimension || 'listing';
        let next;
        if (action === '/verification/start-review') {
          next = { ...current, [`${dimension}_status`]: 'under_review' };
        } else if (action === '/verification/approve') {
          next = { ...current, [`${dimension}_status`]: 'verified' };
        } else if (action === '/verification/reject') {
          next = {
            ...current,
            [`${dimension}_status`]: 'rejected',
            latest_note: body.reason || null,
          };
        } else if (action === '/verification/request-information') {
          next = {
            ...current,
            [`${dimension}_status`]: 'information_requested',
            latest_note: body.note || null,
          };
        } else {
          return route.fulfill({ status: 404, body: '{}' });
        }
        // Mirror the service's audit trail so the sidebar's latest-reason
        // lookup (audit action + reason) behaves like production.
        next.history = [
          ...((current.history || detailPayload().history)),
          {
            audit_id: `a-${Date.now()}`,
            property_id: id,
            verification_id: `v-${id}`,
            verification_type: dimension,
            previous_status: current[`${dimension}_status`] || null,
            new_status: next[`${dimension}_status`],
            action: `${dimension}_${action.split('/').pop().replace('-review', '_review').replace('request-information', 'information_requested')}`
              .replace('approve', 'approved')
              .replace('reject', 'rejected'),
            admin_user_id: 'harness-admin',
            reason: body.reason || body.note || null,
            created_at: new Date().toISOString(),
          },
        ];
        states[id] = next;
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ verification_id: `v-${id}`, property_id: id, ...next }),
        });
      }
      return route.fulfill({ status: 404, body: '{}' });
    });
    await page.route('**/api/v1/staff/properties/', (route) =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          items: [
            {
              property_id: 1184,
              title: 'Corner shoplot, Section 13',
              normalized_address: 'Jalan 13/1, Section 13',
              property_type_normalized: 'Shop lot',
              price: 4500,
              built_up_area_sqft: 1680,
              property_status: 'pending',
              company_name: null,
              city: 'Shah Alam',
              state: 'Selangor',
              verification_id: 'v-1184',
              listing_status: states[1184]?.listing_status || 'pending',
              ownership_status: states[1184]?.ownership_status || 'not_submitted',
              publication_eligible: false,
              latest_note: null,
              submitted_at: T0,
              updated_at: T0,
            },
          ],
          total: 1,
          offset: 0,
          limit: 20,
          counts: { listing: { pending: 1 }, ownership: { not_submitted: 1 } },
        }),
      }),
    );

    const wide = viewport.width >= 1440;
    if (wide) {
      // --- Full fixture: hero, tabs, overview, intelligence, decisions -----
      await page.goto(`${BASE}/admin/listing-detail?id=1184`, {
        waitUntil: 'networkidle',
      });
      await page.waitForSelector('.vd-hero', { timeout: 15000 });
      await page.waitForTimeout(600);

      const snap = await page.evaluate(() => {
        const q = (s) => document.querySelector(s);
        const qa = (s) => Array.from(document.querySelectorAll(s));
        const txt = (s) => (q(s)?.textContent || '').trim().replace(/\s+/g, ' ');
        return {
          shell: q('.app-shell.app-shell--admin') ? true : false,
          shellBg: getComputedStyle(q('.app-shell')).backgroundColor,
          heroTitle: txt('.vd-hero__title'),
          heroAddress: txt('.vd-hero__address'),
          heroFacts: txt('.vd-hero__facts'),
          heroChips: txt('.vd-hero__chips'),
          tabCount: qa('.vd-tab').length,
          tabLabels: qa('.vd-tab').map((t) => t.textContent.trim()),
          overviewSelected: q('.vd-tab[data-vd-tab="overview"]')?.getAttribute('aria-selected'),
          photoCount: qa('.vd-photo').length,
          photoSrc: q('.vd-photo')?.getAttribute('src')?.slice(0, 30),
          overviewText: txt('#vd-panel-overview'),
          frontage: qa('.vd-row').some((r) =>
            /Frontage/.test(r.textContent) && /24 ft/.test(r.textContent)),
          parking: qa('.vd-row').some((r) =>
            /Parking/.test(r.textContent) && /Claimed available/.test(r.textContent)),
          floorMissing: qa('.vd-row').some((r) =>
            /Floor level/.test(r.textContent) && /Not provided/.test(r.textContent)),
          pubChip: txt('.vd-publication'),
          ownershipPill: (() => {
            const bodies = qa('.vd-side__body');
            const own = bodies[1];
            if (!own) return '';
            return own.querySelector('.st')?.textContent.trim() || '';
          })(),
          sideBeforePanel: (() => {
            const layout = q('.vd-layout');
            const main = q('.vd-main');
            const side = q('.vd-side');
            return !!layout && !!main && !!side && side.contains(q('.vd-side__top')) &&
              !main.contains(side);
          })(),
        };
      });
      ok('Admin shell scoped class', snap.shell);
      ok('Admin dark canvas', snap.shellBg === 'rgb(13, 15, 26)', snap.shellBg);
      ok('Hero title from payload', snap.heroTitle === 'Corner shoplot, Section 13');
      ok('Hero address line', /Shah Alam, Selangor, 40460/.test(snap.heroAddress), snap.heroAddress);
      ok('Hero rent fact', /RM 4500/.test(snap.heroFacts), snap.heroFacts);
      ok('Hero psf fact', /RM 2\.68/.test(snap.heroFacts));
      ok('Unpublished chip', /Unpublished/.test(snap.heroChips));
      ok('Address-validated chip', /Address validated/.test(snap.heroChips));
      ok('Exactly two tabs', snap.tabCount === 2, String(snap.tabCount));
      ok('Tab labels', snap.tabLabels.join('|') === 'Property Overview|Location Intelligence');
      ok('Overview selected initially', snap.overviewSelected === 'true');
      ok('Fixture photo rendered', snap.photoCount === 1 && snap.photoSrc.startsWith('data:image'));
      ok('Frontage row real value', snap.frontage);
      ok('Parking declared value', snap.parking);
      ok('Floor level honest Not provided', snap.floorMissing);
      ok('Publication blocked', /Publication blocked/.test(snap.pubChip));
      ok('Ownership pill Not submitted', /Not submitted/i.test(snap.ownershipPill), snap.ownershipPill);
      ok('Sidebar is outside the tabs', snap.sideBeforePanel);

      // Keyboard tabs: ArrowRight from Overview selects Intelligence.
      await page.focus('.vd-tab[data-vd-tab="overview"]');
      await page.keyboard.press('ArrowRight');
      await page.waitForTimeout(250);
      const tabState = await page.evaluate(() => ({
        intelligenceSelected: document
          .querySelector('.vd-tab[data-vd-tab="intelligence"]')
          ?.getAttribute('aria-selected'),
        panelVisible: !!document.querySelector('#vd-panel-intelligence'),
        overviewHidden: !document.querySelector('#vd-panel-overview'),
      }));
      ok('ArrowRight moves selection', tabState.intelligenceSelected === 'true');
      ok('Intelligence panel shown', tabState.panelVisible && tabState.overviewHidden);

      const intel = await page.evaluate(() => {
        const q = (s) => document.querySelector(s);
        const txt = (s) => (q(s)?.textContent || '').trim();
        const qa = (s) => Array.from(document.querySelectorAll(s));
        return {
          badge: txt('.vd-section-head .st'),
          source: txt('.vd-source'),
          metrics: qa('.vd-metric').map((m) => m.textContent.replace(/\s+/g, ' ').trim()),
          demandRow: txt('.vd-demand__row'),
          amenities: qa('.vd-row').some((r) =>
            /Suitable for/.test(r.textContent) && /F&B, retail/.test(r.textContent)),
          notes: txt('.vd-notes'),
          mapFrame: !!q('#vd-panel-intelligence iframe'),
          warning: !!q('.vd-note--warning'),
        };
      });
      ok('Intelligence calculated badge', /Calculated/.test(intel.badge), intel.badge);
      ok('Source line names table', /fyp\.property_geospatial_features/.test(intel.source));
      ok('Competitor 500m real', intel.metrics.some((t) => /F&B competitors · 500 m.*12/.test(t)));
      ok('Competitor 1km real', intel.metrics.some((t) => /F&B competitors · 1 km.*37/.test(t)));
      ok('Demand 1km real', intel.metrics.some((t) => /Demand generators · 1 km.*28/.test(t)));
      ok('Population honest Not calculated', intel.metrics.some((t) =>
        /Population · 500 m.*Not calculated/.test(t)));
      ok('Nearest road 140 m', intel.metrics.some((t) => /Nearest major road.*140 m/.test(t)));
      ok('No fake warning for calculated row', !intel.warning);
      ok('Demand generator listed', /Plaza Alam Sentral/.test(intel.demandRow) && /640 m/.test(intel.demandRow));
      ok('Amenities honest Not provided', intel.amenities);
      ok('Straight-line note present', /straight-line/.test(intel.notes));
      ok('Live map iframe rendered', intel.mapFrame);

      // Tab stability across a state refresh: start the review while the
      // intelligence tab is selected, and it must stay selected.
      await page.click('.vd-side__body button:has-text("Start review")');
      await page.waitForTimeout(900);
      const stability = await page.evaluate(() => ({
        stillIntelligence:
          document.querySelector('.vd-tab[data-vd-tab="intelligence"]')?.getAttribute('aria-selected') === 'true',
        statusPill: (() => {
          const line = Array.from(document.querySelectorAll('.vd-decision-line')).find(
            (l) => /Listing accuracy/.test(l.textContent));
          return line?.querySelector('.st')?.textContent.trim() || '';
        })(),
      }));
      ok('Tab stays on Intelligence after refresh', stability.stillIntelligence);
      ok('Listing pill Under review', /Under review/i.test(stability.statusPill), stability.statusPill);

      // Checklist gates the approve action.
      const gate = await page.evaluate(() => {
        const buttons = Array.from(document.querySelectorAll('.vd-side .btn'));
        const approve = buttons.find((b) => /Approve/.test(b.textContent));
        return {
          approvePresent: !!approve,
          disabled: approve?.className.includes('is-disabled'),
        };
      });
      ok('Approve present under review', gate.approvePresent);
      ok('Approve gated by checklist', gate.disabled);

      for (const label of _checkTexts) {
        await page.click(`.vd-check:has-text("${label}") input`);
      }
      await page.waitForTimeout(200);
      const armed = await page.evaluate(() => {
        const approve = Array.from(document.querySelectorAll('.vd-side .btn')).find((b) =>
          /Approve/.test(b.textContent));
        return !approve?.className.includes('is-disabled');
      });
      ok('Approve armed after checklist', armed);

      await page.click('.vd-side .btn:has-text("Approve")');
      await page.waitForTimeout(900);
      const afterApprove = await page.evaluate(() => {
        const lines = Array.from(document.querySelectorAll('.vd-decision-line'));
        const listing = lines.find((l) => /Listing accuracy/.test(l.textContent));
        const ownership = lines.find((l) => /Ownership & authority/.test(l.textContent));
        return {
          listing: listing?.querySelector('.st')?.textContent.trim() || '',
          ownership: ownership?.querySelector('.st')?.textContent.trim() || '',
          pub: (document.querySelector('.vd-publication')?.textContent || '').trim(),
        };
      });
      ok('Listing verified after approve', /Verified/i.test(afterApprove.listing), afterApprove.listing);
      ok('Ownership stays Not submitted', /Not submitted/i.test(afterApprove.ownership), afterApprove.ownership);
      ok('Publication still blocked', /Publication blocked/.test(afterApprove.pub));

      // --- Reject requires a reason -----------------------------------------
      // Same page: the staff-route intercepts live on this Page object. The
      // property 1186 fixture is served pending by the state machine, giving
      // the note form a fresh under_review cycle.
      await page.goto(`${BASE}/admin/listing-detail?id=1186`, { waitUntil: 'networkidle' });
      await page.waitForSelector('.vd-hero', { timeout: 15000 });
      await page.click('.vd-side__body button:has-text("Start review")');
      await page.waitForTimeout(700);
      await page.click('.vd-side__body button:has-text("Reject")');
      await page.waitForTimeout(200);
      const noteState = await page.evaluate(() => {
        const ta = document.querySelector('.reject-form textarea');
        const confirm = Array.from(document.querySelectorAll('.reject-form .btn')).find(
          (b) => /Confirm reject/.test(b.textContent));
        return { hasForm: !!ta, confirmDisabled: confirm?.className.includes('is-disabled') };
      });
      ok('Reject form opens', noteState.hasForm);
      ok('Confirm disabled with short note', noteState.confirmDisabled);
      await page.fill('.reject-form textarea', 'Photos do not match the stated floor level.');
      await page.waitForTimeout(200);
      const armedReject = await page.evaluate(() => {
        const confirm = Array.from(document.querySelectorAll('.reject-form .btn')).find(
          (b) => /Confirm reject/.test(b.textContent));
        return !confirm?.className.includes('is-disabled');
      });
      ok('Confirm armed with reason', armedReject);
      await page.click('.reject-form .btn:has-text("Confirm reject")');
      await page.waitForTimeout(900);
      const rejected = await page.evaluate(() => {
        const line = Array.from(document.querySelectorAll('.vd-decision-line')).find(
          (l) => /Listing accuracy/.test(l.textContent));
        const note = document.querySelector('.owner-note');
        return {
          pill: line?.querySelector('.st')?.textContent.trim() || '',
          note: note?.textContent.trim() || '',
        };
      });
      ok('Listing rejected', /Rejected/i.test(rejected.pill), rejected.pill);
      ok('Reason surfaced', /Photos do not match/.test(rejected.note));

      // --- Overflow ----------------------------------------------------------
      const overflow = await page.evaluate(
        () => document.scrollingElement.scrollWidth <= window.innerWidth + 1,
      );
      ok(`No horizontal overflow at ${viewport.width}`, overflow);
      ok(`No page errors at ${viewport.width}`, pageErrors.length === 0, pageErrors.join('; '));
    } else {
      // Narrow viewports: sparse fixture + layout sanity.
      await page.goto(`${BASE}/admin/listing-detail?id=1185`, { waitUntil: 'networkidle' });
      await page.waitForSelector('.vd-hero', { timeout: 15000 });
      await page.waitForTimeout(500);
      const sparse = await page.evaluate(() => {
        const txt = (s) => (document.querySelector(s)?.textContent || '').trim();
        const qa = (s) => Array.from(document.querySelectorAll(s));
        return {
          photoEmpty: txt('.vd-photo-empty'),
          overflow: document.scrollingElement.scrollWidth <= window.innerWidth + 1,
          description: qa('.vd-row').some((r) =>
            /Street address/.test(r.textContent)),
        };
      });
      ok(`[${viewport.width}] Photo empty state`, /No property photos submitted/.test(sparse.photoEmpty));
      ok(`[${viewport.width}] No overflow (sparse)`, sparse.overflow);
      // Intelligence "Not calculated" warning (the panel renders only while
      // its tab is selected).
      await page.click('.vd-tab[data-vd-tab="intelligence"]');
      await page.waitForTimeout(300);
      const intelSparse = await page.evaluate(() => {
        const q = (s) => document.querySelector(s);
        const txt = (s) => (q(s)?.textContent || '').trim();
        const qa = (s) => Array.from(document.querySelectorAll(s));
        return {
          warning: txt('.vd-note--warning'),
          badge: txt('.vd-section-head .st'),
          missing: qa('.vd-metric--missing').length,
          mapEmpty: /Map unavailable/.test(q('#vd-panel-intelligence')?.textContent || ''),
          coordsRow: qa('.vd-row').some((r) =>
            /Coordinates/.test(r.textContent) && /Missing coordinates/.test(r.textContent)),
        };
      });
      ok(`[${viewport.width}] Not calculated warning`, /Not calculated for this property/.test(intelSparse.warning));
      ok(`[${viewport.width}] Badge Not calculated`, /Not calculated/.test(intelSparse.badge));
      ok(`[${viewport.width}] All metrics missing`, intelSparse.missing === 9, String(intelSparse.missing));
      ok(`[${viewport.width}] Map unavailable without coords`, intelSparse.mapEmpty);
      ok(`[${viewport.width}] Missing coordinates row`, intelSparse.coordsRow);
      const overflow2 = await page.evaluate(
        () => document.scrollingElement.scrollWidth <= window.innerWidth + 1,
      );
      ok(`[${viewport.width}] No overflow (intelligence)`, overflow2);
    }

    await context.close();
  }

  // --- /admin/listings split still embeds the shared view ------------------
  {
    const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    const page = await context.newPage();
    await installHarnessSession(page, { role: 'admin' });
    await page.route('**/api/v1/staff/properties/**', (route) => {
      const url = new URL(route.request().url());
      if (/\/api\/v1\/staff\/properties\/$/.test(url.pathname)) {
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            items: [
              {
                property_id: 1184,
                title: 'Corner shoplot, Section 13',
                normalized_address: 'Jalan 13/1, Section 13',
                property_type_normalized: 'Shop lot',
                price: 4500,
                built_up_area_sqft: 1680,
                property_status: 'pending',
                company_name: null,
                city: 'Shah Alam',
                state: 'Selangor',
                verification_id: 'v-1184',
                listing_status: 'pending',
                ownership_status: 'not_submitted',
                publication_eligible: false,
                latest_note: null,
                submitted_at: T0,
                updated_at: T0,
              },
            ],
            total: 1,
            offset: 0,
            limit: 20,
            counts: { listing: { pending: 1 }, ownership: { not_submitted: 1 } },
          }),
        });
      }
      const id = /(\d+)/.exec(url.pathname)?.[1];
      return route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(id === '1185' ? SPARSE : detailPayload()),
      });
    });
    await page.goto(`${BASE}/admin/listings`, { waitUntil: 'networkidle' });
    await page.waitForSelector('.queue-item', { timeout: 15000 });
    await page.waitForTimeout(1200);
    const split = await page.evaluate(() => {
      const detail = document.querySelector('.split');
      return {
        queueItem: !!document.querySelector('.queue-item'),
        tabs: document.querySelectorAll('.vd-tab').length,
        hero: !!document.querySelector('.vd-hero'),
        ownership: /Not submitted/i.test(
          Array.from(document.querySelectorAll('.vd-decision-line'))
            .find((l) => /Ownership & authority/.test(l.textContent))
            ?.textContent || '',
        ),
      };
    });
    ok('Split queue renders', split.queueItem);
    ok('Split detail embeds two-tab view', split.tabs === 2 && split.hero);
    ok('Split ownership Not submitted', split.ownership);
    await context.close();
  }

  await browser.close();
  const passed = checks.filter((c) => c.pass).length;
  console.log(`\nprobe_admin_verification: ${passed}/${checks.length} checks passed`);
  const failed = checks.filter((c) => !c.pass);
  if (failed.length) {
    console.log('FAILED:', failed.map((f) => f.name).join(' | '));
    process.exitCode = 1;
  }
}

// The checklist labels are rendered by the component; mirror them here for
// the click loop.
const _checkTexts = [
  'Property information reviewed',
  'Address and coordinates reviewed',
  'Photos, facilities',
];

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
