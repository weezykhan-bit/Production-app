const { chromium } = require('playwright'); const http = require('http'), fs = require('fs'), path = require('path');
// Demo walk-through of agreement templates and clause questions, desktop and phone.
// Usage: MAMMOTH=<path to mammoth.browser.min.js> node tests/demo-agreements.cjs   (screenshots go to the system temp folder)
const root = path.join(__dirname, '..', 'central'), D = require('os').tmpdir() + '/crewdesk-ag-', FX = path.join(__dirname, 'fixtures') + '/';
const srv = http.createServer((q, r) => { const f = path.join(root, q.url.split('?')[0] === '/' ? 'index.html' : q.url.split('?')[0]); fs.readFile(f, (e, d) => { if (e) { r.writeHead(404); return r.end(); } r.writeHead(200, {'content-type': f.endsWith('.js') ? 'application/javascript' : 'text/html'}); r.end(d); }); }).listen(5196);
const as = (p, who, view, pid = 'p_saath') => p.evaluate(([w, v, pid]) => { S.session = w; U.pid = pid; U.view = v; U.drawer = null; U.modal = null; U.agTab = 'people'; render(); renderLayer(); }, [who, view, pid]);
(async () => { const b = await chromium.launch(), errs = [], chk = (c, l) => { if (!c) errs.push('FAIL ' + l); else console.log('ok', l); };
  for (const [w, h, tag] of [[1280, 860, 'desk'], [390, 844, 'phone']]){
    const p = await b.newPage({viewport:{width:w, height:h}}); p.on('pageerror', e => errs.push(tag + ': ' + e.message)); p.on('dialog', d => d.accept());
    await p.route(/fonts\./, r => r.abort());
    await p.route(/jsdelivr.*mammoth/, r => r.fulfill({path:process.env.MAMMOTH, contentType:'application/javascript'}));
    await p.route(/jsdelivr.*xlsx/, r => r.abort());
    await p.goto('http://localhost:5196/'); await p.evaluate(() => localStorage.clear()); await p.reload(); await p.waitForTimeout(300);
    // Dev: an open question blocks signing; he asks another
    await as(p, 'u_dev', 'home');
    await p.evaluate(() => document.querySelectorAll('details.sec').forEach(d => d.open = true));
    chk(await p.locator('.banner:has-text("Signing opens once")').count() === 1, tag + ' signing waits for the open question');
    chk(await p.locator('form[data-form=sign]').count() === 0, tag + ' no sign form while open');
    chk(await p.locator('.cl-ask').count() >= 8, tag + ' every numbered clause has Ask');
    await p.click('.cl-ask[data-cl="7"]'); await p.fill('#aq-body', 'Can I post set photos after release?'); await p.click('form[data-form=ag-ask] button[type=submit]'); await p.waitForTimeout(80);
    chk(await p.evaluate(() => S.agQueries.filter(q => q.status === 'open').length) === 2, tag + ' question raised');
    await p.screenshot({path:D + tag + '-dev-ask.png', fullPage:false});
    // Leela: todos, reply, keep a clause, change the agreement
    await as(p, 'u_leela', 'home');
    chk(await p.evaluate(() => todos('p_saath', 'u_leela').filter(t => t.t.startsWith('Answer')).map(t => t.t).join()) === 'Answer Dev Malhotra’s question on clause 7', tag + ' Legal’s to-do is only the question waiting on the office');
    chk(await p.evaluate(() => todos('p_saath', 'u_dev').some(t => t.t === 'Reply on clause 2 of your agreement')), tag + ' Dev’s to-do is the one waiting on him');
    await as(p, 'u_leela', 'agreements');
    chk(await p.locator('.banner:has-text("1 question")').count() === 1, tag + ' agreements banner counts what waits on the office');
    await p.evaluate(() => { U.drawer = {type:'person', id:S.members.find(m => m.userId === 'u_dev' && m.pid === 'p_saath').id}; renderLayer(); });
    const q2 = await p.evaluate(() => S.agQueries.find(q => q.clause === '7').id);
    await p.fill(`#qn-${q2}`, 'Only with written permission.'); await p.click(`form[data-form=ag-note][data-id="${q2}"] button`); await p.waitForTimeout(80);
    await p.evaluate(() => { U.drawer = {type:'person', id:S.members.find(m => m.userId === 'u_dev' && m.pid === 'p_saath').id}; renderLayer(); });
    await p.click(`[data-act=ag-keep][data-id="${q2}"]`); await p.fill('#ak-reason', 'Posting stays off until the channel allows it.'); await p.click('form[data-form=ag-keep] button[type=submit]'); await p.waitForTimeout(80);
    chk(await p.evaluate(q => S.agQueries.find(x => x.id === q).status === 'kept' && S.agQueries.find(x => x.id === q).notes.length === 1, q2), tag + ' reply and keep');
    await p.evaluate(() => { U.drawer = {type:'person', id:S.members.find(m => m.userId === 'u_dev' && m.pid === 'p_saath').id}; renderLayer(); });
    await p.click('.agq.open [data-act=ag-revise]');
    await p.evaluate(() => { const t = document.querySelector('#ar-text'); t.value = t.value.replace('2. FEE.', '2. FEE. Half the fee is paid if a call is cancelled after the Artist reports.'); });
    await p.fill('#ar-note', 'Clause 2: half fee for a cancelled call'); await p.screenshot({path:D + tag + '-revise.png'});
    await p.click('form[data-form=ag-revise] button[type=submit]'); await p.waitForTimeout(80);
    chk(await p.evaluate(() => { const m = S.members.find(m => m.userId === 'u_dev' && m.pid === 'p_saath'); return m.ag.version === 2 && S.agQueries.find(q => q.id === 'q_dev1').status === 'changed'; }), tag + ' version 2 closes the fee question');
    await p.evaluate(() => { U.drawer = {type:'person', id:S.members.find(m => m.userId === 'u_dev' && m.pid === 'p_saath').id}; renderLayer(); });
    await p.click('.drawer [data-act=ag-diff]'); await p.waitForTimeout(60);
    chk(await p.locator('.drawer .agdiff ins').count() === 1 && await p.locator('.drawer .agdiff del').count() === 1, tag + ' what changed shows one paragraph');
    await p.screenshot({path:D + tag + '-drawer.png'});
    // Dev signs version 2
    await as(p, 'u_dev', 'home'); await p.evaluate(() => document.querySelectorAll('details.sec').forEach(d => d.open = true));
    chk(await p.locator('form[data-form=sign] button[type=submit]:has-text("Sign version 2")').count() === 1, tag + ' sign version 2');
    await p.fill('#sg-name', 'Dev Malhotra'); await p.locator('#sig').scrollIntoViewIfNeeded(); const c = await p.locator('#sig').boundingBox(); await p.mouse.move(c.x + 20, c.y + 20); await p.mouse.down(); await p.mouse.move(c.x + 120, c.y + 40); await p.mouse.up();
    await p.click('form[data-form=sign] button[type=submit]'); await p.waitForTimeout(150);
    chk(await p.evaluate(() => S.members.find(m => m.userId === 'u_dev' && m.pid === 'p_saath').ag.status === 'signed'), tag + ' Dev signed');
    await p.evaluate(() => { window.print = () => { window.__printed = document.querySelector('#printout').innerText; }; document.querySelectorAll('details.sec').forEach(d => d.open = true); });
    await p.click('[data-act=ag-verify]'); await p.waitForTimeout(150); chk((await p.textContent('[id^=agv-]')).startsWith('✓'), tag + ' fingerprint check passes');
    await p.evaluate(() => { memberIn('p_saath', 'u_dev').ag.text += ' tampered'; render(); document.querySelectorAll('details.sec').forEach(d => d.open = true); });
    await p.click('[data-act=ag-verify]'); await p.waitForTimeout(150); chk((await p.textContent('[id^=agv-]')).startsWith('✕'), tag + ' fingerprint check catches a changed text');
    await p.evaluate(() => { const a = memberIn('p_saath', 'u_dev').ag; a.text = a.text.replace(/ tampered$/, ''); render(); document.querySelectorAll('details.sec').forEach(d => d.open = true); });
    await p.click('[data-act=ag-print]'); await p.waitForTimeout(300); const pr = await p.evaluate(() => window.__printed || '');
    chk(pr.includes('Half the fee is paid') && pr.includes('SHA-256 fingerprint') && pr.includes('Questions asked before signing') && pr.includes('Clause 2: half fee'), tag + ' printable record has text, fingerprint, versions and questions');
    await p.click('[data-act=ag-read]'); await p.waitForTimeout(80); chk(await p.locator('.dlg-ag-read .ag-full').count() === 1, tag + ' full-screen reader opens'); await p.screenshot({path:D + tag + '-read.png'}); await p.keyboard.press('Escape');
    // Legal uploads a cast template from Word; can't approve own; Ritika approves; assigned to the cast list
    await as(p, 'u_leela', 'agreements'); await p.click('[data-act=agtab][data-id=templates]');
    chk(await p.locator('.tplcard').count() === 5, tag + ' five templates in the library');
    chk(await p.locator('.tplcard:has-text("Sample:") [data-act=tpl-approve]').count() === 0, tag + ' samples can’t be approved untouched');
    await p.screenshot({path:D + tag + '-templates.png', fullPage:true});
    await p.click('[data-act=tpl-new]'); await p.selectOption('#tp-kind', 'cast');
    await p.setInputFiles('input[data-change=tpl-file]', FX + 'cast-auto-numbered.docx'); await p.waitForFunction(() => document.querySelector('#tp-body').value.includes('{{legal_name}}'), null, {timeout:20000}).catch(() => {});
    const read = await p.inputValue('#tp-body'); chk(read.includes('{{legal_name}}') && read.includes('\n\n1. ROLE.') && read.includes('\n\n6. LAW.') && (await p.inputValue('#tp-name')) === 'cast auto numbered', tag + ' docx read with Word’s automatic numbering kept');
    await p.fill('#tp-name', 'Swastik cast 2026');
    await p.evaluate(() => { const t = document.querySelector('#tp-body'); t.value += '\n\n7. NICKNAME. {{nickname}}'; t.dispatchEvent(new Event('input', {bubbles:true})); });
    chk((await p.textContent('#tp-warn')).includes('{{nickname}}'), tag + ' unknown blank flagged');
    await p.click('form[data-form=tpl] button[type=submit]'); chk((await p.textContent('#tp-err')).includes('nickname'), tag + ' save refused with unknown blank');
    await p.evaluate(() => { const t = document.querySelector('#tp-body'); t.value = t.value.replace('\n\n7. NICKNAME. {{nickname}}', ''); t.setSelectionRange(t.value.length, t.value.length); });
    await p.click('details.blanks summary'); await p.click('[data-act=tpl-blank][data-id=today]');
    await p.click('[data-act=tpl-preview]'); chk((await p.textContent('#tp-prev')).includes('Dev Malhotra'), tag + ' preview uses a cast member');
    await p.screenshot({path:D + tag + '-tpl-edit.png'});
    await p.click('form[data-form=tpl] button[type=submit]'); await p.waitForTimeout(80);
    const tid = await p.evaluate(() => S.templates.find(t => t.name === 'Swastik cast 2026')?.id); chk(!!tid, tag + ' template saved');
    chk(await p.locator(`[data-act=tpl-approve][data-id="${tid}"]`).count() === 0, tag + ' Legal can’t approve their own upload');
    await p.evaluate(() => { S.session = 'u_ritika'; render(); }); await p.click(`[data-act=tpl-approve][data-id="${tid}"]`); await p.waitForTimeout(60);
    await p.selectOption('select[data-change=tpl-assign][data-id=cast]', tid); await p.waitForTimeout(60);
    chk(await p.evaluate(t => S.prodTemplates.some(x => x.pid === 'p_saath' && x.kind === 'cast' && x.templateId === t), tid), tag + ' cast list uses it');
    // send to a cast member who is ready
    const mid = await p.evaluate(() => { const m = S.members.find(m => m.userId === 'u_sana'); const u = user('u_sana'); Object.assign(u, {legal:'Sana Mirza', pan:'SMZPM1122K', address:'Juhu, Mumbai', bank:{holder:'Sana Mirza', name:'HDFC Bank', acct:'50100123499887', ifsc:'HDFC0000060'}, aadhaar4:'1111', docs:{aadhaar:'sample', pan:'sample'}, consent:true, emergency:'x'});
      Object.assign(m, {kind:'cast', dept:'Cast', job:'Day Player'}); m.ag = {status:'none'}; return m.id; });
    await as(p, 'u_leela', 'agreements'); await p.click(`[data-act=send-ag][data-id="${mid}"]`); await p.waitForTimeout(60);
    const prev = await p.textContent('#sa-prev'); chk(prev.includes('SWASTIK CAST AGREEMENT') && prev.includes('••••••122K') && prev.includes('account ending 9887') && !prev.includes('{{'), tag + ' send preview filled from the cast template');
    await p.screenshot({path:D + tag + '-send.png'});
    await p.click('form[data-form=send-ag] button[type=submit]'); await p.waitForTimeout(60);
    chk(await p.evaluate(m => { const a = S.members.find(x => x.id === m).ag; return a.status === 'sent' && a.version === 1 && a.text.includes('SWASTIK CAST'); }, mid), tag + ' sent from the template');
    const o = await p.evaluate(() => document.documentElement.scrollWidth - innerWidth); if (o > 1) errs.push(tag + ' sideways ' + o);
    await p.close();
  }
  console.log(errs.join('\n') || 'NO ERRORS'); await b.close(); srv.close(); process.exit(errs.length ? 1 : 0); })();
