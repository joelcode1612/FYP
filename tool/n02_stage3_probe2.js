const { chromium } = require('playwright');
const fs = require('fs');
const BASE='http://127.0.0.1:8092', SHOTS='backend/var/e2e/shots';
(async()=>{
  const b=await chromium.launch({headless:true,channel:'chrome'});
  const ctx=await b.newContext({viewport:{width:1440,height:1600}});
  const p=await ctx.newPage();
  const api=[]; p.on('response',r=>{const u=r.url();
    if(u.includes('objective-proposals')||u.includes('/api/v1/m2/assessments/')) api.push(`${r.status()} ${u.replace(BASE,'').slice(0,150)}`);});
  await p.goto(BASE+'/login',{waitUntil:'networkidle',timeout:45000});
  await p.fill('#lp-email','gatebc-e2e-b9e62014@example.invalid');
  await p.fill('#lp-password','e2e-local-password');
  await p.click('button.lp-submit'); await p.waitForTimeout(5000);

  await p.goto(`${BASE}/entrepreneur/assessments?id=EP-01051`,{waitUntil:'networkidle',timeout:45000});
  await p.waitForTimeout(6000);
  let t=await p.innerText('body');
  console.log('=== workspace opened? chars:',t.length);
  console.log(t.slice(0,900));
  await p.screenshot({path:`${SHOTS}/n02_08_workspace_ep01051.png`,fullPage:true});

  // try clicking the location-evidence step
  const cands = await p.locator('text=/location evidence/i').all();
  console.log('\nlocation-evidence candidates:',cands.length);
  for (const c of cands.slice(0,3)) {
    try { await c.click({timeout:4000}); await p.waitForTimeout(4000);
      const t2=await p.innerText('body');
      console.log(' after click -> Research objectives:', /Research objectives/i.test(t2), '| chars', t2.length);
      await p.screenshot({path:`${SHOTS}/n02_09_after_stage3_click.png`,fullPage:true});
      fs.writeFileSync('backend/var/e2e/n02_stage3_click_text.txt',t2,'utf8');
      break;
    } catch(e){ console.log(' click failed:',e.message.slice(0,60)); }
  }
  console.log('\n=== api ===\n'+(api.slice(-20).join('\n')||'(none)'));
  await b.close();
})().catch(e=>{console.error('ERROR:',e.message);process.exit(1);});
