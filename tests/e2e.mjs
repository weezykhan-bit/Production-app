// Run: npm i playwright @electric-sql/pglite@0.2.17 qrcode-generator@1.4.4 && node tests/e2e.mjs <path-to-crewdesk> <screenshot-dir>
// End-to-end: drives CrewDesk demo mode in Chromium at phone size, as each role.
import { createRequire } from 'module'; const { chromium } = createRequire(import.meta.url)('playwright');
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = process.argv[2], OUT = process.argv[3];
const NM = path.resolve(process.env.NODE_MODULES || 'node_modules');
const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.sql': 'text/plain', '.json': 'application/json', '.svg': 'image/svg+xml', '.webmanifest': 'application/manifest+json', '.wasm': 'application/wasm', '.data': 'application/octet-stream' };
const HEADERS = Object.fromEntries(JSON.parse(fs.readFileSync(path.join(ROOT, 'vercel.json'), 'utf8')).headers[0].headers.map(h => [h.key, h.value]));
const server = http.createServer((req, res) => {
  const f = path.join(ROOT, decodeURIComponent(req.url.split('?')[0]).replace(/\/$/, '/index.html'));
  fs.readFile(f, (e, d) => { if (e) { res.writeHead(404); return res.end(); } res.writeHead(200, { 'content-type': types[path.extname(f)] || 'application/octet-stream', ...HEADERS }); res.end(d); });
}).listen(8765);
const ok = (c, l) => { if (!c) throw new Error('FAIL ' + l); console.log('ok ', l); };
const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, acceptDownloads: true });
await ctx.route('https://cdn.jsdelivr.net/npm/@electric-sql/pglite@0.2.17/dist/**', r => {
  const f = path.join(NM, '@electric-sql/pglite/dist', r.request().url().split('/dist/')[1]);
  r.fulfill({ path: f, contentType: types[path.extname(f)] || 'application/octet-stream' });
});
await ctx.route('https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js', r => r.fulfill({ path: path.join(NM, 'qrcode-generator/qrcode.js'), contentType: 'text/javascript' }));
const page = await ctx.newPage();
const errs = []; page.on('pageerror', e => errs.push(e.message)); page.on('console', m => /Content Security Policy|Refused to/.test(m.text()) && errs.push('CSP: ' + m.text())); page.on('console', m => m.text().startsWith('DBG') && DBG.push(m.text())); const DBG = []; page.on('console', m => m.type() === 'error' && errs.push(m.text()));
page.on('dialog', d => d.accept());
const t0 = Date.now();
await page.goto('http://localhost:8765/');
await page.waitForSelector('[data-act="persona"]', { timeout: 60000 });
ok(true, `demo database built in browser in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
ok(await page.locator('[data-act="persona"]').count() === 8, 'eight sample people to try as');
await page.screenshot({ path: OUT + '/1-signin.png', fullPage: true });

const as = async u => {
  if (await page.locator('[data-act="signout"]').count()) await page.locator('#demoBand [data-act="signout"]').click();
  try { await page.waitForSelector(`[data-act="persona"][data-u="${u}"]`, { timeout: 10000 }); }
  catch (e) { console.log('BODY:', (await page.textContent('body')).replace(/\s+/g, ' ').slice(0, 700)); console.log(DBG.slice(-12).join('\n')); console.log('ERRS', errs, 'HASH', await page.evaluate(() => location.hash)); throw e; }
  await page.click(`[data-act="persona"][data-u="${u}"]`);
  try { await page.waitForSelector('text=Your productions', { timeout: 15000 }); }
  catch (e) { await page.screenshot({ path: OUT + '/fail.png', fullPage: true }); console.log('MAIN:', (await page.textContent('body')).slice(0, 600)); console.log('ERRS', errs); throw e; }
};
const proj = async (tab = '') => {
  await page.click('text=Monsoon Diaries'); await page.waitForSelector('nav.tabs:not([hidden])');
  await page.waitForSelector('main h1:has-text("Today"), main h1:has-text("Overview")');
  if (tab) { await page.click(`nav.tabs a:has-text("${tab}")`); await page.waitForSelector(`main h1:has-text("${tab}")`); }
};
const text = () => page.textContent('main');

// ---- crew: Chetan signs his contract and invoices
await as('chetan');
await proj();
ok((await text()).includes('Sign your contract'), 'crew sees "Sign your contract" on Today');
ok((await text()).includes('Your call 05:15'), 'crew sees their own call time');
await page.screenshot({ path: OUT + '/2-crew-today.png', fullPage: true });
await page.click('text=Sign your contract');
await page.click('[data-act="sign"]');
const box = await page.locator('#sigpad').boundingBox();
await page.mouse.move(box.x + 20, box.y + 100); await page.mouse.down();
for (let i = 0; i < 12; i++) await page.mouse.move(box.x + 30 + i * 20, box.y + 60 + (i % 2) * 50);
await page.mouse.up();
await page.check('input[name="agree"]');
await page.click('form[data-form="sign"] button.accent');
await page.waitForSelector('.pill:has-text("Awaiting countersign")');
ok((await text()).includes('Document fingerprint'), 'contract signed with drawn signature and fingerprint');
await page.screenshot({ path: OUT + '/3-signed.png', fullPage: true });
await page.click('nav.tabs a:has-text("Invoices")');
await page.click('text=+ New invoice');
ok(await page.inputValue('#f_invoice_no') === 'CHETAN/003', 'invoice number continues the series');
ok(await page.inputValue('#f_rate') === '6500', 'rate pre-filled from the deal');
await page.fill('#f_quantity', '2');
ok((await page.textContent('#invPrev')).includes('₹13,000'), 'live total');
await page.click('form[data-form="invoice"] button.accent');
await page.waitForSelector('h1:has-text("CHETAN/003")');
ok((await text()).includes('Submitted'), 'invoice submitted');

// ---- HOD approves
await as('hari'); await proj('Money');
ok((await text()).includes('CHETAN/003'), 'HOD sees department invoice to approve');
await page.locator('.item:has-text("CHETAN/003") + .actions [data-act="hod-approve"]').click();
await page.waitForSelector('text=Approved, sent to accounts');

// ---- accounts: approve with TDS, payment run, mark paid
await as('asha'); await proj('Money');
await page.screenshot({ path: OUT + '/4-accounts-money.png', fullPage: true });
await page.locator('.item:has-text("CHETAN/003") + .actions [data-act="approve"]').click();
await page.fill('#f_tds', '10');
ok((await page.textContent('#tdsPrev')).includes('₹11,700'), 'TDS preview: payable ₹11,700');
await page.click('form[data-form="approve"] button.ok');
await page.waitForSelector('text=Approved for payment');
await page.click('text=Payment runs');
await page.waitForSelector('main h1:has-text("Payment runs")');
const ready = await page.locator('form[data-form="batch"] input[name="inv"]').count();
if (ready < 2) console.log('MAIN:', (await text()).replace(/\s+/g, ' ').slice(0, 500));
ok(ready >= 2, `${ready} approved invoices ready to pay`);
await page.click('form[data-form="batch"] button');
await page.waitForSelector('text=Payment run created');
const [dl] = await Promise.all([page.waitForEvent('download'), page.locator('[data-act="bank-file"]').first().click()]);
const bank = fs.readFileSync(await dl.path(), 'utf8');
ok(bank.startsWith('Beneficiary name,Account number,IFSC,Amount') && bank.includes('30112233445,SBIN0001234,11700'), 'bank file has Chetan: account, IFSC, ₹11,700');
await page.locator('[data-act="mark-paid"]').first().click();
await page.fill('#f_ref', 'UTR2026TEST01');
await page.click('form[data-form="paid"] button.ok');
await page.waitForSelector('text=Paid · UTR2026TEST01');

// ---- producer: countersign, cost report, Tally export
await as('priya'); await proj();
ok((await text()).includes('contract to countersign') || (await text()).includes('contracts to countersign'), 'producer sees countersign to-do');
await page.screenshot({ path: OUT + '/5-producer-today.png', fullPage: true });
await page.click('nav.tabs a:has-text("Contracts")');
await page.click('.chip:has-text("Awaiting countersign")');
const r0 = await page.evaluate(() => window.__renders); await page.waitForTimeout(1500);
const r1 = await page.evaluate(() => window.__renders);
ok(r1 - r0 <= 1, `screen is stable (${r1 - r0} redraws in 1.5 s)`);
await page.click('.item:has-text("Chetan Kumar")');
await page.click('[data-act="countersign"]');
await page.waitForSelector('.pill:has-text("Fully signed")');
ok(true, 'producer countersigns');
await page.click('nav.tabs a:has-text("Money")');
await page.click('text=Budget & cost report');
const camera = await page.textContent('table.t tr:has-text("Camera")');
ok(camera.includes('₹9,00,000') && camera.includes('₹32,500'), 'cost report: Camera budget ₹9,00,000, committed ₹32,500');
await page.screenshot({ path: OUT + '/6-budget.png', fullPage: true });
const wb = await page.evaluate(() => [document.documentElement.scrollWidth, innerWidth]);
ok(wb[0] === wb[1], `budget screen fits the phone (${wb[0]} px)`);
await page.click('text=← Money');
await page.locator('.item:has-text("LW/26-27/0412") + .actions [data-act="approve"]').click();
await page.fill('#f_tds', '2'); await page.click('form[data-form="approve"] button.ok');
await page.waitForSelector('.toast:has-text("Approved for payment")');
await page.click('text=Tally & exports');
await page.fill('#f_from', '2020-01-01');
const [tx] = await Promise.all([page.waitForEvent('download'), page.click('form[data-form="tally"] button')]);
const tally = fs.readFileSync(await tx.path(), 'utf8');
const parsed = await page.evaluate(x => { const d = new DOMParser().parseFromString(x, 'application/xml'); if (d.querySelector('parsererror')) return 'parse error';
  return [...d.querySelectorAll('VOUCHER')].map(v => [...v.querySelectorAll('AMOUNT')].reduce((s, a) => s + +a.textContent, 0)); }, tally);
ok(Array.isArray(parsed) && parsed.length >= 4 && parsed.every(s => s === 0), `Tally XML is well-formed and all ${parsed.length} vouchers balance`);
ok(tally.includes('<PARTYGSTIN>27AAJFL5566M1ZM</PARTYGSTIN>') && tally.includes('<LEDGERNAME>Input CGST</LEDGERNAME>'), 'Tally: GST vendor ledger with CGST/SGST split (same state)');
ok(tally.includes('<INCOMETAXNUMBER>BCDPK7788L</INCOMETAXNUMBER>') && tally.includes('VCHTYPE="Payment"') && tally.includes('TDS Payable'), 'Tally: crew PAN, TDS and payment vouchers');

// ---- manager: call sheet + check-in
await as('manav'); await proj('Schedule');
await page.click('text=+ Call sheet');
await page.fill('#f_location', 'Aksa Beach, Malad');
await page.fill('#f_general_call', '06:30');
await page.fill('#f_scenes', '30 | EXT. BEACH - DAY. The reveal | Arjun, Meera');
await page.click('[data-act="all-general"]');
await page.click('form[data-form="sheet"] button.block');
await page.waitForSelector('text=Aksa Beach, Malad');
await page.click('[data-act="publish-sheet"]');
await page.waitForSelector('text=Read by 0');
ok(true, 'manager builds and publishes a call sheet');
await page.click('nav.tabs a:has-text("Crew")');
await page.click('text=Check crew in');
const code = await page.evaluate(async () => null);
// read Chetan's card code via his ID card later; here type a wrong code first
await page.fill('#cc', 'ZZZZZZZZ'); await page.click('form[data-form="checkin"] button');
await page.waitForSelector('.toast:has-text("isn\'t on this project")');
ok(true, 'unknown ID code rejected');

await as('chetan'); await proj('Crew');
await page.click('text=My ID card');
await page.waitForSelector('#qr img');
const myCode = (await page.textContent('.idcard .code')).trim();
ok(/^[0-9A-F]{8}$/.test(myCode), 'ID card shows QR and 8-character code');
await page.screenshot({ path: OUT + '/7-idcard.png', fullPage: true });
await page.click('nav.tabs a:has-text("Schedule")'); await page.waitForSelector('main h1:has-text("Schedule")');
ok((await text()).includes('Aksa Beach'), 'crew sees the newly published call sheet');
ok(!(await text()).includes('Draft'), 'crew does not see drafts');

await as('manav'); await proj('Crew'); await page.click('text=Check crew in');
await page.fill('#cc', myCode.toLowerCase()); await page.click('form[data-form="checkin"] button');
await page.waitForSelector('.toast:has-text("Chetan Kumar checked in")');
await page.waitForSelector('.item:has-text("Chetan Kumar") .pill:has-text("On set")'); ok(true, 'manager checks Chetan in by ID code');

// ---- privacy spot checks in the UI
await as('rohit'); await proj();
ok((await text()).includes('Finish your profile'), 'new crew member is asked to complete KYC');
await page.click('nav.tabs a:has-text("Invoices")'); await page.waitForSelector('main h1:has-text("Invoices")');
ok(!(await text()).includes('CHETAN/'), "crew can't see colleagues' invoices");
const w = await page.evaluate(() => [document.documentElement.scrollWidth, innerWidth]);
ok(w[0] === w[1], 'no sideways scrolling at 390 px');
ok(errs.length === 0, 'no page errors ' + errs.join(' | '));
// a brand-new person signs up in the demo and joins with the invite code
await as('priya'); await proj('Crew');
const invite = (await page.textContent('main')).match(/Invite code\s*([0-9A-F]{8})/)[1];
await page.click('#demoBand [data-act="signout"]');
await page.fill('#su_name', 'Test Person'); await page.fill('#su_user', 'priya'); await page.fill('#su_email', 'test@person.demo');
await page.click('form[data-form="signup"] button');
await page.waitForSelector('[data-err="username"]:has-text("taken")');
ok(true, 'sign-up rejects a taken username');
await page.fill('#su_user', 'test.person'); await page.click('form[data-form="signup"] button');
await page.waitForSelector('text=You are not on any production yet');
await page.fill('#jcode', invite.toLowerCase()); await page.click('form[data-form="join"] button');
await page.waitForSelector('main h1:has-text("Today"), main h1:has-text("Overview")');
ok((await page.textContent('main')).includes('Finish your profile'), 'new person joins by invite code and is asked for KYC');
// sweep every screen for layout overflow and errors, as producer and as crew
for (const u of ['priya', 'chetan']) {
  await as(u); await proj();
  const id = (await page.evaluate(() => location.hash)).split('/')[2];
  const firstContract = await page.evaluate(() => null);
  const screens = ['', '/crew', '/id', '/checkin', '/contracts', '/money', '/invoice/new', '/payments', '/budget', '/exports', '/schedule', '/settings', '/member/d0000000-0000-4000-8000-000000000005'];
  for (const sc of screens) {
    await page.evaluate(h => location.hash = h, `#/p/${id}${sc}`);
    await page.waitForTimeout(350);
    const [sw, iw] = await page.evaluate(() => [document.documentElement.scrollWidth, innerWidth]);
    if (sw !== iw) throw new Error(`FAIL ${u} ${sc || '/'} overflows: ${sw}px`);
  }
  for (const h of ['#/profile', '#/new', '#/']) { await page.evaluate(x => location.hash = x, h); await page.waitForTimeout(300);
    const [sw, iw] = await page.evaluate(() => [document.documentElement.scrollWidth, innerWidth]); if (sw !== iw) throw new Error(`FAIL ${u} ${h} overflows`); }
  ok(true, `${u}: all ${screens.length + 3} screens fit a 390 px phone`);
}
await page.screenshot({ path: OUT + '/8-home.png', fullPage: true });
ok(errs.length === 0, 'still no page errors after sweep ' + errs.join(' | '));
console.log('E2E PASSED');
await browser.close(); server.close();
