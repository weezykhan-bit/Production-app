/* ================================================================ live data layer
   Appended to the shared screens (central/app.js) by tools/build-live.py.
   The screens read the same S shape as the demo; here S is filled from Supabase with only what
   row-level security lets this person see, and every change goes through a checked database function. */

const SUPABASE_ESM = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/+esm';
let DB = null;

// One small interface; tests swap in the same calls running against the real schema in the browser.
async function liveDB(cfg){
  const { createClient } = await import(SUPABASE_ESM);
  const sb = createClient(cfg.url, cfg.anonKey, { auth: { persistSession: true, detectSessionInUrl: true } });
  const fail = e => { throw new Error(e?.message || String(e)); };
  const unwrap = ({ data, error }) => { if (error) fail(error); return data; };
  return {
    async select(table, q = {}){
      const all = [];
      for (let from = 0; ; from += 1000){
        let b = sb.from(table).select('*');
        if (q.order) b = b.order(q.order, { ascending: !q.desc });
        const rows = unwrap(await b.range(from, from + 999));
        all.push(...rows);
        if (rows.length < 1000 || (q.limit && all.length >= q.limit)) return all;
      }
    },
    rpc: async (name, args = {}) => unwrap(await sb.rpc(name, args)),
    async upload(path, blob){ unwrap(await sb.storage.from('kyc').upload(path, blob, { contentType: blob.type, upsert: false })); },
    async signed(paths){
      if (!paths.length) return {};
      const out = unwrap(await sb.storage.from('kyc').createSignedUrls(paths, 3600));
      return Object.fromEntries(out.filter(x => x.signedUrl).map(x => [x.path, x.signedUrl]));
    },
    // live updates: new notifications for this person, and a signal whenever one of their productions changes
    live(uid, onNote, onPulse){
      const ch = sb.channel('crewdesk-' + uid)
        .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'notifications', filter: 'user_id=eq.' + uid }, p => onNote(p.new))
        .on('postgres_changes', { event: '*', schema: 'public', table: 'production_pulse' }, () => onPulse())
        .subscribe();
      return () => { sb.removeChannel(ch); };
    },
    auth: {
      async current(){ return (await sb.auth.getSession()).data.session?.user || null; },
      async signIn(login, password){
        const email = unwrap(await sb.rpc('login_email', { p_login: login }));
        if (!email) fail('That username and password don’t match.');
        const { error } = await sb.auth.signInWithPassword({ email, password });
        if (error) fail(/confirm/i.test(error.message) ? 'Confirm your email first: open the link we sent you.' : 'That username and password don’t match.');
      },
      // which sign-in buttons to show: only providers switched on in Supabase
      async providers(){ try { const r = await fetch(cfg.url + '/auth/v1/settings', { headers: { apikey: cfg.anonKey } }); return (await r.json()).external || {}; } catch { return {}; } },
      async google(){ unwrap(await sb.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: location.origin + '/', queryParams: { prompt: 'select_account' } } })); },
      async signUp({ email, password, username, full_name, phone }){
        const data = unwrap(await sb.auth.signUp({ email, password, options: { data: { username, full_name, phone }, emailRedirectTo: location.origin + location.pathname } }));
        return { needsConfirm: !data.session };
      },
      usernameFree: async u => unwrap(await sb.rpc('username_available', { p_username: u })),
      async resetPassword(email){ unwrap(await sb.auth.resetPasswordForEmail(email, { redirectTo: location.origin + location.pathname })); },
      async updatePassword(password){ unwrap(await sb.auth.updateUser({ password })); },
      async signOut(){ await sb.auth.signOut(); },
      onChange(fn){ sb.auth.onAuthStateChange((event, s) => fn(event, s?.user || null)); }
    }
  };
}

/* ---------------------------------------------------------------- load what this person may see */
S = {company:null, admins:[], users:[], projects:[], members:[], invoices:[], days:[], exports:[], log:[], tasks:[], unlocks:[], costs:[], floats:[], session:null};
function save(){}
function log(){}                       // the database writes the activity log itself
const urlCache = {};
const ts = v => v ? new Date(v).getTime() : null;
let loading = null;
function reload(){ loading = loading || load().finally(() => loading = null); return loading; }
async function load(){
  const [ci, admins, prods, crew, people, invs, days, checks, exps, acts, notes, rems, tks, tas, tus, unl, costs, floats] = await Promise.all([
    DB.rpc('company_info'), DB.select('company_admins'), DB.select('productions'), DB.select('crew'), DB.select('people'),
    DB.select('crew_invoices'), DB.select('shoot_days'), DB.select('checkins'), DB.select('tally_exports'), DB.select('activity', {order:'id', desc:true, limit:2000}), DB.select('notifications', {order:'id', desc:true, limit:60}), DB.select('removal_requests'),
    DB.select('tasks'), DB.select('task_assignees'), DB.select('task_updates', {order:'id'}), DB.select('day_unlocks'), DB.select('cost_entries'), DB.select('petty_floats')]);
  // signed links for photos and documents, reused for 50 minutes
  const now = Date.now(), want = [...new Set(people.flatMap(p => [p.photo_path, p.aadhaar_path, p.pan_path]).filter(Boolean))].filter(x => !(urlCache[x]?.until > now));
  if (want.length){ try { const m = await DB.signed(want); for (const [k, v] of Object.entries(m)) urlCache[k] = {url:v, until:now + 50 * 6e4}; } catch {} }
  const url = path => path ? (urlCache[path]?.url || '') : '';
  const adminOf = Object.fromEntries(admins.map(a => [a.user_id, a.role]));
  const next = {session:S.session, admins:admins.map(a => ({userId:a.user_id, role:a.role}))};
  next.company = ci ? {...ci, setupAt:ts(ci.setupAt)} : null;
  next.users = people.map(p => ({id:p.id, username:p.username || '', name:p.full_name || p.username || 'Someone', title:adminOf[p.id] || 'crew', phone:p.phone || '', email:p.email || '',
    photo:url(p.photo_path), legal:p.legal_name || '', pan:p.pan || '', gstin:p.gstin || '', address:p.address || '',
    bank:{holder:p.bank_holder || '', name:p.bank_name || '', acct:p.bank_account || '', ifsc:p.bank_ifsc || ''}, emergency:p.emergency || '',
    aadhaar4:p.aadhaar_last4 || '', docs:{aadhaar:p.aadhaar_path ? (url(p.aadhaar_path) || 'sample') : '', pan:p.pan_path ? (url(p.pan_path) || 'sample') : ''},
    consent:!!p.consent_at, ready:{profile:!!p.profile_ready, docs:!!p.docs_ready}}));
  next.projects = prods.map(p => ({id:p.id, name:p.name, format:p.format, platform:p.platform || '—', status:p.status, planned:p.planned_eps, done:0, block:'',
    location:p.location || '', city:p.city || 'Mumbai', start:p.start_date || '', invite:p.code, codeAt:ts(p.code_at), codeBy:p.code_by, budget:p.budget || {}}));
  next.members = crew.map(c => ({id:c.id, pid:c.production_id, userId:c.user_id || 'invite:' + c.id, pending:!c.user_id, role:c.role, kind:c.kind,
    dept:c.dept || '', job:c.job || '', rate:c.rate ? +c.rate : null, unit:c.unit, joining:c.joining || '', end:c.end_date || '', tds:c.tds, terms:c.terms,
    code:c.crew_code, joinedAt:ts(c.joined_at), active:c.active, removed:!!c.removed_at, removedAt:ts(c.removed_at), removedBy:c.removed_by, removedReason:c.removed_reason || '',
    ag:{status:c.ag_status, text:c.ag_text, sentAt:ts(c.ag_sent_at), signedAt:ts(c.ag_signed_at), signedName:c.ag_signed_name, sig:c.ag_signature, hash:c.ag_hash, counterAt:ts(c.ag_counter_at), counterBy:c.ag_counter_by}}));
  // people invited but not joined yet show under the name they were invited with
  crew.filter(c => !c.user_id).forEach(c => next.users.push({id:'invite:' + c.id, username:'', name:c.invite_name, title:'crew', phone:c.invite_phone || '', email:c.invite_email || '',
    photo:'', legal:'', pan:'', gstin:'', address:'', bank:{}, emergency:'', aadhaar4:'', docs:{}, consent:false, ready:{profile:false, docs:false}, pending:true}));
  // company owners act as owners on every production
  next.admins.forEach(a => { if (!next.users.some(u => u.id === a.userId)) return;
    next.projects.forEach(p => next.members.push({id:`admin:${p.id}:${a.userId}`, pid:p.id, userId:a.userId, role:a.role, kind:'crew', dept:'Production', job:ROLES[a.role].label,
      rate:null, unit:'month', joining:'', end:'', tds:'none', terms:30, code:'—', ag:{status:'countersigned'}, synthetic:true})); });
  next.invoices = invs.map(i => ({id:i.id, pid:i.production_id, memberId:i.crew_id, by:i.user_id, dept:i.dept || '', no:i.no, from:i.period_from, to:i.period_to, qty:+i.qty, rate:+i.rate, unit:i.unit,
    desc:i.descr || '', amount:+i.amount, gstRate:+i.gst_rate, gst:+i.gst, tdsKey:i.tds_key, tds:+i.tds, payable:+i.payable, status:i.status, at:ts(i.submitted_at),
    approvedAt:ts(i.approved_at), paidAt:ts(i.paid_at), utr:i.utr || '', reason:i.reason || '', tp:i.tally_purchase, tpay:i.tally_payment,
    deductions:i.deductions || [], deduction:+i.deduction || 0, remarks:i.remarks || '',
    auditedBy:i.audited_by, auditedAt:ts(i.audited_at), hopBy:i.hop_by, hopAt:ts(i.hop_at), approvedBy:i.approved_by}));
  next.days = days.map(d => ({id:d.id, pid:d.production_id, date:d.day, status:d.status, location:d.location || '—', call:d.call_time, wrap:d.wrap_time, epFrom:d.ep_from, epTo:d.ep_to, note:d.note || '', confirmedAt:ts(d.att_confirmed_at), confirmedBy:d.att_confirmed_by,
    dpr:d.dpr_at ? {call:d.act_call || '', first:d.first_shot || '', lunch:d.lunch_min, wrap:d.act_wrap || '', planned:d.scenes_planned, shot:d.scenes_shot, minutes:d.minutes_shot == null ? null : +d.minutes_shot, delay:d.delay || '', by:d.dpr_by, at:ts(d.dpr_at)} : null,
    att:checks.filter(c => c.day_id === d.id && !c.removed_at).map(c => c.user_id)}));
  next.exports = exps.map(x => ({id:x.batch, pid:x.production_id, at:ts(x.at), by:x.by, purchases:x.purchases, payments:x.payments, value:+x.value}));
  next.log = acts.map(a => ({id:a.id, at:ts(a.at), by:a.by, pid:a.production_id, type:a.type, text:a.text, memberId:a.crew_id, invoiceId:a.invoice_id,
    field:a.field === 'end_date' ? 'end' : a.field, before:a.before, after:a.after, reverted:!!a.reverted_at}));
  next.tasks = tks.map(t => ({id:t.id, pid:t.production_id, title:t.title, details:t.details || '', kind:t.kind, status:t.status, priority:t.priority, dept:t.dept || '', due:t.due || '',
    dayId:t.day_id, by:t.created_by, at:ts(t.created_at), doneAt:ts(t.done_at), assignees:tas.filter(a => a.task_id === t.id).map(a => a.user_id),
    updates:tus.filter(u => u.task_id === t.id).map(u => ({id:String(u.id), by:u.by, kind:u.kind, body:u.body, at:ts(u.at), accepted:!!u.accepted}))}));
  next.unlocks = unl.map(q => ({id:q.id, pid:q.production_id, dayId:q.day_id, date:q.on_date, by:q.requested_by, reason:q.reason, at:ts(q.at), status:q.status, decidedBy:q.decided_by, decidedAt:ts(q.decided_at), expiresAt:ts(q.expires_at), note:q.note || ''}));
  next.costs = costs.map(c => ({id:c.id, pid:c.production_id, date:c.on_date, head:c.head, item:c.item || '', descr:c.descr || '', payee:c.payee || '', qty:+c.qty, rate:c.rate == null ? null : +c.rate, amount:+c.amount,
    mode:c.mode, holder:c.petty_holder, bill:c.bill_no || '', notes:c.notes || '', source:c.source, batch:c.batch, by:c.created_by, at:ts(c.created_at)}));
  next.floats = floats.map(f => ({id:f.id, pid:f.production_id, holder:f.holder, amount:+f.amount, date:f.on_date, note:f.note || '', by:f.given_by, at:ts(f.at)}));
  next.removals = rems.map(q => ({id:q.id, pid:q.production_id, memberId:q.crew_id, person:q.person, by:q.requested_by, reason:q.reason, at:ts(q.at), status:q.status, note:q.note || ''}));
  next.notes = notes.map(n => ({id:n.id, pid:n.production_id, at:ts(n.at), kind:n.kind, title:n.title, body:n.body || '', view:n.view, read:!!n.read_at}));
  S = next;
}

/* ---------------------------------------------------------------- calling the database */
const FAIL = Symbol('fail');
function friendly(m){
  m = String(m || '');
  const map = [[/pan_check/, 'PAN is 10 characters: 5 letters, 4 numbers, 1 letter (like ABCDE1234F).'], [/bank_ifsc_check/, 'IFSC is 11 characters: 4 letters, a zero, then 6 letters or numbers (like HDFC0001234).'],
    [/bank_account_check/, 'Account numbers are 6 to 20 digits.'], [/gstin_check/, 'That GSTIN doesn’t look right. Check every character.'], [/companies_check/, 'The GSTIN must contain the company PAN.'],
    [/tan_check/, 'TAN is 10 characters: 4 letters, 5 numbers, 1 letter (like MUMS12345C).'], [/aadhaar_last4/, 'Enter the last 4 digits of your Aadhaar.'],
    [/rate limit|too many (emails|requests)|429/i, 'Too many sign-up emails went out in the last hour. Use “Continue with Google”, or try again in an hour.'],
    [/JWT|not authenticated|session/i, 'Your session expired. Sign in again.'], [/Failed to fetch|NetworkError|Load failed/i, 'No connection. Check your internet and try again.']];
  for (const [re, t] of map) if (re.test(m)) return t;
  return m.replace(/^ERROR:\s*/, '');
}
async function call(fn, args = {}, errId){
  try { return await DB.rpc(fn, args); }
  catch (e){ const m = friendly(e.message); if (errId && document.getElementById(errId)) err(errId, m); else toast(m); return FAIL; }
}
async function done(msg){ try { await reload(); } catch (e) { toast(friendly(e.message)); } render(); if (msg) toast(msg); }
function dataUrlToBlob(d){ const [h, b] = d.split(','), bin = atob(b), a = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) a[i] = bin.charCodeAt(i); return new Blob([a], {type:h.slice(5, h.indexOf(';'))}); }
async function uploadDoc(kind, file){
  const data = await readImage(file, kind === 'photo' ? 360 : 1200), path = `${S.session}/${kind}-${Date.now()}.jpg`;
  toast('Uploading…');
  try { await DB.upload(path, dataUrlToBlob(data)); } catch (e) { return toast(friendly(e.message)); }
  if (await call('set_document', {p_kind:kind, p_path:path}) !== FAIL) done(kind === 'photo' ? 'Photo updated' : kind === 'pan' ? 'PAN card photo saved' : 'Aadhaar photo saved');
}

/* ---------------------------------------------------------------- actions */
const step = async (fn, id, msg) => { const i = S.invoices.find(x => x.id === id); if (await call(fn, {p_id:id}) !== FAIL){ U.drawer = null; done(`${i?.no || 'Invoice'} ${msg}`); } };
const GOOGLE_G = '<svg width="18" height="18" viewBox="0 0 48 48" aria-hidden="true"><path fill="#EA4335" d="M24 9.5c3.5 0 6.6 1.2 9.1 3.6l6.8-6.8C35.8 2.4 30.3 0 24 0 14.6 0 6.6 5.4 2.7 13.3l7.9 6.2C12.5 13.7 17.8 9.5 24 9.5z"/><path fill="#4285F4" d="M46.1 24.5c0-1.6-.1-3.1-.4-4.5H24v9h12.4c-.5 2.9-2.2 5.3-4.6 6.9l7.5 5.8c4.4-4 6.8-10 6.8-17.2z"/><path fill="#FBBC05" d="M10.6 28.5c-.5-1.4-.8-2.9-.8-4.5s.3-3.1.8-4.5l-7.9-6.2C1 16.6 0 20.2 0 24s1 7.4 2.7 10.7l7.9-6.2z"/><path fill="#34A853" d="M24 48c6.5 0 11.9-2.1 15.9-5.8l-7.5-5.8c-2.1 1.4-4.9 2.3-8.4 2.3-6.2 0-11.5-4.2-13.4-9.9l-7.9 6.2C6.6 42.6 14.6 48 24 48z"/></svg>';
Object.assign(ACT, {
  'rm-withdraw': async el => { if (await call('withdraw_removal', {p_request:el.dataset.id}) !== FAIL) done('Request withdrawn'); },
  'rm-restore': async el => { if (await call('restore_person', {p_crew:el.dataset.id}) !== FAIL) done('Restored to the production'); },
  help: () => { U.menu = false; U.modal = {type:'welcome'}; render(); },
  'set-pass': () => { U.menu = false; U.modal = {type:'newpass'}; render(); },
  google: async () => { try { await DB.auth.google(); } catch (e) { toast(friendly(e.message)); } },
  'demo-login': () => {}, reset: () => {}, 'reset-empty': () => {},
  logout: async () => { U.menu = false; U.chat = false; U.chatLog = []; U.pid = null; U.drawer = null; U.modal = null; await DB.auth.signOut(); },
  forgot: () => { U.auth = 'forgot'; render(); },
  nudge: async el => { const m = member(el.dataset.id); if (await call('remind', {p_crew:m.id}) !== FAIL) done(`Reminder logged for ${user(m.userId).name}. Send them the production code on WhatsApp too.`); },
  'send-ag': async el => { const m = member(el.dataset.id); if (stageOf(m).next !== 'sent') return toast('Deal, profile and documents must be complete first.');
    if (await call('send_agreement', {p_crew:m.id, p_text:agText(m)}) !== FAIL) done(`Agreement sent to ${user(m.userId).name}`); },
  countersign: async el => { const m = member(el.dataset.id); if (await call('countersign', {p_crew:m.id}) !== FAIL) done(`${user(m.userId).name} is onboarded`); },
  'inv-step': async el => { const i = S.invoices.find(x => x.id === el.dataset.id), r = await call('advance_invoice', {p_id:el.dataset.id}); if (r === FAIL) return; done(`${i?.no || 'Invoice'}: ${INV[r][0].toLowerCase()}`); },
  'cost-del': async el => { if (await call('delete_cost_entry', {p_id:el.dataset.id}) !== FAIL) done('Line deleted'); },
  'cost-undo': async el => { const n = await call('undo_cost_import', {p_batch:el.dataset.id}); if (n !== FAIL) done(`Import undone · ${n} lines removed`); },
  'cost-import': async () => { const rows = U.modal.rows.filter(r => !r.errs.length);
    const n = await call('add_cost_entries', {p_production:U.pid, p_rows:rows.map(r => ({date:r.date, head:r.head, item:r.item, descr:r.descr, payee:r.payee, qty:r.qty, rate:r.rate, amount:r.amount, mode:r.mode, holder:r.holder || '', bill_no:r.bill, notes:r.notes})), p_source:'excel'}, 'ci2-err');
    if (n === FAIL) return; U.modal = null; U.cdate = rows[0].date; done(`${n} lines imported`); },
  'att-confirm': async el => { const n = await call('confirm_attendance', {p_day:el.dataset.id}); if (n !== FAIL) done(`Attendance confirmed · ${n} checked in`); },
  'task-st': async el => { if (await call('set_task_status', {p_task:el.dataset.id, p_status:el.dataset.s}) !== FAIL) done(TASK_ST[el.dataset.s][0]); },
  'task-accept': async el => { if (await call('accept_solution', {p_update:+el.dataset.id}) !== FAIL) done('Solution accepted; issue closed'); },
  'task-del': async el => { if (!confirm('Delete this task?')) return; if (await call('delete_task', {p_task:el.dataset.id}) !== FAIL){ U.drawer = null; done('Task deleted'); } },
  revert: async el => { if (await call('revert_change', {p_log:+el.dataset.id}) !== FAIL) done('Change undone and logged'); },
  'day-status': async el => { if (await call('set_day_status', {p_day:el.dataset.id, p_status:el.dataset.s}) !== FAIL) done(`Day marked ${DAY[el.dataset.s][0].toLowerCase()}`); },
  uncheck: async el => { if (await call('remove_checkin', {p_day:el.dataset.id, p_user:el.dataset.u}) !== FAIL) done('Check-in removed'); },
  'tally-mark': async () => { const b = await call('tally_mark', {p_production:U.pid}); if (b !== FAIL){ U.modal = null; done(`${b}: vouchers marked as in Tally`); } },
  'new-code': async () => {
    if (!U.confirmCode){ U.confirmCode = true; setTimeout(() => U.confirmCode = false, 5000); return toast('Tap “Generate new code” again to confirm. The current code will stop working.'); }
    U.confirmCode = false; const c = await call('new_production_code', {p_id:U.pid}); if (c !== FAIL) done(`New code ${fmtCode(c)}. Share it with the crew.`); },
  budget: () => { U.modal = {type:'budget'}; renderLayer(); },
  'add-admin': () => { U.modal = {type:'admin'}; renderLayer(); },
});

const v = id => (document.getElementById(id)?.value || '').trim();
Object.assign(FORMS, {
  login: async () => { const id = v('li-user'), pw = $('#li-pass').value;
    if (!id || !pw) return err('li-err', 'Enter your username or email and your password.');
    try { await DB.auth.signIn(id, pw); } catch (e) { err('li-err', friendly(e.message)); } },
  signup: async () => { const name = v('su-name'), un = v('su-user').toLowerCase(), email = v('su-email').toLowerCase(), phone = v('su-phone'), pw = $('#su-pass').value;
    if (name.length < 2) return err('su-err', 'Enter your full name.');
    if (!/^[a-z0-9_.]{3,30}$/.test(un)) return err('su-err', 'Usernames are 3–30 characters: a–z, 0–9, dot or underscore.');
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return err('su-err', 'Enter a valid email; we send a link to confirm it.');
    if (phone.replace(/\D/g, '').length < 10) return err('su-err', 'Enter your 10-digit mobile number; it links you to your invite.');
    if (pw.length < 8) return err('su-err', 'Use a password of at least 8 characters.');
    try { if (!(await DB.auth.usernameFree(un))) return err('su-err', 'That username is taken. Try another.');
      const r = await DB.auth.signUp({email, password:pw, username:un, full_name:name, phone});
      if (r.needsConfirm){ U.auth = 'sent'; U.sentTo = email; render(); } }
    catch (e) { err('su-err', friendly(e.message)); } },
  forgot: async () => { const email = v('fp-email');
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return err('fp-err', 'Enter the email you signed up with.');
    try { await DB.auth.resetPassword(email); U.auth = 'sent'; U.sentTo = email; U.sentWhat = 'reset'; render(); } catch (e) { err('fp-err', friendly(e.message)); } },
  newpass: async () => { const pw = $('#np-pass').value; if (pw.length < 8) return err('npw-err', 'Use at least 8 characters.');
    try { await DB.auth.updatePassword(pw); U.modal = null; renderLayer(); toast('Password changed'); } catch (e) { err('npw-err', friendly(e.message)); } },
  join: async () => { if (v('join-phone') && await call('set_my_phone', {p_phone:v('join-phone')}, 'join-err') === FAIL) return;
    const r = await call('join_production', {p_code:v('join-code'), p_kind:v('join-kind')}, 'join-err'); if (r === FAIL) return;
    if (!r.ok) return err('join-err', r.error); U.pid = r.production_id; U.view = 'home'; done(r.already ? `You’re already on ${r.name}` : `You joined ${r.name}`); },
  project: async () => { if (!v('np-name')) return err('np-err', 'Give the production a name.');
    const id = await call('create_production', {p:{name:v('np-name'), format:v('np-format'), platform:v('np-plat'), status:v('np-status'), planned_eps:+v('np-eps') || 1, location:v('np-loc'), start_date:v('np-start')}}, 'np-err');
    if (id === FAIL) return; U.modal = null; U.pid = id; U.view = 'home'; done('Production created. Share its code with the crew.'); },
  onboard: async () => { const name = v('ob-name'), rate = +v('ob-rate'), joining = v('ob-join');
    if (name.length < 2) return err('ob-err', 'Enter the person’s full name.'); if (!(rate > 0)) return err('ob-err', 'Enter the rate in rupees.'); if (!joining) return err('ob-err', 'Pick a joining date.');
    if (v('ob-end') && v('ob-end') < joining) return err('ob-err', 'The end date is before the joining date.');
    if (!v('ob-phone') && !v('ob-email')) return err('ob-err', 'Enter their mobile or email, so their account links to this invite when they join.');
    const id = await call('onboard', {p_production:U.pid, p:{name, phone:v('ob-phone'), email:v('ob-email'), kind:v('ob-kind'), dept:v('ob-dept'), job:v('ob-job'), rate, unit:v('ob-unit'),
      terms:+v('ob-terms'), joining, end:v('ob-end'), tds:v('ob-tds'), role:v('ob-role')}}, 'ob-err');
    if (id === FAIL) return; U.modal = {type:'invite2', name, phone:v('ob-phone'), email:v('ob-email')}; done(); },
  deal: async () => { const rate = +v('ob-rate'); if (!(rate > 0)) return err('ob-err', 'Enter the rate in rupees.'); if (!v('ob-join')) return err('ob-err', 'Pick a joining date.');
    const n = await call('set_deal', {p_crew:U.modal.id, p:{rate, unit:v('ob-unit'), joining:v('ob-join'), end:v('ob-end'), tds:v('ob-tds'), terms:+v('ob-terms'), dept:v('ob-dept'), job:v('ob-job'), role:v('ob-role')}}, 'ob-err');
    if (n === FAIL) return; U.modal = null; done(n ? `Deal saved · ${n} change${n > 1 ? 's' : ''} logged` : 'No changes'); },
  profile: async () => { const pan = v('pf-pan').toUpperCase(), gstin = v('pf-gstin').toUpperCase(), ifsc = v('pf-ifsc').toUpperCase(), acct = v('pf-acct').replace(/\s/g, '');
    if (!v('pf-legal')) return err('pf-err', 'Enter your legal name as it appears on your PAN.');
    if (!PAN_RE.test(pan)) return err('pf-err', 'PAN is 10 characters: 5 letters, 4 numbers, 1 letter (like ABCDE1234F).');
    if (gstin && !GSTIN_RE.test(gstin)) return err('pf-err', 'GSTIN is 15 characters, like 27ABCDE1234F1Z5. Leave it empty if you aren’t registered.');
    if (gstin && gstin.slice(2, 12) !== pan) return err('pf-err', 'Your GSTIN must contain your PAN (characters 3 to 12).');
    if (!v('pf-addr')) return err('pf-err', 'Enter your address.'); if (!v('pf-holder')) return err('pf-err', 'Enter the account holder’s name.');
    if (!ACCT_RE.test(acct)) return err('pf-err', 'Account numbers are 9 to 18 digits.'); if (!IFSC_RE.test(ifsc)) return err('pf-err', 'IFSC is 11 characters: 4 letters, a zero, then 6 letters or numbers.');
    if (await call('save_profile', {p:{legal:v('pf-legal'), phone:v('pf-phone'), emergency:v('pf-emer'), address:v('pf-addr'), pan, gstin, bank_holder:v('pf-holder'), bank_name:v('pf-bank'), bank_account:acct, bank_ifsc:ifsc}}, 'pf-err') === FAIL) return;
    if (U.modal?.type === 'profile') U.modal = null; done('Details saved'); },
  docs: async () => { if (await call('save_documents', {p_aadhaar4:v('dc-a4'), p_consent:$('#dc-consent').checked}, 'dc-err') === FAIL) return; if (U.modal?.type === 'profile') U.modal = null; done('Documents saved'); },
  sign: async () => { const m = memberIn(U.pid, S.session), name = v('sg-name');
    if (name.length < 2) return err('sg-err', 'Type your full name.'); if (!U.sigInk) return err('sg-err', 'Draw your signature in the box.');
    if (await call('sign_agreement', {p_crew:m.id, p_name:name, p_signature:$('#sig').toDataURL('image/png')}, 'sg-err') !== FAIL) done('Signed. The CFO or Commercial Head approves it next.'); },
  raise: async () => { if (!v('rv-no')) return err('rv-err', 'Enter your invoice number.'); const from = v('rv-from'), to = v('rv-to');
    if (!from || !to || to < from) return err('rv-err', 'Check the dates: the period ends before it starts.');
    if (await call('submit_crew_invoice', {p_production:U.pid, p:{no:v('rv-no'), from, to, qty:+v('rv-qty'), gst_rate:+v('rv-gst') || 0, desc:v('rv-desc')}}, 'rv-err') === FAIL) return;
    U.modal = null; done(`Invoice ${v('rv-no') || ''} submitted to your HOD`); },
  pay: async () => { if (await call('pay_invoices', {p_production:U.pid, p_ids:[U.modal.id], p_ref:v('md-v')}, 'md-err') === FAIL) return; U.modal = null; done('Marked paid'); },
  remove: async () => { const r = await call('remove_person', {p_crew:U.modal.id, p_reason:v('rm-why')}, 'rm-err'); if (r === FAIL) return;
    U.modal = null; U.drawer = null; done(r === 'deleted' ? 'Deleted' : 'Removed from the production; their records are kept'); },
  rmask: async () => { if (await call('request_removal', {p_crew:U.modal.id, p_reason:v('rm-why')}, 'rm-err') === FAIL) return; U.modal = null; done('Request sent to the CFO and Commercial Head'); },
  rmdecide: async () => { const r = await call('decide_removal', {p_request:U.modal.id, p_approve:!!U.modal.yes, p_note:v('rm-note')}, 'rm-err'); if (r === FAIL) return;
    if (r !== 'declined') U.drawer = null; U.modal = null; done(r === 'declined' ? 'Kept; they’ve been told why' : r === 'deleted' ? 'Approved and deleted' : 'Approved; removed from the production'); },
  unlockask: async () => { if (await (U.modal.id ? call('request_day_unlock', {p_day:U.modal.id, p_reason:v('ul-why')}, 'ul-err') : call('request_date_unlock', {p_production:U.pid, p_date:U.modal.date, p_reason:v('ul-why')}, 'ul-err')) === FAIL) return; U.modal = null; done('Request sent to the Commercial Head and Commercial Managers'); },
  unlockdecide: async () => { if (await call('decide_day_unlock', {p_request:U.modal.id, p_approve:!!U.modal.yes, p_note:v('ud-note')}, 'ud-err') === FAIL) return; const y = U.modal.yes; U.modal = null; done(y ? 'Allowed for 24 hours' : 'Refused'); },
  task: async () => { const who = [...document.querySelectorAll('input[name=tk-who]:checked')].map(x => x.value);
    const id = await call('save_task', {p_production:U.pid, p:{id:U.modal.id || '', title:v('tk-title'), kind:document.querySelector('input[name=tk-kind]:checked')?.value || 'task', details:v('tk-details'),
      priority:v('tk-prio'), due:v('tk-due'), dept:v('tk-dept'), day_id:v('tk-day'), assignees:who}}, 'tk-err');
    if (id === FAIL) return; U.modal = null; U.drawer = {type:'task', id}; done(who.length ? 'Saved; the people assigned have been told' : 'Saved'); },
  costadd: async () => { const c = costForm(); if (!c) return;
    if (await call('add_cost_entries', {p_production:U.pid, p_rows:[{date:c.date, head:c.head, item:c.item, payee:c.payee, qty:c.qty, rate:c.rate, amount:c.amount, mode:c.mode, holder:c.holder || '', bill_no:c.bill}], p_source:'manual'}, 'ca-err') === FAIL) return;
    U.chead = c.head; U.cmode = c.mode; done(`${inr(c.amount)} added to ${c.head}`); },
  float: async () => { const a = Math.round(+v('fl-amt')); if (!a) return err('fl-err', 'Enter an amount (negative if cash came back).');
    if (await call('give_petty_float', {p_production:U.pid, p_holder:v('fl-who'), p_amount:a, p_note:v('fl-note')}, 'fl-err') === FAIL) return; U.modal = null; done('Petty cash recorded; they’ve been told'); },
  dpr: async () => { const x = dprValues(); if (!x.call || !x.wrap) return err('dp-err', 'Enter the actual call and wrap times.');
    if (await call('save_dpr', {p_day:U.drawer.id, p:{act_call:x.call, first_shot:x.first, lunch_min:x.lunch ?? '', act_wrap:x.wrap, scenes_planned:x.planned ?? '', scenes_shot:x.shot ?? '', minutes_shot:x.minutes ?? '', delay:x.delay}}, 'dp-err') === FAIL) return;
    U.dprEdit = false; done('Daily report filed'); },
  taskupdate: async () => { if (await call('add_task_update', {p_task:U.drawer.id, p_body:v('tu-body'), p_kind:document.querySelector('input[name=tu-kind]:checked')?.value || 'comment'}, 'tu-err') === FAIL) return; done('Posted'); },
  dayedit: async () => { const e1 = v('de-ep1'), e2 = v('de-ep2');
    if (await call('update_day', {p_day:U.modal.id, p:{call:v('de-call'), wrap:v('de-wrap'), location:v('de-loc'), note:v('de-note'), ep_from:e1, ep_to:e2 || e1}}, 'de-err') === FAIL) return;
    U.modal = null; done('Saved; the crew have been told about any change to the call, wrap or location'); },
  daycancel: async () => { if (await call('set_day_status', {p_day:U.modal.id, p_status:'cancelled', p_note:v('dc-why')}, 'dx-err') === FAIL) return; U.modal = null; done('Day cancelled; the crew have been told'); },
  adjust: async () => { const items = dedRows().map(({type, amount, note}) => ({type, amount, note}));
    const r = await call('set_invoice_adjustments', {p_id:U.modal.id, p_items:items, p_remarks:v('dd-rem')}, 'dd-err'); if (r === FAIL) return; U.modal = null; done(`Saved · will pay ${inr(+r)}`); },
  reject: async () => { if (await call('reject_crew_invoice', {p_id:U.modal.id, p_reason:v('md-v')}, 'md-err') === FAIL) return; U.modal = null; U.drawer = null; done('Invoice rejected; they’ll see the reason'); },
  payrun: async () => { const n = await call('pay_invoices', {p_production:U.pid, p_ids:U.sel, p_ref:v('md-v')}, 'md-err'); if (n === FAIL) return; U.sel = []; U.modal = null; done(`${n} invoice${n > 1 ? 's' : ''} marked paid`); },
  company: async () => { const g = v('co-gstin').toUpperCase(), pan = v('co-pan').toUpperCase(), tan = v('co-tan').toUpperCase(), ifsc = v('co-ifsc').toUpperCase(), acct = v('co-acct').replace(/\s/g, '');
    if (!v('co-legal')) return err('co-err', 'Enter the company’s legal name as it appears on its PAN.');
    if (!PAN_RE.test(pan)) return err('co-err', 'The company PAN is 10 characters: 5 letters, 4 numbers, 1 letter.');
    if (!TAN_RE.test(tan)) return err('co-err', 'TAN is 10 characters: 4 letters, 5 numbers, 1 letter (like MUMS12345C). You need it to deduct TDS.');
    if (g && !GSTIN_RE.test(g)) return err('co-err', 'That GSTIN doesn’t look right: 15 characters, like 27AAACS1234K1Z5.');
    if (g && g.slice(2, 12) !== pan) return err('co-err', 'The GSTIN must contain the company PAN (characters 3 to 12).');
    if (!v('co-addr')) return err('co-err', 'Enter the registered address.'); if (!v('co-sig')) return err('co-err', 'Enter who signs agreements for the company.');
    if (!ACCT_RE.test(acct) || !IFSC_RE.test(ifsc)) return err('co-err', 'Enter the account number (9 to 18 digits) and IFSC of the bank you pay crew from.');
    const first = !S.company;
    const r = await call('setup_company', {p:{legal:v('co-legal'), brand:v('co-brand'), type:v('co-type'), pan, tan, gstin:g, state:v('co-state'), cin:v('co-cin'), address:v('co-addr'),
      signatory:v('co-sig'), designation:v('co-desig'), email:v('co-email'), phone:v('co-phone'), bank:{name:v('co-bank'), acct, ifsc},
      tally:{company:v('co-tco') || v('co-legal'), bankLedger:v('co-tbank') || `${v('co-bank') || 'Bank'} - Production A/c`, expenseGroup:v('co-texp'), creditorsGroup:v('co-tcred')}}}, 'co-err');
    if (r === FAIL) return; U.coEdit = false;
    if (first){ U.view = 'projects'; U.modal = {type:'project'}; return done('Company saved. Step 2: create your first production.'); }
    done('Company details saved'); },
  plan: async () => { const n = await call('plan_days', {p_production:U.pid, p:{from:v('pl-from'), to:v('pl-to'), skip_sundays:$('#pl-sun').checked, call:v('pl-call'), wrap:v('pl-wrap'),
      location:v('pl-loc'), eps_per_day:+v('pl-eps') || 0, start_ep:+v('pl-ep') || 1}}, 'pl-err');
    if (n === FAIL) return; U.modal = null; U.month = ymOf(v('pl-from') || today()); done(`${n} shoot day${n > 1 ? 's' : ''} added`); },
  checkin: async () => { const name = await call('check_in', {p_day:U.drawer?.id, p_code:v('ci-code')}, 'ci-err'); if (name !== FAIL) done(`${name} checked in`); },
  budget: async () => { const b = {}; document.querySelectorAll('[data-budget]').forEach(i => { const n = +i.value; if (n > 0) b[i.dataset.budget] = n; });
    if (await call('set_budgets', {p_id:U.pid, p:b}, 'bd-err') === FAIL) return; U.modal = null; done('Budgets saved'); },
  admin: async () => { if (await call('add_admin', {p_username:v('ad-user'), p_role:v('ad-role')}, 'ad-err') === FAIL) return; U.modal = null; done('Owner access given'); },
});

/* ---------------------------------------------------------------- screens that differ from the demo */
function loginView(){
  const mode = U.auth || 'in';
  const tabs = `<div class="tabs" role="group" aria-label="Sign in or create account"><button data-act="auth" data-id="in" aria-pressed="${mode === 'in'}">Sign in</button><button data-act="auth" data-id="signup" aria-pressed="${mode === 'signup'}">Create account</button></div>`;
  let form;
  if (mode === 'signup') form = `<form class="stack" data-form="signup"><h2>Create your account</h2>
      <div class="grid2"><label class="f">Full name<input type="text" id="su-name" autocomplete="name"></label><label class="f">Mobile <span class="hint">links you to your invite</span><input type="tel" id="su-phone" autocomplete="tel" placeholder="98200 00000"></label></div>
      <label class="f">Email <span class="hint">we send a link to confirm it</span><input type="email" id="su-email" autocomplete="email"></label>
      <label class="f">Username <span class="hint">3–30 characters: a–z, 0–9, dot or underscore</span><input type="text" id="su-user" autocomplete="username"></label>
      <label class="f">Password <span class="hint">at least 8 characters</span><input type="password" id="su-pass" autocomplete="new-password"></label>
      <p class="err" id="su-err"></p><button class="btn primary" type="submit">Create account</button>
      <p class="small muted">Then confirm your email, sign in, and enter the production code your Line Producer sent you.</p></form>`;
  else if (mode === 'forgot') form = `<form class="stack" data-form="forgot"><h2>Reset your password</h2><label class="f">Email you signed up with<input type="email" id="fp-email" autocomplete="email"></label>
      <p class="err" id="fp-err"></p><div class="row"><button class="btn primary" type="submit">Send reset link</button><button class="btn ghost" type="button" data-act="auth" data-id="in">Back to sign in</button></div></form>`;
  else if (mode === 'sent') form = `<div class="stack"><h2>Check your email</h2><p>We sent a link to <b>${esc(U.sentTo || '')}</b>. ${U.sentWhat === 'reset' ? 'Open it to choose a new password.' : 'Open it to confirm your account, then sign in here.'}</p>
      <p class="small muted">Nothing there after a few minutes? Check spam, or try again.</p><button class="btn" data-act="auth" data-id="in" style="justify-self:start">Back to sign in</button></div>`;
  else form = `<form class="stack" data-form="login"><h2>Sign in</h2>
      <label class="f">Username or email<input type="text" id="li-user" autocomplete="username"></label>
      <label class="f">Password<input type="password" id="li-pass" autocomplete="current-password"></label>
      <p class="err" id="li-err"></p><div class="row"><button class="btn primary" type="submit">Sign in</button><button class="btn ghost sm" type="button" data-act="forgot">Forgot password?</button></div></form>`;
  const gbtn = t => `<button class="btn gbtn" type="button" data-act="google">${GOOGLE_G}${t}</button>`;
  // with Google switched on it is the main way in; the password form folds away (and stays open once used)
  let main;
  if (U.google && ['in','signup'].includes(mode)) main = `<div class="stack gcard"><h2>${mode === 'signup' ? 'Create your account' : 'Sign in'}</h2>${gbtn(mode === 'signup' ? 'Sign up with Google' : 'Continue with Google')}
      <p class="small muted">${mode === 'signup' ? 'Your name and email come from Google. No password, no confirmation email.' : 'One tap with your Gmail. New here? This creates your account too.'} Use the Gmail your Line Producer invited, if they used one.</p></div>
    <details class="pwbox" ${U.pwOpen ? 'open' : ''}><summary>${mode === 'signup' ? 'No Gmail? Create an account with a username and password' : 'Use a username and password instead'}</summary>${form.replace(/<h2>[^<]*<\/h2>/, '').replace('<button class="btn ghost sm" type="button" data-act="forgot">Forgot password?</button>', '')}</details>
    ${mode === 'in' ? '<button class="btn ghost sm" type="button" data-act="forgot" style="justify-self:start">Forgot password?</button>' : ''}`;
  else if (U.google && mode === 'forgot') main = `${form}<div class="or"><span>or skip the email</span></div>${gbtn('Sign in with Google instead')}
      <p class="small muted">If your account uses a Gmail address, sign in with that Google account: you’re straight back in, with all your details. Then set a new password from your name menu if you want one.</p>`;
  else main = form;
  return `<div class="login">
  <section class="login-brand"><div class="stripes"></div>
    <div class="row" style="gap:10px"><span class="brand" style="color:inherit"><i style="background:var(--accent-ink);color:var(--accent)">CD</i><span>CrewDesk</span></span></div>
    <div class="stack" style="gap:18px"><h1>Every production, one front desk.</h1>
      <p>Onboard crew, cast and vendors once: deal, KYC, agreement, schedule, invoices and payments in one place, with every change on record.</p></div>
    <p class="small" style="opacity:.85;max-width:44ch">Your details are private. Bank, PAN and Aadhaar are seen only by you, the CFO, the Commercial Head and Finance on your production.</p>
  </section>
  <section class="login-form">${['in','signup'].includes(mode) ? tabs : ''}${main}
    <div class="helpbox">${helpLink('New here? Watch the 2-minute setup video')}<p class="small muted">Or <a href="/central/" target="_blank" rel="noopener">look around the demo</a> with sample data.</p></div></section></div>`;
}
// keep what people type on the sign-in screens through redraws and errors (in memory only; cleared once they're in)
const DRAFT = {};
document.addEventListener('input', e => { const t = e.target; if (t.id && t.closest?.('.login-form')) DRAFT[t.id] = t.value; });
document.addEventListener('toggle', e => { if (e.target.matches?.('.pwbox')) U.pwOpen = e.target.open; }, true);
function fillDrafts(){
  const from = {'li-user':['su-user','su-email'], 'fp-email':['su-email','li-user'], 'su-email':['fp-email','li-user']};
  document.querySelectorAll('.login-form input').forEach(el => {
    if (el.value) return;
    let v = DRAFT[el.id];
    if (!v) for (const k of from[el.id] || []) if (DRAFT[k] && (el.type !== 'email' || DRAFT[k].includes('@'))) { v = DRAFT[k]; break; }
    if (v) el.value = v;
  });
}
const demoRender = render;
render = function(){
  const a = document.activeElement, id = a?.id, sel = a && 'selectionStart' in a ? [a.selectionStart, a.selectionEnd] : null;
  demoRender();
  if (S.session) return;
  fillDrafts();
  const back = id && document.getElementById(id); if (back && back !== document.activeElement){ back.focus(); try { if (sel) back.setSelectionRange(...sel); } catch {} }
};
const demoModal = modalBody;
modalBody = function(){
  const M = U.modal, head = (t, s = '') => `<div class="spread"><div class="stack" style="gap:4px"><h2>${t}</h2>${s ? `<p class="muted small">${s}</p>` : ''}</div><button class="btn ghost sm" data-act="close-modal" aria-label="Close">${icon('x', 16)}</button></div>`;
  if (M.type === 'invite2'){
    const p = proj(U.pid), msg = `Hi ${M.name.split(' ')[0]}, you're on ${p.name} in CrewDesk.\n\n1. Open ${location.origin}/ and ${U.google ? `tap “Continue with Google”${M.email ? ` with ${M.email}` : ''}${M.phone ? ` (it asks for your mobile: ${M.phone})` : ''}` : `create your account${M.phone ? ` with this mobile number: ${M.phone}` : M.email ? ` with this email: ${M.email}` : ''}`}\n2. Enter the production code: ${fmtCode(p.invite)}\n3. Add your bank details, PAN, masked Aadhaar and a photo\n4. Sign your agreement in the app`;
    return `${head('Invite ready', 'Their deal is saved. When they join with the code using this mobile or email, it’s linked to them automatically.')}
      <div class="copybox"><pre>${esc(msg)}</pre></div><div class="row"><button class="btn primary" data-act="copy" data-text="${esc(msg)}">${icon('copy', 16)}Copy message</button><a class="btn" href="https://wa.me/?text=${encodeURIComponent(msg)}" target="_blank" rel="noopener">Open WhatsApp</a><button class="btn ghost" data-act="close-modal">Done</button></div>`;
  }
  if (M.type === 'budget'){
    const p = proj(U.pid);
    return `${head('Department budgets', 'Before GST. Used for “budget used” on Home and Reports.')}<form class="stack" data-form="budget"><div class="grid2">${Object.keys(DEPTS).map(d => `<label class="f">${esc(d)}<input type="number" min="0" step="10000" class="mono" data-budget="${esc(d)}" value="${p.budget?.[d] || ''}"></label>`).join('')}</div>
      <p class="err" id="bd-err"></p><div class="row"><button class="btn primary" type="submit">Save budgets</button><button class="btn ghost" type="button" data-act="close-modal">Cancel</button></div></form>`;
  }
  if (M.type === 'admin') return `${head('Give owner access', 'Owners see and run every production: deals, agreements, final approvals and company details.')}
    <form class="stack" data-form="admin"><div class="grid2"><label class="f">Their username or email<input type="text" id="ad-user" autocomplete="off"></label><label class="f">As<select id="ad-role"><option value="cfo">CFO</option><option value="commercial">Commercial Head</option></select></label></div>
    <p class="small muted">They need a CrewDesk account first.</p><p class="err" id="ad-err"></p><div class="row"><button class="btn primary" type="submit">Give access</button><button class="btn ghost" type="button" data-act="close-modal">Cancel</button></div></form>`;
  if (M.type === 'welcome'){
    const u = me(), office = isOwner(u.title) || S.members.some(m => m.userId === S.session && isStaff(m.role)), first = (u.name || '').split(' ')[0];
    const steps = office
      ? [['Set up once', 'Company details, then a production. Each show gets its own joining code.'], ['Onboard people', 'Set the deal and send the invite on WhatsApp. They fill their own details.'], ['Agreements and the schedule', 'Send agreements, approve them, plan shoot days and check people in.'], ['One approval chain', 'Auditor → Head of Production → Commercial Head → paid; each person is told in turn. Assign tasks to the team.']]
      : [['Join your show', 'Enter the production code and your mobile number.'], ['Fill your details', 'Photo, PAN, bank account, then Aadhaar and PAN card photos.'], ['Sign your agreement', 'You get a notification when it’s ready.'], ['Get paid', 'Show your Crew ID at the gate, then raise your invoice in a few taps.']];
    return `<div class="welcome ${office ? 'land' : 'port'}">
      <div class="w-video"><video src="/help/${office ? 'crewdesk-office' : 'crewdesk-setup'}.mp4" poster="/help/${office ? 'crewdesk-office' : 'crewdesk-setup'}.jpg" controls playsinline preload="metadata" aria-label="Welcome video"></video></div>
      <div class="w-text"><button class="btn ghost sm w-x" data-act="close-modal" aria-label="Close">${icon('x', 16)}</button>
        <h2>${office ? 'Run your production office in one place' : 'You’ll be set up in 2 minutes'}</h2><p class="meta">Welcome to CrewDesk${first ? ', ' + esc(first) : ''}</p>
        <p class="muted">${office ? 'Watch how a show runs from invite to payment, then try it.' : 'Watch the short video, then follow the steps on your screen.'}</p>
        <ol class="w-steps">${steps.map(([t, d]) => `<li><b>${esc(t)}</b><span>${esc(d)}</span></li>`).join('')}</ol>
        <div class="row"><button class="btn primary" data-act="close-modal">Get started</button><a class="btn ghost" href="/help/" target="_blank" rel="noopener">Open the full guide</a></div>
        <p class="small muted">Watch it again any time: your name, top right → How to use CrewDesk.</p></div></div>`;
  }
  if (M.type === 'newpass') return `${head('Choose a new password')}<form class="stack" data-form="newpass"><label class="f">New password <span class="hint">at least 8 characters</span><input type="password" id="np-pass" autocomplete="new-password"></label><p class="err" id="npw-err"></p><button class="btn primary" type="submit" style="justify-self:start">Save password</button></form>`;
  return demoModal();
};
const demoCompanyView = companyView;
companyView = function(){
  const html = demoCompanyView();
  if (!S.company) return html;
  const owners = S.admins.map(a => `<li>${av(user(a.userId), 26)}<span class="spread"><b>${esc(user(a.userId)?.name || 'Owner')}</b><span class="chip acc">${ROLES[a.role].label}</span></span></li>`).join('');
  return html + `<section class="panel"><div class="spread" style="margin-bottom:8px"><h3>Owner access</h3>${can.company(me()) ? '<button class="btn sm" data-act="add-admin">Give owner access</button>' : ''}</div><ul class="feed">${owners}</ul></section>`;
};
const demoReportsView = reportsView;
reportsView = function(){
  const html = demoReportsView(), r = myRole();
  return isOwner(r) || r === 'accounts' ? html.replace('<span class="small muted">before GST</span></div>\n    <div class="tablewrap">', '<span class="row"><span class="small muted">before GST</span><button class="btn sm" data-act="budget">Edit budgets</button></span></div>\n    <div class="tablewrap">') : html;
};

/* ---------------------------------------------------------------- notifications and live updates */
I.bell = '<path d="M6 9a6 6 0 0 1 12 0c0 5 2 7 2 7H4s2-2 2-7"/><path d="M10 20a2 2 0 0 0 4 0"/>';
const unread = () => (S.notes || []).filter(n => !n.read).length;
const demoTopBar = topBar;
topBar = function(){
  const h = demoTopBar(), n = unread();
  const bell = `<button class="bell" data-act="notes" aria-label="Notifications${n ? `, ${n} unread` : ''}" aria-expanded="${!!U.notesOpen}">${icon('bell', 20)}${n ? `<span class="badge">${n > 99 ? '99+' : n}</span>` : ''}</button>${U.notesOpen ? notesPanel() : ''}`;
  return h.replace('<span class="grow"></span>', '<span class="grow"></span>' + bell);
};
function notesPanel(){
  const list = S.notes || [], ask = 'Notification' in window && Notification.permission === 'default';
  return `<section class="notes" aria-label="Notifications"><header class="spread"><b>Notifications</b>${unread() ? '<button class="btn ghost sm" data-act="notes-read">Mark all read</button>' : ''}</header>
    ${ask ? '<button class="notes-perm" data-act="notes-perm">Turn on desktop alerts for when CrewDesk is open in another tab</button>' : ''}
    <ul>${list.map(n => `<li><button data-act="note-open" data-id="${n.id}" class="${n.read ? '' : 'unread'}"><span class="dot" aria-hidden="true"></span><span class="tx"><b>${esc(n.title)}</b>${n.body ? `<span>${esc(n.body)}</span>` : ''}<time>${n.pid && proj(n.pid) ? esc(proj(n.pid).name) + ' · ' : ''}${fmtT(n.at)}</time></span></button></li>`).join('')
      || '<li class="none">Nothing yet. Approvals, signatures, invoices and payments that concern you will show here.</li>'}</ul></section>`;
}
Object.assign(ACT, {
  notes: () => { U.notesOpen = !U.notesOpen; U.menu = false; render(); },
  'notes-read': async () => { if (await call('mark_notifications_read', {}) !== FAIL){ (S.notes || []).forEach(n => n.read = true); render(); } },
  'notes-perm': async () => { try { await Notification.requestPermission(); } catch {} render(); },
  'note-open': async el => {
    const n = (S.notes || []).find(x => String(x.id) === el.dataset.id); U.notesOpen = false;
    if (n && !n.read){ n.read = true; call('mark_notifications_read', {p_ids:[n.id]}); }
    if (n?.pid && S.projects.some(p => p.id === n.pid)){ U.pid = n.pid; U.view = n.view || 'home'; }
    U.drawer = null; U.modal = null; render(); window.scrollTo(0, 0);
  },
});
document.addEventListener('click', e => { if (U.notesOpen && !e.target.closest('.notes') && !e.target.closest('.bell')){ U.notesOpen = false; render(); } });

// Changes from other people arrive within a second or two. If you're typing, signing or have a form open,
// the screen waits and catches up as soon as you're done, so nothing you've entered is lost.
let stopLive = () => {}, liveTimer = null, pollTimer = null;
function busy(){ const a = document.activeElement; return !!(U.modal || (a && a.matches('input,textarea,select')) || (document.querySelector('#sig') && U.sigInk)); }
function refreshSoon(){
  clearTimeout(liveTimer);
  liveTimer = setTimeout(async () => { if (!S.session) return; try { await reload(); } catch { return; } if (busy()) U.pendingRender = true; else render(); }, 350);
}
function desktopAlert(n){ try { if (document.hidden && 'Notification' in window && Notification.permission === 'granted') new Notification(n.title, {body:n.body || '', tag:'crewdesk-' + n.id}); } catch {} }
function startLive(uid){
  stopLive();
  const seen = new Set((S.notes || []).map(n => n.id));
  const onNote = n => { if (seen.has(n.id)) return; seen.add(n.id); toast(n.title); desktopAlert(n); refreshSoon(); };
  try { stopLive = DB.live(uid, onNote, refreshSoon) || (() => {}); } catch { stopLive = () => {}; }
  clearInterval(pollTimer); pollTimer = setInterval(() => { if (!document.hidden) refreshSoon(); }, 60000);   // safety net
}
document.addEventListener('focusout', () => setTimeout(() => { if (U.pendingRender && !busy()){ U.pendingRender = false; render(); } }, 60));
const demoCloseModal = ACT['close-modal'];
ACT['close-modal'] = () => { demoCloseModal(); if (U.pendingRender){ U.pendingRender = false; render(); } };

/* ---------------------------------------------------------------- start */
async function boot(){
  $('#app').innerHTML = '<main><div class="wrap"><p class="muted" style="padding:40px 0">Loading CrewDesk…</p></div></main>';
  const cfg = window.CREWDESK_CONFIG || {};
  // coming back from Google with an error (cancelled, or the provider is switched off)
  const back = new URLSearchParams(location.search + '&' + location.hash.slice(1)), backErr = back.get('error_description');
  if (backErr){ history.replaceState(null, '', location.pathname); setTimeout(() => toast(/cancel|denied/i.test(backErr) ? 'Google sign-in was cancelled.' : 'Google sign-in didn’t work: ' + backErr.replace(/\+/g, ' ')), 300); }
  try { DB = window.CREWDESK_TEST_DB ? await window.CREWDESK_TEST_DB() : await liveDB(cfg); }
  catch (e) { $('#app').innerHTML = `<main><div class="wrap"><div class="empty">CrewDesk couldn’t start: ${esc(friendly(e.message))}. Check your connection and reload.</div></div></main>`; return; }
  const enter = async u => {
    S.session = u?.id || null;
    if (u){ Object.keys(DRAFT).forEach(k => delete DRAFT[k]); U.pwOpen = false; try { await reload(); } catch (e) { toast(friendly(e.message)); } startLive(u.id);
      // the first time someone signs in, show them the welcome video for their role (once, on any device)
      try { if (!U.modal && !(await DB.rpc('tour_status'))){ U.modal = {type:'welcome'}; DB.rpc('tour_done').catch(() => {}); } } catch {} }
    else { stopLive(); clearInterval(pollTimer); U.notesOpen = false; S = {company:null, admins:[], users:[], projects:[], members:[], invoices:[], days:[], exports:[], log:[], notes:[], removals:[], tasks:[], unlocks:[], session:null}; }
    render();
  };
  DB.auth.onChange((event, u) => {
    if (event === 'PASSWORD_RECOVERY'){ U.modal = {type:'newpass'}; }
    if (event === 'SIGNED_OUT') U.auth = 'in';
    if (event === 'SIGNED_IN' && u?.id === S.session) return;
    if (['SIGNED_IN','SIGNED_OUT','PASSWORD_RECOVERY','USER_UPDATED'].includes(event)) enter(u);
  });
  DB.auth.providers?.().then(x => { if (U.google === !!x.google) return; U.google = !!x.google; if (!S.session) render(); });
  await enter(await DB.auth.current());
  // pick up other people's changes when someone comes back to the tab
  addEventListener('focus', () => { if (S.session && !U.modal && !document.activeElement?.matches('input,textarea,select')) reload().then(render, () => {}); });
}
boot();
