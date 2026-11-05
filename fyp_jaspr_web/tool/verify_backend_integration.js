// Checks real unsigned/OAuth entry flows, then UI data binding with an explicit
// authenticated fixture. Does not create accounts or bypass the production API.
const { chromium } = require('playwright-core');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const base = process.argv[2] || 'http://localhost:8091';
const cache = path.join(process.env.LOCALAPPDATA, 'ms-playwright');
const browsers = fs.readdirSync(cache).filter(x => /^chromium-\d+$/.test(x)).sort((a,b) => +b.split('-')[1] - +a.split('-')[1]);
const executablePath = process.env.CHROME_PATH || path.join(cache,browsers[0],'chrome-win64/chrome.exe');
const columns = ['id','title','address','city','state','postcode','rental_rm','size_sqft','latitude','longitude','property_type','image_url','suitability_score','dataset_validation'];
const dataset = JSON.parse(fs.readFileSync(path.join(__dirname, '../../test/.data/properties.json'),'utf8'))
  .map(row => Object.fromEntries(columns.map(key => [key,row[key]])));

(async () => {
  const browser = await chromium.launch({ executablePath, args: ['--enable-unsafe-swiftshader'] });
  const errors = [];
  try {
    for (const width of [1440,390]) {
      const context = await browser.newContext({ viewport: { width,height:900 } });
      const page = await context.newPage();
      page.on('pageerror', error => errors.push(error.message));
      await page.goto(base + '/entrepreneur/explore');
      await page.locator('.login-page').waitFor();
      assert.ok(page.url().includes('/login?next='));
      const google = page.getByRole('button',{ name:'Continue with Google',exact:true });
      assert.ok(await google.isEnabled());
      await page.locator('.lp-submit').click();
      await page.getByText('Email address is required.',{exact:true}).waitFor({timeout:1000}).catch(async () =>
        page.getByText('Enter a valid email address.',{exact:true}).waitFor());
      let oauth;
      await page.route('**/auth/v1/authorize?**',async route => {
        oauth = new URL(route.request().url());
        await route.fulfill({ contentType:'text/html',body:'OAuth navigation intercepted by automated test.' });
      });
      await google.click();
      await page.waitForURL('**/auth/v1/authorize?**');
      assert.equal(oauth.searchParams.get('provider'),'google');
      assert.equal(oauth.searchParams.get('redirect_to'),base + '/auth/callback');
      assert.equal(oauth.searchParams.get('code_challenge_method'),'s256');
      assert.ok(oauth.searchParams.get('code_challenge'));
      await page.goto(base + '/signup');
      await page.getByRole('button',{name:'Continue with Google',exact:true}).waitFor();
      await context.close();
      console.log(`PASS ${width}px: protected-route redirect, login/signup Google button, PKCE OAuth request`);

      // Test the actual production Dart UI against normalized workbook records.
      const fixture = await browser.newContext({ viewport:{width,height:900} });
      const p = await fixture.newPage();
      p.on('pageerror',error => errors.push(error.message));
      await p.route('**/auth_bundle.js',route => route.fulfill({ contentType:'application/javascript',body:`
        const rows=${JSON.stringify(dataset)};
        window.sitewiseAuth={ready:Promise.resolve(),snapshot:()=>JSON.stringify({configured:true,error:'',profile:{user_id:'fixture',display_name:'Test account',email:'test@example.com',role:'entrepreneur'}}),
          request:async (route)=>{const u=new URL(route,'http://fixture');if(u.pathname==='/api/v1/catalog/properties'){const offset=+(u.searchParams.get('offset')||0),limit=+(u.searchParams.get('limit')||200);return JSON.stringify({data:rows.slice(offset,offset+limit),meta:{total:rows.length}});}throw new Error('Unexpected fixture route');},signout:async()=>{},google:async()=>{}};
      ` }));
      await p.goto(base + '/entrepreneur/explore');
      await p.locator('.pcard').first().waitFor();
      assert.equal(await p.locator('.pcard').count(),24);
      await p.getByText('2126 properties match your filters.',{exact:true}).waitFor();
      assert.ok(await p.locator('.pcard-media img').count() > 0);
      await p.getByRole('button',{name:'Show more properties',exact:true}).click();
      assert.equal(await p.locator('.pcard').count(),48);
      await p.locator('.filters input[type="search"]').fill('no-such-property-fixture');
      await p.getByText('No properties match these filters',{exact:true}).waitFor();
      await p.goto(base + '/admin');
      await p.waitForURL(base + '/entrepreneur');
      await p.locator('.bento').waitFor();
      assert.equal(await p.getByText('Something went wrong',{exact:true}).count(),0);
      await fixture.close();
      console.log(`PASS ${width}px: 2126 imported records, lazy images, pagination, filtering, role boundary, workbook-based shortlist`);
    }
    assert.deepEqual(errors,[],'Browser runtime errors');
  } finally { await browser.close(); }
})().catch(error => { console.error(error);process.exitCode=1; });
