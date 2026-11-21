// Isolated browser acceptance only. No API response is mocked. The existing
// auth bridge receives a short-lived, privately signed test identity; FastAPI
// still verifies it and reads ownership from the disposable PostgreSQL lab.
const fs = require('node:fs');
const { chromium } = require('playwright');

(async () => {
  const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  if (!/^http:\/\/127\.0\.0\.1:\d+$/.test(cfg.base)) throw Error('Private loopback required');
  const me = await fetch(cfg.base + '/api/v1/auth/me', {headers:{Authorization:'Bearer '+cfg.token}});
  if (!me.ok) throw Error('Private identity rejected: ' + me.status);
  const profile = await me.json();
  const browser = await chromium.launch({headless: process.env.V14_VISIBLE_BROWSER !== '1',
    slowMo: process.env.V14_VISIBLE_BROWSER === '1' ? 450 : 0,
    ...(process.env.PART_TWO_CHROMIUM ? {executablePath:process.env.PART_TWO_CHROMIUM} : {})});
  const page = await browser.newPage({viewport:{width:1440,height:1000}});
  const evidence = {scope:'ISOLATED_TEST_IDENTITY_REAL_HTTP',responses:[],errors:[]};
  page.on('pageerror', e => evidence.errors.push(e.message));
  page.on('response', r => {
    if (r.url().includes('/api/')) evidence.responses.push({method:r.request().method(),path:new URL(r.url()).pathname,status:r.status()});
  });
  // Stop only the real identity SDK from initializing in this private test.
  // Every application API request below goes to the actual running backend.
  await page.route('**/auth_bundle.js', r => r.fulfill({status:200,contentType:'text/javascript',body:'// Isolated test uses the existing bridge interface.'}));
  await page.addInitScript(({token,profile,testLabel}) => {
    async function detailed(path, method, body) {
      const response = await fetch(path, {method:method || 'GET',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},...(body ? {body} : {})});
      const payload = await response.json();
      return response.ok ? {ok:true,body:payload} : {ok:false,status:response.status,code:payload.detail?.code,message:payload.detail?.message || 'Held'};
    }
    window.sitewiseAuth = {
      ready:Promise.resolve(),snapshot:()=>JSON.stringify({configured:true,profile,error:'',user:{id:profile.user_id,email:profile.email}}),
      requestDetailed:async (...args)=>JSON.stringify(await detailed(...args)),
      request:async (...args)=>{const r=await detailed(...args);if(!r.ok)throw Error(r.message);return JSON.stringify(r.body);}
    };
    const mark=()=>{
      if(!document.body || document.getElementById('private-test-identity')) return;
      const banner=document.createElement('aside');banner.id='private-test-identity';
      banner.textContent=testLabel || 'ISOLATED DEVELOPMENT TEST · PRIVATE IDENTITY · NO LIVE FIELDING';
      banner.style.cssText='background:#ffdd81;color:#241700;padding:8px;position:fixed;top:0;right:0;z-index:99999';document.body.append(banner);
    };
    new MutationObserver(mark).observe(document,{childList:true,subtree:true});
    document.addEventListener('DOMContentLoaded',mark);
  }, {token:cfg.token,profile,testLabel:cfg.hellop ? 'TEST_ONLY / NOT_ADOPTED · hellop.txt · NO LIVE FIELDING' : ''});
  try {
    if (cfg.previewObjective) {
      await page.goto(cfg.base+'/entrepreneur/m2-review?assessment='+cfg.assessment+'&confirmation='+cfg.confirmation+'&revision='+cfg.revision);
      await page.getByRole('button',{name:'Load saved research'}).click();
      await page.getByRole('heading',{name:cfg.objective,exact:true}).waitFor();
      await page.screenshot({path:cfg.output+'/confirmed-objective.png',fullPage:true});
      evidence.result='PASS';return;
    }
    if (cfg.ownerReview) {
      await page.goto(cfg.base+'/entrepreneur');
      await page.getByRole('button',{name:'Load assigned research reviews'}).click();
      await page.getByText(/Workflow snapshot .*Model execution: NOT_VERIFIED/).first().waitFor();
      await page.getByLabel('Review rationale').fill(cfg.decision.rationale);
      const response=page.waitForResponse(r=>r.url().endsWith('/owner-review') && r.request().method()==='POST');
      await page.getByRole('button',{name:cfg.decision.decision==='REJECT'?'Reject candidate':'Approve for continued review'}).click();
      const receipt=await (await response).json();
      if(receipt.decision!==cfg.decision.decision || receipt.fielding_authorized!==false || receipt.scientific_acceptance!==false) throw Error('Invalid review receipt');
      await page.getByText(new RegExp(cfg.decision.decision+' ·')).first().waitFor();
      await page.screenshot({path:cfg.output+'/owner-'+cfg.decision.decision+'.png',fullPage:true});
      evidence.result='PASS';return;
    }
    if (cfg.researchReview) {
      await page.goto(cfg.base+'/entrepreneur/m2-review?assessment='+cfg.assessment+'&confirmation='+cfg.confirmation+'&revision=9');
      await page.getByLabel('Research uncertainty').fill('Browser research objective');
      await page.getByRole('button',{name:'Confirm customer research objective',exact:true}).click();
      await page.getByText(/Research objective saved:/).waitFor();
      await page.getByRole('button',{name:'Load saved research'}).click();
      await page.getByRole('heading',{name:'Browser research objective'}).waitFor();
      const clarification=page.locator('section').filter({has:page.getByRole('heading',{name:'Browser missing detail',exact:true})}).last();
      await clarification.getByLabel('Clarification').fill('Compare two specified categories.');
      let saved=page.waitForResponse(r=>r.url().endsWith('/confirmed-revisions') && r.status()===201);
      await clarification.getByRole('button',{name:'Submit clarification'}).click(); await saved;
      const explore=page.locator('section').filter({has:page.getByRole('heading',{name:'Browser proposed exploration',exact:true})}).last();
      saved=page.waitForResponse(r=>r.url().endsWith('/confirmed-revisions') && r.status()===201);
      await explore.getByRole('button',{name:'Confirm broader objective'}).click(); await saved;
      await page.getByRole('button',{name:'Clear preference'}).first().click();
      await page.getByRole('button',{name:'I · Interested',exact:true}).first().click();
      await page.reload();
      await page.getByRole('button',{name:'Load saved research'}).click();
      await page.getByRole('button',{name:'I · Interested (selected)',exact:true}).waitFor();
      await page.getByRole('button',{name:'Load workflow overview'}).click();
      await page.getByText('Scientific review: NOT_VERIFIED',{exact:true}).waitFor();
      await page.screenshot({path:cfg.output+'/research-review.png',fullPage:true});
      evidence.result='PASS';return;
    }
    if (cfg.expectUnavailable) {
      const refused=page.waitForResponse(r=>r.url().includes('/api/v1/m2/')&&r.status()===503);
      await page.goto(cfg.base+'/entrepreneur/activity-history?assessment='+cfg.assessment);
      await refused;
      await page.getByRole('heading',{name:'Activity History',exact:true}).waitFor();
      await page.getByRole('heading',{name:'Activity Timeline — unavailable',exact:true}).waitFor();
      await page.getByRole('heading',{name:'Activity Details',exact:true}).waitFor();
      if(await page.locator('button.sr-event').count()) throw Error('Unavailable source exposed activity rows');
      if(await page.getByText('Activity Timeline (0)',{exact:true}).count()) throw Error('Unavailable source inferred a zero count');
      const filter=page.locator('.sr-filter-field').filter({hasText:'Engine / Module'}).getByRole('combobox');
      if(!await filter.isDisabled()) throw Error('Unavailable filter remains active');
      await page.screenshot({path:cfg.output+'/browser_activity_unavailable.png',fullPage:true});
      evidence.result='PASS';
      return;
    }
    if (cfg.historyIncrement) {
      const response=await fetch(cfg.base+'/api/v1/m2/assessments/'+cfg.assessment+'/activity',
        {headers:{Authorization:'Bearer '+cfg.token}});
      if(!response.ok) throw Error('History source rejected');
      const source=await response.json();
      await page.goto(cfg.base+'/entrepreneur/activity-history?assessment='+cfg.assessment);
      await page.getByRole('heading',{name:'Activity Timeline ('+source.events.length+')',exact:true}).waitFor();
      await page.getByRole('heading',{name:'Workflow history coverage',exact:true}).waitFor();
      await page.getByText('QJ: NOT_VERIFIED — no version-bound research processing/route/review history API.',{exact:true}).waitFor();
      await page.getByText('Latest BCB status snapshots — not attempt history',{exact:true}).waitFor();
      const shown=[];
      while(true) {
        shown.push(...await page.locator('button.sr-event').evaluateAll(nodes=>nodes.map(n=>n.dataset.eventId)));
        const next=page.getByRole('button',{name:'Next',exact:true});
        if(await next.isDisabled()) break;
        await next.click();
      }
      const expected=source.events.map(e=>e.kind+':'+e.event_id);
      if(JSON.stringify(shown)!==JSON.stringify(expected) || new Set(shown).size!==shown.length)
        throw Error('Chronology, pagination or event uniqueness differs from PostgreSQL source');
      const engine=page.locator('.sr-filter-field').filter({hasText:'Engine / Module'}).getByRole('combobox');
      await engine.selectOption('BCB');
      await page.locator('button.sr-event').filter({hasText:'CONTEXT_PERSISTED'}).click();
      await page.getByText('Historical source revision — original outcome retained; not a current handoff.',{exact:true}).waitFor();
      if(await page.getByText('PRIVATE-HISTORY-CONTENT',{exact:false}).count()) throw Error('Private content exposed');
      await page.screenshot({path:cfg.output+'/activity_browser_history.png',fullPage:true});
      evidence.persisted_history={event_ids:shown,source_revision:source.assessment_revision,
        bcb_status:source.bcb_statuses[0]?.status,source_is_current:source.bcb_statuses[0]?.source_is_current,
        authorization_decisions_included:source.authorization_decisions_included};
      await page.goto(cfg.base+'/entrepreneur/activity-history?assessment='+cfg.otherAssessment);
      await page.getByRole('heading',{name:'Activity Timeline — unavailable',exact:true}).waitFor();
      if(await page.locator('button.sr-event').count()) throw Error('Cross-owner or previous-source rows exposed');
      await page.screenshot({path:cfg.output+'/activity_browser_cross_owner.png',fullPage:true});
      if(evidence.errors.length) throw Error('Browser runtime error');
      evidence.result='PASS';
      return;
    }
    await page.goto(cfg.base+'/entrepreneur/m2-entry?assessment='+cfg.assessment);
    if(cfg.createViaUI) {
      const created=page.waitForResponse(r=>new URL(r.url()).pathname==='/api/v1/m2/assessments'&&r.request().method()==='POST');
      await page.getByRole('button',{name:cfg.startLabel || /^Start M2 /,exact:!!cfg.startLabel}).click();
      const response=await created;
      if(response.status()!==201)throw Error('Jaspr assessment creation failed');
      cfg.assessment=(await response.json()).id;
      evidence.created_assessment_id=cfg.assessment;
    }
    await page.getByRole('button',{name:'Save answer',exact:true}).waitFor();
    if(cfg.hellop) {
      await require('./hellop_source_browser.cjs').run(page,cfg,evidence);
      evidence.result='PASS';
      return;
    }
    if (cfg.submitBoundary) {
      const submit=page.getByRole('button',{name:'Submit answers for BDJ review',exact:true});
      const evaluations=()=>evidence.responses.filter(r=>r.path.endsWith('/bdj/evaluate'));
      await page.locator('[data-m2-item="M2-04"]').click();
      await page.locator('textarea[data-m2-answer="M2-04"]').fill('We guarantee profit.');
      if(evaluations().length) throw Error('Typing evaluated BDJ');
      await submit.click();
      await page.getByText('Complete the required answers before submitting for BDJ review: M2-01, M2-05',{exact:true}).waitFor();
      if(evaluations().length) throw Error('Incomplete M2 evaluated BDJ');
      // Reopen the saved questionnaire before continuing: this proves resume
      // comes from persisted answers rather than the original editor state.
      await page.reload();
      await page.getByRole('button',{name:'Save answer',exact:true}).waitFor();
      await page.locator('[data-m2-item="M2-04"]').click();
      const resumed=await page.locator('textarea[data-m2-answer="M2-04"]').inputValue();
      if(resumed!=='We guarantee profit.') throw Error('Saved M2 answer did not resume unchanged');
      evidence.resume={pageReloaded:true,item:'M2-04',value:resumed};
      if(evaluations().length) throw Error('Resuming questionnaire evaluated BDJ');
      await page.locator('[data-m2-item="M2-01"]').click();
      await page.locator('input[name="m2-option"][value="SYNTHETIC_A"]').check();
      // Navigation must persist pending input without evaluating.
      await page.locator('[data-m2-item="M2-05"]').click();
      await page.locator('input[name="m2-state"][value="NOT_DECIDED"]').check();
      if(evaluations().length) throw Error('Question navigation evaluated BDJ');
      const evaluated=page.waitForResponse(r=>r.url().endsWith('/bdj/evaluate'));
      await submit.click();
      const first=await evaluated;
      if(first.status()!==200 || (await first.json()).revision!==3) throw Error('Incorrect submitted revision');
      await page.getByRole('button',{name:'Keep my original answer',exact:true}).click();
      await page.getByRole('button',{name:'Record that I reviewed this revision',exact:true}).click();
      await page.getByText('Review recorded for revision 3.',{exact:true}).waitFor();
      if(evaluations().length!==1) throw Error('Finding decision reevaluated BDJ');
      await page.getByRole('button',{name:'Confirm this business information',exact:true}).click();
      await page.getByText('Your confirmation snapshot was saved.',{exact:true}).waitFor();
      await page.screenshot({path:cfg.output+'/browser_m2_confirmed_revision3.png',fullPage:true});
      // A correction invalidates the displayed worksheet; submission evaluates
      // only the newly saved revision, retaining the older immutable snapshot.
      await page.locator('[data-m2-item="M2-04"]').click();
      await page.locator('textarea[data-m2-answer="M2-04"]').fill('An entrepreneur correction after review.');
      if(await page.getByRole('button',{name:'Confirm this business information',exact:true}).count()) throw Error('Unsaved correction retained confirmation action');
      const revised=page.waitForResponse(r=>r.url().endsWith('/bdj/evaluate'));
      await submit.click();
      const second=await revised;
      if(second.status()!==200 || (await second.json()).revision!==4) throw Error('Correction evaluated wrong revision');
      await page.getByRole('button',{name:'Record that I reviewed this revision',exact:true}).click();
      await page.getByText('Review recorded for revision 4.',{exact:true}).waitFor();
      await page.getByRole('button',{name:'Confirm this business information',exact:true}).click();
      await page.getByText('Your confirmation snapshot was saved.',{exact:true}).waitFor();
      await page.screenshot({path:cfg.output+'/browser_m2_confirmed_revision4.png',fullPage:true});
      if(evaluations().length!==2 || evidence.errors.length) throw Error('Unexpected evaluations or browser errors');
      evidence.result='PASS';
      return;
    }
    if (!cfg.activityOnly) {
      for (const [item,value] of [['M2-01','SYNTHETIC_A'],['M2-04','Browser-authored fictional cafe for isolated integration.'],['M2-05','TAKEAWAY_FOCUSED']]) {
        await page.locator('[data-m2-item="'+item+'"]').click();
        if(item==='M2-04') await page.locator('textarea[data-m2-answer="M2-04"]').fill(value);
        else await page.locator('input[name="m2-option"][value="'+value+'"]').check();
        const saved=page.waitForResponse(r=>r.url().endsWith('/answers/'+item)&&r.request().method()==='PUT');
        await page.getByRole('button',{name:'Save answer',exact:true}).click();
        if((await saved).status()!==200) throw Error('Answer save failed');
        await page.getByRole('button',{name:'Save answer',exact:true}).waitFor({state:'visible'});
        await page.waitForFunction(()=>!document.querySelector('button[disabled]')?.textContent?.includes('Save answer'));
        await page.getByRole('status').filter({hasText:'Answer saved at revision'}).waitFor();
      }
      await page.getByRole('button',{name:'Submit answers for BDJ review',exact:true}).click();
      await page.getByText('No candidate findings from the checked rules.',{exact:false}).waitFor();
      await page.getByRole('button',{name:'Record that I reviewed this revision',exact:true}).click();
      await page.getByText('Review recorded for revision 3.',{exact:true}).waitFor();
      await page.getByRole('button',{name:'Confirm this business information',exact:true}).click();
      await page.getByText('Your confirmation snapshot was saved.',{exact:true}).waitFor();
      await page.screenshot({path:cfg.output+'/browser_m2_confirmed.png',fullPage:true});
    }
    await page.goto(cfg.base+'/entrepreneur/activity-history');
    await page.getByRole('combobox',{name:'Saved M2 assessment'}).selectOption(cfg.assessment);
    const savedHistory=await (await fetch(cfg.base+'/api/v1/m2/assessments/'+cfg.assessment+'/activity',
      {headers:{Authorization:'Bearer '+cfg.token}})).json();
    await page.getByRole('heading',{name:'Activity Timeline ('+savedHistory.events.length+')',exact:true}).waitFor();
    await page.locator('button.sr-event').filter({hasText:'ANSWER_SAVED'}).first().click();
    await page.getByRole('heading',{name:'ANSWER_SAVED',exact:true}).waitFor();
    const engine=page.locator('.sr-filter-field').filter({hasText:'Engine / Module'}).getByRole('combobox');
    await engine.selectOption('Question Bank / QG');
    await page.getByText('No recorded activity matches these filters.',{exact:true}).waitFor();
    await engine.selectOption('Business Understanding');
    await page.locator('button.sr-event').filter({hasText:'CONTEXT_CONFIRMED'}).click();
    await page.getByRole('heading',{name:'CONTEXT_CONFIRMED',exact:true}).waitFor();
    await page.locator('#private-test-identity').waitFor();
    await page.getByRole('button',{name:'Refresh saved activity',exact:true}).click();
    await page.getByRole('heading',{name:'CONTEXT_CONFIRMED',exact:true}).waitFor();
    await page.screenshot({path:cfg.output+'/browser_activity.png',fullPage:true});
    evidence.result='PASS';
  } catch(e) {
    evidence.result='FAIL'; evidence.failure=e.stack;
    await page.screenshot({path:cfg.output+'/browser_failure.png',fullPage:true});
    throw e;
  } finally {
    fs.writeFileSync(cfg.output+(cfg.ownerReview?'/owner-'+cfg.decision.decision+'.json':cfg.expectUnavailable?'/browser_http_unavailable.json':'/browser_http.json'),JSON.stringify(evidence,null,2));
    await browser.close();
  }
})().catch(e=>{console.error(e);process.exitCode=1;});
