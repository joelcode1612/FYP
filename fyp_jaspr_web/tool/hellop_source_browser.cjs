// Existing compiled Jaspr M2 controls; test driver only, no questionnaire engine.
const fs=require('node:fs');
exports.run=async(page,cfg,evidence)=>{
  const {source,answers}=cfg.hellop;
  const evaluationCount=()=>evidence.responses.filter(r=>r.path.endsWith('/bdj/evaluate')).length;
  const activeKeys=source.items.filter(i=>i.lifecycle==='ACTIVE'&&i.answer_kind!=='ACTION').map(i=>i.item_key);
  const actualKeys=await page.locator('[data-m2-item]').evaluateAll(nodes=>nodes.map(n=>n.dataset.m2Item));
  if(JSON.stringify(activeKeys)!==JSON.stringify(actualKeys))throw Error('Source item order, deferred item or action visibility mismatch');
  if(await page.getByRole('button',{name:'Confirm this business information',exact:true}).count())throw Error('Unexpected prior-confirmation control');
  await page.screenshot({path:cfg.output+'/browser_hellop_initial_question.png',fullPage:true});
  await page.getByRole('button',{name:'Submit answers for BDJ review',exact:true}).click();
  await page.getByRole('alert').filter({hasText:'Complete the required answers'}).waitFor();
  if(evaluationCount())throw Error('Incomplete answers invoked BDJ');
  let revision=0;
  for(const answer of answers){
    await page.locator('[data-m2-item="'+answer.item_key+'"]').click();
    const heading=await page.locator('.asw-q__prompt').textContent();
    if(heading!==answer.question_text)throw Error('Source wording/conditions changed: '+answer.item_key);
    const shown=await page.locator('input[name="m2-option"]').evaluateAll(nodes=>nodes.map(n=>n.value));
    if(JSON.stringify(shown)!==JSON.stringify(answer.options))throw Error('Source option wording/order changed: '+answer.item_key);
    if(answer.answer_state!=='ANSWERED'){
      await page.locator('input[name="m2-state"][value="'+answer.answer_state+'"]').check();
    }else if(answer.kind==='TEXT'){
      await page.locator('textarea[data-m2-answer="'+answer.item_key+'"]').fill(answer.value);
    }else{
      for(const value of Array.isArray(answer.value)?answer.value:[answer.value]){
        await page.getByRole(answer.kind==='MULTI'?'checkbox':'radio',{name:value,exact:true}).check();
      }
    }
    if(evaluationCount())throw Error('Answering invoked BDJ');
    const saved=page.waitForResponse(r=>r.request().method()==='PUT'&&r.url().endsWith('/answers/'+answer.item_key));
    await page.getByRole('button',{name:'Save answer',exact:true}).click();
    const response=await saved;const body=await response.json();revision++;
    if(response.status()!==200||body.assessment_revision!==revision)throw Error('Save revision mismatch');
    await page.getByText('Answer saved at revision '+revision+'.',{exact:true}).waitFor();
    if(answer.item_key==='M2-07')await page.screenshot({path:cfg.output+'/browser_hellop_primary_group_gap.png',fullPage:true});
    if(answer.item_key==='M2-15')await page.screenshot({path:cfg.output+'/browser_hellop_privacy_skipped.png',fullPage:true});
  }
  if(revision!==20||evaluationCount())throw Error('Premature evaluation or missing answer saves');
  await page.goto(cfg.base+'/entrepreneur/m2-entry?assessment='+cfg.assessment);
  await page.getByRole('button',{name:'Save answer',exact:true}).waitFor();
  await page.locator('[data-m2-item="M2-04"]').click();
  const original=answers.find(a=>a.item_key==='M2-04').value;
  if(await page.locator('textarea').inputValue()!==original)throw Error('Saved exact value failed resume');
  await page.screenshot({path:cfg.output+'/browser_hellop_resumed.png',fullPage:true});
  const evaluate=async expected=>{
    const pending=page.waitForResponse(r=>r.url().endsWith('/bdj/evaluate'));
    await page.getByRole('button',{name:'Submit answers for BDJ review',exact:true}).click();
    const response=await pending;const worksheet=await response.json();
    if(response.status()!==200||worksheet.revision!==expected)throw Error('BDJ did not evaluate saved revision');
    await page.getByRole('heading',{name:'Business description review',exact:true}).waitFor();
    return worksheet;
  };
  const first=await evaluate(20);
  if(!first.findings.some(f=>f.rule_id==='UNSUPPORTED_PROFIT_GUARANTEE'))throw Error('Expected deterministic source finding missing');
  while(await page.getByRole('button',{name:'Keep my original answer',exact:true}).count()){
    // This case intentionally contains exactly one candidate issue.
    const decision=page.waitForResponse(r=>r.url().endsWith('/decisions'));
    await page.getByRole('button',{name:'Keep my original answer',exact:true}).first().click();
    if((await decision).status()!==200)throw Error('Finding decision failed');
    break;
  }
  const reviewConfirm=async rev=>{
    await page.getByRole('button',{name:'Record that I reviewed this revision',exact:true}).click();
    await page.getByText('Review recorded for revision '+rev+'.',{exact:true}).waitFor();
    const confirmed=page.waitForResponse(r=>r.url().endsWith('/confirm'));
    await page.getByRole('button',{name:'Confirm this business information',exact:true}).click();
    if((await confirmed).status()!==200)throw Error('Confirmation failed');
    await page.getByText('Your confirmation snapshot was saved.',{exact:true}).waitFor();
  };
  await reviewConfirm(20);
  await page.screenshot({path:cfg.output+'/browser_hellop_review_confirmed20.png',fullPage:true});
  await page.locator('[data-m2-item="M2-04"]').click();
  const correction='TEST_ONLY fictional plan: A small café serving coffee and pastries to nearby residents.';
  await page.locator('textarea[data-m2-answer="M2-04"]').fill(correction);
  if(await page.getByRole('button',{name:'Confirm this business information',exact:true}).count())throw Error('Correction retained old worksheet');
  const second=await evaluate(21);
  if(second.findings.length)throw Error('Corrected text retained a historical candidate issue');
  await reviewConfirm(21);
  if(evaluationCount()!==2)throw Error('Unexpected BDJ calls while answering/reviewing');
  await page.screenshot({path:cfg.output+'/browser_hellop_review_confirmed21.png',fullPage:true});
  evidence.hellop={label:source.label,source_sha256:source.source_sha256,
    production_authority:source.production_authority,visible_answer_fields:activeKeys,
    inputs:answers,confirmation_revisions:[20,21],evaluation_revisions:[20,21],
    bdj_calls_during_answering:0,correction,source_condition_conformance:'PARTIAL_SEE_EXPLICIT_GAPS',
    source_gaps:source.known_representation_gaps};
  fs.writeFileSync(cfg.output+'/hellop_browser_values.json',JSON.stringify(evidence.hellop,null,2));
  if(evidence.errors.length)throw Error('Browser runtime error');
};
