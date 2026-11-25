// Capture the real /bdj/current response the Stage 4 panel consumes, plus the
// composed-questionnaire document, using the page's own session.
const { openPage } = require('./cdp.js');

(async () => {
  const page = await openPage('/entrepreneur/assessments');

  const storage = await page.evaluate(`(() => {
    const dump = (s) => {
      const out = {};
      for (let i = 0; i < s.length; i++) {
        const k = s.key(i);
        const v = s.getItem(k);
        out[k] = v && v.length > 60 ? v.slice(0, 60) + '...(' + v.length + ')' : v;
      }
      return out;
    };
    return { local: dump(localStorage), session: dump(sessionStorage), cookie: document.cookie };
  })()`);
  console.log('=== storage keys ===');
  console.log(JSON.stringify(storage, null, 2).slice(0, 2000));

  // Find a token: try the common keys.
  const token = await page.evaluate(`(() => {
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i);
      if (!k.startsWith('sb-') || !k.endsWith('-auth-token')) continue;
      try {
        const v = JSON.parse(localStorage.getItem(k));
        if (v && v.access_token) return { key: k, value: v.access_token };
      } catch (e) {}
    }
    return null;
  })()`);
  console.log('\n=== token ===', token ? token.key + ' len=' + token.value.length : 'none');

  const q = (u) =>
    page.evaluate(`(async () => {
      const r = await fetch(${JSON.stringify(u)}, {
        headers: { Authorization: 'Bearer ' + ${JSON.stringify(token ? token.value : '')} },
      });
      const t = await r.text();
      return { status: r.status, body: t };
    })()`);

  const m2 = '0f958d15-c629-4df4-90b1-ba444e042612';
  const conf = 'd5a72e84-c653-4b16-b225-3de857009b45';

  const bdj = await q(`/api/v1/m2/assessments/${m2}/bdj/current?confirmation_id=${conf}&expected_revision=24`);
  console.log('\n=== /bdj/current status:', bdj.status, '===');
  console.log(bdj.body.slice(0, 3000));

  const composed = await q(`/api/v1/project1-workflow/assessments/${m2}/stage5/composed-questionnaire?expected_revision=24&confirmation_id=${conf}`);
  console.log('\n=== /stage5/composed-questionnaire status:', composed.status, '===');
  if (composed.status === 200) {
    const doc = JSON.parse(composed.body);
    console.log(JSON.stringify({
      contract_version: doc.contract_version,
      composition_status: doc.composition_status,
      sections: (doc.sections || []).map((s) => ({ id: s.section_id, items: (s.items || []).length })),
      additional_status: doc.additional_status,
      admitted_objective_count: doc.admitted_objective_count,
      publication_readiness: doc.publication_readiness,
      fielding_authorized: doc.fielding_authorized,
      publication_authorized: doc.publication_authorized,
      scientifically_accepted: doc.scientifically_accepted,
      customer_fielding_enabled: doc.customer_fielding_enabled,
      report_release_authorized: doc.report_release_authorized,
      unresolved: (doc.unresolved_requirements || []).map((r) => r.code + '/' + (r.item_id || r.scope)),
      excluded: (doc.excluded_candidates || []).map((c) => c.code),
    }, null, 2));
  } else {
    console.log(composed.body.slice(0, 800));
  }
  process.exit(0);
})().catch((e) => {
  console.error('FAILED:', e && e.message ? e.message : e);
  process.exit(1);
});
