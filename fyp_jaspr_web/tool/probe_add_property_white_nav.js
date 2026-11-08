// Focused verification for the white floating workspace navbar and the
// entrepreneur Add Property five-step wizard, against the BUILT Jaspr app.
//
// Usage (from fyp_jaspr_web, with the SPA fallback server running):
//   node tool/serve_spa.js 8141
//   NODE_PATH=<managed node_modules> node tool/probe_add_property_white_nav.js \
//       http://127.0.0.1:8141
//
// Uses the existing session_harness so no live Supabase credentials or backend
// are required. It deliberately asserts that NO successful property creation
// is claimed, because the web repository has no working create operation.

const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness');

const EXE =
  'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = process.argv[2] || 'http://127.0.0.1:8141';
const ROUTE = '/entrepreneur/add-property';

const results = [];
function check(name, ok, detail = '') {
  results.push({ name, ok });
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail ? ' :: ' + detail : ''}`);
}

// 1x1 PNG, used only to exercise the local (non-uploaded) photo preview path.
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
  'base64',
);

async function open(browser, width, route) {
  const ctx = await browser.newContext({
    viewport: { width, height: 900 },
    deviceScaleFactor: 1,
  });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => {
    if (m.type() === 'error' && !m.text().includes('404')) {
      errors.push(m.text());
    }
  });
  await installHarnessSession(page, { role: 'entrepreneur' });
  const resp = await page.goto(BASE + route, {
    waitUntil: 'networkidle',
    timeout: 30000,
  });
  await page
    .waitForSelector('.sw-reg-stepper', { timeout: 20000 })
    .catch(() => {});
  await page.waitForTimeout(500);
  return { ctx, page, resp, errors };
}

const measure = () =>
  document.documentElement.scrollWidth - window.innerWidth;

(async () => {
  const browser = await chromium.launch({
    executablePath: EXE,
    args: ['--no-sandbox'],
  });
  let crashed = null;

  try {
    // ---------------------------------------------------------------- navbar
    {
      const { ctx, page, resp, errors } = await open(browser, 1440, ROUTE);
      check('add-property route returns 200', resp && resp.status() === 200);

      const pill = await page.evaluate(() => {
        const all = document.querySelectorAll('.app-pill');
        const el = all[0];
        if (!el) return { count: all.length };
        const s = getComputedStyle(el);
        const active = document.querySelector('.app-pill__link--active');
        const links = [...document.querySelectorAll('.app-pill__link')];
        return {
          count: all.length,
          bg: s.backgroundColor,
          radius: s.borderRadius,
          shadow: s.boxShadow,
          linkColor: links.length
            ? getComputedStyle(links[0]).color
            : '',
          linkCount: links.length,
          hrefs: links.map((a) => a.getAttribute('href')),
          activeText: active ? active.textContent.trim() : '',
          activeAria: active ? active.getAttribute('aria-current') : '',
          shellBg: getComputedStyle(document.querySelector('.app-shell'))
            .backgroundColor,
        };
      });

      check('exactly one shared navbar (no duplicate)', pill.count === 1, `count=${pill.count}`);
      const rgb = (pill.bg || '').match(/\d+/g)?.map(Number) || [];
      check(
        'navbar background is white / near-white',
        rgb.length >= 3 && rgb[0] >= 245 && rgb[1] >= 245 && rgb[2] >= 245,
        pill.bg,
      );
      check(
        'navbar has a soft shadow',
        !!pill.shadow && pill.shadow !== 'none',
        (pill.shadow || '').slice(0, 50),
      );
      check(
        'navbar is a rounded floating pill',
        parseFloat(pill.radius) >= 20 || /999/.test(pill.radius || ''),
        pill.radius,
      );
      const linkRgb = (pill.linkColor || '').match(/\d+/g)?.map(Number) || [];
      check(
        'nav links are dark enough for white surface',
        linkRgb.length >= 3 && Math.max(...linkRgb.slice(0, 3)) < 160,
        pill.linkColor,
      );
      check(
        'active link uses aria-current="page"',
        pill.activeAria === 'page',
        `active="${pill.activeText}" aria=${pill.activeAria}`,
      );
      check(
        'active link resolves to real parent route (My Properties)',
        pill.activeText === 'My Properties',
        pill.activeText,
      );
      check(
        'all 8 real entrepreneur destinations rendered',
        pill.linkCount === 8,
        `count=${pill.linkCount}`,
      );
      const valid = [
        '/entrepreneur',
        '/entrepreneur/explore',
        '/entrepreneur/map',
        '/entrepreneur/recommendations',
        '/entrepreneur/compare',
        '/entrepreneur/saved',
        '/entrepreneur/my-properties',
        '/entrepreneur/profile',
      ];
      check(
        'no invented / hardcoded nav destinations',
        (pill.hrefs || []).every((h) => valid.includes(h)),
        (pill.hrefs || []).join(','),
      );
      const focusable = await page.evaluate(() =>
        [...document.querySelectorAll('.app-pill a, .app-pill button')].every(
          (el) => el.tabIndex >= 0 && !el.hasAttribute('disabled'),
        ),
      );
      check('every navbar control is keyboard reachable', focusable);
      check(
        'no horizontal overflow at 1440px',
        (await page.evaluate(measure)) <= 2,
      );
      check('no runtime errors on add-property', errors.length === 0, errors.slice(0, 2).join(' | '));
      await ctx.close();
    }

    // ------------------------------------------- white navbar is sitewide
    {
      const { ctx, page } = await open(browser, 1440, '/entrepreneur');
      const state = await page.evaluate(() => {
        const pill = document.querySelector('.app-pill');
        const shell = document.querySelector('.app-shell');
        return {
          bg: pill ? getComputedStyle(pill).backgroundColor : '',
          shellBg: shell ? getComputedStyle(shell).backgroundColor : '',
        };
      });
      const rgb = (state.bg || '').match(/\d+/g)?.map(Number) || [];
      check(
        'white navbar present on another workspace route',
        rgb.length >= 3 && rgb[0] >= 245 && rgb[1] >= 245 && rgb[2] >= 245,
        state.bg,
      );
      const shellRgb = (state.shellBg || '').match(/\d+/g)?.map(Number) || [];
      check(
        'dark canvas unchanged on other workspace routes',
        shellRgb.length >= 3 && Math.max(...shellRgb.slice(0, 3)) < 45,
        state.shellBg,
      );
      await ctx.close();
    }

    // ------------------------------------------------- responsive + a11y
    for (const width of [834, 390]) {
      const { ctx, page } = await open(browser, width, ROUTE);
      check(
        `no horizontal overflow at ${width}px`,
        (await page.evaluate(measure)) <= 2,
        `overflow=${await page.evaluate(measure)}px`,
      );
      const stepper = await page.evaluate(() => {
        const steps = [...document.querySelectorAll('.sw-reg-step')];
        return {
          count: steps.length,
          active: steps.findIndex((s) => s.classList.contains('is-active')),
          cols: getComputedStyle(document.querySelector('.sw-reg-stepper'))
            .gridTemplateColumns.split(' ').length,
        };
      });
      check(
        `five-step stepper at ${width}px`,
        stepper.count === 5 && stepper.active === 0,
        JSON.stringify(stepper),
      );
      const labels = await page.evaluate(() => {
        const controls = [
          ...document.querySelectorAll(
            '.sw-reg input, .sw-reg select, .sw-reg textarea',
          ),
        ];
        return controls
          .filter((el) => el.type !== 'hidden')
          .map((el) => ({
            id: el.id,
            labelled: !!(
              el.id && document.querySelector(`label[for="${el.id}"]`)
            ),
          }));
      });
      check(
        `every visible control has a real <label for> at ${width}px`,
        labels.length > 0 && labels.every((l) => l.labelled),
        `${labels.filter((l) => !l.labelled).length} unlabelled`,
      );
      await page.evaluate(() => {
        document.documentElement.style.fontSize = '20px';
      });
      await page.waitForTimeout(120);
      check(
        `no horizontal overflow after text scaling at ${width}px`,
        (await page.evaluate(measure)) <= 2,
      );
      await ctx.close();
    }

    // ------------------------------------------------- functional 5-step flow
    {
      const { ctx, page, errors } = await open(browser, 1440, ROUTE);

      const notice = await page.evaluate(() => ({
        connection: document.querySelector('.sw-reg-connection')?.textContent || '',
        status: document.querySelector('.sw-reg-status')?.textContent || '',
        body: document.body.innerText,
      }));
      check(
        'submission is explicitly labelled "not connected"',
        /not connected/i.test(notice.connection),
      );
      check(
        'hero status says "not submitted"',
        /not submitted/i.test(notice.status),
      );
      check(
        'no fake property ID shown before submit',
        !/property\s*id\s*[:#]\s*[a-z0-9-]{4,}/i.test(notice.body),
      );

      // --- Step 1 validation: empty required fields -------------------------
      await page.click('.sw-reg-footer .sw-btn-primary');
      await page.waitForTimeout(150);
      let summary = await page.locator('.sw-error-summary').innerText().catch(() => '');
      check(
        'empty required fields block step 1',
        /required/i.test(summary) && /Property name/i.test(summary),
        summary.slice(0, 90).replace(/\n/g, ' '),
      );

      await page.fill('#propertyName', 'SS15 Corner Retail');
      await page.selectOption('#propertyType', 'Shoplot / shophouse');
      await page.fill('#builtUp', '-5');
      await page.click('.sw-reg-footer .sw-btn-primary');
      await page.waitForTimeout(150);
      summary = await page.locator('.sw-error-summary').innerText().catch(() => '');
      check(
        'negative built-up area rejected',
        /Built-up area must be a number greater than 0/i.test(summary),
        summary.slice(0, 90).replace(/\n/g, ' '),
      );

      await page.fill('#builtUp', '1680');
      await page.click('.sw-reg-footer .sw-btn-primary');
      await page.waitForTimeout(200);
      let active = await page.evaluate(
        () =>
          [...document.querySelectorAll('.sw-reg-step')].findIndex((s) =>
            s.classList.contains('is-active'),
          ),
      );
      check('valid step 1 advances to step 2', active === 1, `active=${active}`);

      // --- Step 2 validation: postcode + rent -------------------------------
      await page.fill('#address', '12 Jalan SS15/4');
      await page.fill('#city', 'Subang Jaya');
      await page.selectOption('#state', 'Selangor');
      await page.fill('#postcode', '123');
      // A number input cannot hold "abc"; -1 exercises the business rule.
      await page.fill('#monthlyRent', '-1');
      await page.click('.sw-reg-footer .sw-btn-primary');
      await page.waitForTimeout(150);
      summary = await page.locator('.sw-error-summary').innerText().catch(() => '');
      check(
        'invalid postcode and rent are both rejected',
        /Postcode/i.test(summary) && /Monthly rent/i.test(summary),
        summary.slice(0, 120).replace(/\n/g, ' '),
      );

      await page.fill('#postcode', '47500');
      await page.fill('#monthlyRent', '7800');
      await page.click('.sw-reg-footer .sw-btn-primary');
      await page.waitForTimeout(200);
      active = await page.evaluate(
        () =>
          [...document.querySelectorAll('.sw-reg-step')].findIndex((s) =>
            s.classList.contains('is-active'),
          ),
      );
      check('valid step 2 advances to step 3', active === 2, `active=${active}`);

      // --- Back navigation preserves values ---------------------------------
      await page.click('.sw-reg-stepper .sw-reg-step:first-child');
      await page.waitForTimeout(200);
      const retained = await page.inputValue('#propertyName');
      check(
        'back navigation preserves entered values',
        retained === 'SS15 Corner Retail',
        retained,
      );
      await page.click('.sw-reg-footer .sw-btn-primary');
      await page.waitForTimeout(200);
      const retainedAddress = await page.inputValue('#address');
      check(
        'forward navigation also preserves values',
        retainedAddress === '12 Jalan SS15/4',
        retainedAddress,
      );

      // --- Steps 3 (F&B readiness) -> 4 (Photos & proof) ---------------------
      await page.click('.sw-reg-footer .sw-btn-primary');
      await page.waitForTimeout(200);
      await page.click('.sw-reg-footer .sw-btn-primary');
      await page.waitForTimeout(200);
      await page.waitForSelector('#swRegPhotoInput', { timeout: 10000 });
      const proofStep = await page.evaluate(
        () =>
          [...document.querySelectorAll('.sw-reg-step')].findIndex((s) =>
            s.classList.contains('is-active'),
          ),
      );
      check('reached photos & proof step', proofStep === 3, `active=${proofStep}`);

      // --- Step 4: local photo selection, validation, removal ---------------
      await page.setInputFiles('#swRegPhotoInput', {
        name: 'bad.txt',
        mimeType: 'text/plain',
        buffer: Buffer.from('not an image'),
      });
      await page.waitForTimeout(150);
      const photoErr = await page
        .locator('.sw-photo-error')
        .innerText()
        .catch(() => '');
      check('unsupported photo type rejected', /JPG|PNG|WebP/i.test(photoErr), photoErr);

      await page.setInputFiles('#swRegPhotoInput', {
        name: 'exterior.png',
        mimeType: 'image/png',
        buffer: PNG,
      });
      await page.waitForTimeout(200);
      let photos = await page.locator('.sw-photo-item').count();
      const blobSrc = await page
        .locator('.sw-photo-item img')
        .first()
        .getAttribute('src')
        .catch(() => '');
      check(
        'selected image renders a local preview',
        photos === 1 && /^blob:/.test(blobSrc || ''),
        `count=${photos} src=${(blobSrc || '').slice(0, 24)}`,
      );
      await page.click('.sw-photo-remove');
      await page.waitForTimeout(150);
      photos = await page.locator('.sw-photo-item').count();
      check('remove-image action works', photos === 0, `count=${photos}`);

      await page.selectOption('#ownerRole', 'Registered owner');
      await page.click('.sw-reg-footer .sw-btn-primary');
      await page.waitForTimeout(200);
      active = await page.evaluate(
        () =>
          [...document.querySelectorAll('.sw-reg-step')].findIndex((s) =>
            s.classList.contains('is-active'),
          ),
      );
      check('step 4 advances to review', active === 4, `active=${active}`);

      const review = await page.locator('.sw-review-list').innerText();
      check(
        'review shows the real entered values',
        /SS15 Corner Retail/.test(review) && /7800/.test(review),
        review.slice(0, 100).replace(/\n/g, ' '),
      );

      // --- Step 5: confirmation guard + duplicate submit --------------------
      await page.click('.sw-reg-footer .sw-btn-primary');
      await page.waitForTimeout(150);
      summary = await page.locator('.sw-error-summary').innerText().catch(() => '');
      check(
        'unconfirmed review blocks saving',
        /confirm/i.test(summary),
        summary.slice(0, 90).replace(/\n/g, ' '),
      );

      await page.click('.sw-confirm-box');
      // Two rapid clicks exercise the duplicate-submit guard.
      await page.click('.sw-reg-footer .sw-btn-primary');
      await page.click('.sw-reg-footer .sw-btn-primary').catch(() => {});
      await page.waitForSelector('.sw-saved-card', { timeout: 10000 });
      await page.waitForTimeout(200);

      const saved = await page.evaluate(() => ({
        cards: document.querySelectorAll('.sw-saved-card').length,
        text: document.querySelector('.sw-saved-card')?.textContent || '',
      }));
      check('exactly one saved-state card', saved.cards === 1, `count=${saved.cards}`);
      check(
        'saved state says "not submitted"',
        /not submitted/i.test(saved.text),
      );
      check(
        'saved state denies any property creation / ID',
        /no property was created/i.test(saved.text) &&
          !/property\s*id\s*[:#]\s*[a-z0-9-]{4,}/i.test(saved.text),
      );
      check(
        'no page errors during the whole flow',
        errors.length === 0,
        errors.slice(0, 2).join(' | '),
      );
      await ctx.close();
    }
  } catch (e) {
    crashed = e;
    check('probe completed without an exception', false, e.message.split('\n')[0]);
  } finally {
    await browser.close();
  }

  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  if (failed.length) {
    console.log('FAILURES:', failed.map((f) => f.name).join(' | '));
  }
  process.exit(failed.length || crashed ? 1 : 0);
})();
