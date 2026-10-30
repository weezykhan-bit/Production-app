// Shared by the end-to-end test and the guide-video recorder: the real database schema and rules running in
// PGlite (Postgres compiled to WebAssembly) in place of Supabase, a web server with the production security
// headers on port 5188, and FAKE, the browser-side stand-in for the Supabase client.
import { createRequire } from 'module';
import http from 'http'; import fs from 'fs'; import path from 'path';
const require = createRequire(import.meta.url);
export const { chromium } = require('playwright');
const { PGlite } = await import(process.env.PGLITE || '@electric-sql/pglite');
export const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const read = f => fs.readFileSync(path.join(ROOT, f), 'utf8');

// ---------------------------------------------------------------- database
export const db = new PGlite();
await db.exec(read('supabase/tests/supabase_stub.sql'));
await db.exec(read('supabase/tests/storage_stub.sql'));
await db.exec(read('supabase/migrations/20261029100000_crewdesk.sql'));
await db.exec(`insert into auth.users (id, email, raw_user_meta_data) values ('11111111-1111-1111-1111-111111111111', 'fowzan@swastikstories.com', '{"username":"fowzan","full_name":"Fowzan","phone":"9820022031"}')`);
await db.exec(read('supabase/migrations/20261030100000_central.sql'));
await db.exec(read('supabase/migrations/20261030100100_central_storage.sql'));
await db.exec(read('supabase/migrations/20261030100200_central_hardening.sql'));
await db.exec(read('supabase/migrations/20261031100000_notifications.sql'));
await db.exec(read('supabase/migrations/20261101100000_deductions_and_lists.sql'));
await db.exec(read('supabase/migrations/20261102100000_google_signin.sql'));
await db.exec(read('supabase/migrations/20261103100000_removals.sql'));
await db.exec(read('supabase/migrations/20261104100000_welcome_tour.sql'));
await db.exec(read('supabase/migrations/20261105100000_schedule_alerts_and_fixes.sql'));
await db.exec(read('supabase/migrations/20261106100000_chain_locks_tasks.sql'));
// scripted runs start with the welcome video already seen; a test turns it back on where it checks it
await db.exec('alter table profiles alter column tour_seen_at set default now(); update profiles set tour_seen_at = now()');
const ident = s => { if (!/^[a-z_][a-z0-9_]*$/.test(s)) throw new Error('bad name ' + s); return s; };
const retType = {};
let q = Promise.resolve();
const serial = fn => { const p = q.then(fn, fn); q = p.catch(() => {}); return p; };
const asUser = (uid, sql, params) => serial(async () => {
  await db.exec('begin');
  try {
    await db.query("select set_config('request.jwt.claim.sub', $1, true)", [uid || '']);
    await db.exec(`set local role ${uid ? 'authenticated' : 'anon'}`);
    const r = await db.query(sql, params); await db.exec('commit'); return r.rows;
  } catch (e) { await db.exec('rollback'); throw e; }
});
export async function pg(op, a){
  if (op === 'select'){
    const rows = await asUser(a.uid, `select coalesce(jsonb_agg(to_jsonb(t)), '[]') j from (select * from public.${ident(a.table)}${a.order ? ` order by ${ident(a.order)} ${a.desc ? 'desc' : 'asc'}` : ''}) t`);
    return rows[0].j;
  }
  if (op === 'rpc'){
    if (!(a.name in retType)) retType[a.name] = (await db.query(`select format_type(prorettype, null) t from pg_proc where proname = $1 and pronamespace = 'public'::regnamespace`, [a.name])).rows[0]?.t;
    const keys = Object.keys(a.args || {}), vals = keys.map(k => { const v = a.args[k]; return v !== null && typeof v === 'object' && !Array.isArray(v) ? JSON.stringify(v) : v; });
    const rows = await asUser(a.uid, `select (public.${ident(a.name)}(${keys.map((k, i) => `${ident(k)} => $${i + 1}`).join(', ')}))::text as j`, vals);
    const t = retType[a.name], j = rows[0].j;
    return t === 'void' || j === null ? null : t === 'jsonb' ? JSON.parse(j) : t === 'integer' ? +j : j;
  }
  if (op === 'login'){
    const r = (await db.query(`select u.id, u.email from auth.users u join profiles p on p.id = u.id where p.username = lower($1) or lower(u.email) = lower($1)`, [a.login.trim()])).rows[0];
    if (!r) throw new Error('That username and password don’t match.'); return r;
  }
  if (op === 'signup'){
    const id = (await db.query('select gen_random_uuid() id')).rows[0].id;
    await db.query('insert into auth.users (id, email, raw_user_meta_data) values ($1, $2, $3)', [id, a.email, JSON.stringify({username:a.username, full_name:a.full_name, phone:a.phone})]);
    return {id, email:a.email};
  }
  if (op === 'google'){   // what Supabase does when Google sends someone back: a confirmed email, their Google name, no username or mobile
    let r = (await db.query('select id, email from auth.users where email = $1', [a.email])).rows[0];
    if (!r){ r = {id:(await db.query('select gen_random_uuid() id')).rows[0].id, email:a.email}; await db.query('insert into auth.users (id, email, raw_user_meta_data) values ($1, $2, $3)', [r.id, a.email, JSON.stringify({name:a.name, avatar_url:'https://lh3.googleusercontent.com/x'})]); }
    return r;
  }
  if (op === 'usernameFree') return (await db.query('select username_available($1) ok', [a.u])).rows[0].ok;
  throw new Error('unknown op ' + op);
}

// ---------------------------------------------------------------- web server with the production security headers
const csp = JSON.parse(read('vercel.json')).headers[0].headers[0].value;
export const server = http.createServer((req, res) => {
  let f = path.join(ROOT, decodeURIComponent(req.url.split('?')[0])); if (f.endsWith('/')) f += 'index.html';
  if (!fs.existsSync(f)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, {'Content-Type':{'.html':'text/html', '.js':'application/javascript', '.svg':'image/svg+xml'}[path.extname(f)] || 'text/plain', 'Content-Security-Policy':csp});
  res.end(fs.readFileSync(f));
}).listen(5188);

// ---------------------------------------------------------------- the browser side of the stand-in client
export const FAKE = () => {
  const files = new Proxy(JSON.parse(sessionStorage.getItem('fake-files') || '{}'), {set(t, k, v){ t[k] = v; sessionStorage.setItem('fake-files', JSON.stringify(t)); return true; }}); let user = JSON.parse(sessionStorage.getItem('fake-user') || 'null'); const fns = [];
  const set = (u, ev) => { user = u; sessionStorage.setItem('fake-user', JSON.stringify(u)); fns.forEach(f => f(ev, u)); };
  const run = async (op, a) => { const r = await window.pgCall(op, {...a, uid:user?.id}); if (r && r.__error) throw new Error(r.__error); return r; };
  window.CREWDESK_TEST_DB = async () => ({
    select: (table, q = {}) => run('select', {table, ...q}),
    rpc: (name, args = {}) => run('rpc', {name, args}),
    async upload(p, blob){ if (p.split('/')[0] !== user.id) throw new Error('new row violates row-level security policy'); files[p] = await new Promise(r => { const fr = new FileReader(); fr.onload = () => r(fr.result); fr.readAsDataURL(blob); }); },
    async signed(paths){ return Object.fromEntries(paths.filter(p => files[p]).map(p => [p, files[p]])); },
    // stands in for Supabase Realtime by checking every half second, as the signed-in person (so the same rules apply)
    live(uid, onNote, onPulse){
      let lastNote = null, lastPulse = null, stop = false;
      const tick = async () => {
        if (stop) return;
        try {
          const n = await run('select', {table:'notifications', order:'id', desc:true}), top = n[0]?.id || 0;
          if (lastNote !== null && top > lastNote) n.filter(x => x.id > lastNote).reverse().forEach(onNote);
          lastNote = top;
          const pulse = (await run('select', {table:'production_pulse'})).map(x => x.at).sort().pop() || '';
          if (lastPulse !== null && pulse !== lastPulse) onPulse();
          lastPulse = pulse;
        } catch {}
        setTimeout(tick, 500);
      };
      tick(); return () => { stop = true; };
    },
    auth: {
      current: async () => user,
      async signIn(login){ const u = await run('login', {login}); set(u, 'SIGNED_IN'); },
      async signUp(o){ await run('signup', o); return {needsConfirm:true}; },
      usernameFree: u => run('usernameFree', {u}),
      providers: async () => ({google:true, email:true}),
      async google(){ const u = await run('google', window.FAKE_GOOGLE || {email:'kavya.rao@gmail.com', name:'Kavya Rao'}); set(u, 'SIGNED_IN'); },
      async resetPassword(){}, async updatePassword(){},
      async signOut(){ set(null, 'SIGNED_OUT'); },
      onChange(fn){ fns.push(fn); }
    }
  });
};

// ---------------------------------------------------------------- the journey
