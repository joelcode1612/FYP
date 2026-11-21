const { chromium } = require('playwright-core');
const { installHarnessSession, FIXTURE } = require('./session_harness');
const fs = require('fs');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
(async () => {
  const fixture = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
  const prop = fixture.rows[1 % fixture.rows.length];
  const record = { assessment_id:'as-ws-preview', property_id:prop.id, status:'in_progress', current_stage:4, current_stage_key:'ai_explanation', completed_stages:3, total_stages:5, progress_percent:60, report_available:false, requirements:{fnb_concept:'cafe_coffee_shop', service_model:'dine_in', target_customers:['office_workers'], recommendation_priority:'easy_customer_accessibility', space_size_preference:'standard_business_space'}, requirements_version:3, stages:[{key:'select_property',number:1,title:'Select property',status:'complete'},{key:'business_requirements',number:2,title:'Business preferences',status:'complete'},{key:'location_evidence',number:3,title:'Location evidence',status:'complete'},{key:'ai_explanation',number:4,title:'AI explanation',status:'current'},{key:'assessment_report',number:5,title:'Assessment report',status:'incomplete'}], capabilities:{model:{available:true},explanation:{available:true},report:{available:true}}, next_action:{kind:'continue',stage_key:'ai_explanation',label:'x'}, property:prop, updated_at:'2026-11-14T16:20:00Z' };
  const b = await chromium.launch({ executablePath: EXE, args:['--no-sandbox','--no-proxy-server'] });
  const ctx = await b.newContext({ viewport:{width:1440,height:1100}, bypassCSP:true });
  const page = await ctx.newPage();
  await installHarnessSession(page, { role:'entrepreneur' });
  await page.route('**/api/v1/assessments/by-property/**', r => r.fulfill({status:200,contentType:'application/json',body:JSON.stringify({assessment:record})}));
  await page.route('**/api/v1/catalog/properties/**', r => { const u=new URL(r.request().url()); if(u.pathname.includes('/evidence')) return r.fallback(); const id=decodeURIComponent(u.pathname.split('/').pop()); const row=fixture.rows.find(x=>x.id===id); return r.fulfill({status:200,contentType:'application/json',body:JSON.stringify(row)}); });
  await page.route('**/api/v1/catalog/properties/**/evidence**', r => r.fulfill({status:200,contentType:'application/json',body:JSON.stringify({property_id:prop.id,available:true,groups:[{key:'competitor_pressure',label:'Competitor pressure',metrics:[{key:'fnb_competitors_1000m',label:'F&B competitors within 1 km',unit:'count',value:47,status:'available'}]}]})}));
  await page.goto('http://127.0.0.1:8095/entrepreneur/assessments?id='+encodeURIComponent(prop.id)+'&stage=ai_explanation', {waitUntil:'networkidle'});
  await page.waitForSelector('.asw-rqr');
  await page.waitForTimeout(2000);
  const info = await page.evaluate(() => {
    const pick = (sel) => {
      const el = document.querySelector(sel);
      if (!el) return null;
      const cs = getComputedStyle(el);
      const r = el.getBoundingClientRect();
      return { text: el.textContent, cls: el.className, color: cs.color, font: cs.fontFamily, fs: cs.fontSize, w: Math.round(r.width), h: Math.round(r.height) };
    };
    return {
      fontLoaded: document.fonts.check('16px "Material Symbols Outlined"'),
      groupIcon: pick('.asw-rqr__grouphead .ms'),
      decIcon: pick('.asw-rqr__decopt .ms'),
      noteIcon: pick('.asw-rqr__note h5 .ms'),
      boxIcon: pick('.asw-rqr__boxhead .ms'),
    };
  });
  console.log(JSON.stringify(info, null, 2));
  await b.close();
})();
