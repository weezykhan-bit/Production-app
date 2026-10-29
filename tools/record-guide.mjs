// Records the crew setup video at help/crewdesk-setup.mp4: the real screens on a phone-sized browser, against the
// real database rules (PGlite, as in the end-to-end test), with captions added on top. The production office's
// side (sending the agreement, approving, checking in, paying) happens off camera in a second browser.
// Usage: PGLITE=<path to @electric-sql/pglite dist/index.js> node tools/record-guide.mjs   (needs ffmpeg)
import fs from 'fs'; import path from 'path'; import { execFileSync } from 'child_process';
import { chromium, pg, server, FAKE, ROOT } from '../tests/harness.mjs';

const OUT = path.join(ROOT, 'help'), TMP = fs.mkdtempSync('/tmp/crewdesk-guide-');
const URL = 'http://localhost:5188/', W = 390, H = 844;
const b = await chromium.launch();
const ctxFor = async (opts, name) => {
  const c = await b.newContext(opts);
  await c.exposeFunction('pgCall', async (op, a) => { try { return await pg(op, a); } catch (e) { return {__error:e.message}; } });
  await c.addInitScript(FAKE);
  if (name) await c.addInitScript(n => { window.FAKE_GOOGLE = n; }, name);
  const p = await c.newPage();
  await p.route(/fonts\.(googleapis|gstatic)|jsdelivr/, r => r.abort());
  p.on('pageerror', e => console.log('page error:', e.message));
  return [c, p];
};
const wait = ms => new Promise(r => setTimeout(r, ms));

// ---------------------------------------------------------------- the production office, off camera
const [, o] = await ctxFor({viewport:{width:1280, height:900}});
await o.goto(URL); await o.waitForSelector('.gbtn'); await o.evaluate(() => { document.querySelector('.pwbox').open = true; });
await o.fill('#li-user', 'fowzan'); await o.fill('#li-pass', 'whatever123'); await o.click('form[data-form=login] button[type=submit]'); await o.waitForSelector('#co-legal');
for (const [k, v] of Object.entries({'co-legal':'Swastik Stories Pvt Ltd', 'co-pan':'AABCS1234K', 'co-tan':'MUMS12345C', 'co-addr':'Andheri West, Mumbai', 'co-bank':'HDFC Bank', 'co-acct':'50200011112222', 'co-ifsc':'HDFC0000212'})) await o.fill('#' + k, v);
await o.click('form[data-form=company] button[type=submit]'); await o.waitForSelector('#np-name');
await o.fill('#np-name', 'Saath Phere'); await o.selectOption('#np-status', 'Shooting'); await o.click('form[data-form=project] button[type=submit]'); await o.waitForSelector('.codegen .code');
const code = (await o.textContent('.codegen .code')).trim();
await o.evaluate(() => { U.view = 'people'; render(); }); await o.click('[data-act=onboard]');
await o.fill('#ob-name', 'Kavya Rao'); await o.fill('#ob-phone', '98111 22233'); await o.fill('#ob-rate', '3500');
await o.selectOption('#ob-dept', 'Hair & Makeup'); await o.selectOption('#ob-job', 'Makeup Artist'); await o.click('form[data-form=onboard] button[type=submit]'); await wait(300);
await o.evaluate(async () => { const d = n => { const x = new Date(); x.setDate(x.getDate() + n); return x.toISOString().slice(0, 10); };
  await call('plan_days', {p_production:U.pid, p:{from:d(-6), to:d(6), skip_sundays:false, call:'07:00', wrap:'19:00', location:'Umargam · Floor 3', eps_per_day:1, start_ep:301}}); });
const office = body => o.evaluate(`(async () => { await reload(); const kavya = () => S.members.find(m => !m.synthetic && user(m.userId)?.name === 'Kavya Rao'); ${body} })()`);

// ---------------------------------------------------------------- sample images (clearly marked as samples)
const [, art] = await ctxFor({viewport:{width:800, height:600}});
await art.goto(URL);
const draw = async (kind) => Buffer.from((await art.evaluate(k => {
  const c = document.createElement('canvas'), x = c.getContext('2d');
  if (k === 'photo'){ c.width = c.height = 400; const g = x.createLinearGradient(0, 0, 0, 400); g.addColorStop(0, '#f3d9c4'); g.addColorStop(1, '#e8b796'); x.fillStyle = g; x.fillRect(0, 0, 400, 400);
    x.fillStyle = '#5b3a29'; x.beginPath(); x.arc(200, 165, 92, Math.PI, 0); x.fill(); x.fillStyle = '#c98b67'; x.beginPath(); x.arc(200, 175, 78, 0, 2 * Math.PI); x.fill();
    x.fillStyle = '#0d6b63'; x.beginPath(); x.ellipse(200, 420, 150, 130, 0, Math.PI, 0); x.fill(); }
  else { c.width = 640; c.height = 400; x.fillStyle = k === 'pan' ? '#dfeaf5' : '#fbf3e4'; x.fillRect(0, 0, 640, 400); x.strokeStyle = '#8a9aa8'; x.lineWidth = 6; x.strokeRect(3, 3, 634, 394);
    x.fillStyle = '#1d2b36'; x.font = 'bold 34px sans-serif'; x.fillText(k === 'pan' ? 'PAN CARD' : 'AADHAAR (masked)', 36, 70);
    x.fillStyle = '#c9a98f'; x.fillRect(36, 110, 150, 180); x.fillStyle = '#1d2b36'; x.font = '26px sans-serif';
    x.fillText('KAVYA RAO', 220, 150); x.font = '28px monospace'; x.fillText(k === 'pan' ? 'ABCPR1234K' : 'XXXX XXXX 4821', 220, 210);
    x.fillStyle = '#c0392b'; x.font = 'bold 46px sans-serif'; x.fillText('SAMPLE', 220, 300); }
  return c.toDataURL('image/png').split(',')[1];
}, kind)), 'base64');
const IMG = {photo:await draw('photo'), aadhaar:await draw('aadhaar'), pan:await draw('pan')};

// ---------------------------------------------------------------- the crew member's phone, on camera
const [cam, p] = await ctxFor({viewport:{width:W, height:H}, deviceScaleFactor:2, isMobile:true, hasTouch:true, recordVideo:{dir:TMP, size:{width:W * 2, height:H * 2}}},
  {email:'kavya.rao@gmail.com', name:'Kavya Rao'});
await p.addInitScript(() => {
  const css = `#guide-cap{pointer-events:none;position:fixed;left:10px;right:10px;bottom:12px;z-index:9999;background:rgba(16,32,30,.94);color:#fff;border-radius:14px;padding:12px 14px 13px;font:15px/1.35 system-ui,sans-serif;box-shadow:0 8px 30px rgba(0,0,0,.25);transition:opacity .25s}
    #guide-cap b{display:inline-block;background:#f2b23a;color:#1d1a12;border-radius:999px;padding:1px 9px;margin-right:8px;font-size:12px;vertical-align:2px}
    #guide-cap small{display:block;opacity:.75;font-size:13px;margin-top:3px}
    #guide-card{position:fixed;inset:0;z-index:10000;background:#0d6b63;color:#fff;display:grid;place-content:center;text-align:center;padding:32px;font-family:system-ui,sans-serif;transition:opacity .4s}
    #guide-card h1{font-size:30px;line-height:1.15;margin:0 0 12px} #guide-card p{font-size:17px;opacity:.85;margin:0}
    #guide-card i{display:inline-grid;place-items:center;width:58px;height:58px;border-radius:14px;background:#fff;color:#0d6b63;font:800 22px system-ui;font-style:normal;margin:0 auto 22px}
    .guide-tap{position:fixed;z-index:9998;width:44px;height:44px;margin:-22px 0 0 -22px;border-radius:50%;background:rgba(242,178,58,.55);border:3px solid #f2b23a;pointer-events:none;animation:gtap .6s ease-out forwards}
    @keyframes gtap{from{transform:scale(.4);opacity:1}to{transform:scale(1.4);opacity:0}}
    main{padding-bottom:170px!important} .fab{bottom:150px!important} .toast{top:70px!important;bottom:auto!important}`;
  addEventListener('DOMContentLoaded', () => { const s = document.createElement('style'); s.textContent = css; document.head.append(s); });
  window.__cap = (n, t, sub) => { let el = document.getElementById('guide-cap'); if (!el){ el = document.createElement('div'); el.id = 'guide-cap'; document.body.append(el); }
    el.style.opacity = t ? 1 : 0; el.innerHTML = t ? `${n ? `<b>${n}</b>` : ''}${t}${sub ? `<small>${sub}</small>` : ''}` : ''; };
  window.__card = (t, sub) => { let el = document.getElementById('guide-card'); if (!t){ if (el){ el.style.opacity = 0; setTimeout(() => el.remove(), 400); } return; }
    if (!el){ el = document.createElement('div'); el.id = 'guide-card'; document.body.append(el); } el.style.opacity = 1; el.innerHTML = `<div><i>CD</i><h1>${t}</h1><p>${sub || ''}</p></div>`; };
  window.__tap = (x, y) => { const d = document.createElement('div'); d.className = 'guide-tap'; d.style.left = x + 'px'; d.style.top = y + 'px'; document.body.append(d); setTimeout(() => d.remove(), 700); };
});
const cap = (n, t, sub) => p.evaluate(([n, t, s]) => window.__cap(n, t, s), [n, t, sub]);
const card = (t, sub) => p.evaluate(([t, s]) => window.__card(t, s), [t, sub]);
const show = async sel => { await p.$eval(sel, el => el.scrollIntoView({block:'center', behavior:'smooth'})); await wait(650); };
const tap = async sel => { await show(sel); const bb = await p.locator(sel).first().boundingBox(); await p.evaluate(([x, y]) => window.__tap(x, y), [bb.x + bb.width / 2, bb.y + bb.height / 2]); await wait(380); await p.locator(sel).first().click(); await wait(450); };
const type = async (sel, text) => { await show(sel); await p.locator(sel).first().click(); await p.locator(sel).first().fill(''); await p.locator(sel).first().type(text, {delay:45}); await wait(200); };

await p.goto(URL); await p.waitForSelector('.gbtn');
await card('Set up your CrewDesk account', 'About 2 minutes, on your phone'); await wait(3200); await card();
await cap('1', 'Open the CrewDesk link your Line Producer sent you', 'crewdesk-production.vercel.app'); await wait(2600);
await cap('1', 'Tap “Continue with Google” and pick your Gmail', 'No password to remember. New here? This creates your account.'); await wait(2400);
await tap('.gbtn'); await p.waitForSelector('#join-code'); await wait(600);
await cap('2', 'Enter the production code and your mobile number', 'Use the mobile number your Line Producer has, so CrewDesk finds your invite.'); await wait(1800);
await type('#join-code', code); await type('#join-phone', '98111 22233'); await wait(500);
await tap('form[data-form=join] button[type=submit]'); await p.waitForSelector('[data-form=profile]'); await wait(900);
await cap('', 'You’re in! This page shows what’s left to do.', 'Your deal, rate and joining date are already set by the office.'); await wait(3200);
await cap('3', 'Add a clear photo of your face', 'It goes on your Crew ID so the gate and your HOD can recognise you.'); await show('input[data-upload=photo]'); await wait(1500);
await p.setInputFiles('input[data-upload=photo]', {name:'me.png', mimeType:'image/png', buffer:IMG.photo}); await p.waitForFunction(() => !!me().photo, null, {timeout:8000}); await wait(1400);
await cap('4', 'Fill your details exactly as on your PAN card and bank account', 'Only you, the CFO, the Commercial Head and Accounts can see them.'); await wait(1800);
await type('#pf-legal', 'Kavya Rao'); await type('#pf-addr', 'Malad West, Mumbai 400064'); await type('#pf-pan', 'ABCPR1234K');
await type('#pf-holder', 'Kavya Rao'); await type('#pf-bank', 'State Bank of India'); await type('#pf-acct', '30211122233'); await type('#pf-ifsc', 'SBIN0001234');
await tap('form[data-form=profile] button[type=submit]'); await p.waitForSelector('[data-form=docs]'); await wait(900);
await cap('5', 'Upload photos of your Aadhaar and PAN card', 'Cover the first 8 Aadhaar digits (a masked Aadhaar). Then enter its last 4 digits.'); await show('[data-form=docs]'); await wait(2200);
await p.setInputFiles('input[data-upload=aadhaar]', {name:'aadhaar.png', mimeType:'image/png', buffer:IMG.aadhaar}); await p.waitForFunction(() => !!me().docs.aadhaar, null, {timeout:8000}); await wait(800);
await p.setInputFiles('input[data-upload=pan]', {name:'pan.png', mimeType:'image/png', buffer:IMG.pan}); await p.waitForFunction(() => !!me().docs.pan, null, {timeout:8000}); await wait(800);
await type('#dc-a4', '4821'); await tap('#dc-consent'); await tap('form[data-form=docs] button[type=submit]'); await wait(1200);
await cap('', 'Done for now. The office sends your agreement next.', 'You’ll get a notification on the bell, top right.'); await p.evaluate(() => scrollTo({top:0, behavior:'smooth'})); await wait(2400);
await office("const m = kavya(); U.pid = m.pid; await ACT['send-ag']({dataset:{id:m.id}});");
await p.waitForFunction(() => memberIn(U.pid, S.session)?.ag?.status === 'sent', null, {timeout:15000}); await wait(1500);
await cap('6', 'Read your agreement, type your name and sign with your finger', 'It shows your role, rate, payment terms and tax deducted.'); await show('.agreement'); await wait(2600);
await type('#sg-name', 'Kavya Rao'); await show('#sig');
{ const bb = await p.locator('#sig').boundingBox(), pts = [[.12, .62], [.2, .3], [.27, .7], [.34, .35], [.42, .66], [.5, .4], [.58, .62], [.66, .45], [.76, .6], [.86, .5]];
  await p.mouse.move(bb.x + bb.width * pts[0][0], bb.y + bb.height * pts[0][1]); await p.mouse.down();
  for (const [x, y] of pts.slice(1)) await p.mouse.move(bb.x + bb.width * x, bb.y + bb.height * y, {steps:6}); await p.mouse.up(); }
await wait(600); await tap('form[data-form=sign] button[type=submit]'); await wait(1400);
await cap('', 'Signed. The CFO or Commercial Head approves it.', 'You’ll be told the moment it’s approved.'); await wait(2200);
await office("await ACT.countersign({dataset:{id:kavya().id}});");
await p.waitForFunction(() => memberIn(U.pid, S.session)?.ag?.status === 'countersigned', null, {timeout:15000}); await p.evaluate(() => scrollTo({top:0, behavior:'smooth'})); await wait(1200);
await cap('7', 'This is your Crew ID', 'Show the code at the gate on every shoot day. Your check-ins fill your invoice.'); await show('.idcard'); await wait(3800);
// a few days on set, off camera
await office("const m = kavya(), days = S.days.filter(d => d.pid === m.pid && d.date < today()).slice(-4); for (const d of days) await call('check_in', {p_day:d.id, p_code:m.code});");
await p.evaluate(() => reload().then(render)); await wait(800);
await cap('8', 'To get paid, raise an invoice in My invoices', 'Pick the dates. Your days come in from the gate, so there’s nothing to count.'); await wait(1500);
await tap('.rail [data-id=invoices]'); await wait(700); await tap('[data-act=raise]'); await wait(500);
await p.evaluate(() => { const d = n => { const x = new Date(); x.setDate(x.getDate() + n); return x.toISOString().slice(0, 10); }; for (const [id, v] of [['rv-from', d(-6)], ['rv-to', d(-1)]]){ const el = document.getElementById(id); el.value = v; el.dispatchEvent(new Event('input', {bubbles:true})); } });
await wait(900); await type('#rv-no', 'KR-001'); await show('#rv-calc'); await wait(2200);
await tap('form[data-form=raise] button[type=submit]'); await wait(1400);
await cap('9', 'The bell tells you when it’s checked, approved and paid', 'With the bank reference, so you can match it in your account.'); await wait(1200);
await office("const i = S.invoices.find(x => x.no === 'KR-001'); await call('hod_approve', {p_id:i.id}); await call('final_approve', {p_id:i.id}); await call('pay_invoices', {p_production:i.pid, p_ids:[i.id], p_ref:'SBINR52026110310'});");
await p.waitForFunction(() => S.invoices.some(i => i.no === 'KR-001' && i.status === 'paid'), null, {timeout:15000}); await wait(800);
await tap('.bell'); console.log('bell open:', await p.evaluate(() => [U.notesOpen, !!document.querySelector('.notes')]));
if (!(await p.$('.notes'))) await p.evaluate(() => { U.notesOpen = true; render(); });
await wait(3800); await p.keyboard.press('Escape'); await p.evaluate(() => { U.notesOpen = false; render(); });
await cap('', 'Stuck anywhere? Tap the Guide button and ask.', 'Or ask your Line Producer. That’s it, see you on set!'); await wait(2600);
await card('You’re all set', 'Questions? Tap Guide in the app'); await wait(2600);

const raw = await p.video().path(); await cam.close();
fs.mkdirSync(OUT, {recursive:true});
const mp4 = path.join(OUT, 'crewdesk-setup.mp4'), poster = path.join(OUT, 'crewdesk-setup.jpg');
execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-i', raw, '-vf', 'scale=720:-2,fps=30', '-c:v', 'libx264', '-preset', 'slow', '-crf', '27', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-an', mp4]);
execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-ss', '1.5', '-i', mp4, '-frames:v', '1', '-vf', 'scale=540:-2', '-q:v', '4', poster]);
console.log('wrote', mp4, (fs.statSync(mp4).size / 1e6).toFixed(1) + ' MB');
await b.close(); server.close(); process.exit(0);
