// End-to-end test of the live app: the real screens in Chromium, the real database schema and rules
// running in PGlite (Postgres compiled to WebAssembly) in place of Supabase.
// Usage: PGLITE=<path to @electric-sql/pglite dist/index.js> XLSX=<path to xlsx.full.min.js> node tests/live-e2e.mjs
import fs from 'fs'; import path from 'path';
import { chromium, db, pg, server, FAKE, ROOT } from './harness.mjs';

const errs = [], ok = m => console.log('  ok ' + m);
const b = await chromium.launch();
const ctx = await b.newContext({viewport:{width:1280, height:900}, acceptDownloads:true});
await ctx.exposeFunction('pgCall', async (op, a) => { try { return await pg(op, a); } catch (e) { return {__error:e.message}; } });
await ctx.addInitScript(FAKE);
const p = await ctx.newPage();
p.on('pageerror', e => errs.push('page error: ' + e.message)); p.on('response', r => { if (r.status() === 404) errs.push('404 ' + r.url().slice(0, 120)); });
p.on('console', m => { if (m.type() === 'error' && !/fonts\.g|ERR_FAILED/.test(m.text())) errs.push('console: ' + m.text()); });
await p.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
await p.route(/cdn\.jsdelivr\.net\/npm\/xlsx/, r => r.fulfill({path:process.env.XLSX, contentType:'application/javascript'}));
const click = async s => { await p.click(s); await p.waitForTimeout(150); };
const fill = async (o) => { for (const [k, v] of Object.entries(o)) await p.fill('#' + k, String(v)); };
const over = async tag => { const o = await p.evaluate(() => document.documentElement.scrollWidth - innerWidth); if (o > 1) errs.push(`sideways scroll ${o}px at ${tag}`); };
const text = async s => (await p.textContent(s)) || '';
const pwOpen = () => p.evaluate(() => { const d = document.querySelector('.pwbox'); if (d && !d.open){ d.open = true; d.dispatchEvent(new Event('toggle')); } });
const signIn = async login => { await p.goto('http://localhost:5188/'); await p.waitForSelector('.login-form'); await pwOpen(); await fill({'li-user':login, 'li-pass':'whatever123'}); await click('form[data-form=login] button[type=submit]'); await p.waitForTimeout(400); };
const signOut = async () => { await p.keyboard.press('Escape'); await p.keyboard.press('Escape'); await click('.me'); await click('.menu [data-act=logout]'); await p.waitForSelector('.login-form'); };
const ev = (f, a) => p.evaluate(f, a);
const IMG = path.join(ROOT, 'icon.svg');
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64');
fs.writeFileSync('/tmp/crewdesk-test.png', png);

try {
  // 1. Owner: one-time company setup, then the first production
  await signIn('fowzan'); await over('company setup');
  if (!(await text('h1')).includes('company details')) throw new Error('owner was not sent to company setup');
  await fill({'co-legal':'Test Films Pvt Ltd', 'co-pan':'AABCT1234K', 'co-tan':'MUMT12345A', 'co-addr':'Andheri West, Mumbai', 'co-bank':'HDFC Bank', 'co-acct':'50200011112222', 'co-ifsc':'HDFC0000212'});
  await click('form[data-form=company] button[type=submit]');
  await p.waitForSelector('#np-name'); ok('company saved; production form opened');
  await fill({'np-name':'Saath Phere', 'np-eps':400, 'np-loc':'Umargam · Floor 3'}); await p.selectOption('#np-status', 'Shooting');
  await click('form[data-form=project] button[type=submit]'); await p.waitForSelector('.codegen .code');
  const code = (await text('.codegen .code')).trim(); ok('production created with code ' + code);
  // onboard two people before they have accounts
  for (const o of [{n:'Imran Shaikh', ph:'99300 18842', d:'Camera', j:'1st AC / Focus Puller', r:4500, role:'crew'}, {n:'Manoj Patil', em:'manoj@test.in', d:'Production', j:'Line Producer', r:9000, role:'lp'}]){
    await click('[data-act=onboard]'); await fill({'ob-name':o.n, 'ob-rate':o.r}); if (o.ph) await p.fill('#ob-phone', o.ph); if (o.em) await p.fill('#ob-email', o.em);
    await p.selectOption('#ob-dept', o.d); await p.selectOption('#ob-job', o.j); await p.selectOption('#ob-role', o.role);
    await click('form[data-form=onboard] button[type=submit]');
    if (!(await p.$('.dialog pre'))) throw new Error('invite message not shown: ' + await text('#ob-err').catch(() => ''));
    if (!(await text('.dialog pre')).includes(code.slice(0, 4))) errs.push('invite message lacks the code'); await click('.dialog [data-act=close-modal]');
  }
  ok('two invites created');
  await click('.rail [data-id=schedule]'); await click('[data-act=plan]');
  await fill({'pl-from':await ev(() => isoD(dayOff(-6))), 'pl-to':await ev(() => isoD(dayOff(6))), 'pl-ep':300});
  await click('form[data-form=plan] button[type=submit]');
  const days = await ev(() => S.days.length); if (days < 10) throw new Error('planning failed: ' + days); ok(`planned ${days} shoot days`); await over('schedule');
  await signOut();

  // 2. Line Producer signs up and joins; the invite matched by email gives LP access
  // typed details survive a failed sign-in, a redraw and switching tabs
  await p.goto('http://localhost:5188/'); await p.waitForSelector('.gbtn');
  if (await p.isVisible('#li-user')) errs.push('password form should fold away when Google is on');
  await pwOpen(); await fill({'li-user':'manoj.typo', 'li-pass':'wrongpass1'}); await click('form[data-form=login] button[type=submit]'); await p.waitForTimeout(300);
  await ev(() => render()); await click('[data-act=auth][data-id=signup]'); await click('[data-act=auth][data-id=in]');
  const kept = await ev(() => [document.getElementById('li-user').value, document.getElementById('li-pass').value, document.getElementById('li-err').textContent]);
  if (kept[0] !== 'manoj.typo' || kept[1] !== 'wrongpass1' || !(await p.isVisible('#li-user'))) errs.push('sign-in details were lost: ' + JSON.stringify(kept)); else ok('sign-in details kept after an error, a redraw and switching tabs');
  await click('[data-act=auth][data-id=signup]'); await pwOpen();
  await fill({'su-name':'Manoj Patil', 'su-phone':'98330 44120', 'su-email':'manoj@test.in', 'su-user':'manoj', 'su-pass':'longpassword'});
  await click('form[data-form=signup] button[type=submit]'); if (!(await text('h2')).includes('Check your email')) throw new Error('sign-up did not ask to confirm email');
  await signIn('manoj'); await fill({'join-code':code}); await click('form[data-form=join] button[type=submit]');
  if (await ev(() => myRole()) !== 'lp') throw new Error('Manoj did not get Line Producer access'); ok('LP joined and took up the invite');
  await signOut();

  // 3. Crew member signs up with the invited mobile number, joins, fills profile and documents
  await click('[data-act=auth][data-id=signup]'); await pwOpen();
  await fill({'su-name':'Imran Shaikh', 'su-phone':'9930018842', 'su-email':'imran@test.in', 'su-user':'imran', 'su-pass':'longpassword'});
  await click('form[data-form=signup] button[type=submit]'); await signIn('imran');
  await fill({'join-code':code.toLowerCase()}); await click('form[data-form=join] button[type=submit]');
  if (!(await text('h1')).includes('onboarding')) throw new Error('crew did not land on My setup'); await over('my setup');
  await p.setInputFiles('input[data-upload=photo]', '/tmp/crewdesk-test.png'); await p.waitForTimeout(500);
  await fill({'pf-legal':'Imran Shaikh', 'pf-addr':'Jogeshwari West, Mumbai', 'pf-pan':'FHSPS3349D', 'pf-holder':'Imran Shaikh', 'pf-bank':'Axis Bank', 'pf-acct':'917010023456789', 'pf-ifsc':'UTIB0000071'});
  await click('form[data-form=profile] button[type=submit]');
  await p.setInputFiles('input[data-upload=aadhaar]', '/tmp/crewdesk-test.png'); await p.waitForFunction(() => !!me().docs.aadhaar, null, {timeout:5000});
  await p.setInputFiles('input[data-upload=pan]', '/tmp/crewdesk-test.png'); await p.waitForFunction(() => !!me().docs.pan, null, {timeout:5000});
  await p.fill('#dc-a4', '1234'); await p.check('#dc-consent'); await click('form[data-form=docs] button[type=submit]');
  const ready = await ev(() => me().ready); if (!ready.profile || !ready.docs) throw new Error('profile/docs not complete: ' + JSON.stringify(ready) + ' ' + await text('#dc-err').catch(() => ''));
  if (!(await ev(() => !!me().photo))) errs.push('photo not shown after upload');
  ok('crew profile, photo, Aadhaar and PAN saved');
  await signOut();

  // 4. LP sends the agreement; crew signs; owner approves
  await signIn('manoj'); await click('[data-act=open-project]'); await click('.rail [data-id=people]');
  await click('tr:has-text("Imran Shaikh")'); await click('.drawer [data-act=send-ag]');
  if (await ev(() => S.members.find(m => !m.synthetic && m.job.startsWith('1st AC')).ag.status) !== 'sent') throw new Error('agreement not sent');
  if (await ev(() => S.users.find(u => u.name === 'Imran Shaikh').pan)) errs.push('Line Producer can see the crew PAN');
  ok('agreement sent; LP cannot see PAN'); await signOut();
  await signIn('imran'); await click('[data-act=open-project]');
  await p.fill('#sg-name', 'Imran Shaikh'); const c = await p.$('#sig'); await c.scrollIntoViewIfNeeded(); const bb = await c.boundingBox();
  await p.mouse.move(bb.x + 20, bb.y + 40); await p.mouse.down(); await p.mouse.move(bb.x + 140, bb.y + 90, {steps:8}); await p.mouse.up();
  await click('form[data-form=sign] button[type=submit]');
  if (await ev(() => memberIn(U.pid, S.session).ag.status) !== 'signed') throw new Error('signing failed: ' + await text('#sg-err').catch(() => ''));
  const crewCode = await ev(() => memberIn(U.pid, S.session).code); ok('crew signed'); await signOut();
  await signIn('fowzan'); await click('[data-act=open-project]'); await click('[data-act=open-person]');
  await click('.drawer [data-act=countersign]');
  if (await ev(() => S.members.find(m => m.job.startsWith('1st AC')).ag.status) !== 'countersigned') throw new Error('owner approval failed'); ok('owner approved the agreement');
  if (!(await ev(() => S.users.find(u => u.name === 'Imran Shaikh').pan === 'FHSPS3349D'))) errs.push('owner cannot see crew PAN');
  if (!(await ev(() => String(S.users.find(u => u.name === 'Imran Shaikh').docs.aadhaar).startsWith('data:image')))) errs.push('owner cannot open the crew Aadhaar image: ' + await ev(() => String(S.users.find(u => u.name === 'Imran Shaikh').docs.aadhaar).slice(0, 30)));
  await signOut();

  // 5. LP checks the crew member in on a past shoot day
  await signIn('manoj'); await click('[data-act=open-project]'); await click('.rail [data-id=schedule]');
  await ev(() => { const d = S.days.filter(x => x.date < today()).pop(); U.drawer = {type:'day', id:d.id}; renderLayer(); });
  await p.fill('#ci-code', crewCode); await click('form[data-form=checkin] button[type=submit]');
  if ((await ev(() => S.days.filter(d => d.att.length).length)) !== 1) throw new Error('check-in failed: ' + await text('#ci-err').catch(() => ''));
  ok('gate check-in recorded'); await signOut();

  // 6. Crew raises an invoice (days filled from check-ins); LP and owner approve; owner pays and sends to Tally
  await signIn('imran'); await click('[data-act=open-project]'); await click('.rail [data-id=invoices]'); await click('[data-act=raise]');
  await fill({'rv-from':await ev(() => isoD(dayOff(-6))), 'rv-to':await ev(() => isoD(dayOff(-1)))});
  await p.waitForTimeout(100); const qty = await p.inputValue('#rv-qty');
  if (qty !== '1') errs.push('invoice days not filled from check-ins: ' + qty);
  await p.fill('#rv-no', 'IS-001'); await click('form[data-form=raise] button[type=submit]');
  if (await ev(() => S.invoices.length) !== 1) throw new Error('invoice not submitted: ' + await text('#rv-err').catch(() => ''));
  ok('invoice submitted for ' + qty + ' day'); await signOut();
  await signIn('manoj'); await click('[data-act=open-project]'); await click('.rail [data-id=invoices]'); await click('[data-act=hod-ok]');
  if (await ev(() => S.invoices[0].status) !== 'hod_ok') throw new Error('HOD step failed'); await signOut();
  await signIn('fowzan'); await click('[data-act=open-project]'); await click('.rail [data-id=invoices]'); await click('[data-act=final-ok]');
  // deduction and remark before payment
  await click('main [data-act=adjust]'); await p.selectOption('#dd-t0', 'advance'); await fill({'dd-a0':50, 'dd-n0':'Advance paid on set'}); await p.fill('#dd-rem', 'Return the walkie');
  if (!(await text('#dd-calc')).includes('4,405')) errs.push('deduction preview wrong: ' + await text('#dd-calc'));
  await click('form[data-form=adjust] button[type=submit]');
  const inv0 = await ev(() => S.invoices[0]);
  if (inv0.deduction !== 50 || inv0.payable !== 4405 || inv0.remarks !== 'Return the walkie') throw new Error('deduction not saved: ' + JSON.stringify(inv0) + ' ' + await text('#dd-err').catch(() => ''));
  if (!(await text('main tbody')).includes('Return the walkie')) errs.push('remark not shown in the invoice table');
  ok('owner took off ₹50 advance with a remark; payable now ₹4,405');
  await click('.rail [data-id=finance]'); await p.check('input[data-change=selall]'); await p.waitForTimeout(150); await click('[data-act=payrun]');
  await p.fill('#md-v', 'HDFCBATCH001'); await click('form[data-form=payrun] button[type=submit]');
  if (await ev(() => S.invoices[0].status) !== 'paid') throw new Error('payment failed: ' + await text('#md-err').catch(() => ''));
  ok('approved and paid');
  await click('[data-act=ftab][data-id=tally]'); await click('[data-act=tally-preview]'); await click('[data-act=tally-mark]');
  if (await ev(() => S.exports.length) !== 1) throw new Error('Tally batch not recorded'); ok('sent to Tally as ' + await ev(() => S.exports[0].id));
  // artists, crew and vendors listed apart
  await click('.rail [data-id=people]');
  for (const o of [{n:'Rhea Kapoor', k:'cast', j:'Lead Actor', r:60000}, {n:'Shree Vans', k:'vendor', j:'Vanity vans', r:8000}]){
    await click('[data-act=onboard]'); await fill({'ob-name':o.n, 'ob-rate':o.r, 'ob-phone':'98200 1' + o.r}); await p.selectOption('#ob-kind', o.k); await p.selectOption('#ob-job', o.j);
    await click('form[data-form=onboard] button[type=submit]'); if (!(await p.$('.dialog pre'))) throw new Error(o.n + ' not onboarded: ' + await text('#ob-err').catch(() => '')); await click('.dialog [data-act=close-modal]');
  }
  const kinds = await ev(() => Object.fromEntries(S.members.filter(m => !m.synthetic).map(m => [user(m.userId).name, m.kind])));
  if (kinds['Rhea Kapoor'] !== 'cast' || kinds['Shree Vans'] !== 'vendor' || kinds['Imran Shaikh'] !== 'crew') errs.push('lists wrong: ' + JSON.stringify(kinds));
  await click('[data-act=pk][data-id=cast]'); const artists = await p.$$eval('#people-rows tr', r => r.map(x => x.textContent));
  if (artists.length !== 1 || !artists[0].includes('Rhea')) errs.push('Artists tab shows: ' + artists.join(' | '));
  await click('[data-act=pk][data-id=vendor]'); const vend = await p.$$eval('#people-rows tr', r => r.map(x => x.textContent));
  if (vend.length !== 1 || !vend[0].includes('Shree')) errs.push('Vendors tab shows: ' + vend.join(' | '));
  await click('[data-act=pk][data-id=all]'); ok('People splits into Artists, Crew and Vendors');
  await click('.rail [data-id=agreements]'); await click('[data-act=agk][data-id=cast]');
  if (!(await text('main tbody')).includes('Artist agreement')) errs.push('Agreements artist tab missing the artist');
  await click('[data-act=agk][data-id=crew]'); await click('[data-act=agf][data-id=countersigned]');
  const apr = await p.$$eval('main tbody tr', r => r.map(x => x.textContent)); if (apr.length !== 1 || !apr[0].includes('Imran')) errs.push('approved crew agreements: ' + apr.join(' | '));
  await click('[data-act=agk][data-id=all]'); await over('agreements'); ok('Agreements filter by list and by status');
  const sheets = await ev(() => Object.keys(workbookData(U.pid))); if (!['Artists','Crew','Vendors'].every(k => sheets.includes(k))) errs.push('Excel sheets: ' + sheets.join(', ')); else ok('Excel has separate Artists, Crew and Vendors sheets');
  const inv1 = await ev(() => workbookData(U.pid).Invoices[0]); if (inv1['Deductions (₹)'] !== 50 || inv1.Remarks !== 'Return the walkie') errs.push('Excel invoice row lacks deductions: ' + JSON.stringify(inv1));
  if (await p.$('main [data-act=adjust]')) errs.push('deductions still editable after Tally');
  // invite someone by mobile; they sign in with Google, add their mobile when joining, and land on their invite
  await click('.rail [data-id=people]'); await click('[data-act=onboard]'); await fill({'ob-name':'Kavya Rao', 'ob-rate':3500, 'ob-phone':'98111 22233'});
  await p.selectOption('#ob-dept', 'Hair & Makeup'); await p.selectOption('#ob-job', 'Makeup Artist'); await click('form[data-form=onboard] button[type=submit]'); await click('.dialog [data-act=close-modal]');
  await signOut();
  if (!(await p.$('.gbtn'))) throw new Error('no Google button on the sign-in screen');
  await click('[data-act=forgot]'); if (!(await text('.login-form')).includes('Sign in with Google instead')) errs.push('forgot-password screen lacks the Google route'); await click('[data-act=auth][data-id=in]');
  await click('[data-act=auth][data-id=signup]'); if (!(await text('.gbtn')).includes('Sign up with Google')) errs.push('sign-up tab lacks the Google button');
  await click('.gbtn'); await p.waitForTimeout(500); await over('google first visit');
  if (!(await p.$('#join-phone'))) throw new Error('Google user is not asked for a mobile when joining');
  await fill({'join-code':code, 'join-phone':'+91 98111 22233'}); await click('form[data-form=join] button[type=submit]'); await p.waitForTimeout(300);
  const kav = await ev(() => { const m = memberIn(U.pid, S.session); return m && {job:m.job, rate:m.rate, name:me().name}; });
  if (!kav || kav.job !== 'Makeup Artist' || kav.rate !== 3500 || kav.name !== 'Kavya Rao') errs.push('Google user did not take up the mobile invite: ' + JSON.stringify(kav) + ' ' + await text('#join-err').catch(() => ''));
  else ok('Google sign-in: name from Google, mobile added at join, invite taken up');
  await click('.me'); if (!(await p.$('.menu [data-act=set-pass]'))) errs.push('no “set password” in the menu'); else { await click('.menu [data-act=set-pass]'); if (!(await p.$('#np-pass'))) errs.push('set password form missing'); await p.keyboard.press('Escape'); await click('[data-act=close-modal]').catch(() => {}); }
  // the LP asks for Kavya to be removed; the owner sees it on Home and approves; with no history she is deleted
  await signOut(); await signIn('manoj'); await click('[data-act=open-project]'); await click('.rail [data-id=people]');
  await click('#people-rows tr:has-text("Kavya Rao")'); if (await p.$('.drawer [data-act=rm-open]')) errs.push('LP sees a direct remove button');
  await click('.drawer [data-act=rm-ask]'); await p.fill('#rm-why', 'Hired twice by mistake'); await click('form[data-form=rmask] button[type=submit]');
  if (!(await text('.drawer')).includes('Removal asked')) errs.push('request not shown on the person: ' + await text('#rm-err').catch(() => ''));
  await signOut(); await signIn('fowzan'); await click('[data-act=open-project]');
  if (!(await text('main')).includes('Decide: remove Kavya Rao?')) errs.push('owner Home lacks the removal request');
  await click('.rail [data-id=people]'); await click('[data-act=pf][data-id=asked]'); await click('#people-rows tr:has-text("Kavya Rao")');
  await click('.drawer [data-act=rm-decide][data-yes]'); await click('form[data-form=rmdecide] button[type=submit]');
  if (await ev(() => S.members.some(m => user(m.userId)?.name === 'Kavya Rao'))) errs.push('Kavya still on the production after approval: ' + await text('#rm-err').catch(() => ''));
  else ok('LP asked, owner approved: Kavya (no history) deleted');
  // the owner removes Imran directly: he has paid invoices, so he is taken off and kept on record, then restored
  await click('[data-act=pf][data-id=all]');
  await click('#people-rows tr:has-text("Imran Shaikh")'); await click('.drawer [data-act=rm-open]');
  if (!(await text('.dialog')).includes('taken off the production rather than deleted')) errs.push('remove dialog does not explain records are kept');
  await p.fill('#rm-why', 'Show wrapped for camera'); await click('form[data-form=remove] button[type=submit]');
  if (!(await ev(() => S.members.find(m => user(m.userId)?.name === 'Imran Shaikh')?.removed))) throw new Error('Imran not removed: ' + await text('#rm-err').catch(() => ''));
  if ((await p.$$eval('#people-rows tr', r => r.map(x => x.textContent))).some(t => t.includes('Imran'))) errs.push('removed person still in the main list');
  await click('[data-act=pf][data-id=removed]'); await click('#people-rows tr:has-text("Imran Shaikh")'); await click('.drawer [data-act=rm-restore]');
  if (await ev(() => S.members.find(m => user(m.userId)?.name === 'Imran Shaikh')?.removed)) errs.push('restore failed'); else ok('owner removed Imran (records kept) and restored him');
  await p.keyboard.press('Escape'); await click('[data-act=pf][data-id=all]');
  await click('.rail [data-id=reports]'); await over('reports');
  const [dl] = await Promise.all([p.waitForEvent('download', {timeout:5000}).catch(() => null), click('[data-act=excel]')]);
  if (!dl) errs.push('no Excel download'); else ok('Excel downloaded: ' + dl.suggestedFilename());
  await click('.rail [data-id=activity]'); const logRows = await p.$$eval('main tbody tr', r => r.length); if (logRows < 15) errs.push('activity log short: ' + logRows); else ok(`activity log has ${logRows} entries`);
  for (const v of ['home','people','invoices','company','access']) { await click(`.rail [data-id=${v}]`); await over(v); }
  await p.screenshot({path:'/tmp/crewdesk-live-home.png', fullPage:true});

  // 7. Live: the crew member has CrewDesk open on their phone; the owner changes their deal; it arrives without a refresh
  const ctx2 = await b.newContext({viewport:{width:390, height:844}});
  await ctx2.exposeFunction('pgCall', async (op, a) => { try { return await pg(op, a); } catch (e) { return {__error:e.message}; } });
  await ctx2.addInitScript(FAKE);
  const q2 = await ctx2.newPage();
  q2.on('pageerror', e => errs.push('phone page error: ' + e.message));
  await q2.route(/fonts\.(googleapis|gstatic)|jsdelivr/, r => r.abort());
  await q2.goto('http://localhost:5188/'); await q2.waitForSelector('.gbtn'); await q2.evaluate(() => { document.querySelector('.pwbox').open = true; });
  await q2.fill('#li-user', 'imran'); await q2.fill('#li-pass', 'whatever123'); await q2.click('form[data-form=login] button[type=submit]');
  await q2.waitForSelector('[data-act=open-project]'); await q2.click('[data-act=open-project]'); await q2.waitForTimeout(400);
  const before = await q2.evaluate(() => ({unread:S.notes.filter(n => !n.read).length, joining:memberIn(U.pid, S.session).joining}));
  if (before.unread < 5) errs.push('crew should already have notifications (agreement, invoice, payment): ' + before.unread); else ok(`crew has ${before.unread} unread notifications`);
  if (!(await q2.$('.bell .badge'))) errs.push('bell shows no unread count');
  await click('.rail [data-id=people]'); await click('tr:has-text("Imran Shaikh")'); await click('.drawer [data-act=edit-deal]');
  const newJoin = await ev(() => isoD(dayOff(-40))); await p.fill('#ob-join', newJoin); await click('form[data-form=deal] button[type=submit]');
  let arrived = null;
  for (let i = 0; i < 20 && !arrived; i++){ await q2.waitForTimeout(300); arrived = await q2.evaluate(j => S.notes[0]?.title === 'Your deal was updated' && memberIn(U.pid, S.session).joining === j ? S.notes.filter(n => !n.read).length : null, newJoin); }
  if (!arrived) errs.push('the deal change did not reach the crew member’s open screen'); else ok(`owner’s change reached the crew member live (now ${arrived} unread)`);
  await q2.click('.bell'); await q2.waitForTimeout(200);
  const items = await q2.$$eval('.notes li button', b => b.map(x => x.querySelector('b').textContent));
  if (!items.some(t => /Deduction on invoice IS-001/.test(t))) errs.push('crew not told about the deduction: ' + items.join(' | '));
  if (!items.some(t => /paid/.test(t)) || !items.some(t => /approved/.test(t))) errs.push('notification list is missing payment/approval: ' + items.join(' | ')); else ok('bell lists: ' + items.slice(0, 4).join(' | '));
  const o2 = await q2.evaluate(() => document.documentElement.scrollWidth - innerWidth); if (o2 > 1) errs.push('phone: sideways scroll with notifications open');
  await q2.screenshot({path:'/tmp/crewdesk-notes-phone.png'});
  await q2.click('[data-act=notes-read]'); await q2.waitForTimeout(400);
  if (await q2.$('.bell .badge')) errs.push('mark all read left a badge'); else ok('mark all read clears the badge');
  await ctx2.close();
} catch (e) { errs.push('STOPPED: ' + e.message); await p.screenshot({path:'/tmp/crewdesk-live-fail.png', fullPage:true}); }
console.log(errs.length ? 'ERRORS:\n' + errs.join('\n') : 'LIVE APP E2E PASSED');
await b.close(); server.close(); process.exit(errs.length ? 1 : 0);
