// Records the welcome videos from the real screens, against the real database rules (PGlite, as in the
// end-to-end test), with captions added on top. Whatever happens on the other side (the office sending an
// agreement, the crew member signing) is done off camera in a second browser.
//   crew   → help/crewdesk-setup.mp4   phone, for crew, artists and vendors
//   office → help/crewdesk-office.mp4  laptop, for the CFO, Commercial Head, Line Producer and Accounts
// Usage: PGLITE=<path to @electric-sql/pglite dist/index.js> node tools/record-guide.mjs crew|office   (needs ffmpeg)
import fs from 'fs'; import path from 'path'; import { execFileSync } from 'child_process';
import { chromium, pg, server, FAKE, ROOT } from '../tests/harness.mjs';

const MODE = process.argv[2] === 'office' ? 'office' : 'crew';
const OUT = path.join(ROOT, 'help'), TMP = fs.mkdtempSync('/tmp/crewdesk-guide-'), URL = 'http://localhost:5188/';
const wait = ms => new Promise(r => setTimeout(r, ms));
const isoDay = n => { const x = new Date(); x.setDate(x.getDate() + n); return x.toISOString().slice(0, 10); };
const b = await chromium.launch();
async function browser(opts, google){
  const c = await b.newContext(opts);
  await c.exposeFunction('pgCall', async (op, a) => { try { return await pg(op, a); } catch (e) { return {__error:e.message}; } });
  await c.addInitScript(FAKE);
  if (google) await c.addInitScript(g => { window.FAKE_GOOGLE = g; }, google);
  const p = await c.newPage();
  await p.route(/fonts\.(googleapis|gstatic)|jsdelivr/, r => r.abort());
  p.on('pageerror', e => console.log('page error:', e.message));
  return [c, p];
}

// ---------------------------------------------------------------- captions, title cards and taps drawn over the app
const OVERLAY = phone => {
  const css = `
    #gcap{pointer-events:none;position:fixed;z-index:9999;background:rgba(12,28,27,.95);color:#fff;border-radius:16px;padding:14px 16px 15px;font:15px/1.4 "IBM Plex Sans",system-ui,sans-serif;box-shadow:0 10px 34px rgba(0,0,0,.28);transition:opacity .3s,transform .3s}
    #gcap.off{opacity:0;transform:translateY(8px)}
    #gcap .k{display:flex;align-items:center;gap:10px;margin-bottom:7px;font:600 11px/1 "IBM Plex Mono",ui-monospace,monospace;letter-spacing:.12em;text-transform:uppercase;color:#f2b23a}
    #gcap .bar{flex:1;height:3px;border-radius:3px;background:rgba(255,255,255,.18);overflow:hidden}
    #gcap .bar i{display:block;height:100%;background:#f2b23a;transition:width .5s}
    #gcap .t{font-weight:600;font-size:16px}
    #gcap .s{opacity:.78;font-size:13.5px;margin-top:3px}
    #gcard{position:fixed;inset:0;z-index:10000;color:#fff;display:grid;place-content:center;text-align:center;padding:36px;font-family:"IBM Plex Sans",system-ui,sans-serif;transition:opacity .45s;
      background:radial-gradient(120% 80% at 20% 10%,#14857d 0%,#0b6b66 45%,#073f3c 100%)}
    #gcard .logo{display:inline-grid;place-items:center;width:64px;height:64px;border-radius:16px;background:#fff;color:#0b6b66;font:800 24px system-ui;margin:0 auto 26px;box-shadow:0 8px 30px rgba(0,0,0,.25)}
    #gcard h1{font:700 ${phone ? 32 : 46}px/1.1 "Bricolage Grotesque",system-ui,sans-serif;margin:0 0 14px;letter-spacing:-.01em}
    #gcard p{font-size:${phone ? 17 : 21}px;opacity:.86;margin:0}
    #gcard small{display:block;margin-top:34px;font:500 13px "IBM Plex Mono",monospace;letter-spacing:.08em;opacity:.7}
    #gcard ul{list-style:none;padding:0;margin:26px auto 0;display:grid;gap:10px;text-align:left;font-size:${phone ? 15 : 18}px;max-width:520px}
    #gcard li::before{content:"✓";color:#f2b23a;font-weight:700;margin-right:10px}
    .gtap{position:fixed;z-index:9998;width:46px;height:46px;margin:-23px 0 0 -23px;border-radius:50%;background:rgba(242,178,58,.5);border:3px solid #f2b23a;pointer-events:none;animation:gtap .65s ease-out forwards}
    @keyframes gtap{from{transform:scale(.35);opacity:1}to{transform:scale(1.45);opacity:0}}
    ${phone ? '#gcap{left:10px;right:10px;bottom:12px} main{padding-bottom:180px!important} .fab{bottom:160px!important} .toast{top:70px!important;bottom:auto!important}'
            : '#gcap{left:24px;bottom:24px;width:470px} .fab{display:none!important}'}`;
  addEventListener('DOMContentLoaded', () => { const s = document.createElement('style'); s.textContent = css; document.head.append(s); });
  window.__cap = (n, of, t, sub) => { let el = document.getElementById('gcap'); if (!el){ el = document.createElement('div'); el.id = 'gcap'; el.className = 'off'; document.body.append(el); }
    if (!t){ el.className = 'off'; return; }
    el.innerHTML = `<div class="k">${n ? `Step ${n} of ${of}` : 'CrewDesk'}<span class="bar"><i style="width:${n ? Math.round(n / of * 100) : 100}%"></i></span></div><div class="t">${t}</div>${sub ? `<div class="s">${sub}</div>` : ''}`;
    el.className = ''; };
  window.__card = (t, sub, list, foot) => { let el = document.getElementById('gcard'); if (!t){ if (el){ el.style.opacity = 0; setTimeout(() => el.remove(), 450); } return; }
    if (!el){ el = document.createElement('div'); el.id = 'gcard'; document.body.append(el); } el.style.opacity = 1;
    el.innerHTML = `<div><span class="logo">CD</span><h1>${t}</h1><p>${sub || ''}</p>${list ? `<ul>${list.map(x => `<li>${x}</li>`).join('')}</ul>` : ''}${foot ? `<small>${foot}</small>` : ''}</div>`; };
  window.__tap = (x, y) => { const d = document.createElement('div'); d.className = 'gtap'; d.style.left = x + 'px'; d.style.top = y + 'px'; document.body.append(d); setTimeout(() => d.remove(), 750); };
};
// chapters: when each numbered step first appears, for the help page's "jump to" list
let T0 = 0, CHAPTERS = [];
function kit(p, total){
  T0 = Date.now(); CHAPTERS = [];
  const k = {
    cap: (n, t, sub) => { if (n && !CHAPTERS.some(c => c.n === n)) CHAPTERS.push({n, t:Math.max(0, (Date.now() - T0) / 1000 - 0.5), title:t}); return p.evaluate(([n, of, t, s]) => window.__cap(n, of, t, s), [n, total, t, sub]); },
    card: (t, sub, list, foot) => p.evaluate(([t, s, l, f]) => window.__card(t, s, l, f), [t, sub, list, foot]),
    show: async sel => { await p.$eval(sel, el => el.scrollIntoView({block:'center', behavior:'smooth'})); await wait(600); },
    tap: async sel => { await k.show(sel); const bb = await p.locator(sel).first().boundingBox();
      await p.evaluate(([x, y]) => window.__tap(x, y), [bb.x + bb.width / 2, bb.y + bb.height / 2]); await wait(380); await p.locator(sel).first().click(); await wait(450); },
    type: async (sel, text, delay = 45) => { await k.show(sel); const l = p.locator(sel).first(); await l.click(); await l.fill(''); await l.type(text, {delay}); await wait(180); },
    fill: async (o) => { for (const [s, v] of Object.entries(o)) await p.fill(s, v); },
  };
  return k;
}
async function finish(p, ctx, name, width){
  const raw = await p.video().path(); await ctx.close();
  fs.mkdirSync(OUT, {recursive:true});
  const mp4 = path.join(OUT, name + '.mp4'), poster = path.join(OUT, name + '.jpg');
  execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-i', raw, '-vf', `scale=${width}:-2:flags=lanczos,fps=30`, '-c:v', 'libx264', '-preset', 'slow', '-crf', '26', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-an', mp4]);
  execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-ss', '1.6', '-i', mp4, '-frames:v', '1', '-vf', `scale=${Math.min(width, 960)}:-2`, '-q:v', '4', poster]);
  fs.writeFileSync(path.join(OUT, name + '.chapters.json'), JSON.stringify(CHAPTERS.map(c => ({...c, t:Math.round(c.t * 10) / 10})), null, 1));
  console.log('wrote', mp4, (fs.statSync(mp4).size / 1e6).toFixed(1) + ' MB');
}

// ---------------------------------------------------------------- sample images, clearly marked as samples
async function samples(){
  const [c, art] = await browser({viewport:{width:800, height:600}}); await art.goto(URL);
  const draw = async kind => Buffer.from((await art.evaluate(k => {
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
  const out = {photo:await draw('photo'), aadhaar:await draw('aadhaar'), pan:await draw('pan')}; await c.close(); return out;
}
const IMG = await samples();
const COMPANY = {'#co-legal':'Swastik Stories Pvt Ltd', '#co-pan':'AABCS1234K', '#co-tan':'MUMS12345C', '#co-addr':'Andheri West, Mumbai', '#co-bank':'HDFC Bank', '#co-acct':'50200011112222', '#co-ifsc':'HDFC0000212'};

// uploads go through the same image-shrinking and storage path as the app; retry if a redraw swallowed the file
async function upload(p, kind, buf, check){
  for (let i = 0; i < 3; i++){
    await p.setInputFiles(`input[data-upload=${kind}]`, {name:kind + '.png', mimeType:'image/png', buffer:buf});
    try { await p.waitForFunction(check, null, {timeout:6000}); return; } catch (e) { if (i === 2) throw e; }
  }
}
// the crew member's own steps, used on camera (crew video) or off camera (office video)
async function crewJoin(p, code, k){
  if (k){ await k.type('#join-code', code); await k.type('#join-phone', '98111 22233'); await k.tap('form[data-form=join] button[type=submit]'); }
  else { await p.fill('#join-code', code); await p.fill('#join-phone', '98111 22233'); await p.click('form[data-form=join] button[type=submit]'); }
  await p.waitForSelector('[data-form=profile]');
}
async function crewProfile(p, k){
  const v = {'#pf-legal':'Kavya Rao', '#pf-addr':'Malad West, Mumbai 400064', '#pf-pan':'ABCPR1234K', '#pf-holder':'Kavya Rao', '#pf-bank':'State Bank of India', '#pf-acct':'30211122233', '#pf-ifsc':'SBIN0001234'};
  await upload(p, 'photo', IMG.photo, () => !!me().photo);
  if (k){ await wait(1200); await k.cap(4, 'Fill your details exactly as on your PAN card and bank account', 'Only you, the CFO, the Commercial Head and Accounts can see them.'); await wait(1500);
    for (const [s, t] of Object.entries(v)) await k.type(s, t); await k.tap('form[data-form=profile] button[type=submit]'); }
  else { for (const [s, t] of Object.entries(v)) await p.fill(s, t); await p.click('form[data-form=profile] button[type=submit]'); }
  await p.waitForSelector('[data-form=docs]');
}
async function crewDocs(p, k){
  if (k){ await k.cap(5, 'Upload photos of your Aadhaar and PAN card', 'Cover the first 8 Aadhaar digits (a masked Aadhaar), then enter its last 4 digits.'); await k.show('[data-form=docs]'); await wait(2000); }
  await upload(p, 'aadhaar', IMG.aadhaar, () => !!me().docs.aadhaar); if (k) await wait(700);
  await upload(p, 'pan', IMG.pan, () => !!me().docs.pan); if (k) await wait(700);
  if (k){ await k.type('#dc-a4', '4821'); await k.tap('#dc-consent'); await k.tap('form[data-form=docs] button[type=submit]'); }
  else { await p.fill('#dc-a4', '4821'); await p.check('#dc-consent'); await p.click('form[data-form=docs] button[type=submit]'); }
  await p.waitForFunction(() => me().ready.docs, null, {timeout:8000}).catch(async e => { console.log('docs not ready:', await p.evaluate(() => [document.getElementById('dc-err')?.textContent, JSON.stringify(me().ready), JSON.stringify(me().docs).slice(0, 80), me().aadhaar4, me().consent])); throw e; });
}
async function crewSign(p, k){
  await p.waitForFunction(() => memberIn(U.pid, S.session)?.ag?.status === 'sent', null, {timeout:15000});
  await p.evaluate(() => render()); await p.waitForSelector('#sg-name');
  if (k){ await k.cap(6, 'Read your agreement, type your name and sign with your finger', 'It shows your role, rate, payment terms and the tax deducted.'); await k.show('.agreement'); await wait(2600); await k.type('#sg-name', 'Kavya Rao'); await k.show('#sig'); }
  else { await p.fill('#sg-name', 'Kavya Rao'); await p.$eval('#sig', el => el.scrollIntoView({block:'center'})); }
  const bb = await p.locator('#sig').boundingBox(), pts = [[.12, .62], [.2, .3], [.27, .7], [.34, .35], [.42, .66], [.5, .4], [.58, .62], [.66, .45], [.76, .6], [.86, .5]];
  await p.mouse.move(bb.x + bb.width * pts[0][0], bb.y + bb.height * pts[0][1]); await p.mouse.down();
  for (const [x, y] of pts.slice(1)) await p.mouse.move(bb.x + bb.width * x, bb.y + bb.height * y, {steps:6}); await p.mouse.up();
  if (k){ await wait(500); await k.tap('form[data-form=sign] button[type=submit]'); } else await p.click('form[data-form=sign] button[type=submit]');
  await p.waitForFunction(() => memberIn(U.pid, S.session)?.ag?.status === 'signed', null, {timeout:8000});
}
async function crewInvoice(p, k){
  if (k){ await k.tap('.rail [data-id=invoices]'); await wait(600); await k.tap('[data-act=raise]'); await wait(400); }
  else { await p.evaluate(() => reload().then(render)); await p.click('.rail [data-id=invoices]'); await p.click('[data-act=raise]'); }
  await p.evaluate(([f, t]) => { for (const [id, v] of [['rv-from', f], ['rv-to', t]]){ const el = document.getElementById(id); el.value = v; el.dispatchEvent(new Event('input', {bubbles:true})); } }, [isoDay(-6), isoDay(-1)]);
  if (k){ await wait(900); await k.type('#rv-no', 'KR-001'); await k.show('#rv-calc'); await wait(2200); await k.tap('form[data-form=raise] button[type=submit]'); }
  else { await p.fill('#rv-no', 'KR-001'); await p.click('form[data-form=raise] button[type=submit]'); }
  await p.waitForFunction(() => S.invoices.some(i => i.no === 'KR-001'), null, {timeout:8000});
}
const kavya = "S.members.find(m => !m.synthetic && user(m.userId)?.name === 'Kavya Rao')";

if (MODE === 'crew'){
  // ---------------------------------------------------------------- the production office, off camera
  const [, o] = await browser({viewport:{width:1280, height:900}});
  await o.goto(URL); await o.waitForSelector('.gbtn'); await o.evaluate(() => { document.querySelector('.pwbox').open = true; });
  await o.fill('#li-user', 'fowzan'); await o.fill('#li-pass', 'whatever123'); await o.click('form[data-form=login] button[type=submit]'); await o.waitForSelector('#co-legal');
  for (const [s, v] of Object.entries(COMPANY)) await o.fill(s, v);
  await o.click('form[data-form=company] button[type=submit]'); await o.waitForSelector('#np-name');
  await o.fill('#np-name', 'Saath Phere'); await o.selectOption('#np-status', 'Shooting'); await o.click('form[data-form=project] button[type=submit]'); await o.waitForSelector('.codegen .code');
  const code = (await o.textContent('.codegen .code')).trim();
  await o.evaluate(() => { U.view = 'people'; render(); }); await o.click('[data-act=onboard]');
  await o.fill('#ob-name', 'Kavya Rao'); await o.fill('#ob-phone', '98111 22233'); await o.fill('#ob-rate', '3500');
  await o.selectOption('#ob-dept', 'Hair & Makeup'); await o.selectOption('#ob-job', 'Makeup Artist'); await o.click('form[data-form=onboard] button[type=submit]'); await wait(300);
  await o.evaluate(([f, t]) => call('plan_days', {p_production:U.pid, p:{from:f, to:t, skip_sundays:false, call:'07:00', wrap:'19:00', location:'Umargam · Floor 3', eps_per_day:1, start_ep:301}}), [isoDay(-6), isoDay(6)]);
  const office = body => o.evaluate(`(async () => { await reload(); const m = ${kavya}; ${body} })()`);

  // ---------------------------------------------------------------- the crew member's phone, on camera
  const [cam, p] = await browser({viewport:{width:390, height:844}, isMobile:true, hasTouch:true, recordVideo:{dir:TMP, size:{width:390, height:844}}}, {email:'kavya.rao@gmail.com', name:'Kavya Rao'});
  await p.addInitScript(OVERLAY, true);
  const k = kit(p, 9);
  await p.goto(URL); await p.waitForSelector('.gbtn');
  await k.card('Set up your CrewDesk account', 'About 2 minutes, on your phone', null, 'FOR CREW · ARTISTS · VENDORS'); await wait(3400); await k.card();
  await k.cap(1, 'Open the CrewDesk link your Line Producer sent you', 'crewdesk-production.vercel.app'); await wait(2500);
  await k.cap(1, 'Tap “Continue with Google” and pick your Gmail', 'No password to remember. New here? This creates your account.'); await wait(2300);
  await k.tap('.gbtn'); await p.waitForSelector('#join-code'); await wait(600);
  await k.cap(2, 'Enter the production code and your mobile number', 'Every show has its own code. Use the mobile your Line Producer has, so CrewDesk finds your invite.'); await wait(2000);
  await crewJoin(p, code, k); await wait(900);
  await k.cap(3, 'You’re in. This page shows what’s left to do', 'Your deal is already set by the office. Start with a clear photo of your face for your Crew ID.'); await k.show('input[data-upload=photo]'); await wait(3000);
  await crewProfile(p, k); await wait(800);
  await crewDocs(p, k); await wait(900);
  await k.cap(0, 'Done for now. The office sends your agreement next', 'You’ll get a notification on the bell, top right.'); await p.evaluate(() => scrollTo({top:0, behavior:'smooth'})); await wait(2400);
  await office("U.pid = m.pid; await ACT['send-ag']({dataset:{id:m.id}});");
  await crewSign(p, k); await wait(1300);
  await k.cap(0, 'Signed. The CFO or Commercial Head approves it', 'You’re told the moment it’s approved.'); await wait(2200);
  await office('await ACT.countersign({dataset:{id:m.id}});');
  await p.waitForFunction(() => memberIn(U.pid, S.session)?.ag?.status === 'countersigned', null, {timeout:15000}); await p.evaluate(() => scrollTo({top:0, behavior:'smooth'})); await wait(1200);
  await k.cap(7, 'This is your Crew ID', 'Show the code at the gate on every shoot day. Your check-ins fill your invoice.'); await k.show('.idcard'); await wait(3800);
  await office("for (const d of S.days.filter(d => d.pid === m.pid && d.date < today()).slice(-4)) await call('check_in', {p_day:d.id, p_code:m.code});");
  await p.evaluate(() => reload().then(render)); await wait(800);
  await k.cap(8, 'To get paid, raise an invoice in My invoices', 'Pick the dates. Your days come in from the gate, so there’s nothing to count.'); await wait(1500);
  await crewInvoice(p, k); await wait(1300);
  await k.cap(9, 'The bell tells you when it’s checked, approved and paid', 'With the bank reference, so you can match it in your account.'); await wait(1200);
  await office("const i = S.invoices.find(x => x.no === 'KR-001'); await call('hod_approve', {p_id:i.id}); await call('final_approve', {p_id:i.id}); await call('pay_invoices', {p_production:i.pid, p_ids:[i.id], p_ref:'SBINR52026110310'});");
  await p.waitForFunction(() => S.invoices.some(i => i.no === 'KR-001' && i.status === 'paid'), null, {timeout:15000}); await wait(800);
  await k.tap('.bell'); if (!(await p.$('.notes'))) await p.evaluate(() => { U.notesOpen = true; render(); }); await wait(3800);
  await p.evaluate(() => { U.notesOpen = false; render(); });
  await k.cap(0, 'Stuck anywhere? Tap the round Guide button and ask', 'Or ask your Line Producer.'); await wait(2600);
  await k.card('You’re all set', 'See you on set', ['Crew ID at the gate', 'Invoice in a few taps', 'Updates on the bell'], 'CREWDESK-PRODUCTION.VERCEL.APP/HELP'); await wait(3200);
  await finish(p, cam, 'crewdesk-setup', 720);
} else {
  // ---------------------------------------------------------------- the crew member, off camera
  const [, c] = await browser({viewport:{width:390, height:844}}, {email:'kavya.rao@gmail.com', name:'Kavya Rao'});
  // ---------------------------------------------------------------- the CFO's laptop, on camera
  const [cam, p] = await browser({viewport:{width:1280, height:800}, recordVideo:{dir:TMP, size:{width:1280, height:800}}}, {email:'fowzan@swastikstories.com', name:'Fowzan'});
  await p.addInitScript(OVERLAY, false);
  const k = kit(p, 10);
  await p.goto(URL); await p.waitForSelector('.gbtn');
  await k.card('CrewDesk for the production office', 'From invite to payment, in about 3 minutes', null, 'FOR CFO · COMMERCIAL HEAD · LINE PRODUCER · ACCOUNTS'); await wait(3600); await k.card();
  await k.cap(1, 'Sign in with your Google account', 'Your role decides what you see: owners, Line Producers, HODs and Accounts each get their own view.'); await wait(2600);
  await k.tap('.gbtn'); await p.waitForSelector('#co-legal'); await wait(600);
  await k.cap(2, 'Once, at the start: your company details', 'Agreements, invoices, the TDS and GST registers and Tally all read from here.'); await wait(1500);
  await k.type('#co-legal', 'Swastik Stories Pvt Ltd', 30); await k.fill(Object.fromEntries(Object.entries(COMPANY).slice(1))); await k.show('form[data-form=company] button[type=submit]'); await wait(1300);
  await k.tap('form[data-form=company] button[type=submit]'); await p.waitForSelector('#np-name'); await wait(700);
  await k.cap(3, 'Create a production', 'Format, episodes and the shoot base.'); await k.type('#np-name', 'Saath Phere', 50); await p.selectOption('#np-status', 'Shooting'); await p.fill('#np-loc', 'Umargam · Floor 3'); await wait(900);
  await k.tap('form[data-form=project] button[type=submit]'); await p.waitForSelector('.codegen .code');
  const code = (await p.textContent('.codegen .code')).trim();
  await k.cap(3, 'Every show gets its own joining code', 'Share it with your crew. You can make a new one if it leaks.'); await k.show('.codegen'); await wait(3400);
  await k.tap('.rail [data-id=people]'); await wait(500);
  await k.cap(4, 'Onboard someone: set the deal once', 'Artist, crew or vendor; department, rate and joining date. Their invite goes on WhatsApp.'); await k.tap('[data-act=onboard]');
  await k.type('#ob-name', 'Kavya Rao', 40); await k.type('#ob-phone', '98111 22233', 40); await p.selectOption('#ob-dept', 'Hair & Makeup'); await wait(300);
  await p.selectOption('#ob-job', 'Makeup Artist'); await k.type('#ob-rate', '3500', 60); await wait(800);
  await k.tap('form[data-form=onboard] button[type=submit]'); await wait(2800); await p.click('.dialog [data-act=close-modal]'); await wait(400);
  // Kavya joins and fills her details on her phone
  await c.goto(URL); await c.waitForSelector('.gbtn'); await c.click('.gbtn'); await c.waitForSelector('#join-code');
  await crewJoin(c, code); await crewProfile(c); await crewDocs(c);
  await p.evaluate(() => reload().then(render)); await wait(800);
  await k.cap(5, 'Watch everyone’s progress live', 'Kavya filled her own bank, PAN and Aadhaar on her phone. She’s ready for her agreement.'); await k.show('#people-rows'); await wait(3000);
  await k.tap('#people-rows tr:has-text("Kavya Rao")'); await wait(900);
  await k.cap(5, 'Send the agreement in one tap', 'It’s filled from the deal and your company details. If the deal changes, it’s withdrawn and re-sent.'); await wait(1800);
  await k.tap('.drawer [data-act=send-ag]'); await wait(1600); await p.evaluate(() => { U.drawer = null; renderLayer(); });
  await crewSign(c);
  await p.evaluate(() => reload().then(render)); await p.waitForFunction(() => S.members.some(m => m.ag?.status === 'signed'), null, {timeout:15000}); await wait(600);
  await k.tap('.rail [data-id=home]'); await wait(500);
  await k.cap(6, 'Home shows what’s waiting on you', 'Kavya signed. The bell told you; approving it finishes her onboarding.'); await wait(2800);
  await k.tap('main [data-act=open-person]'); await wait(800); await k.tap('.drawer [data-act=countersign]'); await wait(1400); await p.evaluate(() => { U.drawer = null; renderLayer(); });
  await k.tap('.rail [data-id=schedule]'); await wait(500);
  await k.cap(7, 'Plan shoot days, then check people in at the gate', 'Each check-in becomes a working day on their invoice.'); await k.tap('[data-act=plan]');
  await p.fill('#pl-from', isoDay(-6)); await p.fill('#pl-to', isoDay(6)); await p.uncheck('#pl-sun'); await p.fill('#pl-ep', '301'); await wait(1200);
  await k.tap('form[data-form=plan] button[type=submit]'); await wait(1600);
  const crewCode = await p.evaluate(`${kavya}.code`);
  for (const [i, id] of (await p.evaluate(() => S.days.filter(d => d.date < today()).slice(-4).map(d => d.id))).entries()){
    await p.evaluate(id => { U.drawer = {type:'day', id}; renderLayer(); }, id); await wait(i ? 250 : 900);
    if (i) await p.fill('#ci-code', crewCode); else await k.type('#ci-code', crewCode, 70);
    await (i ? p.click('form[data-form=checkin] button[type=submit]') : k.tap('form[data-form=checkin] button[type=submit]')); await wait(i ? 350 : 1400);
  }
  await p.evaluate(() => { U.drawer = null; renderLayer(); });
  await crewInvoice(c);
  await p.evaluate(() => reload().then(render)); await k.tap('.rail [data-id=invoices]'); await wait(600);
  await k.cap(8, 'Approve invoices: HOD check, then final approval', 'Days are checked against gate check-ins. Nobody can approve their own invoice.'); await wait(2600);
  await k.tap('main [data-act=hod-ok]'); await wait(1000); await k.tap('main [data-act=final-ok]'); await wait(1000);
  await k.cap(8, 'Take off an advance or a loss before paying', 'Every deduction has a reason the person sees. TDS stays on the full fee.'); await k.tap('main [data-act=adjust]');
  await p.selectOption('#dd-t0', 'advance'); await k.type('#dd-a0', '2000', 60); await k.type('#dd-n0', 'Advance paid on day 1', 25); await wait(1400);
  await k.tap('form[data-form=adjust] button[type=submit]'); await wait(1300);
  await k.tap('.rail [data-id=finance]'); await wait(500);
  await k.cap(9, 'Pay in one run, then send it to Tally', 'You get the bank’s bulk-payment file. Vouchers carry GST, TDS and deductions.'); await wait(1400);
  await k.tap('input[data-change=selall]'); await wait(400); await k.tap('[data-act=payrun]'); await k.type('#md-v', 'HDFCBATCH0412', 40); await wait(500);
  await k.tap('form[data-form=payrun] button[type=submit]'); await wait(1200);
  await k.tap('[data-act=ftab][data-id=tally]'); await wait(900); await k.tap('[data-act=tally-preview]'); await wait(2600); await p.evaluate(() => { U.modal = null; renderLayer(); });
  await k.tap('.rail [data-id=reports]'); await wait(600);
  await k.cap(10, 'Reports and Excel, any day of the month', 'Cost by department, shoot days, budget used, payments, and separate lists of artists, crew and vendors.'); await wait(1200);
  await p.evaluate(() => scrollTo({top:520, behavior:'smooth'})); await wait(2600); await p.evaluate(() => scrollTo({top:0, behavior:'smooth'})); await wait(900);
  await k.tap('.rail [data-id=agreements]'); await wait(500);
  await k.cap(10, 'Agreements and the activity log keep everyone honest', 'Filter by artist, crew or vendor and by status. Every change is logged and can be undone.'); await wait(3000);
  await k.tap('.rail [data-id=activity]'); await wait(2600);
  await k.cap(0, 'Stuck? Tap Guide, or open the help page from your name menu', ''); await wait(2200);
  await k.card('That’s a show, start to finish', 'Invite → agreement → schedule → invoice → payment → Tally', ['Each show has its own code', 'Everyone sees only what their role allows', 'Every change is on record'], 'CREWDESK-PRODUCTION.VERCEL.APP/HELP'); await wait(3600);
  await finish(p, cam, 'crewdesk-office', 1280);
}
await b.close(); server.close(); process.exit(0);
