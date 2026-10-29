// CrewDesk app: screens, routing and actions. Data rules live in the database (supabase/migrations);
// this file only shows what the signed-in person is allowed to see and calls the database functions.
import { createBackend } from './backend.js';

const QR_SRC = 'https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js';

/* ================================================================ utilities */
const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const inr = n => '₹' + Math.round(+n || 0).toLocaleString('en-IN');
const pad = n => String(n).padStart(2, '0');
const isoDate = d => d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
const today = () => isoDate(new Date());
const addDays = (s, n) => { const d = new Date(s + 'T00:00:00'); d.setDate(d.getDate() + n); return isoDate(d); };
const fmtD = s => s ? new Date(String(s).slice(0, 10) + 'T00:00:00').toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '—';
const fmtDay = s => new Date(s + 'T00:00:00').toLocaleDateString('en-IN', { weekday: 'short', day: 'numeric', month: 'short' });
const fmtTS = t => t ? new Date(t).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' }) : '—';
const hm = t => t ? String(t).slice(0, 5) : '—';
const initials = s => (s || '?').split(/\s+/).map(w => w[0]).slice(0, 2).join('').toUpperCase();
const by = (f, desc) => (a, b) => (f(a) < f(b) ? -1 : f(a) > f(b) ? 1 : 0) * (desc ? -1 : 1);
const groupBy = (xs, f) => xs.reduce((m, x) => ((m[f(x)] ||= []).push(x), m), {});
const sum = (xs, f) => xs.reduce((s, x) => s + (+f(x) || 0), 0);

const PAN_RE = /^[A-Z]{5}[0-9]{4}[A-Z]$/, IFSC_RE = /^[A-Z]{4}0[A-Z0-9]{6}$/;
function gstinOk(g){
  if (!/^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/.test(g)) return false;
  const cs = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'; let t = 0;
  for (let i = 0; i < 14; i++) { const p = cs.indexOf(g[i]) * (i % 2 ? 2 : 1); t += Math.floor(p / 36) + p % 36; }
  return cs[(36 - t % 36) % 36] === g[14];
}
const STATES = {'01':'Jammu & Kashmir','02':'Himachal Pradesh','03':'Punjab','04':'Chandigarh','05':'Uttarakhand','06':'Haryana','07':'Delhi','08':'Rajasthan','09':'Uttar Pradesh','10':'Bihar','11':'Sikkim','12':'Arunachal Pradesh','13':'Nagaland','14':'Manipur','15':'Mizoram','16':'Tripura','17':'Meghalaya','18':'Assam','19':'West Bengal','20':'Jharkhand','21':'Odisha','22':'Chhattisgarh','23':'Madhya Pradesh','24':'Gujarat','26':'Dadra & Nagar Haveli and Daman & Diu','27':'Maharashtra','29':'Karnataka','30':'Goa','31':'Lakshadweep','32':'Kerala','33':'Tamil Nadu','34':'Puducherry','35':'Andaman & Nicobar','36':'Telangana','37':'Andhra Pradesh','38':'Ladakh'};

const ROLES = { producer: 'Producer', manager: 'Production manager', accounts: 'Accounts', hod: 'Head of department', crew: 'Crew', vendor: 'Vendor' };
const KINDS = { film: 'Feature film', series: 'Series', web: 'Web series', ad: 'Ad film', documentary: 'Documentary', music: 'Music video', other: 'Other' };
const C_STATUS = { draft: ['', 'Draft'], sent: ['warn', 'Awaiting signature'], signed: ['info', 'Awaiting countersign'], countersigned: ['ok', 'Fully signed'], void: ['', 'Void'] };
const I_STATUS = { submitted: ['warn', 'Submitted'], hod_approved: ['info', 'HOD approved'], approved: ['ok', 'Approved'], rejected: ['bad', 'Rejected'], paid: ['ok', 'Paid'] };
const pill = (map, s) => `<span class="pill ${map[s]?.[0] || ''}">${esc(map[s]?.[1] || s)}</span>`;

function toast(msg){
  document.querySelectorAll('.toast').forEach(t => t.remove());
  const t = document.createElement('div'); t.className = 'toast'; t.setAttribute('role', 'status'); t.textContent = msg;
  document.body.appendChild(t); setTimeout(() => t.remove(), 3200);
}
function openSheet(html, onOpen){
  const d = $('#dlg'); $('#dlgBody').innerHTML = html; d.showModal(); onOpen?.(d);
}
function closeSheet(){ const d = $('#dlg'); if (d.open) d.close(); }
$('#dlg').addEventListener('click', e => { if (e.target.id === 'dlg') closeSheet(); });

function download(name, text, type){
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([text], { type })); a.download = name;
  document.body.appendChild(a); a.click(); setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 500);
}
function printHTML(html){ $('#print').innerHTML = html; window.print(); }
let qrReady;
function loadQR(){ return qrReady ||= new Promise((ok, no) => { const s = document.createElement('script'); s.src = QR_SRC; s.onload = ok; s.onerror = () => no(new Error('QR library failed to load')); document.head.appendChild(s); }); }

/* ================================================================ state */
let BE, USER = null, MYPROFILE = null, PROJECTS = [], P = null;
const role = () => P?.role;
const canManage = () => ['producer', 'manager'].includes(role());
const canPay = () => ['producer', 'manager', 'accounts'].includes(role());
const isProducer = () => role() === 'producer';
const person = id => P?.people[id] || { full_name: 'Unknown', id };
const nameOf = id => { const p = person(id); return p.full_name || p.legal_name || p.username || 'Unknown'; };
const memberOf = id => P?.members.find(m => m.user_id === id);

async function loadHome(){
  const [projects, mine, me] = await Promise.all([
    BE.select('projects', { order: 'created_at', desc: true }),
    BE.select('members', { eq: { user_id: USER.id } }),
    BE.select('profiles', { eq: { id: USER.id } })
  ]);
  MYPROFILE = me[0] || null;
  PROJECTS = projects.map(p => ({ ...p, member: mine.find(m => m.project_id === p.id) })).filter(p => p.member?.active);
}

async function loadProject(id){
  const [projRows, members, people, contracts, templates, invoices, sheets, reports, attendance] = await Promise.all([
    BE.select('projects', { eq: { id } }),
    BE.select('members', { eq: { project_id: id } }),
    BE.select('directory'),
    BE.select('contracts', { eq: { project_id: id }, order: 'created_at', desc: true }),
    BE.select('contract_templates', { order: 'created_at' }),
    BE.select('invoices', { eq: { project_id: id }, order: 'created_at', desc: true }),
    BE.select('call_sheets', { eq: { project_id: id }, order: 'shoot_date' }),
    BE.select('day_reports', { eq: { project_id: id }, order: 'shoot_date' }),
    BE.select('attendance', { eq: { project_id: id }, order: 'check_in', desc: true })
  ]);
  if (!projRows.length) throw new Error('You are not on this project');
  const me = members.find(m => m.user_id === USER.id);
  P = { id, project: projRows[0], members, people: Object.fromEntries(people.map(p => [p.id, p])), contracts,
        templates: templates.filter(t => !t.project_id || t.project_id === id), invoices, sheets, reports, attendance,
        me, role: me?.role, batches: [], report: [], views: [] };
  const extra = [];
  if (canPay()) extra.push(BE.select('payment_batches', { eq: { project_id: id }, order: 'created_at', desc: true }).then(r => P.batches = r),
                          BE.rpc('cost_report', { p_project: id }).then(r => P.report = r || []));
  if (canManage()) extra.push(BE.select('call_sheet_views').then(r => P.views = r));
  // a read counts only if it happened after the sheet was last published
  P.readersOf = s => P.views.filter(v => v.call_sheet_id === s.id && s.published_at && v.viewed_at >= s.published_at).map(v => v.user_id);
  await Promise.all(extra);
}
async function refresh(){ const u = USER; try { if (P) await loadProject(P.id); } catch (e) { if (USER !== u) return; throw e; } if (USER === u) render(); }

// run a database action; on success refresh and toast, on failure show the database's message
// Successful project actions reload the project before confirming, so the next screen is never stale.
async function act(fn, ok){
  let r;
  try { r = await fn(); }
  catch (e) { toast(e.message.replace(/^.*?ERROR:\s*/, '')); return null; }
  if (ok && P) { try { await loadProject(P.id); } catch {} }
  if (ok) toast(ok);
  return r ?? true;
}

/* ================================================================ routing + chrome */
const route = () => (location.hash.replace(/^#\/?/, '').split('?')[0] || '').split('/').filter(Boolean);
const go = h => { if (location.hash === '#' + h) render(); else location.hash = h; };
window.addEventListener('hashchange', () => render());

const ICON = {
  today: '<path d="M4 6h16v14H4zM4 10h16M9 3v4M15 3v4"/>',
  crew: '<circle cx="9" cy="8" r="3.2"/><path d="M3 20c.6-3.4 3-5.5 6-5.5s5.4 2.1 6 5.5M16 5.2a3 3 0 010 5.6M18 14.6c1.6.7 2.7 2.4 3 5.4"/>',
  contracts: '<path d="M7 3h7l5 5v13H7zM14 3v5h5M10 13h6M10 17h4"/>',
  money: '<rect x="3" y="6" width="18" height="13" rx="2"/><path d="M3 10h18M7 15h3"/>',
  schedule: '<path d="M4 5h16v15H4zM4 9h16M8 13h3M8 16h6"/>'
};
function chrome(){
  const r = route(), bar = $('#bar'), tabs = $('#tabs');
  const band = $('#demoBand');
  band.hidden = BE?.mode !== 'demo';
  if (!band.hidden) band.innerHTML = `<span>Demo: sample data that stays in this browser${USER ? ' · signed in as ' + esc(MYPROFILE?.full_name || '') : ''}</span>
    <span>${USER ? '<button data-act="signout">Switch person</button> · ' : ''}<button data-act="reset-demo">Reset demo</button></span>`;
  if (r[0] === 'p' && P) {
    bar.innerHTML = `<button data-go="/" aria-label="All projects">←</button>
      <div class="title"><b>${esc(P.project.name)}</b><small>${esc(ROLES[role()] || '')}${P.me?.department ? ' · ' + esc(P.me.department) : ''}</small></div>
      <button data-go="/profile" aria-label="Your profile">${esc(initials(MYPROFILE?.full_name))}</button>`;
    const cur = r[2] || 'today';
    const map = { crew: 'crew', id: 'crew', checkin: 'crew', member: 'crew', contracts: 'contracts', contract: 'contracts',
                  money: 'money', invoice: 'money', payments: 'money', budget: 'money', exports: 'money', schedule: 'schedule', sheet: 'schedule' };
    const active = map[cur] || 'today';
    const t = todo();
    const badges = { today: t.length, contracts: P.contracts.filter(c => (c.status === 'sent' && c.user_id === USER.id) || (c.status === 'signed' && isProducer())).length,
                     money: approvalsForMe().length };
    tabs.hidden = false;
    tabs.querySelector('.inner').innerHTML = [['today', 'Today'], ['crew', 'Crew'], ['contracts', 'Contracts'], ['money', canPay() || role() === 'hod' ? 'Money' : 'Invoices'], ['schedule', 'Schedule']]
      .map(([k, l]) => `<a href="#/p/${P.id}${k === 'today' ? '' : '/' + k}" ${active === k ? 'aria-current="page"' : ''}>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICON[k]}</svg>${l}
        ${badges[k] ? `<span class="dot">${badges[k]}</span>` : ''}</a>`).join('');
  } else {
    tabs.hidden = true;
    bar.innerHTML = `<div class="title logo"><svg width="26" height="26" viewBox="0 0 512 512" aria-hidden="true"><rect width="512" height="512" rx="112" fill="#f2b544"/><path d="M112 192h288v208H112z" fill="#1f2a44"/><path d="M112 112l288-32 13 80-288 32z" fill="#fff"/></svg>CrewDesk</div>
      ${USER ? `<button data-go="/profile" aria-label="Your profile">${esc(initials(MYPROFILE?.full_name))}</button>` : ''}`;
  }
}

// Each render gets a number; if a newer render (or a sign-out) starts while this one is still
// loading, this one stops instead of drawing stale data over the newer screen.
let RENDER = 0;
async function render(){
  const gen = ++RENDER, stale = () => gen !== RENDER; window.__renders = (window.__renders || 0) + 1;   // read by the browser tests to catch redraw loops
  const view = $('#view');
  const r = route();
  try {
    if (!USER) { chrome(); const h = await vAuth(); if (stale()) return; view.innerHTML = h; return after(); }
    if (r[0] === 'join' && r[1]) return joinFlow(r[1]);
    if (r[0] === 'p' && r[1]) {
      if (!P || P.id !== r[1]) { view.innerHTML = '<div class="empty">Loading project…</div>'; await loadProject(r[1]); }
    } else { P = null; if (!PROJECTS.length || r[0] !== 'profile') await loadHome(); }
    if (stale()) return;
    chrome();
    let html;
    if (r[0] === 'profile') html = vProfile();
    else if (r[0] === 'new') html = vNewProject();
    else if (r[0] === 'p') {
      const [, , sec, a, b] = r;
      html = ({ undefined: vToday, crew: vCrew, member: () => vMember(a), id: vIdCard, checkin: vCheckin,
                contracts: vContracts, contract: () => vContract(a), money: vMoney, invoice: () => a === 'new' ? vNewInvoice() : vInvoice(a),
                payments: vPayments, budget: vBudget, exports: vExports, schedule: vSchedule,
                sheet: () => b === 'edit' ? vSheetEdit(a) : vSheet(a), settings: vSettings }[sec] || vToday)();
    } else html = vHome();
    html = await html;
    if (stale()) return;
    view.innerHTML = html;
    after();
  } catch (e) {
    if (stale()) return;
    chrome();
    view.innerHTML = `<div class="empty"><p>${esc(e.message)}</p><button class="btn" data-go="/">Back to your projects</button></div>`;
  }
}
// per-screen hooks that need live DOM (signature pad, QR, scanner, form previews)
let hooks = [];
function after(){ const h = hooks; hooks = []; h.forEach(f => f()); }

/* ================================================================ sign in */
async function vAuth(){
  const demo = BE.mode === 'demo';
  const personas = demo ? await BE.personas() : [];
  const hero = `<div class="hero"><h1>Run your production from your phone.</h1>
    <p class="muted">Crew onboarding, contracts with e-signature, invoices, approvals, payment runs, call sheets and Tally export, in one place.</p></div>
    <div class="feature-grid">
      <div><b>One-time KYC</b>Crew enter PAN, GSTIN and bank once and reuse them on every project.</div>
      <div><b>Contracts</b>Auto-filled from the deal, signed on a phone, with a full audit trail.</div>
      <div><b>Invoices in seconds</b>Raised from the deal and attendance, checked for GST, routed to the HOD and accounts.</div>
      <div><b>Payment runs</b>Batch approved invoices into a bank file and export everything to Tally.</div>
      <div><b>Call sheets</b>Publish the day, see who has read it, file the day report.</div>
      <div><b>Live cost report</b>Budget against committed and paid spend, by department.</div>
    </div>`;
  if (demo) return hero + `<h2>Try it as someone on a production</h2>
    <p class="muted small">This demo runs entirely in your browser with a sample series, “Monsoon Diaries”. Pick a person to see what they see.</p>
    <div class="stack">${personas.map(p => `<button class="persona" data-act="persona" data-u="${esc(p.username)}">
      <span class="avatar">${esc(initials(p.full_name))}</span><span class="grow"><b>${esc(p.full_name)}</b>
      <span class="muted small" style="display:block">${esc((p.roles || '').split(', ').map(r => ROLES[r] || r).join(', ') || 'No project yet')}</span></span><span aria-hidden="true">→</span></button>`).join('')}</div>
    <h2>Or start fresh</h2>${signUpForm()}`;
  return hero + `<div class="card" style="margin-top:8px">
      <div class="chips" role="tablist"><button class="chip" aria-pressed="${AUTHTAB === 'in'}" data-act="authtab" data-t="in">Sign in</button>
      <button class="chip" aria-pressed="${AUTHTAB === 'up'}" data-act="authtab" data-t="up">Create account</button></div>
      ${AUTHTAB === 'in' ? `<form data-form="signin" class="stack" novalidate>
        <div class="field"><label for="login">Username or email</label><input id="login" name="login" autocomplete="username" required></div>
        <div class="field"><label for="pw">Password</label><input id="pw" name="password" type="password" autocomplete="current-password" required></div>
        <button class="btn block">Sign in</button>
        <div class="between small"><button type="button" class="btn ghost sm" data-act="code-signin">Email me a sign-in code</button>
        <button type="button" class="btn ghost sm" data-act="forgot">Forgot password</button></div></form>` : signUpForm()}
    </div>`;
}
let AUTHTAB = 'in';
const signUpForm = () => `<form data-form="signup" class="stack card" novalidate>
  <div class="field"><label for="su_name">Full name</label><input id="su_name" name="full_name" autocomplete="name" required><span class="err" data-err="full_name"></span></div>
  <div class="field"><label for="su_user">Username</label><input id="su_user" name="username" autocomplete="username" required pattern="[a-z0-9_.]{3,30}"><span class="hint">3–30 characters: lowercase letters, numbers, dot or underscore. You can sign in with it.</span><span class="err" data-err="username"></span></div>
  <div class="field"><label for="su_email">Email</label><input id="su_email" name="email" type="email" autocomplete="email" required><span class="err" data-err="email"></span></div>
  ${BE.mode === 'live' ? `<div class="field"><label for="su_pw">Password</label><input id="su_pw" name="password" type="password" autocomplete="new-password" minlength="8" required><span class="hint">At least 8 characters.</span><span class="err" data-err="password"></span></div>` : ''}
  <button class="btn block">Create account</button></form>`;

/* ================================================================ home + profile */
function kycMissing(p){
  if (!p) return [];
  return [['legal name', p.legal_name], ['PAN', p.pan], ['address', p.address], ['account holder', p.bank_holder], ['bank account', p.bank_account], ['IFSC', p.bank_ifsc]]
    .filter(([, v]) => !String(v || '').trim()).map(([k]) => k);
}
function vHome(){
  const miss = kycMissing(MYPROFILE);
  return `<h1>Hi ${esc((MYPROFILE?.full_name || '').split(' ')[0] || 'there')}</h1>
  ${miss.length ? `<a class="alert warn" style="display:block;text-decoration:none;margin:10px 0" href="#/profile"><b>Finish your profile</b> so you can sign contracts and get paid. Missing: ${esc(miss.join(', '))}. →</a>` : ''}
  <h2>Your productions</h2>
  <div class="list">${PROJECTS.map(p => `<a class="item" href="#/p/${p.id}"><span class="avatar">${esc(initials(p.name))}</span>
    <span class="grow"><b>${esc(p.name)}</b><span class="meta" style="display:block">${esc(KINDS[p.kind] || p.kind)} · ${esc(p.company_name)}</span></span>
    <span class="pill">${esc(ROLES[p.member.role])}</span></a>`).join('') || '<div class="empty">You are not on any production yet. Join one with the invite code from your production office, or create your own.</div>'}</div>
  <h2>Join a production</h2>
  <form data-form="join" class="row" novalidate><div class="field grow"><label for="jcode" class="sr">Invite code</label>
    <input id="jcode" name="code" placeholder="Invite code, e.g. 7F3K9Q2A" autocapitalize="characters" required></div>
    <button class="btn">Join</button></form>
  <label class="row small muted" style="margin-top:6px"><input type="checkbox" form="" id="asVendor"> I'm joining as a vendor or rental company</label>
  <div class="actions"><a class="btn ghost" href="#/new">+ New production</a></div>`;
}
async function joinFlow(code){
  P = null;
  const pr = await act(() => BE.rpc('join_project', { p_code: code, p_as_vendor: false }), 'You joined the production');
  await loadHome();
  go(pr ? '/p/' + pr.id : '/');
}

function field(name, label, value, opts = {}){
  const id = 'f_' + name;
  const attrs = Object.entries(opts.attrs || {}).map(([k, v]) => `${k}="${esc(v)}"`).join(' ');
  const input = opts.type === 'textarea' ? `<textarea id="${id}" name="${name}" ${attrs}>${esc(value)}</textarea>`
    : opts.type === 'select' ? `<select id="${id}" name="${name}" ${attrs}>${opts.options.map(([v, l]) => `<option value="${esc(v)}" ${String(v) === String(value ?? '') ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select>`
    : `<input id="${id}" name="${name}" type="${opts.type || 'text'}" value="${esc(value)}" ${attrs}>`;
  return `<div class="field"><label for="${id}">${esc(label)}</label>${input}${opts.hint ? `<span class="hint">${esc(opts.hint)}</span>` : ''}<span class="err" data-err="${name}"></span></div>`;
}
function vProfile(){
  const p = MYPROFILE || {};
  const miss = kycMissing(p);
  return `<h1>Your profile</h1>
  <p class="muted">Fill this in once. Every production you join uses it for contracts, invoices and payments. Only you, and the producer, manager and accounts of productions you join, can see your PAN and bank details.</p>
  ${miss.length ? `<div class="alert warn">Missing: ${esc(miss.join(', '))}</div>` : '<div class="alert ok">Your profile is complete.</div>'}
  <form data-form="profile" class="stack" style="margin-top:14px" novalidate>
    <h2>About you</h2>
    <div class="grid2">${field('full_name', 'Full name', p.full_name, { attrs: { autocomplete: 'name' } })}${field('username', 'Username', p.username, { attrs: { autocomplete: 'username' }, hint: 'For signing in' })}</div>
    <div class="grid2">${field('phone', 'Phone / WhatsApp', p.phone, { type: 'tel', attrs: { autocomplete: 'tel' } })}<div class="field"><label>Email</label><input value="${esc(p.email)}" disabled></div></div>
    <h2>Legal and tax</h2>
    ${field('legal_name', 'Name for contracts and invoices', p.legal_name, { hint: 'Your full legal name, or your company name if you bill as a company' })}
    <div class="grid2">${field('pan', 'PAN', p.pan, { attrs: { autocapitalize: 'characters', maxlength: 10 } })}${field('gstin', 'GSTIN (if registered)', p.gstin, { attrs: { autocapitalize: 'characters', maxlength: 15 } })}</div>
    ${field('address', 'Address', p.address, { type: 'textarea', attrs: { autocomplete: 'street-address' } })}
    ${field('state_code', 'State', p.state_code, { type: 'select', options: [['', 'Select state'], ...Object.entries(STATES).map(([c, n]) => [c, n])] })}
    <h2>Bank account for payments</h2>
    ${field('bank_holder', 'Account holder name', p.bank_holder)}
    <div class="grid2">${field('bank_name', 'Bank', p.bank_name)}${field('bank_ifsc', 'IFSC', p.bank_ifsc, { attrs: { autocapitalize: 'characters', maxlength: 11 } })}</div>
    <div class="grid2">${field('bank_account', 'Account number', p.bank_account, { attrs: { inputmode: 'numeric', autocomplete: 'off' } })}${field('bank_account2', 'Re-enter account number', p.bank_account, { attrs: { inputmode: 'numeric', autocomplete: 'off' } })}</div>
    <button class="btn block">Save profile</button>
  </form>
  <div class="actions"><button class="btn ghost" data-act="signout">Sign out</button></div>`;
}

function vNewProject(){
  return `<h1>New production</h1><p class="muted">You'll be its producer. Invite your crew with a code after this.</p>
  <form data-form="newproject" class="stack" novalidate>
    ${field('name', 'Production name', '', { attrs: { required: '' } })}
    ${field('kind', 'Type', 'film', { type: 'select', options: Object.entries(KINDS) })}
    ${field('company', 'Production company (as on invoices)', MYPROFILE?.legal_name || '', { attrs: { required: '' } })}
    ${field('gstin', 'Company GSTIN', '', { attrs: { autocapitalize: 'characters', maxlength: 15 }, hint: 'Used for the GST split on invoices (CGST/SGST or IGST)' })}
    ${field('address', 'Company address', '', { type: 'textarea' })}
    <div class="grid2">${field('start', 'Start', today(), { type: 'date' })}${field('end', 'End', addDays(today(), 30), { type: 'date' })}</div>
    <button class="btn block">Create production</button></form>`;
}

/* ================================================================ today */
function approvalsForMe(){
  if (!P) return [];
  const r = role();
  return P.invoices.filter(i => i.submitted_by !== USER.id || r === 'producer').filter(i =>
    (r === 'hod' && i.status === 'submitted' && i.department === P.me.department) ||
    (r === 'accounts' && i.status === 'hod_approved') ||
    (['producer', 'manager'].includes(r) && ['submitted', 'hod_approved'].includes(i.status)));
}
function todo(){
  if (!P) return [];
  const t = [], me = USER.id, base = `#/p/${P.id}`;
  const miss = kycMissing(MYPROFILE);
  if (miss.length) t.push([`Finish your profile (${miss.join(', ')})`, '#/profile', 'warn']);
  P.contracts.filter(c => c.user_id === me && c.status === 'sent').forEach(c => t.push(['Sign your contract', `${base}/contract/${c.id}`, 'warn']));
  P.invoices.filter(i => i.submitted_by === me && i.status === 'rejected').forEach(i => t.push([`Invoice ${i.invoice_no} was rejected: ${i.reject_reason}`, `${base}/invoice/${i.id}`, 'bad']));
  const ap = approvalsForMe();
  if (ap.length) t.push([`${ap.length} invoice${ap.length > 1 ? 's' : ''} to approve`, `${base}/money`, 'info']);
  if (isProducer()) { const n = P.contracts.filter(c => c.status === 'signed').length; if (n) t.push([`${n} contract${n > 1 ? 's' : ''} to countersign`, `${base}/contracts?f=signed`, 'info']); }
  if (canManage()) {
    const n = P.members.filter(m => m.active && !['producer'].includes(m.role) && !P.contracts.some(c => c.user_id === m.user_id && c.status !== 'void')).length;
    if (n) t.push([`${n} crew member${n > 1 ? 's have' : ' has'} no contract`, `${base}/contracts`, '']);
    const d = P.contracts.filter(c => c.status === 'draft').length;
    if (d) t.push([`${d} draft contract${d > 1 ? 's' : ''} not sent`, `${base}/contracts?f=draft`, '']);
  }
  if (canPay()) { const n = P.invoices.filter(i => i.status === 'approved' && !i.batch_id).length; if (n) t.push([`${n} approved invoice${n > 1 ? 's' : ''} waiting for a payment run`, `${base}/payments`, 'info']);
                  const b = P.batches.filter(b => !b.paid_at).length; if (b) t.push([`${b} payment run${b > 1 ? 's' : ''} to mark as paid`, `${base}/payments`, 'warn']); }
  return t;
}
function myCall(s){ return (s.calls || []).find(c => c.user_id === USER.id)?.call; }
function vToday(){
  const t = todo(), base = `#/p/${P.id}`;
  const upcoming = P.sheets.filter(s => s.shoot_date >= today() && (s.status === 'published' || canManage()));
  const s = upcoming[0];
  const committed = sum(P.report, r => r.committed), budget = sum(P.report, r => r.budget);
  const signed = P.contracts.filter(c => c.status === 'countersigned').length, issued = P.contracts.filter(c => c.status !== 'void').length;
  return `<h1>${s && s.shoot_date === today() ? 'Today' : 'Overview'}</h1>
  ${s ? `<a class="card" style="display:block;text-decoration:none;color:inherit;margin:8px 0 14px" href="${base}/sheet/${s.shoot_date}">
      <div class="between"><b>${s.shoot_date === today() ? 'Today' : fmtDay(s.shoot_date)}${s.day_no ? ' · Day ' + s.day_no : ''}</b>${s.status === 'draft' ? '<span class="pill">Draft</span>' : '<span class="pill ok">Call sheet out</span>'}</div>
      <div style="font-size:18px;font-weight:700;margin:6px 0 2px">${esc(s.location || 'Location TBC')}</div>
      <div class="muted small">General call ${hm(s.general_call)}${myCall(s) ? ` · <b style="color:var(--ink)">Your call ${esc(myCall(s))}</b>` : ''}${s.wrap_est ? ' · Wrap est. ' + hm(s.wrap_est) : ''}</div></a>`
    : `<div class="card muted" style="margin:8px 0 14px">No upcoming shoot day published yet.</div>`}
  ${canPay() ? `<div class="kpis"><div class="kpi"><b>${P.members.filter(m => m.active).length}</b><span>On the crew list</span></div>
    <div class="kpi"><b>${signed}/${issued}</b><span>Contracts fully signed</span></div>
    <div class="kpi"><b>${budget ? Math.round(committed / budget * 100) + '%' : inr(committed)}</b><span>${budget ? 'Of budget committed' : 'Committed spend'}</span></div></div>` : ''}
  <h2>Needs you</h2>
  <div class="list">${t.map(([txt, href, k]) => `<a class="item" href="${href}"><span class="pill ${k}">${k === 'bad' ? '!' : '•'}</span><span class="grow">${esc(txt)}</span><span aria-hidden="true">→</span></a>`).join('') || '<div class="empty">Nothing waiting on you. 🎬</div>'}</div>
  ${isProducer() ? `<div class="actions"><a class="btn ghost sm" href="${base}/settings">Production settings</a></div>` : ''}`;
}

/* ================================================================ crew */
function inviteLink(){ return location.origin + location.pathname + '#/join/' + P.project.invite_code; }
function vCrew(){
  const base = `#/p/${P.id}`;
  const groups = groupBy(P.members.filter(m => m.active), m => m.department || 'Unassigned');
  const today_ = P.attendance.filter(a => a.day === today());
  return `<div class="between"><h1>Crew</h1><a class="btn ghost sm" href="${base}/id">My ID card</a></div>
  ${canManage() ? `<div class="card" style="margin:10px 0">
      <div class="between"><div><div class="muted small">Invite code</div><div style="font:700 22px ui-monospace,Menlo,monospace;letter-spacing:.12em">${esc(P.project.invite_code)}</div></div>
      <div class="row"><button class="btn sm ghost" data-act="copy-invite">Copy link</button>
      <a class="btn sm" target="_blank" rel="noopener" href="https://wa.me/?text=${encodeURIComponent(`Join "${P.project.name}" on CrewDesk: ${inviteLink()}`)}">WhatsApp</a></div></div>
      <p class="muted small" style="margin:8px 0 0">Crew open the link, create an account once, and land on this production.</p></div>
    <div class="between" style="margin:6px 0 4px"><span class="muted small">${today_.length} checked in today</span><a class="btn sm" href="${base}/checkin">Check crew in</a></div>` : ''}
  ${Object.keys(groups).sort().map(d => `<h2>${esc(d)} <span class="muted small">${groups[d].length}</span></h2><div class="list">
    ${groups[d].sort(by(m => nameOf(m.user_id))).map(m => {
      const c = P.contracts.filter(c => c.user_id === m.user_id && c.status !== 'void')[0];
      const kyc = P.people[m.user_id]?.kyc_missing;
      return `<a class="item" href="${base}/member/${m.user_id}"><span class="avatar">${esc(initials(nameOf(m.user_id)))}</span>
      <span class="grow"><b>${esc(nameOf(m.user_id))}</b><span class="meta" style="display:block">${esc(m.designation || ROLES[m.role])}${canManage() && m.rate ? ' · ' + inr(m.rate) + (m.rate_unit === 'lump' ? '' : '/' + m.rate_unit) : ''}</span></span>
      ${m.role !== 'crew' ? `<span class="pill">${esc(ROLES[m.role])}</span>` : ''}
      ${canPay() && kyc?.length ? '<span class="pill warn">KYC</span>' : ''}
      ${canManage() ? (c ? pill(C_STATUS, c.status) : '<span class="pill">No contract</span>') : ''}</a>`; }).join('')}</div>`).join('')}`;
}
function vMember(uid){
  const m = memberOf(uid); if (!m) return '<div class="empty">Not on this production.</div>';
  const p = person(uid), base = `#/p/${P.id}`;
  const contracts = P.contracts.filter(c => c.user_id === uid);
  const invoices = P.invoices.filter(i => i.submitted_by === uid);
  const roleOpts = Object.entries(ROLES).filter(([k]) => isProducer() || !['producer', 'manager', 'accounts'].includes(k) || k === m.role);
  return `<a class="btn ghost sm" href="${base}/crew">← Crew</a>
  <div class="row" style="margin:14px 0"><span class="avatar" style="width:56px;height:56px;font-size:18px">${esc(initials(nameOf(uid)))}</span>
    <div class="grow"><h1>${esc(nameOf(uid))}</h1><div class="muted">${esc(m.designation || '')}${m.department ? ' · ' + esc(m.department) : ''} · ${esc(ROLES[m.role])}</div></div></div>
  <div class="actions">${p.phone ? `<a class="btn ghost sm" href="tel:${esc(p.phone.replace(/\s/g, ''))}">Call</a><a class="btn ghost sm" target="_blank" rel="noopener" href="https://wa.me/${esc(p.phone.replace(/\D/g, ''))}">WhatsApp</a>` : ''}
    ${p.email ? `<a class="btn ghost sm" href="mailto:${esc(p.email)}">Email</a>` : ''}</div>
  ${canPay() ? `<h2>KYC</h2><div class="card small">${p.kyc_missing?.length ? `<div class="alert warn" style="margin-bottom:8px">Missing: ${esc(p.kyc_missing.join(', '))}</div>` : ''}
    <table class="t"><tr><th>Legal name</th><td>${esc(p.legal_name || '—')}</td></tr><tr><th>PAN</th><td>${esc(p.pan || '—')}</td></tr>
    <tr><th>GSTIN</th><td>${esc(p.gstin || 'Not registered')}</td></tr><tr><th>Bank</th><td>${p.bank_account ? esc(`${p.bank_holder}, ${p.bank_name || ''}, A/c ••••${p.bank_account.slice(-4)}, ${p.bank_ifsc}`) : '—'}</td></tr></table></div>` : ''}
  ${canManage() ? `<h2>Deal</h2><form data-form="member" data-uid="${uid}" class="stack card" novalidate>
    <div class="grid2">${field('role', 'Access', m.role, { type: 'select', options: roleOpts })}
    ${field('department', 'Department', m.department, { type: 'select', options: [['', 'Select'], ...P.project.departments.map(d => [d, d])] })}</div>
    ${field('designation', 'Designation', m.designation)}
    <div class="grid2">${field('rate', 'Rate (₹)', m.rate, { type: 'number', attrs: { min: 0, inputmode: 'numeric' } })}
    ${field('rate_unit', 'Per', m.rate_unit, { type: 'select', options: [['day', 'Day'], ['week', 'Week'], ['month', 'Month'], ['lump', 'Lump sum']] })}</div>
    <div class="grid2">${field('start_date', 'From', m.start_date, { type: 'date' })}${field('end_date', 'To', m.end_date, { type: 'date' })}</div>
    ${field('rating', 'Your rating (private to producers)', m.rating || '', { type: 'select', options: [['', 'Not rated'], [5, '★★★★★'], [4, '★★★★'], [3, '★★★'], [2, '★★'], [1, '★']] })}
    <button class="btn">Save</button></form>
    <div class="actions"><button class="btn sm" data-act="issue-contract" data-uid="${uid}">Issue contract</button>
    ${uid !== USER.id ? `<button class="btn danger sm" data-act="remove-member" data-uid="${uid}">Remove from production</button>` : ''}</div>` : ''}
  ${contracts.length ? `<h2>Contracts</h2><div class="list">${contracts.map(c => `<a class="item" href="${base}/contract/${c.id}"><span class="grow">${esc(c.template_name)} <span class="muted small">${esc(c.ref)}</span></span>${pill(C_STATUS, c.status)}</a>`).join('')}</div>` : ''}
  ${invoices.length ? `<h2>Invoices</h2><div class="list">${invoices.map(invItem).join('')}</div>` : ''}`;
}
function vIdCard(){
  const m = P.me;
  hooks.push(async () => {
    try { await loadQR(); const q = window.qrcode(0, 'M'); q.addData(m.card_code); q.make();
          $('#qr').innerHTML = `<img alt="QR code ${esc(m.card_code)}" src="${q.createDataURL(6, 0)}">`; }
    catch { $('#qr').textContent = m.card_code; }
  });
  return `<a class="btn ghost sm" href="#/p/${P.id}/crew">← Crew</a>
  <div class="idcard" style="margin-top:16px"><div class="small" style="opacity:.8">${esc(P.project.name)}</div>
    <div style="font-size:22px;font-weight:800;margin-top:6px">${esc(nameOf(USER.id))}</div>
    <div style="opacity:.85">${esc(m.designation || ROLES[m.role])}${m.department ? ' · ' + esc(m.department) : ''}</div>
    <div class="qr" id="qr" style="color:#000">…</div><div class="code">${esc(m.card_code)}</div>
    <div class="small" style="opacity:.75;margin-top:8px">Show this at the unit base to check in and out.</div></div>`;
}
let scanStop = null;
function vCheckin(){
  if (!canManage()) return '<div class="empty">Only the producer or production manager can check crew in.</div>';
  const list = P.attendance.filter(a => a.day === today());
  hooks.push(startScanner);
  return `<a class="btn ghost sm" href="#/p/${P.id}/crew">← Crew</a><h1 style="margin-top:12px">Check crew in</h1>
  <p class="muted small">Scan a crew member's ID card. Scanning again checks them out.</p>
  <div id="scanBox" class="card" hidden><video id="scanVideo" playsinline muted style="width:100%;border-radius:10px;background:#000"></video></div>
  <form data-form="checkin" class="row" style="margin-top:10px" novalidate><div class="field grow"><label for="cc" class="sr">ID card code</label>
    <input id="cc" name="code" placeholder="Or type the 8-character code" autocapitalize="characters" maxlength="8"></div><button class="btn">Check in / out</button></form>
  <h2>Today (${list.length})</h2><div class="list">${list.map(a => `<div class="item"><span class="avatar">${esc(initials(nameOf(a.user_id)))}</span>
    <span class="grow"><b>${esc(nameOf(a.user_id))}</b><span class="meta" style="display:block">In ${fmtTS(a.check_in)}${a.check_out ? ' · Out ' + fmtTS(a.check_out) : ''}</span></span>
    ${a.check_out ? '<span class="pill">Out</span>' : '<span class="pill ok">On set</span>'}</div>`).join('') || '<div class="empty">Nobody checked in yet today.</div>'}</div>`;
}
async function startScanner(){
  scanStop?.();
  if (!('BarcodeDetector' in window) || !navigator.mediaDevices?.getUserMedia) return;
  try {
    const det = new window.BarcodeDetector({ formats: ['qr_code'] });
    const stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } });
    const v = $('#scanVideo'); if (!v) { stream.getTracks().forEach(t => t.stop()); return; }
    $('#scanBox').hidden = false; v.srcObject = stream; await v.play();
    let last = '', lastAt = 0, alive = true;
    scanStop = () => { alive = false; stream.getTracks().forEach(t => t.stop()); scanStop = null; };
    const tick = async () => {
      if (!alive || !document.body.contains(v)) return scanStop?.();
      try { const [c] = await det.detect(v); if (c && (c.rawValue !== last || Date.now() - lastAt > 5000)) { last = c.rawValue; lastAt = Date.now(); await doScan(c.rawValue); } } catch {}
      setTimeout(tick, 400);
    };
    tick();
  } catch { /* camera refused: typing the code still works */ }
}
async function doScan(code){
  const r = await act(() => BE.rpc('scan_id_card', { p_project: P.id, p_code: code }));
  if (r) { toast(`${r.name} ${r.out ? 'checked out' : 'checked in'}`); P.attendance = await BE.select('attendance', { eq: { project_id: P.id }, order: 'check_in', desc: true }); render(); }
}

/* ================================================================ contracts */
const qs = () => new URLSearchParams(location.hash.split('?')[1] || '');
function vContracts(){
  const base = `#/p/${P.id}`, f = qs().get('f') || 'all';
  const counts = s => P.contracts.filter(c => c.status === s).length;
  const shown = P.contracts.filter(c => f === 'all' ? c.status !== 'void' : c.status === f);
  const noContract = P.members.filter(m => m.active && m.role !== 'producer' && !P.contracts.some(c => c.user_id === m.user_id && c.status !== 'void'));
  return `<div class="between"><h1>Contracts</h1>${canManage() ? `<button class="btn sm ghost" data-act="templates">Templates</button>` : ''}</div>
  ${canManage() && noContract.length ? `<div class="alert info" style="margin:10px 0">${noContract.length} people have no contract yet.
     <button class="btn sm" style="margin-left:6px" data-act="bulk-contracts">Issue to all</button></div>` : ''}
  <div class="chips" role="group" aria-label="Filter">${[['all', 'All'], ['draft', 'Draft'], ['sent', 'Awaiting signature'], ['signed', 'Awaiting countersign'], ['countersigned', 'Fully signed'], ['void', 'Void']]
    .map(([k, l]) => `<a class="chip" aria-pressed="${f === k}" href="${base}/contracts${k === 'all' ? '' : '?f=' + k}">${l}${k !== 'all' ? `<b>${counts(k)}</b>` : ''}</a>`).join('')}</div>
  <div class="list">${shown.map(c => `<a class="item" href="${base}/contract/${c.id}"><span class="avatar">${esc(initials(nameOf(c.user_id)))}</span>
    <span class="grow"><b>${esc(nameOf(c.user_id))}</b><span class="meta" style="display:block">${esc(c.fields.designation || '')} · ${esc(c.ref)}</span></span>${pill(C_STATUS, c.status)}</a>`).join('')
    || `<div class="empty">${canManage() ? 'No contracts here.' : 'No contracts for you yet. The production office issues them.'}</div>`}</div>`;
}
const renderDoc = c => c.signed_text || c.body.replace(/\{\{(\w+)\}\}/g, (_, k) => c.fields[k] ?? `{{${k}}}`);
async function vContract(id){
  const c = P.contracts.find(x => x.id === id); if (!c) return '<div class="empty">Contract not found.</div>';
  const events = await BE.select('contract_events', { eq: { contract_id: id }, order: 'at' });
  const mine = c.user_id === USER.id, base = `#/p/${P.id}`;
  return `<a class="btn ghost sm" href="${base}/contracts">← Contracts</a>
  <div class="between" style="margin:14px 0 6px"><div><h1>${esc(nameOf(c.user_id))}</h1><div class="muted small">${esc(c.template_name)} · ${esc(c.ref)}</div></div>${pill(C_STATUS, c.status)}</div>
  ${mine && c.status === 'sent' ? `<div class="alert warn" style="margin:10px 0">Read the agreement, then sign at the bottom.</div>` : ''}
  <div class="doc">${esc(renderDoc(c))}</div>
  ${c.signed_at ? `<div class="card" style="margin-top:12px"><div class="grid2"><div><div class="muted small">Signed by</div><b>${esc(c.signed_name)}</b><div class="small muted">${fmtTS(c.signed_at)}</div>
      ${c.signature ? `<img alt="Signature of ${esc(c.signed_name)}" src="${esc(c.signature)}" style="max-width:100%;height:70px;object-fit:contain;background:#fff;border-radius:6px;margin-top:6px">` : ''}</div>
      <div><div class="muted small">Countersigned</div>${c.countersigned_at ? `<b>${esc(nameOf(c.countersigned_by))}</b><div class="small muted">${fmtTS(c.countersigned_at)}</div>` : '<span class="muted">Not yet</span>'}</div></div>
      <div class="small muted" style="margin-top:8px;word-break:break-all">Document fingerprint (SHA-256): ${esc(c.signed_hash)}</div></div>` : ''}
  <div class="actions">
    ${mine && c.status === 'sent' ? `<button class="btn accent" data-act="sign" data-id="${id}">Sign contract</button>` : ''}
    ${canManage() && ['draft', 'sent'].includes(c.status) ? `<button class="btn ghost" data-act="edit-contract" data-id="${id}">Edit details</button>` : ''}
    ${canManage() && c.status === 'draft' ? `<button class="btn" data-act="send-contract" data-id="${id}">Send to ${esc(nameOf(c.user_id).split(' ')[0])}</button>` : ''}
    ${isProducer() && c.status === 'signed' ? `<button class="btn ok" data-act="countersign" data-id="${id}">Countersign</button>` : ''}
    <button class="btn ghost" data-act="print-contract" data-id="${id}">Print / PDF</button>
    ${canManage() && c.status !== 'void' ? `<button class="btn danger" data-act="void-contract" data-id="${id}">Void</button>` : ''}
  </div>
  <h2>History</h2><ul class="timeline">${events.map(e => `<li><b>${esc(e.action)}</b> · ${esc(nameOf(e.actor))} · ${fmtTS(e.at)}</li>`).join('')}</ul>`;
}
function signSheet(id){
  const miss = kycMissing(MYPROFILE);
  if (miss.length) return openSheet(`<h2 style="margin-top:0">Finish your profile first</h2><p>Your contract uses your legal details. Missing: <b>${esc(miss.join(', '))}</b>.</p>
    <a class="btn block" href="#/profile" data-close>Go to your profile</a>`, d => d.querySelector('[data-close]').onclick = closeSheet);
  openSheet(`<h2 style="margin-top:0">Sign contract</h2>
    <form data-form="sign" data-id="${id}" class="stack" novalidate>
      ${field('name', 'Type your full name', MYPROFILE.legal_name || MYPROFILE.full_name)}
      <div class="field"><label>Draw your signature</label><canvas class="sig" id="sigpad" aria-label="Signature pad"></canvas>
      <div class="between"><span class="hint">Use your finger or mouse.</span><button type="button" class="btn ghost sm" id="sigclear">Clear</button></div></div>
      <label class="row small"><input type="checkbox" name="agree" required> I have read this agreement and agree to sign it electronically.</label>
      <button class="btn accent block">Sign</button><button type="button" class="btn ghost block" data-close>Cancel</button></form>`, d => {
    d.querySelector('[data-close]').onclick = closeSheet;
    const cv = d.querySelector('#sigpad'), ctx = cv.getContext('2d');
    const fit = () => { const r = cv.getBoundingClientRect(), k = window.devicePixelRatio || 1; cv.width = r.width * k; cv.height = r.height * k; ctx.scale(k, k); ctx.lineWidth = 2.4; ctx.lineCap = 'round'; ctx.strokeStyle = '#111'; };
    fit(); cv.dataset.empty = '1';
    let drawing = false;
    const pt = e => { const r = cv.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };
    cv.onpointerdown = e => { drawing = true; cv.setPointerCapture(e.pointerId); ctx.beginPath(); ctx.moveTo(...pt(e)); };
    cv.onpointermove = e => { if (!drawing) return; ctx.lineTo(...pt(e)); ctx.stroke(); cv.dataset.empty = ''; };
    cv.onpointerup = () => { drawing = false; };
    d.querySelector('#sigclear').onclick = () => { ctx.clearRect(0, 0, cv.width, cv.height); cv.dataset.empty = '1'; };
  });
}
function contractPrint(c){
  return `<h2>${esc(c.template_name)} · ${esc(c.ref)}</h2><div class="doc">${esc(renderDoc(c))}</div>
  ${c.signed_at ? `<table style="margin-top:16px"><tr><th>Signed by</th><td>${esc(c.signed_name)} on ${fmtTS(c.signed_at)}<br>${c.signature ? `<img src="${esc(c.signature)}" style="height:60px">` : ''}</td></tr>
  <tr><th>Countersigned</th><td>${c.countersigned_at ? esc(nameOf(c.countersigned_by)) + ' on ' + fmtTS(c.countersigned_at) : '—'}</td></tr>
  <tr><th>Fingerprint</th><td style="word-break:break-all">${esc(c.signed_hash)}</td></tr></table>` : ''}`;
}

/* ================================================================ money */
function invItem(i){
  return `<a class="item" href="#/p/${P.id}/invoice/${i.id}"><span class="grow"><b>${esc(i.vendor?.name || nameOf(i.submitted_by))}</b>
    <span class="meta" style="display:block">${esc(i.invoice_no)} · ${esc(i.description)}</span></span>
    <span style="text-align:right"><span class="money">${inr(i.status === 'approved' || i.status === 'paid' ? i.payable : i.total)}</span><br>${pill(I_STATUS, i.status)}</span></a>`;
}
function vMoney(){
  const base = `#/p/${P.id}`, f = qs().get('f') || 'todo';
  const mine = P.invoices.filter(i => i.submitted_by === USER.id);
  const ap = approvalsForMe();
  let html = `<div class="between"><h1>${canPay() || role() === 'hod' ? 'Money' : 'Invoices'}</h1><a class="btn sm accent" href="${base}/invoice/new">+ New invoice</a></div>`;
  if (canPay()) {
    const sets = { todo: ap, approved: P.invoices.filter(i => i.status === 'approved' && !i.batch_id), inrun: P.invoices.filter(i => i.status === 'approved' && i.batch_id),
                   paid: P.invoices.filter(i => i.status === 'paid'), rejected: P.invoices.filter(i => i.status === 'rejected'), all: P.invoices };
    html += `<div class="actions" style="margin-top:6px"><a class="btn ghost sm" href="${base}/payments">Payment runs</a><a class="btn ghost sm" href="${base}/budget">Budget & cost report</a><a class="btn ghost sm" href="${base}/exports">Tally & exports</a></div>
    <div class="chips" style="margin-top:12px">${[['todo', 'To approve'], ['approved', 'Approved'], ['inrun', 'In payment run'], ['paid', 'Paid'], ['rejected', 'Rejected'], ['all', 'All']]
      .map(([k, l]) => `<a class="chip" aria-pressed="${f === k}" href="${base}/money?f=${k}">${l}<b>${sets[k].length}</b></a>`).join('')}</div>
    <div class="list">${sets[f].map(i => invItem(i) + (f === 'todo' ? quickApprove(i) : '')).join('') || '<div class="empty">Nothing here.</div>'}</div>`;
  } else if (role() === 'hod') {
    html += `<h2>To approve (${P.me.department})</h2><div class="list">${ap.map(i => invItem(i) + quickApprove(i)).join('') || '<div class="empty">Nothing waiting for you.</div>'}</div>`;
  }
  html += `<h2>My invoices</h2><div class="list">${mine.map(invItem).join('') || '<div class="empty">You haven\'t raised an invoice on this production yet.</div>'}</div>`;
  return html;
}
function quickApprove(i){
  const r = role();
  const step = (r === 'hod' || (i.status === 'submitted' && r !== 'producer' && r !== 'manager')) ? 'hod' : 'final';
  return `<div class="actions" style="margin:-2px 0 6px">${step === 'hod' || (i.status === 'submitted' && r === 'hod')
    ? `<button class="btn ok sm" data-act="hod-approve" data-id="${i.id}">Approve (HOD)</button>`
    : `<button class="btn ok sm" data-act="approve" data-id="${i.id}">Approve for payment</button>`}
    <button class="btn danger sm" data-act="reject" data-id="${i.id}">Reject</button></div>`;
}
function gstSplit(i){
  const company = P.project.company_state_code, vendor = i.vendor?.state_code || (i.vendor?.gstin || '').slice(0, 2);
  if (!+i.gst) return [];
  if (company && vendor && company !== vendor) return [['IGST ' + i.gst_rate + '%', i.gst]];
  const h = Math.round(i.gst / 2);
  return [['CGST ' + i.gst_rate / 2 + '%', h], ['SGST ' + i.gst_rate / 2 + '%', i.gst - h]];
}
function vInvoice(id){
  const i = P.invoices.find(x => x.id === id); if (!i) return '<div class="empty">Invoice not found.</div>';
  const r = role(), base = `#/p/${P.id}`, v = i.vendor || {};
  const canHod = i.status === 'submitted' && i.submitted_by !== USER.id && (r === 'hod' && P.me.department === i.department || ['producer', 'manager'].includes(r));
  const canFinal = ['submitted', 'hod_approved'].includes(i.status) && (['producer', 'manager'].includes(r) || (r === 'accounts' && i.status === 'hod_approved')) && (i.submitted_by !== USER.id || r === 'producer');
  const canRej = ['submitted', 'hod_approved', 'approved'].includes(i.status) && !i.batch_id && (canPay() || (r === 'hod' && P.me.department === i.department));
  return `<a class="btn ghost sm" href="${base}/money">← Money</a>
  <div class="between" style="margin:14px 0 6px"><div><h1>${esc(i.invoice_no)}</h1><div class="muted small">${esc(i.ref)} · ${fmtD(i.invoice_date)}</div></div>${pill(I_STATUS, i.status)}</div>
  ${i.status === 'rejected' ? `<div class="alert bad">Rejected by ${esc(nameOf(i.rejected_by))}: ${esc(i.reject_reason)}</div>` : ''}
  ${invoiceDoc(i)}
  <h2>Progress</h2><ul class="timeline">
    <li><b>Submitted</b> · ${esc(nameOf(i.submitted_by))} · ${fmtTS(i.created_at)}</li>
    ${i.hod_at ? `<li><b>Approved by HOD</b> · ${esc(nameOf(i.hod_by))} · ${fmtTS(i.hod_at)}</li>` : ''}
    ${i.approved_at ? `<li><b>Approved for payment</b> · ${esc(nameOf(i.approved_by))} · TDS ${+i.tds_rate}% · ${fmtTS(i.approved_at)}</li>` : ''}
    ${i.batch_id ? `<li><b>Added to payment run</b> ${esc(P.batches.find(b => b.id === i.batch_id)?.ref || '')}</li>` : ''}
    ${i.paid_at ? `<li><b>Paid</b> · ref ${esc(i.payment_ref)} · ${fmtTS(i.paid_at)}</li>` : ''}
    ${i.rejected_at ? `<li><b>Rejected</b> · ${esc(nameOf(i.rejected_by))} · ${fmtTS(i.rejected_at)}</li>` : ''}</ul>
  <div class="actions">${canHod ? `<button class="btn ok" data-act="hod-approve" data-id="${id}">Approve (HOD)</button>` : ''}
    ${canFinal ? `<button class="btn ok" data-act="approve" data-id="${id}">Approve for payment</button>` : ''}
    ${canRej ? `<button class="btn danger" data-act="reject" data-id="${id}">Reject</button>` : ''}
    <button class="btn ghost" data-act="print-invoice" data-id="${id}">Print / PDF</button>
    ${i.status === 'rejected' && i.submitted_by === USER.id ? `<a class="btn" href="${base}/invoice/new?from=${id}">Raise a corrected invoice</a>` : ''}</div>`;
}
function invoiceDoc(i){
  const v = i.vendor || {}, pr = P.project;
  return `<div class="card" style="margin-top:10px"><div class="grid2 small">
    <div><div class="muted">From</div><b>${esc(v.name)}</b><br>${esc(v.address || '')}<br>PAN ${esc(v.pan || '—')}${v.gstin ? '<br>GSTIN ' + esc(v.gstin) : ''}</div>
    <div><div class="muted">Bill to</div><b>${esc(pr.company_name)}</b><br>${esc(pr.company_address || '')}${pr.company_gstin ? '<br>GSTIN ' + esc(pr.company_gstin) : ''}<br>Production: ${esc(pr.name)}</div></div>
    <div class="tablewrap" style="margin-top:12px"><table class="t"><tr><th>Description</th><th class="r">Qty</th><th class="r">Rate</th><th class="r">Amount</th></tr>
    <tr><td>${esc(i.description)}${i.period_from ? `<div class="muted small">${fmtD(i.period_from)} – ${fmtD(i.period_to)}</div>` : ''}</td><td class="r">${+i.quantity}</td><td class="r">${inr(i.rate)}</td><td class="r">${inr(i.amount)}</td></tr>
    ${gstSplit(i).map(([l, a]) => `<tr><td colspan="3">${l}</td><td class="r">${inr(a)}</td></tr>`).join('')}
    <tr><th colspan="3">Invoice total</th><th class="r">${inr(i.total)}</th></tr>
    ${+i.tds ? `<tr><td colspan="3">Less TDS ${+i.tds_rate}%</td><td class="r">−${inr(i.tds)}</td></tr><tr><th colspan="3">Payable</th><th class="r">${inr(i.payable)}</th></tr>` : ''}</table></div>
    <div class="small muted" style="margin-top:8px">Pay to: ${esc(v.bank_holder || '')}, ${esc(v.bank_name || '')}, A/c ${esc(v.bank_account || '')}, IFSC ${esc(v.bank_ifsc || '')}</div></div>`;
}
function vNewInvoice(){
  const m = P.me, mine = P.invoices.filter(i => i.submitted_by === USER.id);
  const from = qs().get('from') && P.invoices.find(i => i.id === qs().get('from'));
  const prefix = (MYPROFILE.username || initials(MYPROFILE.full_name)).toUpperCase().slice(0, 6);
  const nextNo = `${prefix}/${String(mine.length + 1).padStart(3, '0')}`;
  const lastTo = mine.map(i => i.period_to).filter(Boolean).sort().pop();
  const pf = from?.period_from || (lastTo ? addDays(lastTo, 1) : (m.start_date || P.project.start_date || today()));
  const pt = from?.period_to || today();
  const miss = kycMissing(MYPROFILE);
  const gstOpts = MYPROFILE.gstin ? [[18, '18%'], [12, '12%'], [5, '5%'], [28, '28%'], [0, 'No GST']] : [[0, 'No GST (not registered)']];
  hooks.push(() => {
    const f = $('form[data-form="invoice"]'); if (!f) return;
    const upd = () => {
      const q = +f.quantity.value || 0, r = +f.rate.value || 0, g = +f.gst_rate.value || 0, a = Math.round(q * r), gst = Math.round(a * g / 100);
      const days = P.attendance.filter(x => x.user_id === USER.id && x.day >= f.period_from.value && x.day <= f.period_to.value).length;
      $('#invPrev').innerHTML = `Amount ${inr(a)}${gst ? ` + GST ${inr(gst)}` : ''} = <b>${inr(a + gst)}</b>`;
      $('#attHint').textContent = days ? `Attendance shows ${days} day${days > 1 ? 's' : ''} checked in for this period.` : '';
      $('#attUse').hidden = !days || m.rate_unit !== 'day' || days === q; $('#attUse').dataset.days = days;
    };
    f.addEventListener('input', upd); upd();
    $('#attUse').onclick = () => { f.quantity.value = $('#attUse').dataset.days; upd(); };
  });
  return `<a class="btn ghost sm" href="#/p/${P.id}/money">← Money</a><h1 style="margin-top:12px">New invoice</h1>
  <p class="muted small">Billed to ${esc(P.project.company_name)}. Your PAN, GSTIN and bank details come from your profile.</p>
  ${miss.length ? `<div class="alert warn">Finish your profile before invoicing. Missing: ${esc(miss.join(', '))}. <a href="#/profile">Open profile</a></div>` : ''}
  <form data-form="invoice" class="stack" style="margin-top:10px" novalidate>
    <div class="grid2">${field('invoice_no', 'Invoice number', nextNo)}${field('invoice_date', 'Date', today(), { type: 'date' })}</div>
    <div class="grid2">${field('period_from', 'Work from', pf, { type: 'date' })}${field('period_to', 'Work to', pt, { type: 'date' })}</div>
    ${field('description', 'Description', from?.description || `${m.designation || 'Services'}${m.rate_unit === 'day' ? ', shoot days' : ''}`)}
    <div class="grid3">${field('quantity', m.rate_unit === 'day' ? 'Days' : 'Quantity', from?.quantity || 1, { type: 'number', attrs: { min: 0.5, step: 0.5, inputmode: 'decimal' } })}
      ${field('rate', 'Rate (₹)', from?.rate || m.rate || '', { type: 'number', attrs: { min: 1, inputmode: 'numeric' } })}
      ${field('gst_rate', 'GST', MYPROFILE.gstin ? 18 : 0, { type: 'select', options: gstOpts })}</div>
    <div class="small muted"><span id="attHint"></span> <button type="button" class="btn ghost sm" id="attUse" hidden>Use attendance days</button></div>
    <div class="card" id="invPrev" aria-live="polite"></div>
    <button class="btn accent block" ${miss.length ? 'disabled' : ''}>Submit invoice</button></form>`;
}
function vPayments(){
  if (!canPay()) return '<div class="empty">Only accounts, the producer or the production manager can see payment runs.</div>';
  const ready = P.invoices.filter(i => i.status === 'approved' && !i.batch_id);
  return `<a class="btn ghost sm" href="#/p/${P.id}/money">← Money</a><h1 style="margin-top:12px">Payment runs</h1>
  <p class="muted small">Pick approved invoices, download the bank file, upload it to your bank's bulk payment, then mark the run paid with the bank reference. Everyone in the run sees it as paid.</p>
  <h2>Ready to pay (${ready.length})</h2>
  ${ready.length ? `<form data-form="batch" class="stack"><div class="list">${ready.map(i => `<label class="item"><input type="checkbox" name="inv" value="${i.id}" checked>
    <span class="grow"><b>${esc(i.vendor?.name)}</b><span class="meta" style="display:block">${esc(i.invoice_no)} · ${esc(i.vendor?.bank_ifsc || '')}</span></span><span class="money">${inr(i.payable)}</span></label>`).join('')}</div>
    <button class="btn block">Create payment run</button></form>` : '<div class="empty">No approved invoices waiting.</div>'}
  <h2>Runs</h2><div class="list">${P.batches.map(b => `<div class="card"><div class="between"><div><b>${esc(b.ref)}</b><div class="muted small">${b.invoices} invoice${b.invoices > 1 ? 's' : ''} · ${fmtTS(b.created_at)}</div></div><span class="money">${inr(b.amount)}</span></div>
    <div class="actions"><button class="btn ghost sm" data-act="bank-file" data-id="${b.id}">Download bank file (CSV)</button>
    ${b.paid_at ? `<span class="pill ok">Paid · ${esc(b.payment_ref)}</span>` : `<button class="btn ok sm" data-act="mark-paid" data-id="${b.id}">Mark as paid</button>`}</div></div>`).join('') || '<div class="empty">No payment runs yet.</div>'}</div>`;
}
function vBudget(){
  if (!canPay()) return '<div class="empty">Only accounts, the producer or the production manager can see the cost report.</div>';
  const rows = P.report.filter(r => +r.budget || +r.committed || +r.pending);
  const T = k => sum(P.report, r => r[k]);
  return `<a class="btn ghost sm" href="#/p/${P.id}/money">← Money</a><h1 style="margin-top:12px">Budget & cost report</h1>
  <p class="muted small">Live from invoices: committed = approved + paid (before GST). Pending = submitted, not yet approved.</p>
  <div class="kpis"><div class="kpi"><b>${inr(T('budget'))}</b><span>Budget</span></div><div class="kpi"><b>${inr(T('committed'))}</b><span>Committed</span></div><div class="kpi"><b>${inr(T('pending'))}</b><span>Pending approval</span></div></div>
  <div class="tablewrap card" style="margin-top:12px;padding:6px 10px"><table class="t"><tr><th>Department</th><th class="r">Budget</th><th class="r">Committed</th><th class="r">Left</th></tr>
  ${rows.map(r => { const pct = +r.budget ? Math.min(100, r.committed / r.budget * 100) : (+r.committed ? 100 : 0); const over = +r.committed > +r.budget;
    return `<tr><td>${esc(r.department)}<div class="meter"><i class="${over ? 'over' : ''}" style="width:${pct}%"></i></div>${+r.pending ? `<div class="small muted">${inr(r.pending)} pending</div>` : ''}</td>
    <td class="r">${inr(r.budget)}</td><td class="r">${inr(r.committed)}</td><td class="r" style="color:${over ? 'var(--bad)' : 'inherit'}">${inr(r.budget - r.committed)}</td></tr>`; }).join('') || '<tr><td colspan="4" class="muted">No budget or spend yet.</td></tr>'}</table></div>
  ${canManage() || role() === 'accounts' ? `<h2>Set budget</h2><form data-form="budget" class="stack card" novalidate>
    <div class="grid2">${field('department', 'Department', P.project.departments[0], { type: 'select', options: P.project.departments.map(d => [d, d]) })}
    ${field('amount', 'Budget (₹)', '', { type: 'number', attrs: { min: 0, inputmode: 'numeric' } })}</div><button class="btn">Save</button></form>` : ''}`;
}
function vExports(){
  if (!canPay()) return '<div class="empty">Only accounts, the producer or the production manager can export.</div>';
  const t = P.project.tally;
  return `<a class="btn ghost sm" href="#/p/${P.id}/money">← Money</a><h1 style="margin-top:12px">Tally & exports</h1>
  <h2>Tally</h2><div class="card stack"><p class="small">Creates a file you import in Tally (Gateway of Tally → Import → Vouchers). It includes a ledger for each vendor (under ${esc(t.creditors_group)}), a ${esc(t.voucher_type)} voucher for every approved or paid invoice, and a Payment voucher for every paid one.</p>
    <p class="small muted">These ledgers must already exist in Tally: ${esc([t.expense_ledger, t.input_cgst, t.input_sgst, t.input_igst, t.tds_ledger, t.bank_ledger].join(', '))}. ${isProducer() ? 'Change the names in production settings.' : ''}</p>
    <form data-form="tally" class="grid2" novalidate>${field('from', 'Invoices from', P.project.start_date || addDays(today(), -30), { type: 'date' })}${field('to', 'To', today(), { type: 'date' })}
    <button class="btn" style="grid-column:1/-1">Download Tally file (XML)</button></form></div>
  <h2>Spreadsheet</h2><div class="card"><p class="small">All invoices with vendor KYC, GST, TDS and payment status.</p><button class="btn ghost" data-act="invoices-csv">Download invoices (CSV)</button></div>`;
}

/* ================================================================ schedule */
function vSchedule(){
  const base = `#/p/${P.id}`;
  const sheets = P.sheets.filter(s => s.status === 'published' || canManage());
  const up = sheets.filter(s => s.shoot_date >= today()), past = sheets.filter(s => s.shoot_date < today()).reverse();
  const nextFree = (() => { let d = today(); while (P.sheets.some(s => s.shoot_date === d)) d = addDays(d, 1); return d; })();
  const seen = s => P.readersOf(s).length;
  const item = s => `<a class="item" href="${base}/sheet/${s.shoot_date}"><span class="avatar" style="border-radius:12px">${s.day_no || '–'}</span>
    <span class="grow"><b>${fmtDay(s.shoot_date)}</b><span class="meta" style="display:block">${esc(s.location || 'Location TBC')} · Call ${hm(s.general_call)}${myCall(s) ? ' · You ' + esc(myCall(s)) : ''}</span></span>
    ${s.status === 'draft' ? '<span class="pill">Draft</span>' : canManage() ? `<span class="pill">${seen(s)}/${(s.calls || []).length || P.members.length} read</span>` : ''}
    ${P.reports.some(r => r.shoot_date === s.shoot_date) ? '<span class="pill ok">DPR</span>' : ''}</a>`;
  return `<div class="between"><h1>Schedule</h1>${canManage() ? `<a class="btn sm accent" href="${base}/sheet/${nextFree}/edit">+ Call sheet</a>` : ''}</div>
  <h2>Coming up</h2><div class="list">${up.map(item).join('') || '<div class="empty">No upcoming call sheets.</div>'}</div>
  ${past.length ? `<h2>Shot</h2><div class="list">${past.map(item).join('')}</div>` : ''}`;
}
function vSheet(date){
  const s = P.sheets.find(x => x.shoot_date === date);
  const base = `#/p/${P.id}`;
  if (!s) return canManage() ? (go(`/p/${P.id}/sheet/${date}/edit`), '') : '<div class="empty">No call sheet for this day.</div>';
  if (s.status === 'published' && !canManage()) BE.rpc('mark_call_sheet_viewed', { p_id: s.id }).catch(() => {});
  const rep = P.reports.find(r => r.shoot_date === date);
  const readers = P.readersOf(s);
  return `<a class="btn ghost sm" href="${base}/schedule">← Schedule</a>
  ${sheetDoc(s)}
  ${canManage() ? `<div class="actions"><a class="btn ghost" href="${base}/sheet/${date}/edit">Edit</a>
     ${s.status === 'draft' ? `<button class="btn accent" data-act="publish-sheet" data-id="${s.id}">Publish to crew</button>` : `<button class="btn ghost" data-act="publish-sheet" data-id="${s.id}">Re-publish (ask all to re-read)</button>`}
     <button class="btn ghost" data-act="print-sheet" data-date="${date}">Print / PDF</button></div>
     ${s.status === 'published' ? `<p class="small muted" style="margin-top:8px">Read by ${readers.length}: ${esc(readers.map(nameOf).join(', ') || 'nobody yet')}</p>` : ''}`
    : `<div class="actions"><button class="btn ghost" data-act="print-sheet" data-date="${date}">Print / PDF</button></div>`}
  <h2>Day report</h2>
  ${rep ? `<div class="card"><div class="grid3 small"><div><span class="muted">Crew call</span><br><b>${hm(rep.crew_call)}</b></div><div><span class="muted">First shot</span><br><b>${hm(rep.first_shot)}</b></div><div><span class="muted">Wrap</span><br><b>${hm(rep.wrap)}</b></div></div>
     <p class="small" style="margin-top:10px"><b>Scenes done:</b> ${esc(rep.scenes_done || '—')}<br><b>Carried over:</b> ${esc(rep.scenes_left || '—')}<br><b>Setups:</b> ${rep.setups ?? '—'}</p>
     ${rep.notes ? `<p class="small">${esc(rep.notes)}</p>` : ''}</div>` : '<p class="muted small">Not filed yet.</p>'}
  ${canManage() && date <= today() ? `<form data-form="dpr" data-date="${date}" class="stack card" style="margin-top:10px" novalidate>
     <div class="grid2">${field('crew_call', 'Crew call', hm(rep?.crew_call || s.general_call).replace('—', ''), { type: 'time' })}${field('first_shot', 'First shot', hm(rep?.first_shot).replace('—', ''), { type: 'time' })}</div>
     <div class="grid2">${field('lunch', 'Lunch', hm(rep?.lunch).replace('—', ''), { type: 'time' })}${field('wrap', 'Wrap', hm(rep?.wrap).replace('—', ''), { type: 'time' })}</div>
     <div class="grid2">${field('scenes_done', 'Scenes completed', rep?.scenes_done || (s.scenes || []).map(x => x.scene).join(', '))}${field('setups', 'Setups', rep?.setups ?? '', { type: 'number', attrs: { min: 0 } })}</div>
     ${field('scenes_left', 'Carried over', rep?.scenes_left || '')}${field('notes', 'Notes (delays, incidents)', rep?.notes || '', { type: 'textarea' })}
     <button class="btn">${rep ? 'Update' : 'File'} day report</button></form>` : ''}`;
}
function sheetDoc(s){
  const mine = myCall(s);
  return `<div style="margin:14px 0 6px"><div class="muted small">${esc(P.project.name)}${s.day_no ? ' · Day ' + s.day_no : ''}</div><h1>${fmtDay(s.shoot_date)}</h1>
    ${s.status === 'draft' ? '<span class="pill">Draft: crew can\'t see this yet</span>' : ''}</div>
  ${mine ? `<div class="alert info" style="margin:8px 0"><b>Your call: ${esc(mine)}</b></div>` : ''}
  <div class="card"><div style="font-size:18px;font-weight:700">${esc(s.location || 'Location TBC')}</div>
    ${s.location_url ? `<a href="${esc(s.location_url)}" target="_blank" rel="noopener" class="small">Open in maps</a>` : ''}
    <div class="grid3 small" style="margin-top:10px"><div><span class="muted">General call</span><br><b>${hm(s.general_call)}</b></div><div><span class="muted">First shot</span><br><b>${hm(s.first_shot)}</b></div><div><span class="muted">Wrap (est.)</span><br><b>${hm(s.wrap_est)}</b></div></div></div>
  ${(s.scenes || []).length ? `<h2>Scenes</h2><div class="tablewrap card" style="padding:6px 10px"><table class="t"><tr><th>Sc.</th><th>Description</th><th>Cast</th></tr>
    ${s.scenes.map(x => `<tr><td><b>${esc(x.scene)}</b></td><td>${esc(x.description)}</td><td>${esc(x.cast || '')}</td></tr>`).join('')}</table></div>` : ''}
  ${(s.calls || []).length ? `<h2>Crew calls</h2><div class="tablewrap card" style="padding:6px 10px"><table class="t"><tr><th>Name</th><th>Dept</th><th class="r">Call</th></tr>
    ${[...s.calls].sort(by(c => c.call)).map(c => `<tr${c.user_id === USER.id ? ' style="font-weight:700"' : ''}><td>${esc(c.name)}</td><td>${esc(c.department || '')}</td><td class="r">${esc(c.call)}</td></tr>`).join('')}</table></div>` : ''}
  ${s.notes ? `<h2>Notes</h2><div class="card small">${esc(s.notes)}</div>` : ''}
  ${s.emergency ? `<div class="alert bad" style="margin-top:12px"><b>Emergency:</b> ${esc(s.emergency)}</div>` : ''}`;
}
function vSheetEdit(date){
  if (!canManage()) return '<div class="empty">Only the producer or production manager can edit call sheets.</div>';
  const s = P.sheets.find(x => x.shoot_date === date) || { shoot_date: date, scenes: [], calls: [], day_no: (Math.max(0, ...P.sheets.map(x => x.day_no || 0)) + 1) };
  const callOf = uid => (s.calls || []).find(c => c.user_id === uid)?.call || '';
  const people = P.members.filter(m => m.active && m.role !== 'vendor').sort(by(m => (m.department || '') + nameOf(m.user_id)));
  return `<a class="btn ghost sm" href="#/p/${P.id}/schedule">← Schedule</a><h1 style="margin-top:12px">Call sheet</h1>
  <form data-form="sheet" data-existing="${s.id ? 1 : ''}" class="stack" novalidate>
    <div class="grid2">${field('shoot_date', 'Shoot date', s.shoot_date, { type: 'date' })}${field('day_no', 'Shoot day #', s.day_no ?? '', { type: 'number', attrs: { min: 1 } })}</div>
    ${field('location', 'Location', s.location || '')}${field('location_url', 'Map link', s.location_url || '', { type: 'url', attrs: { placeholder: 'https://maps.google.com/…' } })}
    <div class="grid3">${field('general_call', 'General call', hm(s.general_call).replace('—', ''), { type: 'time' })}${field('first_shot', 'First shot', hm(s.first_shot).replace('—', ''), { type: 'time' })}${field('wrap_est', 'Wrap (est.)', hm(s.wrap_est).replace('—', ''), { type: 'time' })}</div>
    ${field('scenes', 'Scenes: one per line as  scene | description | cast', (s.scenes || []).map(x => [x.scene, x.description, x.cast].filter(v => v != null).join(' | ')).join('\n'), { type: 'textarea', attrs: { rows: 4 } })}
    <div class="field"><label>Crew calls <span class="muted">(leave blank if not called)</span></label>
      <div class="between small"><span class="muted">${people.length} people</span><button type="button" class="btn ghost sm" data-act="all-general">Everyone at general call</button></div>
      <div class="list">${people.map(m => `<div class="item" style="padding:8px 12px"><span class="grow"><b>${esc(nameOf(m.user_id))}</b><span class="meta" style="display:block">${esc(m.department || '')}</span></span>
        <input type="time" name="call_${m.user_id}" value="${esc(callOf(m.user_id))}" aria-label="Call time for ${esc(nameOf(m.user_id))}" style="padding:8px;border:1px solid var(--line);border-radius:8px;background:var(--surface)"></div>`).join('')}</div></div>
    ${field('notes', 'Notes', s.notes || '', { type: 'textarea' })}${field('emergency', 'Nearest hospital / emergency contact', s.emergency || '')}
    <button class="btn block">Save draft</button></form>`;
}

/* ================================================================ settings */
function vSettings(){
  if (!isProducer()) return '<div class="empty">Only the producer can change production settings.</div>';
  const p = P.project, t = p.tally;
  return `<a class="btn ghost sm" href="#/p/${P.id}">← Overview</a><h1 style="margin-top:12px">Production settings</h1>
  <form data-form="settings" class="stack" novalidate>
    ${field('name', 'Production name', p.name)}${field('kind', 'Type', p.kind, { type: 'select', options: Object.entries(KINDS) })}
    ${field('company_name', 'Production company', p.company_name)}${field('company_gstin', 'Company GSTIN', p.company_gstin || '')}${field('company_address', 'Company address', p.company_address || '', { type: 'textarea' })}
    <div class="grid2">${field('start_date', 'Start', p.start_date, { type: 'date' })}${field('end_date', 'End', p.end_date, { type: 'date' })}</div>
    ${field('departments', 'Departments (comma separated)', p.departments.join(', '), { type: 'textarea' })}
    ${field('default_tds_rate', 'Default TDS % at approval', p.default_tds_rate, { type: 'number', attrs: { min: 0, max: 30, step: 0.5 }, hint: 'Accounts can change it per invoice' })}
    <h2>Tally ledger names</h2><div class="grid2">
    ${[['expense_ledger', 'Expense'], ['input_cgst', 'Input CGST'], ['input_sgst', 'Input SGST'], ['input_igst', 'Input IGST'], ['tds_ledger', 'TDS'], ['bank_ledger', 'Bank'], ['creditors_group', 'Vendor group'], ['voucher_type', 'Voucher type']]
      .map(([k, l]) => field('tally_' + k, l, t[k] || '')).join('')}</div>
    <button class="btn block">Save settings</button></form>`;
}

/* ================================================================ exports */
const xml = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' }[c]));
const tdate = d => String(d).slice(0, 10).replace(/-/g, '');
function tallyXML(invoices){
  const t = P.project.tally;
  const vendors = [...new Map(invoices.map(i => [i.vendor.name, i.vendor])).values()];
  const entry = (ledger, amt, debit) => `<ALLLEDGERENTRIES.LIST><LEDGERNAME>${xml(ledger)}</LEDGERNAME><ISDEEMEDPOSITIVE>${debit ? 'Yes' : 'No'}</ISDEEMEDPOSITIVE><AMOUNT>${debit ? -amt : amt}</AMOUNT></ALLLEDGERENTRIES.LIST>`;
  const masters = vendors.map(v => `<TALLYMESSAGE xmlns:UDF="TallyUDF"><LEDGER NAME="${xml(v.name)}" ACTION="Create"><NAME.LIST><NAME>${xml(v.name)}</NAME></NAME.LIST>
<PARENT>${xml(t.creditors_group)}</PARENT><ISBILLWISEON>Yes</ISBILLWISEON>${v.gstin ? `<PARTYGSTIN>${xml(v.gstin)}</PARTYGSTIN><GSTREGISTRATIONTYPE>Regular</GSTREGISTRATIONTYPE>` : '<GSTREGISTRATIONTYPE>Unregistered</GSTREGISTRATIONTYPE>'}
<INCOMETAXNUMBER>${xml(v.pan)}</INCOMETAXNUMBER><LEDSTATENAME>${xml(STATES[v.state_code] || '')}</LEDSTATENAME></LEDGER></TALLYMESSAGE>`).join('\n');
  const vouchers = invoices.map(i => {
    const gstLines = gstSplit(i).map(([l, a]) => entry(l.startsWith('IGST') ? t.input_igst : l.startsWith('CGST') ? t.input_cgst : t.input_sgst, a, true)).join('');
    const purchase = `<TALLYMESSAGE xmlns:UDF="TallyUDF"><VOUCHER VCHTYPE="${xml(t.voucher_type)}" ACTION="Create"><DATE>${tdate(i.invoice_date)}</DATE>
<VOUCHERTYPENAME>${xml(t.voucher_type)}</VOUCHERTYPENAME><VOUCHERNUMBER>${xml(i.ref)}</VOUCHERNUMBER><REFERENCE>${xml(i.invoice_no)}</REFERENCE>
<PARTYLEDGERNAME>${xml(i.vendor.name)}</PARTYLEDGERNAME><NARRATION>${xml(`${P.project.name} · ${i.department || ''} · ${i.description}`)}</NARRATION>
${entry(i.vendor.name, i.payable, false)}${+i.tds ? entry(t.tds_ledger, i.tds, false) : ''}${entry(t.expense_ledger, i.amount, true)}${gstLines}</VOUCHER></TALLYMESSAGE>`;
    const payment = i.status === 'paid' ? `<TALLYMESSAGE xmlns:UDF="TallyUDF"><VOUCHER VCHTYPE="Payment" ACTION="Create"><DATE>${tdate(i.paid_at)}</DATE>
<VOUCHERTYPENAME>Payment</VOUCHERTYPENAME><VOUCHERNUMBER>${xml(i.ref)}-P</VOUCHERNUMBER><NARRATION>${xml('Bank ref ' + i.payment_ref)}</NARRATION>
${entry(i.vendor.name, i.payable, true)}${entry(t.bank_ledger, i.payable, false)}</VOUCHER></TALLYMESSAGE>` : '';
    return purchase + payment;
  }).join('\n');
  const env = (report, body) => `<ENVELOPE><HEADER><TALLYREQUEST>Import Data</TALLYREQUEST></HEADER><BODY><IMPORTDATA><REQUESTDESC><REPORTNAME>${report}</REPORTNAME></REQUESTDESC><REQUESTDATA>
${body}
</REQUESTDATA></IMPORTDATA></BODY></ENVELOPE>`;
  return `<?xml version="1.0" encoding="UTF-8"?>\n<!-- CrewDesk export: ${xml(P.project.name)}. Import masters first (this file contains both). -->\n<ENVELOPES>\n${env('All Masters', masters)}\n${env('Vouchers', vouchers)}\n</ENVELOPES>`;
}
const csvCell = v => /[",\n]/.test(String(v ?? '')) ? '"' + String(v).replace(/"/g, '""') + '"' : String(v ?? '');
const csv = rows => rows.map(r => r.map(csvCell).join(',')).join('\r\n');

/* ================================================================ actions */
const ACTIONS = {
  async persona(d){ await BE.auth.signIn(d.u, ''); },
  authtab(d){ AUTHTAB = d.t; render(); },
  async signout(){ scanStop?.(); await BE.auth.signOut(); },
  async 'reset-demo'(){ if (confirm('Reset the demo back to the sample production? Your changes in this browser are cleared.')) { await BE.reset(); location.hash = ''; location.reload(); } },
  'code-signin'(){
    openSheet(`<h2 style="margin-top:0">Sign in with an email code</h2><form data-form="code" class="stack" novalidate>
      ${field('email', 'Email', '', { type: 'email' })}<div class="field" id="codeWrap" hidden>${field('code', 'Code from the email', '', { attrs: { inputmode: 'numeric', autocomplete: 'one-time-code' } })}</div>
      <button class="btn block">Email me a code</button><button type="button" class="btn ghost block" data-close>Cancel</button></form>`, d => d.querySelector('[data-close]').onclick = closeSheet);
  },
  async forgot(){
    const email = prompt('Your account email:'); if (!email) return;
    await act(() => BE.auth.resetPassword(email.trim()), 'Check your email for a reset link');
  },
  'copy-invite'(){ navigator.clipboard?.writeText(inviteLink()).then(() => toast('Invite link copied'), () => prompt('Copy this link', inviteLink())); },
  async 'issue-contract'(d){
    const tpl = P.templates;
    openSheet(`<h2 style="margin-top:0">Issue contract to ${esc(nameOf(d.uid))}</h2><form data-form="issue" data-uid="${d.uid}" class="stack">
      ${field('template', 'Template', tpl[tpl.length - 1]?.id, { type: 'select', options: tpl.map(t => [t.id, t.name]) })}
      <label class="row small"><input type="checkbox" name="send" checked> Send it for signature now</label>
      <button class="btn block">Create contract</button><button type="button" class="btn ghost block" data-close>Cancel</button></form>`, x => x.querySelector('[data-close]').onclick = closeSheet);
  },
  async 'bulk-contracts'(){
    const people = P.members.filter(m => m.active && m.role !== 'producer' && !P.contracts.some(c => c.user_id === m.user_id && c.status !== 'void'));
    openSheet(`<h2 style="margin-top:0">Issue contracts</h2><p class="small muted">Each contract is filled from that person's deal (role, department, rate, dates) and profile.</p>
      <form data-form="bulk" class="stack">${field('template', 'Template', P.templates[0]?.id, { type: 'select', options: P.templates.map(t => [t.id, t.name]) })}
      <div class="list">${people.map(m => `<label class="item"><input type="checkbox" name="u" value="${m.user_id}" checked><span class="grow">${esc(nameOf(m.user_id))}<span class="meta" style="display:block">${esc(m.designation || m.department || '')}${m.rate ? ' · ' + inr(m.rate) : ' · no rate set'}</span></span></label>`).join('')}</div>
      <label class="row small"><input type="checkbox" name="send" checked> Send for signature now</label>
      <button class="btn block">Issue contracts</button><button type="button" class="btn ghost block" data-close>Cancel</button></form>`, x => x.querySelector('[data-close]').onclick = closeSheet);
  },
  async 'remove-member'(d){
    if (!confirm(`Remove ${nameOf(d.uid)} from this production? Their contracts and invoices stay on record.`)) return;
    if (await act(() => BE.rpc('update_member', { p_project: P.id, p_user: d.uid, p_patch: { active: false } }), 'Removed')) { go(`/p/${P.id}/crew`); }
  },
  templates(){
    openSheet(`<h2 style="margin-top:0">Contract templates</h2><div class="list">${P.templates.map(t => `<div class="item"><span class="grow"><b>${esc(t.name)}</b><span class="meta" style="display:block">${t.project_id ? 'This production' : 'Built in'}</span></span></div>`).join('')}</div>
      <h2>Add a template</h2><p class="small muted">Paste your agreement. Use placeholders that CrewDesk fills in: ${['date', 'project', 'company_name', 'company_gstin', 'company_address', 'name', 'pan', 'gstin', 'address', 'phone', 'email', 'department', 'designation', 'rate', 'rate_unit', 'start_date', 'end_date', 'bank'].map(k => `<code>{{${k}}}</code>`).join(' ')}</p>
      <form data-form="template" class="stack">${field('name', 'Template name', '')}${field('body', 'Agreement text', '', { type: 'textarea', attrs: { rows: 10 } })}
      <button class="btn block">Save template</button><button type="button" class="btn ghost block" data-close>Close</button></form>`, x => x.querySelector('[data-close]').onclick = closeSheet);
  },
  async 'send-contract'(d){ if (await act(() => BE.rpc('send_contract', { p_id: d.id }), 'Sent for signature')) render(); },
  async countersign(d){ if (confirm('Countersign this contract on behalf of the production?') && await act(() => BE.rpc('countersign_contract', { p_id: d.id }), 'Countersigned')) render(); },
  async 'void-contract'(d){ if (confirm('Void this contract? It stays on record but no longer applies.') && await act(() => BE.rpc('void_contract', { p_id: d.id }), 'Contract voided')) render(); },
  sign(d){ signSheet(d.id); },
  'edit-contract'(d){
    const c = P.contracts.find(x => x.id === d.id);
    const keys = ['designation', 'department', 'rate', 'rate_unit', 'start_date', 'end_date'];
    openSheet(`<h2 style="margin-top:0">Edit contract details</h2><p class="small muted">The person's name, PAN, address and bank come from their profile when they sign.</p>
      <form data-form="editcontract" data-id="${d.id}" class="stack">${keys.map(k => field(k, k.replace('_', ' ').replace(/^\w/, x => x.toUpperCase()), c.fields[k])).join('')}
      <button class="btn block">Save</button><button type="button" class="btn ghost block" data-close>Cancel</button></form>`, x => x.querySelector('[data-close]').onclick = closeSheet);
  },
  'print-contract'(d){ printHTML(contractPrint(P.contracts.find(x => x.id === d.id))); },
  'print-invoice'(d){ const i = P.invoices.find(x => x.id === d.id); printHTML(`<h2>Tax invoice ${esc(i.invoice_no)}</h2><p>Date ${fmtD(i.invoice_date)} · CrewDesk ref ${esc(i.ref)}</p>` + invoiceDoc(i)); },
  'print-sheet'(d){ printHTML(sheetDoc(P.sheets.find(x => x.shoot_date === d.date))); },
  async 'hod-approve'(d){ if (await act(() => BE.rpc('hod_approve_invoice', { p_id: d.id }), 'Approved, sent to accounts')) render(); },
  approve(d){
    const i = P.invoices.find(x => x.id === d.id);
    openSheet(`<h2 style="margin-top:0">Approve ${esc(i.invoice_no)} for payment</h2><p class="small muted">${esc(i.vendor?.name)} · amount before GST ${inr(i.amount)}</p>
      <form data-form="approve" data-id="${d.id}" class="stack">${field('tds', 'TDS %', P.project.default_tds_rate, { type: 'number', attrs: { min: 0, max: 30, step: 0.5 }, hint: 'Deducted from the amount before GST. Commonly 1–2% for contractors (194C) and 10% for professional fees (194J).' })}
      <div class="card small" id="tdsPrev"></div><button class="btn ok block">Approve</button><button type="button" class="btn ghost block" data-close>Cancel</button></form>`, x => {
      x.querySelector('[data-close]').onclick = closeSheet;
      const f = x.querySelector('form'), upd = () => { const t = Math.round(i.amount * (+f.tds.value || 0) / 100); x.querySelector('#tdsPrev').innerHTML = `TDS ${inr(t)} · payable <b>${inr(i.total - t)}</b>`; };
      f.oninput = upd; upd();
    });
  },
  reject(d){
    openSheet(`<h2 style="margin-top:0">Reject invoice</h2><form data-form="reject" data-id="${d.id}" class="stack">${field('reason', 'Reason (they will see this)', '', { type: 'textarea' })}
      <button class="btn danger block">Reject</button><button type="button" class="btn ghost block" data-close>Cancel</button></form>`, x => x.querySelector('[data-close]').onclick = closeSheet);
  },
  'mark-paid'(d){
    openSheet(`<h2 style="margin-top:0">Mark payment run as paid</h2><form data-form="paid" data-id="${d.id}" class="stack">${field('ref', 'Bank reference (UTR or batch ID)', '')}
      <button class="btn ok block">Mark paid</button><button type="button" class="btn ghost block" data-close>Cancel</button></form>`, x => x.querySelector('[data-close]').onclick = closeSheet);
  },
  'bank-file'(d){
    const b = P.batches.find(x => x.id === d.id), inv = P.invoices.filter(i => i.batch_id === d.id);
    download(`${b.ref}-bank-payments.csv`, csv([['Beneficiary name', 'Account number', 'IFSC', 'Amount', 'Narration', 'Email', 'Phone'],
      ...inv.map(i => [i.vendor.bank_holder, i.vendor.bank_account, i.vendor.bank_ifsc, i.payable, `${P.project.name.slice(0, 12)} ${i.invoice_no}`.slice(0, 30), i.vendor.email, i.vendor.phone])]), 'text/csv');
  },
  'invoices-csv'(){
    download(`${P.project.name.replace(/\W+/g, '-')}-invoices.csv`, csv([['CrewDesk ref', 'Invoice no', 'Date', 'Vendor', 'PAN', 'GSTIN', 'Department', 'Description', 'Amount', 'GST %', 'GST', 'Total', 'TDS %', 'TDS', 'Payable', 'Status', 'Payment ref', 'Paid on'],
      ...P.invoices.map(i => [i.ref, i.invoice_no, i.invoice_date, i.vendor.name, i.vendor.pan, i.vendor.gstin, i.department, i.description, i.amount, i.gst_rate, i.gst, i.total, i.tds_rate, i.tds, i.payable, i.status, i.payment_ref, i.paid_at?.slice(0, 10)])]), 'text/csv');
  },
  async 'publish-sheet'(d){ if (await act(() => BE.rpc('publish_call_sheet', { p_id: d.id }), 'Published to the crew')) render(); },
  'all-general'(){ const f = $('form[data-form="sheet"]'); const g = f.general_call.value || '07:00'; f.querySelectorAll('input[name^="call_"]').forEach(i => i.value = g); }
};

function readForm(f){ return Object.fromEntries(new FormData(f).entries()); }
function setErr(f, name, msg){ const e = f.querySelector(`[data-err="${name}"]`); if (e) e.textContent = msg || ''; f.elements[name]?.setAttribute('aria-invalid', msg ? 'true' : 'false'); }

const FORMS = {
  async signin(f){ const v = readForm(f); if (await act(() => BE.auth.signIn(v.login.trim(), v.password))) {} },
  async signup(f){
    const v = readForm(f);
    f.querySelectorAll('[data-err]').forEach(e => e.textContent = '');
    if (!v.full_name.trim()) return setErr(f, 'full_name', 'Enter your name');
    if (!/^[a-z0-9_.]{3,30}$/.test(v.username)) return setErr(f, 'username', 'Use 3–30 lowercase letters, numbers, dot or underscore');
    if (!/^\S+@\S+\.\S+$/.test(v.email)) return setErr(f, 'email', 'Enter a valid email');
    if (BE.mode === 'live' && (v.password || '').length < 8) return setErr(f, 'password', 'At least 8 characters');
    if (!(await BE.rpc('username_available', { p_username: v.username }).catch(() => true))) return setErr(f, 'username', 'That username is taken');
    const r = await act(() => BE.auth.signUp({ email: v.email.trim(), password: v.password, username: v.username, full_name: v.full_name.trim() }));
    if (r?.needsConfirm) openSheet(`<h2 style="margin-top:0">Check your email</h2><p>We sent a confirmation link to <b>${esc(v.email)}</b>. Open it to finish creating your account.</p><button class="btn block" data-close>OK</button>`, x => x.querySelector('[data-close]').onclick = closeSheet);
  },
  async code(f){
    const v = readForm(f), wrap = $('#codeWrap');
    if (wrap.hidden) { if (await act(() => BE.auth.sendCode(v.email.trim()), 'Code sent')) { wrap.hidden = false; f.querySelector('button.btn').textContent = 'Sign in'; } }
    else if (await act(() => BE.auth.verifyCode(v.email.trim(), v.code.trim()))) closeSheet();
  },
  async join(f){
    const code = readForm(f).code.trim(); if (!code) return;
    const pr = await act(() => BE.rpc('join_project', { p_code: code, p_as_vendor: $('#asVendor')?.checked || false }), 'You joined the production');
    if (pr) { await loadHome(); go('/p/' + pr.id); }
  },
  async profile(f){
    const v = readForm(f); let bad = false;
    const up = k => v[k] = (v[k] || '').trim().toUpperCase();
    ['pan', 'gstin', 'bank_ifsc'].forEach(up); v.bank_account = (v.bank_account || '').replace(/\s/g, ''); v.bank_account2 = (v.bank_account2 || '').replace(/\s/g, '');
    f.querySelectorAll('[data-err]').forEach(e => e.textContent = '');
    const err = (k, m) => { setErr(f, k, m); bad = true; };
    if (v.username && !/^[a-z0-9_.]{3,30}$/.test(v.username)) err('username', '3–30 lowercase letters, numbers, dot or underscore');
    if (v.pan && !PAN_RE.test(v.pan)) err('pan', 'PAN looks like ABCDE1234F');
    if (v.gstin && !gstinOk(v.gstin)) err('gstin', 'This GSTIN is not valid (check digit does not match)');
    if (v.gstin && v.pan && v.gstin.slice(2, 12) !== v.pan) err('gstin', 'GSTIN does not contain your PAN');
    if (v.bank_ifsc && !IFSC_RE.test(v.bank_ifsc)) err('bank_ifsc', 'IFSC looks like HDFC0001234');
    if (v.bank_account && !/^[0-9]{6,20}$/.test(v.bank_account)) err('bank_account', '6–20 digits');
    if (v.bank_account !== v.bank_account2) err('bank_account2', 'Account numbers don\'t match');
    if (v.gstin && !v.state_code) v.state_code = v.gstin.slice(0, 2);
    if (bad) { f.querySelector('[aria-invalid="true"]')?.focus(); return; }
    delete v.bank_account2;
    const patch = Object.fromEntries(Object.entries(v).map(([k, x]) => [k, x === '' ? null : x]));
    if (await act(() => BE.update('profiles', patch, { id: USER.id }), 'Profile saved')) { await loadHome(); render(); }
  },
  async newproject(f){
    const v = readForm(f);
    if (!v.name.trim()) return setErr(f, 'name', 'Give the production a name');
    if (v.gstin && !gstinOk(v.gstin.trim().toUpperCase())) return setErr(f, 'gstin', 'This GSTIN is not valid');
    const pr = await act(() => BE.rpc('create_project', { p_name: v.name, p_kind: v.kind, p_company: v.company || v.name, p_company_gstin: v.gstin, p_company_address: v.address, p_start: v.start || null, p_end: v.end || null }), 'Production created');
    if (pr) { await loadHome(); go('/p/' + pr.id + '/crew'); }
  },
  async member(f){
    const v = readForm(f);
    const patch = { role: v.role, department: v.department, designation: v.designation, rate_unit: v.rate_unit };
    if (v.rate !== '') patch.rate = +v.rate; if (v.start_date) patch.start_date = v.start_date; if (v.end_date) patch.end_date = v.end_date; if (v.rating) patch.rating = +v.rating;
    if (await act(() => BE.rpc('update_member', { p_project: P.id, p_user: f.dataset.uid, p_patch: patch }), 'Saved')) render();
  },
  async issue(f){
    const v = readForm(f);
    const c = await act(() => BE.rpc('create_contract', { p_project: P.id, p_user: f.dataset.uid, p_template: v.template }));
    if (c && v.send) await act(() => BE.rpc('send_contract', { p_id: c.id }));
    if (c) { closeSheet(); toast(v.send ? 'Contract sent for signature' : 'Draft contract created'); await loadProject(P.id); go(`/p/${P.id}/contract/${c.id}`); }
  },
  async bulk(f){
    const v = new FormData(f), users = v.getAll('u'), send = v.get('send');
    let n = 0;
    for (const u of users) { const c = await act(() => BE.rpc('create_contract', { p_project: P.id, p_user: u, p_template: v.get('template') })); if (c) { n++; if (send) await act(() => BE.rpc('send_contract', { p_id: c.id })); } }
    closeSheet(); toast(`${n} contract${n === 1 ? '' : 's'} ${send ? 'sent' : 'created'}`); refresh();
  },
  async template(f){ const v = readForm(f); if (!v.name.trim() || !v.body.trim()) return toast('Add a name and the agreement text');
    if (await act(() => BE.rpc('save_template', { p_project: P.id, p_name: v.name, p_body: v.body }), 'Template saved')) { closeSheet(); render(); } },
  async editcontract(f){ const v = readForm(f); if (await act(() => BE.rpc('edit_contract', { p_id: f.dataset.id, p_fields: v }), 'Saved')) { closeSheet(); render(); } },
  async sign(f){
    const v = readForm(f), cv = $('#sigpad');
    if (!v.agree) return toast('Tick the box to confirm');
    if (cv.dataset.empty) return toast('Draw your signature');
    const png = cv.toDataURL('image/png');
    if (await act(() => BE.rpc('sign_contract', { p_id: f.dataset.id, p_name: v.name, p_signature: png }), 'Signed. The producer will countersign.')) { closeSheet(); render(); }
  },
  async invoice(f){
    const v = readForm(f);
    if (!v.description.trim()) return setErr(f, 'description', 'Describe the work');
    if (!(+v.rate > 0)) return setErr(f, 'rate', 'Enter your rate');
    const i = await act(() => BE.rpc('submit_invoice', { p_project: P.id, p_invoice_no: v.invoice_no, p_date: v.invoice_date, p_from: v.period_from || null, p_to: v.period_to || null,
      p_description: v.description, p_quantity: +v.quantity, p_rate: Math.round(+v.rate), p_gst_rate: +v.gst_rate }), 'Invoice submitted');
    if (i) { await loadProject(P.id); go(`/p/${P.id}/invoice/${i.id}`); }
  },
  async approve(f){ if (await act(() => BE.rpc('approve_invoice', { p_id: f.dataset.id, p_tds_rate: +readForm(f).tds }), 'Approved for payment')) { closeSheet(); render(); } },
  async reject(f){ if (await act(() => BE.rpc('reject_invoice', { p_id: f.dataset.id, p_reason: readForm(f).reason }), 'Rejected')) { closeSheet(); render(); } },
  async paid(f){ if (await act(() => BE.rpc('mark_batch_paid', { p_batch: f.dataset.id, p_ref: readForm(f).ref }), 'Marked paid')) { closeSheet(); render(); } },
  async batch(f){
    const ids = new FormData(f).getAll('inv'); if (!ids.length) return toast('Pick at least one invoice');
    if (await act(() => BE.rpc('create_payment_batch', { p_project: P.id, p_invoices: ids }), 'Payment run created. Download the bank file.')) render();
  },
  async budget(f){ const v = readForm(f); if (await act(() => BE.rpc('set_budget', { p_project: P.id, p_department: v.department, p_amount: Math.round(+v.amount || 0) }), 'Budget saved')) render(); },
  tally(f){
    const v = readForm(f);
    const inv = P.invoices.filter(i => ['approved', 'paid'].includes(i.status) && i.invoice_date >= v.from && i.invoice_date <= v.to);
    if (!inv.length) return toast('No approved or paid invoices in those dates');
    download(`${P.project.name.replace(/\W+/g, '-')}-tally-${v.from}-to-${v.to}.xml`, tallyXML(inv), 'application/xml');
    toast(`${inv.length} invoice${inv.length > 1 ? 's' : ''} exported`);
  },
  async checkin(f){ const code = readForm(f).code.trim(); if (code) { await doScan(code); } },
  async sheet(f){
    const v = readForm(f);
    if (!v.shoot_date) return setErr(f, 'shoot_date', 'Pick the shoot date');
    const scenes = (v.scenes || '').split('\n').map(l => l.split('|').map(x => x.trim())).filter(x => x[0]).map(([scene, description, cast]) => ({ scene, description: description || '', cast: cast || '' }));
    const calls = P.members.filter(m => v['call_' + m.user_id]).map(m => ({ user_id: m.user_id, name: nameOf(m.user_id), department: m.department || '', call: v['call_' + m.user_id] }));
    const t = x => x || null;
    const s = await act(() => BE.rpc('save_call_sheet', { p_project: P.id, p_sheet: { shoot_date: v.shoot_date, day_no: v.day_no ? +v.day_no : null, location: v.location, location_url: v.location_url,
      general_call: t(v.general_call), first_shot: t(v.first_shot), wrap_est: t(v.wrap_est), scenes, calls, notes: v.notes, emergency: v.emergency } }), 'Call sheet saved');
    if (s) { await loadProject(P.id); go(`/p/${P.id}/sheet/${s.shoot_date}`); }
  },
  async dpr(f){
    const v = readForm(f), t = x => x || null;
    if (await act(() => BE.rpc('save_day_report', { p_project: P.id, p_r: { shoot_date: f.dataset.date, crew_call: t(v.crew_call), first_shot: t(v.first_shot), lunch: t(v.lunch), wrap: t(v.wrap),
      scenes_done: v.scenes_done, scenes_left: v.scenes_left, setups: v.setups ? +v.setups : null, notes: v.notes } }), 'Day report filed')) render();
  },
  async settings(f){
    const v = readForm(f);
    if (v.company_gstin && !gstinOk(v.company_gstin.trim().toUpperCase())) return setErr(f, 'company_gstin', 'This GSTIN is not valid');
    const tally = Object.fromEntries(Object.entries(v).filter(([k]) => k.startsWith('tally_')).map(([k, x]) => [k.slice(6), x.trim()]));
    const patch = { name: v.name, kind: v.kind, company_name: v.company_name, company_gstin: v.company_gstin, company_address: v.company_address,
      start_date: v.start_date || null, end_date: v.end_date || null, departments: v.departments.split(',').map(x => x.trim()).filter(Boolean), default_tds_rate: +v.default_tds_rate, tally };
    if (await act(() => BE.rpc('update_project', { p_id: P.id, p_patch: patch }), 'Settings saved')) render();
  }
};

document.addEventListener('click', async e => {
  const g = e.target.closest('[data-go]'); if (g) { e.preventDefault(); return go(g.dataset.go); }
  const a = e.target.closest('[data-act]'); if (!a || !ACTIONS[a.dataset.act]) return;
  e.preventDefault();
  try { await ACTIONS[a.dataset.act](a.dataset, e); } catch (err) { toast(err.message); }
});
document.addEventListener('submit', async e => {
  const f = e.target.closest('form[data-form]'); if (!f || !FORMS[f.dataset.form]) return;
  e.preventDefault();
  const btn = f.querySelector('button:not([type="button"])'); if (btn) btn.disabled = true;
  try { await FORMS[f.dataset.form](f); } catch (err) { toast(err.message); }
  finally { if (btn && document.body.contains(btn)) btn.disabled = false; }
});

/* ================================================================ boot */
(async () => {
  try {
    BE = await createBackend();
    USER = await BE.auth.current();
    BE.auth.onChange(async u => {
      const changed = (u?.id || null) !== (USER?.id || null);
      USER = u; P = null; PROJECTS = []; MYPROFILE = null;
      if (changed) { if (u && location.hash.startsWith('#/join/')) return render(); if (!u) location.hash = ''; render(); }
    });
    render();
  } catch (e) {
    $('#view').innerHTML = `<div class="empty"><p>CrewDesk couldn't start: ${esc(e.message)}</p><p class="small">Check your connection and reload.</p></div>`;
  }
})();
