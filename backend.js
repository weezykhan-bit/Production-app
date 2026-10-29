// CrewDesk data layer. The app talks to one small interface:
//   auth: current(), signIn(login, password), signUp({...}), sendCode(email), verifyCode(email, code), signOut(), onChange(fn)
//   rpc(name, params) -> data (throws Error with a readable message)
//   select(table, {eq, in, order, desc, limit}) -> rows
// Two engines implement it:
//   live — Supabase (config.js holds the project URL + anon key)
//   demo — the same database schema running in the browser (PGlite), seeded with a sample production.

const SUPABASE_ESM = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/+esm';
const PGLITE_ESM = 'https://cdn.jsdelivr.net/npm/@electric-sql/pglite@0.2.17/dist/index.js';
const MIGRATION = './supabase/migrations/20261029100000_crewdesk.sql';
const STUB = './supabase/tests/supabase_stub.sql';
const SEED = './demo/seed.sql';
const DEMO_DB = 'idb://crewdesk-demo-v1';

const fail = e => { throw new Error(e?.message || String(e)); };

/* ------------------------------------------------------------------ live */
async function liveBackend(cfg){
  const { createClient } = await import(SUPABASE_ESM);
  const sb = createClient(cfg.url, cfg.anonKey, { auth: { persistSession: true } });
  const unwrap = ({ data, error }) => { if (error) fail(error); return data; };
  const select = async (table, q = {}) => {
    const all = [];
    for (let from = 0; ; from += 1000) {   // the API returns at most 1,000 rows per request
      let b = sb.from(table).select(q.cols || '*');
      for (const [k, v] of Object.entries(q.eq || {})) b = b.eq(k, v);
      for (const [k, v] of Object.entries(q.in || {})) b = b.in(k, v);
      if (q.order) b = b.order(q.order, { ascending: !q.desc });
      b = b.range(from, from + Math.min(q.limit || 1000, 1000) - 1);
      const rows = unwrap(await b);
      all.push(...rows);
      if (rows.length < 1000 || (q.limit && all.length >= q.limit)) return all;
    }
  };
  return {
    mode: 'live',
    select,
    async update(table, patch, eq){
      let b = sb.from(table).update(patch);
      for (const [k, v] of Object.entries(eq)) b = b.eq(k, v);
      unwrap(await b);
    },
    rpc: async (name, params = {}) => unwrap(await sb.rpc(name, params)),
    auth: {
      async current(){ return (await sb.auth.getSession()).data.session?.user || null; },
      async signIn(login, password){
        const email = unwrap(await sb.rpc('login_email', { p_login: login }));
        if (!email) fail('No account with that username or email');
        unwrap(await sb.auth.signInWithPassword({ email, password }));
      },
      async signUp({ email, password, username, full_name }){
        const data = unwrap(await sb.auth.signUp({ email, password, options: { data: { username, full_name }, emailRedirectTo: location.origin + location.pathname } }));
        return { needsConfirm: !data.session };
      },
      async sendCode(email){ unwrap(await sb.auth.signInWithOtp({ email, options: { emailRedirectTo: location.origin + location.pathname } })); },
      async verifyCode(email, token){ unwrap(await sb.auth.verifyOtp({ email, token, type: 'email' })); },
      async resetPassword(email){ unwrap(await sb.auth.resetPasswordForEmail(email, { redirectTo: location.origin + location.pathname })); },
      async signOut(){ await sb.auth.signOut(); },
      onChange(fn){ sb.auth.onAuthStateChange((_e, s) => fn(s?.user || null)); }
    }
  };
}

/* ------------------------------------------------------------------ demo */
// Each call runs in its own transaction as the signed-in persona, under the same row-level security as production.
async function demoBackend(opts = {}){
  const { PGlite } = await import(opts.pgliteUrl || PGLITE_ESM);
  let db, fresh = false;
  try {
    db = new PGlite(opts.memory ? undefined : DEMO_DB);
    await db.waitReady;
    fresh = !(await db.query("select to_regclass('public.projects') is not null as ok")).rows[0].ok;
  } catch {
    db = new PGlite(); await db.waitReady; fresh = true;   // private windows can block IndexedDB
  }
  if (fresh) {
    const text = async u => { const r = await fetch(u); if (!r.ok) fail('Could not load ' + u); return r.text(); };
    const [stub, mig, seed] = await Promise.all([text(STUB), text(MIGRATION), text(SEED)]);
    await db.exec(stub); await db.exec(mig); await db.exec(seed);
  }
  let user = null; const listeners = [];
  try { const id = localStorage.getItem('crewdesk-demo-user'); if (id) user = (await db.query('select id, email from auth.users where id = $1', [id])).rows[0] || null; } catch {}
  // One request at a time (the browser database has a single connection). A failed request
  // must not fail the ones queued behind it, so the queue itself never stays rejected.
  let queue = Promise.resolve();
  const enqueue = fn => { const p = queue.then(fn, fn); queue = p.catch(() => {}); return p; };
  const asUser = (sql, params) => enqueue(async () => {
    await db.exec('begin');
    try {
      await db.query("select set_config('request.jwt.claim.sub', $1, true)", [user?.id || '']);
      await db.exec(`set local role ${user ? 'authenticated' : 'anon'}`);
      const r = await db.query(sql, params);
      await db.exec('commit');
      return r.rows[0]?.j ?? null;
    } catch (e) { await db.exec('rollback'); fail(e); }
  });
  // demo-only lookups (sample people, demo sign-in) run as the database owner, in the same queue
  const asOwner = (sql, params) => enqueue(async () => (await db.query(sql, params)).rows);
  const ident = s => { if (!/^[a-z_][a-z0-9_]*$/.test(s)) fail('bad name ' + s); return s; };
  const setUser = u => { user = u; try { u ? localStorage.setItem('crewdesk-demo-user', u.id) : localStorage.removeItem('crewdesk-demo-user'); } catch {} listeners.forEach(f => f(u)); };
  return {
    mode: 'demo',
    async select(table, q = {}){
      const where = [], params = [];
      for (const [k, v] of Object.entries(q.eq || {})) { params.push(v); where.push(`${ident(k)} = $${params.length}`); }
      for (const [k, v] of Object.entries(q.in || {})) { params.push(v); where.push(`${ident(k)} = any($${params.length})`); }
      const sql = `select coalesce(jsonb_agg(to_jsonb(t)), '[]') j from (select * from public.${ident(table)}`
        + (where.length ? ' where ' + where.join(' and ') : '')
        + (q.order ? ` order by ${ident(q.order)} ${q.desc ? 'desc' : 'asc'}` : '')
        + (q.limit ? ` limit ${+q.limit}` : '') + ') t';
      return asUser(sql, params);
    },
    async update(table, patch, eq){
      const keys = Object.keys(patch), params = keys.map(k => patch[k]);
      const where = Object.entries(eq).map(([k, v]) => { params.push(v); return `${ident(k)} = $${params.length}`; });
      await asUser(`with u as (update public.${ident(table)} set ${keys.map((k, i) => `${ident(k)} = $${i + 1}`).join(', ')}
                    where ${where.join(' and ')} returning 1) select count(*) j from u`, params);
    },
    async rpc(name, params = {}){
      const keys = Object.keys(params);
      const vals = keys.map(k => params[k] !== null && typeof params[k] === 'object' && !Array.isArray(params[k]) ? JSON.stringify(params[k]) : params[k]);
      // set-returning and scalar functions both come back as JSON
      const sql = `select coalesce((select jsonb_agg(to_jsonb(r)) from public.${ident(name)}(${keys.map((k, i) => `${ident(k)} => $${i + 1}`).join(', ')}) r), 'null') j`;
      const out = await asUser(sql, vals);
      if (!Array.isArray(out)) return out;
      const unwrapScalar = x => (x && typeof x === 'object' && Object.keys(x).length === 1 && name in x) ? x[name] : x;
      const SET_RETURNING = ['cost_report'];
      return SET_RETURNING.includes(name) ? out : unwrapScalar(out[0] ?? null);
    },
    personas: () => asOwner(`select u.id, u.email, p.full_name, p.username,
        (select string_agg(distinct m.role::text, ', ') from members m where m.user_id = u.id) as roles
      from auth.users u join profiles p on p.id = u.id order by u.email`),
    async reset(){ try { await db.close(); indexedDB.deleteDatabase(DEMO_DB.replace('idb://', '/pglite/')); } catch {} setUser(null); },
    auth: {
      async current(){ return user; },
      async signIn(login, _password){
        const r = (await asOwner(`select u.id, u.email from auth.users u join profiles p on p.id = u.id
                                   where p.username = lower($1) or u.email = lower($1)`, [login.trim()]))[0];
        if (!r) fail('No demo account with that username');
        setUser(r);
      },
      async signUp({ email, username, full_name }){
        const id = crypto.randomUUID();
        await asOwner('insert into auth.users (id, email, raw_user_meta_data) values ($1, lower($2), $3)', [id, email, JSON.stringify({ username, full_name })]);
        setUser({ id, email });
        return { needsConfirm: false };
      },
      async sendCode(){ fail('Email codes work on the live site; in the demo, pick a person below.'); },
      async verifyCode(){ fail('Email codes work on the live site.'); },
      async resetPassword(){ fail('Password reset works on the live site.'); },
      async signOut(){ setUser(null); },
      onChange(fn){ listeners.push(fn); }
    }
  };
}

export async function createBackend(opts = {}){
  const cfg = window.CREWDESK_CONFIG;
  if (!opts.forceDemo && cfg?.url && cfg?.anonKey) return liveBackend(cfg);
  return demoBackend(opts);
}
