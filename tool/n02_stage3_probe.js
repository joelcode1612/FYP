const { chromium } = require('playwright');
const fs = require('fs');
const BASE='http://127.0.0.1:8092', SHOTS='backend/var/e2e/shots';
(async()=>{
  const b=await chromium.launch({headless:true,channel:'chrome'});
  const ctx=await b.newContext({viewport:{width:1440,height:1500}});
  const p=await ctx.newPage();
  const api=[]; p.on('response',r=>{const u=r.url();
    if(u.includes('objective-proposals')||u.includes('/api/v1/m2/assessments/')) api.push(`${r.status()} ${u.replace(BASE,'').slice(0,140)}`);});
  await p.goto(BASE+'/login',{waitUntil:'networkidle',timeout:45000});
  await p.fill('#lp-email','gatebc-e2e-b9e62014@example.invalid');
  await p.fill('#lp-password','e2e-local-password');
  await p.click('button.lp-submit'); await p.waitForTimeout(5000);
  for (const q of ['id=EP-GAP01-OWNER-C&stage=location_evidence','id=EP-GAP01-OWNER-C&step=3']) {
    await p.goto(`${BASE}/entrepreneur/assessments?${q}`,{waitUntil:'networkidle',timeout:45000});
    await p.waitForTimeout(5000);
    const t=await p.innerText('body');
    console.log('\n===',q,'| url:',p.url());
    console.log('  Research objectives:', /Research objectives/i.test(t));
    console.log('  could not be read  :', /could not be read|not current|no verified/i.test(t));
    const m=/Research objectives[\s\S]{0,700}/i.exec(t); if(m) console.log('  ---panel---\n'+m[0].slice(0,700));
    fs.writeFileSync(`backend/var/e2e/n02_stage3_${q.replace(/[^a-z0-9]/gi,'_')}.txt`,t,'utf8');
    await p.screenshot({path:`${SHOTS}/n02_07_stage3_${q.replace(/[^a-z0-9]/gi,'_')}.png`,fullPage:true});
  }
  console.log('\n=== api ===\n'+ (api.slice(-20).join('\n')||'(none)'));
  await b.close();
})().catch(e=>{console.error('ERROR:',e.message);process.exit(1);});
