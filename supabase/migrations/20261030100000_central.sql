-- CrewDesk Central: company, productions, crew onboarding, shoot schedule, invoices, payments and Tally.
-- Builds on profiles, the sign-up trigger and the helper functions from 20261029100000_crewdesk.sql.
-- Adds tables and functions only; nothing existing is removed.
--
-- Security model
--   * Every table has row-level security and no insert/update/delete policy, so the API refuses direct writes.
--     (The one exception, from the first migration: people may update their own profile row.)
--   * Every change goes through a function below that checks who is calling and what their role allows.
--   * Helper functions that write (add_log) run with the caller's rights, so calling them directly is refused.
--   * Bank, PAN and Aadhaar details are visible only to the person, company owners and Finance on their production.

-- ================================================================ profile additions

alter table public.profiles
  add column if not exists photo_path    text,
  add column if not exists aadhaar_last4 text,
  add column if not exists aadhaar_path  text,
  add column if not exists pan_path      text,
  add column if not exists consent_at    timestamptz,
  add column if not exists emergency     text;
alter table public.profiles add constraint profiles_aadhaar_last4 check (aadhaar_last4 ~ '^[0-9]{4}$');
-- uploaded files must sit in the person's own folder
alter table public.profiles add constraint profiles_own_files check (
  (photo_path is null or split_part(photo_path, '/', 1) = id::text) and
  (aadhaar_path is null or split_part(aadhaar_path, '/', 1) = id::text) and
  (pan_path is null or split_part(pan_path, '/', 1) = id::text));

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare u text := nullif(lower(coalesce(new.raw_user_meta_data ->> 'username', '')), '');
begin
  if u is not null and (u !~ '^[a-z0-9_.]{3,30}$' or exists (select 1 from public.profiles where username = u)) then u := null; end if;
  insert into public.profiles (id, email, username, full_name, phone)
  values (new.id, new.email, u, nullif(new.raw_user_meta_data ->> 'full_name', ''), nullif(new.raw_user_meta_data ->> 'phone', ''))
  on conflict do nothing;
  return new;
end $$;

create function public.profile_ready(p public.profiles) returns boolean
language sql immutable set search_path = public as $$ select coalesce(array_length(kyc_missing(p), 1), 0) = 0 $$;
create function public.docs_ready(p public.profiles) returns boolean
language sql immutable set search_path = public as $$
  select p.aadhaar_path is not null and p.pan_path is not null and p.aadhaar_last4 is not null and p.consent_at is not null $$;

-- ================================================================ company (one per installation)

create table public.companies (
  id          boolean primary key default true check (id),
  legal       text not null check (length(trim(legal)) > 1),
  brand       text,
  entity_type text,
  pan         text not null check (pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  tan         text not null check (tan ~ '^[A-Z]{4}[0-9]{5}[A-Z]$'),
  gstin       text check (gstin_valid(gstin) and (gstin is null or substr(gstin, 3, 10) = pan)),
  state       text not null check (state ~ '^[0-9]{2}$'),
  cin         text,
  address     text not null check (length(trim(address)) > 3),
  signatory   text not null check (length(trim(signatory)) > 1),
  designation text,
  email       text,
  phone       text,
  bank        jsonb not null check (bank ->> 'acct' ~ '^[0-9]{9,18}$' and bank ->> 'ifsc' ~ '^[A-Z]{4}0[A-Z0-9]{6}$'),
  tally       jsonb not null default '{}',
  setup_by    uuid references auth.users on delete set null,
  setup_at    timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Owners of the whole company: CFO and Commercial Head. They see and run every production.
create table public.company_admins (
  user_id  uuid primary key references auth.users on delete cascade,
  role     text not null check (role in ('cfo','commercial')),
  added_by uuid references auth.users on delete set null,
  added_at timestamptz not null default now()
);

-- ================================================================ productions and crew

create table public.productions (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 0),
  format      text not null,
  platform    text,
  status      text not null default 'Pre-production' check (status in ('Pre-production','Shooting','Post-production','Wrapped')),
  planned_eps int not null default 1 check (planned_eps > 0),
  location    text,
  city        text not null default 'Mumbai',
  start_date  date,
  code        text not null unique check (code ~ '^[A-Z0-9]{8}$'),
  code_at     timestamptz not null default now(),
  code_by     uuid references auth.users on delete set null,
  budget      jsonb not null default '{}',
  created_by  uuid references auth.users on delete set null,
  created_at  timestamptz not null default now()
);

create table public.crew (
  id            uuid primary key default gen_random_uuid(),
  production_id uuid not null references public.productions on delete cascade,
  user_id       uuid references auth.users on delete cascade,          -- empty until the invited person joins
  invite_name   text,
  invite_phone  text,
  invite_email  text,
  role          text not null default 'crew' check (role in ('hop','lp','accounts','hod','crew','vendor')),
  kind          text not null default 'crew' check (kind in ('crew','cast','vendor')),
  dept          text,
  job           text,
  rate          bigint check (rate > 0),
  unit          text not null default 'day' check (unit in ('day','episode','week','month','lump')),
  joining       date,
  end_date      date,
  tds           text not null default '194C-1' check (tds in ('194C-1','194C-2','194J-10','194J-2','none')),
  terms         int not null default 30 check (terms in (7, 15, 30, 45)),
  active        boolean not null default true,
  crew_code     text not null default upper(substr(md5(gen_random_uuid()::text), 1, 6)),
  ag_status     text not null default 'none' check (ag_status in ('none','sent','signed','countersigned')),
  ag_text       text,
  ag_sent_at    timestamptz,
  ag_signed_at  timestamptz,
  ag_signed_name text,
  ag_signature  text check (ag_signature is null or length(ag_signature) < 200000),
  ag_hash       text,
  ag_counter_at timestamptz,
  ag_counter_by uuid references auth.users on delete set null,
  joined_at     timestamptz not null default now(),
  check (user_id is not null or invite_name is not null),
  check (end_date is null or joining is null or end_date >= joining),
  unique (production_id, user_id),
  unique (production_id, crew_code)
);
create index crew_user_idx on public.crew (user_id);

-- wrong production codes, to stop anyone guessing them
create table public.join_attempts (user_id uuid not null, at timestamptz not null default now());
create index join_attempts_idx on public.join_attempts (user_id, at);

-- ================================================================ schedule, invoices, Tally, activity

create table public.shoot_days (
  id            uuid primary key default gen_random_uuid(),
  production_id uuid not null references public.productions on delete cascade,
  day           date not null,
  status        text not null default 'planned' check (status in ('planned','shot','cancelled')),
  location      text,
  call_time     text not null default '08:00' check (call_time ~ '^[0-2][0-9]:[0-5][0-9]$'),
  wrap_time     text not null default '20:00' check (wrap_time ~ '^[0-2][0-9]:[0-5][0-9]$'),
  ep_from       int,
  ep_to         int,
  note          text,
  created_by    uuid references auth.users on delete set null,
  unique (production_id, day),
  check (ep_from is null or ep_to >= ep_from)
);

create table public.checkins (
  day_id     uuid not null references public.shoot_days on delete cascade,
  user_id    uuid not null references auth.users on delete cascade,
  at         timestamptz not null default now(),
  by         uuid references auth.users on delete set null,
  removed_at timestamptz,
  primary key (day_id, user_id)
);

create table public.crew_invoices (
  id            uuid primary key default gen_random_uuid(),
  production_id uuid not null references public.productions on delete cascade,
  crew_id       uuid not null references public.crew on delete cascade,
  user_id       uuid not null references auth.users on delete cascade,
  dept          text,
  no            text not null check (length(trim(no)) > 0),
  period_from   date not null,
  period_to     date not null,
  qty           numeric(8,2) not null check (qty > 0),
  rate          bigint not null,
  unit          text not null,
  descr         text,
  amount        bigint not null,
  gst_rate      numeric(4,2) not null default 0 check (gst_rate in (0, 5, 12, 18, 28)),
  gst           bigint not null default 0,
  tds_key       text not null,
  tds           bigint not null default 0,
  payable       bigint not null,
  status        text not null default 'submitted' check (status in ('submitted','hod_ok','approved','paid','rejected')),
  submitted_at  timestamptz not null default now(),
  hod_by        uuid references auth.users on delete set null,
  hod_at        timestamptz,
  approved_by   uuid references auth.users on delete set null,
  approved_at   timestamptz,
  paid_at       timestamptz,
  utr           text,
  reason        text,
  tally_purchase text,
  tally_payment  text,
  check (period_to >= period_from),
  unique (production_id, user_id, no)
);
create index crew_invoices_prod_idx on public.crew_invoices (production_id, status);

create table public.tally_exports (
  production_id uuid not null references public.productions on delete cascade,
  batch         text not null,
  at            timestamptz not null default now(),
  by            uuid references auth.users on delete set null,
  purchases     int not null,
  payments      int not null,
  value         bigint not null,
  primary key (production_id, batch)
);

create table public.activity (
  id            bigint generated always as identity primary key,
  production_id uuid references public.productions on delete cascade,   -- empty for company-wide changes
  at            timestamptz not null default clock_timestamp(),
  by            uuid references auth.users on delete set null,
  type          text not null,
  text          text not null,
  crew_id       uuid,
  invoice_id    uuid,
  field         text,
  before        jsonb,
  after         jsonb,
  reverted_at   timestamptz
);
create index activity_prod_idx on public.activity (production_id, at desc);

-- ================================================================ who is calling

create function public.admin_role(p_user uuid default auth.uid()) returns text
language sql stable security definer set search_path = public as $$ select role from company_admins where user_id = p_user $$;

-- the caller's role on a production: owners of the company have owner rights everywhere
create function public.prod_role(p uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select role from company_admins where user_id = auth.uid()),
                  (select role from crew where production_id = p and user_id = auth.uid() and active)) $$;
create function public.prod_member(p uuid) returns boolean language sql stable security definer set search_path = public as $$ select prod_role(p) is not null $$;
create function public.prod_owner(p uuid) returns boolean language sql stable security definer set search_path = public as $$ select coalesce(prod_role(p) in ('cfo','commercial'), false) $$;
create function public.prod_lead(p uuid) returns boolean language sql stable security definer set search_path = public as $$ select coalesce(prod_role(p) in ('cfo','commercial','hop','lp'), false) $$;
create function public.prod_staff(p uuid) returns boolean language sql stable security definer set search_path = public as $$ select coalesce(prod_role(p) not in ('crew','vendor'), false) $$;
create function public.prod_finance(p uuid) returns boolean language sql stable security definer set search_path = public as $$ select coalesce(prod_role(p) in ('cfo','commercial','accounts'), false) $$;
create function public.prod_audit(p uuid) returns boolean language sql stable security definer set search_path = public as $$ select coalesce(prod_role(p) in ('cfo','commercial','hop','lp','accounts'), false) $$;

-- names and photos: yourself, company owners, and people on a production where you are staff
create function public.person_visible(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    p_user = auth.uid()
    or exists (select 1 from company_admins where user_id = auth.uid())
    or exists (select 1 from company_admins where user_id = p_user)
    or exists (select 1 from crew me join crew them using (production_id)
               where me.user_id = auth.uid() and me.active and me.role not in ('crew','vendor') and them.user_id = p_user)) $$;
-- PAN, Aadhaar, address and bank: yourself, company owners, and Finance on a production you are both on
create function public.kyc_visible(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    p_user = auth.uid()
    or exists (select 1 from company_admins where user_id = auth.uid())
    or exists (select 1 from crew me join crew them using (production_id)
               where me.user_id = auth.uid() and me.active and me.role = 'accounts' and them.user_id = p_user)) $$;

create view public.people with (security_invoker = false) as
  select p.id, p.username, p.full_name, p.phone, p.email, p.photo_path,
         case when kyc_visible(p.id) then p.legal_name end    as legal_name,
         case when kyc_visible(p.id) then p.pan end           as pan,
         case when kyc_visible(p.id) then p.gstin end         as gstin,
         case when kyc_visible(p.id) then p.address end       as address,
         case when kyc_visible(p.id) then p.bank_holder end   as bank_holder,
         case when kyc_visible(p.id) then p.bank_name end     as bank_name,
         case when kyc_visible(p.id) then p.bank_account end  as bank_account,
         case when kyc_visible(p.id) then p.bank_ifsc end     as bank_ifsc,
         case when kyc_visible(p.id) then p.aadhaar_last4 end as aadhaar_last4,
         case when kyc_visible(p.id) then p.aadhaar_path end  as aadhaar_path,
         case when kyc_visible(p.id) then p.pan_path end      as pan_path,
         case when kyc_visible(p.id) then p.consent_at end    as consent_at,
         case when kyc_visible(p.id) then p.emergency end     as emergency,
         profile_ready(p) as profile_ready,
         docs_ready(p)    as docs_ready
  from profiles p
  where person_visible(p.id);

-- Uploaded files: your own folder; someone's photo if you can see them; their Aadhaar/PAN only with KYC access.
create function public.kyc_file_visible(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    split_part(p_name, '/', 1) = auth.uid()::text
    or exists (select 1 from profiles p where p.id::text = split_part(p_name, '/', 1) and (
         (p.photo_path = p_name and person_visible(p.id))
         or ((p.aadhaar_path = p_name or p.pan_path = p_name) and kyc_visible(p.id))))) $$;

create function public.pname(p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(full_name, ''), username, 'Someone') from profiles where id = p_user $$;
create function public.crew_name(c public.crew) returns text
language sql stable security definer set search_path = public as $$ select coalesce(pname(c.user_id), c.invite_name, 'Someone') $$;
create function public.today_ist() returns date language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

-- Runs with the caller's rights: works inside the functions below, refused if called directly.
create function public.add_log(p uuid, t text, txt text, c uuid default null, i uuid default null, f text default null, b jsonb default null, a jsonb default null) returns void
language sql set search_path = public as $$
  insert into activity (production_id, by, type, text, crew_id, invoice_id, field, before, after) values (p, auth.uid(), t, txt, c, i, f, b, a)
$$;

create function public.gen_code(p_name text) returns text
language plpgsql volatile set search_path = public as $$
declare a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
        pre text := rpad(left(regexp_replace(upper(coalesce(p_name, '')), '[^A-Z]', '', 'g'), 4), 4, 'X'); s text;
begin
  loop
    s := pre;
    for i in 1..4 loop s := s || substr(a, 1 + floor(random() * 32)::int, 1); end loop;
    exit when not exists (select 1 from productions where code = s);
  end loop;
  return s;
end $$;

-- ================================================================ company

create function public.company_info() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('legal', c.legal, 'brand', c.brand, 'type', c.entity_type, 'pan', c.pan, 'tan', c.tan, 'gstin', c.gstin, 'state', c.state,
           'cin', c.cin, 'address', c.address, 'signatory', c.signatory, 'designation', c.designation, 'email', c.email, 'phone', c.phone,
           'bank', case when admin_role() is not null or exists (select 1 from crew where user_id = auth.uid() and role = 'accounts' and active) then c.bank
                        else jsonb_build_object('name', c.bank ->> 'name', 'ifsc', c.bank ->> 'ifsc', 'acct', '••••' || right(c.bank ->> 'acct', 4)) end,
           'tally', c.tally, 'setupBy', c.setup_by, 'setupAt', c.setup_at)
  from companies c where auth.uid() is not null
$$;

create function public.setup_company(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare old jsonb; nw jsonb; changed text[];
begin
  perform must(admin_role() is not null, 'Only the CFO or Commercial Head can set up company details');
  select to_jsonb(c) - 'updated_at' - 'setup_at' - 'setup_by' into old from companies c;
  insert into companies (id, legal, brand, entity_type, pan, tan, gstin, state, cin, address, signatory, designation, email, phone, bank, tally, setup_by)
  values (true, trim(p ->> 'legal'), nullif(trim(p ->> 'brand'), ''), p ->> 'type', upper(trim(p ->> 'pan')), upper(trim(p ->> 'tan')),
          nullif(upper(trim(p ->> 'gstin')), ''), coalesce(nullif(substr(upper(trim(p ->> 'gstin')), 1, 2), ''), p ->> 'state'),
          nullif(upper(trim(p ->> 'cin')), ''), trim(p ->> 'address'), trim(p ->> 'signatory'), nullif(trim(p ->> 'designation'), ''),
          nullif(trim(p ->> 'email'), ''), nullif(trim(p ->> 'phone'), ''),
          jsonb_build_object('name', trim(p -> 'bank' ->> 'name'), 'acct', regexp_replace(coalesce(p -> 'bank' ->> 'acct', ''), '\s', '', 'g'), 'ifsc', upper(trim(p -> 'bank' ->> 'ifsc'))),
          coalesce(p -> 'tally', '{}'), auth.uid())
  on conflict (id) do update set legal = excluded.legal, brand = excluded.brand, entity_type = excluded.entity_type, pan = excluded.pan, tan = excluded.tan,
    gstin = excluded.gstin, state = excluded.state, cin = excluded.cin, address = excluded.address, signatory = excluded.signatory,
    designation = excluded.designation, email = excluded.email, phone = excluded.phone, bank = excluded.bank, tally = excluded.tally, updated_at = now();
  select to_jsonb(c) - 'updated_at' - 'setup_at' - 'setup_by' into nw from companies c;
  if old is null then perform add_log(null, 'company', 'Set up the company details');
  else
    select array_agg(k order by k) into changed from jsonb_object_keys(nw) k where old -> k is distinct from nw -> k;
    if changed is not null then perform add_log(null, 'company', 'Updated company details: ' || array_to_string(changed, ', ')); end if;
  end if;
  return company_info();
end $$;

create function public.add_admin(p_username text, p_role text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  perform must(admin_role() is not null, 'Only the CFO or Commercial Head can give owner access');
  perform must(p_role in ('cfo','commercial'), 'Owner access is for the CFO or the Commercial Head');
  select id into u from profiles where username = lower(trim(p_username));
  if u is null then raise exception 'No account with the username %', p_username; end if;
  insert into company_admins (user_id, role, added_by) values (u, p_role, auth.uid())
  on conflict (user_id) do update set role = excluded.role;
  perform add_log(null, 'company', 'Gave ' || pname(u) || ' owner access as ' || case p_role when 'cfo' then 'CFO' else 'Commercial Head' end);
end $$;

-- ================================================================ productions

create function public.create_production(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare pr productions;
begin
  perform must(admin_role() is not null, 'Only the CFO or Commercial Head can create a production');
  perform must(exists (select 1 from companies), 'Set up the company details first');
  insert into productions (name, format, platform, status, planned_eps, location, start_date, code, code_by, created_by)
  values (trim(p ->> 'name'), coalesce(nullif(p ->> 'format', ''), 'Long-format fiction · daily'), nullif(trim(p ->> 'platform'), ''),
          coalesce(nullif(p ->> 'status', ''), 'Pre-production'), greatest(1, coalesce((p ->> 'planned_eps')::int, 1)), nullif(trim(p ->> 'location'), ''),
          nullif(p ->> 'start_date', '')::date, gen_code(p ->> 'name'), auth.uid(), auth.uid())
  returning * into pr;
  perform add_log(pr.id, 'project', 'Created the production ' || pr.name || ' · production code ' || left(pr.code, 4) || '-' || right(pr.code, 4));
  return pr.id;
end $$;

create function public.new_production_code(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare old text; nw text;
begin
  perform must(prod_lead(p_id), 'Only the Line Producer, Head of Production, CFO or Commercial Head can change the code');
  select code into old from productions where id = p_id;
  nw := gen_code((select name from productions where id = p_id));
  update productions set code = nw, code_at = now(), code_by = auth.uid() where id = p_id;
  perform add_log(p_id, 'project', 'Generated a new production code ' || left(nw, 4) || '-' || right(nw, 4) || '; ' || left(old, 4) || '-' || right(old, 4) || ' no longer works');
  return nw;
end $$;

create function public.set_budgets(p_id uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform must(prod_owner(p_id) or prod_role(p_id) = 'accounts', 'Only the CFO, Commercial Head or Finance can set budgets');
  perform must(not exists (select 1 from jsonb_each(p) e where jsonb_typeof(e.value) <> 'number' or (case when jsonb_typeof(e.value) = 'number' then (e.value)::numeric end) < 0), 'Budgets must be amounts in rupees');
  update productions set budget = (select coalesce(jsonb_object_agg(key, value), '{}') from jsonb_each(p) where (value)::numeric > 0) where id = p_id;
  perform add_log(p_id, 'project', 'Updated the department budgets');
end $$;

-- Wrong codes are counted; ten in an hour locks joining for that account for the rest of the hour.
create function public.join_production(p_code text, p_kind text default 'crew') returns jsonb
language plpgsql security definer set search_path = public as $$
declare pr productions; c crew; me profiles; tries int; ph text;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'Sign in first'); end if;
  select count(*) into tries from join_attempts where user_id = auth.uid() and at > now() - interval '1 hour';
  if tries >= 10 then return jsonb_build_object('ok', false, 'error', 'Too many wrong codes. Try again in an hour, or ask your Line Producer for the code.'); end if;
  select * into pr from productions where code = upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  if pr.id is null then
    insert into join_attempts (user_id) values (auth.uid());
    return jsonb_build_object('ok', false, 'error', 'No production has that code. Check it with your Line Producer.');
  end if;
  if exists (select 1 from crew where production_id = pr.id and user_id = auth.uid()) then
    update crew set active = true where production_id = pr.id and user_id = auth.uid();
    return jsonb_build_object('ok', true, 'production_id', pr.id, 'name', pr.name, 'already', true);
  end if;
  select * into me from profiles where id = auth.uid();
  ph := right(regexp_replace(coalesce(me.phone, ''), '\D', '', 'g'), 10);
  -- an invite made for this person, matched on email or mobile number
  select * into c from crew where production_id = pr.id and user_id is null and (
      (me.email is not null and lower(invite_email) = lower(me.email))
      or (length(ph) = 10 and right(regexp_replace(coalesce(invite_phone, ''), '\D', '', 'g'), 10) = ph))
    order by joined_at limit 1;
  if c.id is not null then
    update crew set user_id = auth.uid(), joined_at = now() where id = c.id;
    perform add_log(pr.id, 'onboard', pname(auth.uid()) || ' joined with the production code and took up their invite', c.id);
  else
    insert into crew (production_id, user_id, role, kind, tds)
    values (pr.id, auth.uid(), case when p_kind = 'vendor' then 'vendor' else 'crew' end,
            case when p_kind in ('vendor','cast') then p_kind else 'crew' end, case when p_kind = 'vendor' then '194C-2' else '194C-1' end)
    returning * into c;
    perform add_log(pr.id, 'onboard', pname(auth.uid()) || ' joined with the production code', c.id);
  end if;
  return jsonb_build_object('ok', true, 'production_id', pr.id, 'name', pr.name);
end $$;

-- ================================================================ onboarding and deals

create function public.onboard(p_production uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare r text := coalesce(nullif(p ->> 'role', ''), 'crew'); c crew; existing uuid; em text := nullif(lower(trim(p ->> 'email')), '');
begin
  perform must(prod_lead(p_production), 'Only the Line Producer, Head of Production, CFO or Commercial Head can onboard people');
  if r in ('hop','lp','accounts') then perform must(prod_owner(p_production), 'Only the CFO or Commercial Head can give that access'); end if;
  perform must(length(trim(coalesce(p ->> 'name', ''))) > 1, 'Enter the person’s full name');
  perform must((p ->> 'rate')::bigint > 0, 'Enter the rate in rupees');
  perform must(nullif(p ->> 'joining', '') is not null, 'Pick a joining date');
  if em is not null then select id into existing from profiles where lower(email) = em; end if;
  if existing is not null and exists (select 1 from crew where production_id = p_production and user_id = existing) then
    raise exception 'That person is already on this production; edit their deal instead';
  end if;
  insert into crew (production_id, user_id, invite_name, invite_phone, invite_email, role, kind, dept, job, rate, unit, joining, end_date, tds, terms)
  values (p_production, existing, trim(p ->> 'name'), nullif(trim(p ->> 'phone'), ''), em, r,
          case when r = 'vendor' then 'vendor' else coalesce(nullif(p ->> 'kind', ''), 'crew') end,
          p ->> 'dept', p ->> 'job', (p ->> 'rate')::bigint, coalesce(nullif(p ->> 'unit', ''), 'day'), (p ->> 'joining')::date,
          nullif(p ->> 'end', '')::date, coalesce(nullif(p ->> 'tds', ''), '194C-1'), coalesce((p ->> 'terms')::int, 30))
  returning * into c;
  perform add_log(p_production, 'onboard', 'Invited ' || trim(p ->> 'name') || ' as ' || coalesce(c.job, '') || ', ' || coalesce(c.dept, '') || ' at ₹' || c.rate || ' ' || c.unit, c.id);
  return c.id;
end $$;

-- Owners set or change a deal; every changed field is logged with its old and new value so it can be undone.
create function public.set_deal(p_crew uuid, p jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare c crew; n crew; k text; changed int := 0;
begin
  select * into c from crew where id = p_crew;
  perform must(c.id is not null and prod_owner(c.production_id), 'Only the CFO or Commercial Head can change a deal');
  perform must(c.user_id is distinct from auth.uid() or coalesce(p ->> 'role', c.role) = c.role, 'You can’t change your own access');
  n := c;
  n.rate := coalesce((p ->> 'rate')::bigint, c.rate); n.unit := coalesce(nullif(p ->> 'unit', ''), c.unit);
  n.joining := coalesce(nullif(p ->> 'joining', '')::date, c.joining);
  n.end_date := case when p ? 'end' then nullif(p ->> 'end', '')::date else c.end_date end;
  n.tds := coalesce(nullif(p ->> 'tds', ''), c.tds); n.terms := coalesce((p ->> 'terms')::int, c.terms);
  n.dept := coalesce(nullif(p ->> 'dept', ''), c.dept); n.job := coalesce(nullif(p ->> 'job', ''), c.job); n.role := coalesce(nullif(p ->> 'role', ''), c.role);
  perform must(n.rate > 0, 'Enter the rate in rupees');
  if c.ag_status in ('signed','countersigned') and (n.rate is distinct from c.rate or n.unit is distinct from c.unit) then
    raise exception 'The fee is in a signed agreement. Agree the change in writing, then issue a new agreement';
  end if;
  update crew set rate = n.rate, unit = n.unit, joining = n.joining, end_date = n.end_date, tds = n.tds, terms = n.terms, dept = n.dept, job = n.job, role = n.role
   where id = p_crew;
  foreach k in array array['rate','unit','joining','end_date','tds','terms','dept','job','role'] loop
    if to_jsonb(c) -> k is distinct from to_jsonb(n) -> k then
      changed := changed + 1;
      perform add_log(c.production_id, 'deal', 'Changed ' || crew_name(c) || '’s ' || replace(k, '_', ' '), c.id, null, k, to_jsonb(c) -> k, to_jsonb(n) -> k);
    end if;
  end loop;
  -- a sent but unsigned agreement no longer matches the deal: withdraw it so it is re-sent with the new terms
  if changed > 0 and c.ag_status = 'sent' then
    update crew set ag_status = 'none', ag_text = null, ag_sent_at = null where id = p_crew;
    perform add_log(c.production_id, 'agreement', 'Withdrew ' || crew_name(c) || '’s unsigned agreement because the deal changed', c.id);
  end if;
  return changed;
end $$;

create function public.revert_change(p_log bigint) returns void
language plpgsql security definer set search_path = public as $$
declare l activity; c crew;
begin
  select * into l from activity where id = p_log;
  perform must(l.id is not null and l.type = 'deal' and prod_owner(l.production_id), 'Only the CFO or Commercial Head can undo a deal change');
  if l.reverted_at is not null then raise exception 'That change has already been undone'; end if;
  select * into c from crew where id = l.crew_id;
  if to_jsonb(c) -> l.field is distinct from l.after then raise exception 'This value has changed since; undo the later change first'; end if;
  perform set_deal(c.id, jsonb_build_object(case when l.field = 'end_date' then 'end' else l.field end, coalesce(l.before #>> '{}', '')));
  update activity set reverted_at = now() where id = p_log;
end $$;

create function public.remind(p_crew uuid) returns void
language plpgsql security definer set search_path = public as $$
declare c crew;
begin
  select * into c from crew where id = p_crew;
  perform must(c.id is not null and prod_lead(c.production_id), 'Only production leads can send reminders');
  perform add_log(c.production_id, 'onboard', 'Sent a reminder to ' || crew_name(c), c.id);
end $$;

-- ================================================================ profile and documents

create function public.save_profile(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare was boolean; v_pan text := upper(trim(p ->> 'pan')); v_g text := nullif(upper(trim(p ->> 'gstin')), '');
begin
  perform must(auth.uid() is not null, 'Sign in first');
  if v_g is not null then perform must(substr(v_g, 3, 10) = v_pan, 'Your GSTIN must contain your PAN (characters 3 to 12)'); end if;
  select profile_ready(x) into was from profiles x where id = auth.uid();
  update profiles set legal_name = trim(p ->> 'legal'), phone = nullif(trim(p ->> 'phone'), ''), emergency = nullif(trim(p ->> 'emergency'), ''),
    address = trim(p ->> 'address'), pan = v_pan, gstin = v_g, state_code = coalesce(substr(v_g, 1, 2), state_code),
    bank_holder = trim(p ->> 'bank_holder'), bank_name = nullif(trim(p ->> 'bank_name'), ''),
    bank_account = regexp_replace(coalesce(p ->> 'bank_account', ''), '\s', '', 'g'), bank_ifsc = upper(trim(p ->> 'bank_ifsc')),
    full_name = coalesce(nullif(trim(p ->> 'full_name'), ''), full_name)
  where id = auth.uid();
  perform add_log(c.production_id, 'profile', case when was then 'Updated profile and bank details' else 'Completed profile and bank details' end, c.id)
    from crew c where c.user_id = auth.uid();
end $$;

create function public.set_document(p_kind text, p_path text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform must(auth.uid() is not null, 'Sign in first');
  perform must(p_kind in ('photo','aadhaar','pan'), 'Unknown document');
  perform must(split_part(p_path, '/', 1) = auth.uid()::text, 'Files must be in your own folder');
  update profiles set photo_path = case when p_kind = 'photo' then p_path else photo_path end,
                      aadhaar_path = case when p_kind = 'aadhaar' then p_path else aadhaar_path end,
                      pan_path = case when p_kind = 'pan' then p_path else pan_path end
   where id = auth.uid();
  perform add_log(c.production_id, 'profile', case p_kind when 'photo' then 'Updated profile photo' when 'aadhaar' then 'Uploaded masked Aadhaar' else 'Uploaded PAN card' end, c.id)
    from crew c where c.user_id = auth.uid();
end $$;

create function public.save_documents(p_aadhaar4 text, p_consent boolean) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  select * into me from profiles where id = auth.uid();
  perform must(me.id is not null, 'Sign in first');
  perform must(me.aadhaar_path is not null, 'Upload a photo of your masked Aadhaar');
  perform must(me.pan_path is not null, 'Upload a photo of your PAN card');
  perform must(coalesce(p_aadhaar4, '') ~ '^[0-9]{4}$', 'Enter the last 4 digits of your Aadhaar');
  perform must(p_consent, 'Tick the consent box so the production can keep these copies');
  update profiles set aadhaar_last4 = p_aadhaar4, consent_at = coalesce(consent_at, now()) where id = auth.uid();
  perform add_log(c.production_id, 'docs', 'Confirmed masked Aadhaar and PAN card', c.id) from crew c where c.user_id = auth.uid();
end $$;

-- ================================================================ agreements

create function public.send_agreement(p_crew uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare c crew; pr profiles;
begin
  select * into c from crew where id = p_crew;
  perform must(c.id is not null and prod_lead(c.production_id), 'Only the Line Producer, Head of Production, CFO or Commercial Head can send agreements');
  perform must(c.user_id is not null, 'This person hasn’t joined yet');
  perform must(c.ag_status = 'none', 'An agreement has already been sent');
  perform must(c.rate is not null and c.joining is not null and c.dept is not null and c.job is not null, 'Set the deal first');
  select * into pr from profiles where id = c.user_id;
  perform must(profile_ready(pr), 'Their profile and bank details aren’t complete yet');
  perform must(docs_ready(pr), 'Their Aadhaar and PAN documents aren’t complete yet');
  perform must(length(coalesce(p_text, '')) between 200 and 60000, 'The agreement text is missing');
  update crew set ag_status = 'sent', ag_text = p_text, ag_sent_at = now() where id = p_crew;
  perform add_log(c.production_id, 'agreement', 'Sent the agreement to ' || crew_name(c), c.id);
end $$;

create function public.sign_agreement(p_crew uuid, p_name text, p_signature text) returns void
language plpgsql security definer set search_path = public as $$
declare c crew; pr profiles;
begin
  select * into c from crew where id = p_crew;
  perform must(c.id is not null and c.user_id = auth.uid(), 'Only the person named in the agreement can sign it');
  if c.ag_status <> 'sent' then raise exception 'This agreement isn’t waiting for your signature'; end if;
  select * into pr from profiles where id = auth.uid();
  perform must(profile_ready(pr) and docs_ready(pr), 'Complete your profile and documents before signing');
  perform must(length(trim(coalesce(p_name, ''))) >= 2, 'Type your full name to sign');
  perform must(coalesce(p_signature, '') ~ '^data:image/png;base64,', 'Draw your signature');
  update crew set ag_status = 'signed', ag_signed_at = now(), ag_signed_name = trim(p_name), ag_signature = p_signature,
         ag_hash = encode(sha256(convert_to(ag_text || '|' || trim(p_name) || '|' || p_signature, 'UTF8')), 'hex')
   where id = p_crew;
  perform add_log(c.production_id, 'agreement', crew_name(c) || ' signed the engagement agreement', c.id);
end $$;

create function public.countersign(p_crew uuid) returns void
language plpgsql security definer set search_path = public as $$
declare c crew;
begin
  select * into c from crew where id = p_crew;
  perform must(c.id is not null and prod_owner(c.production_id), 'Only the CFO or Commercial Head can approve agreements');
  if c.ag_status <> 'signed' then raise exception 'Only a signed agreement can be approved'; end if;
  update crew set ag_status = 'countersigned', ag_counter_at = now(), ag_counter_by = auth.uid() where id = p_crew;
  perform add_log(c.production_id, 'agreement', 'Approved ' || crew_name(c) || '’s agreement', c.id);
end $$;

-- ================================================================ schedule and gate check-in

create function public.plan_days(p_production uuid, p jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare d date := (p ->> 'from')::date; t date := (p ->> 'to')::date; per int := greatest(0, coalesce((p ->> 'eps_per_day')::int, 0));
        ep int := greatest(1, coalesce((p ->> 'start_ep')::int, 1)); n int := 0; ins int;
begin
  perform must(prod_lead(p_production), 'Only the Line Producer, Head of Production, CFO or Commercial Head can plan the schedule');
  perform must(d is not null and t is not null and t >= d, 'Check the dates: the block ends before it starts');
  perform must(t - d <= 120, 'Plan up to 120 days at a time');
  while d <= t loop
    if not (coalesce((p ->> 'skip_sundays')::boolean, true) and extract(dow from d) = 0) then
      insert into shoot_days (production_id, day, location, call_time, wrap_time, ep_from, ep_to, created_by)
      values (p_production, d, nullif(trim(p ->> 'location'), ''), coalesce(nullif(p ->> 'call', ''), '08:00'), coalesce(nullif(p ->> 'wrap', ''), '20:00'),
              case when per > 0 then ep end, case when per > 0 then ep + per - 1 end, auth.uid())
      on conflict (production_id, day) do nothing;
      get diagnostics ins = row_count;
      if ins > 0 then n := n + 1; if per > 0 then ep := ep + per; end if; end if;
    end if;
    d := d + 1;
  end loop;
  if n = 0 then raise exception 'Those dates are already on the schedule'; end if;
  perform add_log(p_production, 'schedule', 'Planned ' || n || ' shoot day' || case when n > 1 then 's' else '' end || ' from ' || to_char((p ->> 'from')::date, 'DD Mon') || ' to ' || to_char((p ->> 'to')::date, 'DD Mon YYYY'));
  return n;
end $$;

create function public.set_day_status(p_day uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare d shoot_days;
begin
  select * into d from shoot_days where id = p_day;
  perform must(d.id is not null and prod_lead(d.production_id), 'Only the Line Producer, Head of Production, CFO or Commercial Head can change the schedule');
  perform must(p_status in ('planned','shot','cancelled'), 'Unknown status');
  if p_status = 'shot' and d.day > today_ist() then raise exception 'A day can be marked shot only on or after its date'; end if;
  update shoot_days set status = p_status where id = p_day;
  perform add_log(d.production_id, 'schedule', 'Marked ' || to_char(d.day, 'DD Mon YYYY') || ' as ' || case p_status when 'planned' then 'scheduled' else p_status end);
end $$;

create function public.check_in(p_day uuid, p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare d shoot_days; c crew;
begin
  select * into d from shoot_days where id = p_day;
  perform must(d.id is not null and prod_lead(d.production_id), 'Only the Line Producer, Head of Production, CFO or Commercial Head can check crew in');
  if d.status = 'cancelled' then raise exception 'This day is cancelled'; end if;
  if d.day > today_ist() then raise exception 'Check-in opens on the day'; end if;
  select * into c from crew where production_id = d.production_id and crew_code = upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  if c.id is null or c.user_id is null then raise exception 'No one on this production has that Crew ID'; end if;
  if not c.active then raise exception '% is no longer active on this production', crew_name(c); end if;
  if c.ag_status <> 'countersigned' then raise exception '% isn’t fully onboarded yet', crew_name(c); end if;
  if exists (select 1 from checkins where day_id = p_day and user_id = c.user_id and removed_at is null) then raise exception '% is already checked in', crew_name(c); end if;
  insert into checkins (day_id, user_id, by) values (p_day, c.user_id, auth.uid())
  on conflict (day_id, user_id) do update set removed_at = null, at = now(), by = auth.uid();
  if d.status = 'planned' then update shoot_days set status = 'shot' where id = p_day; end if;
  perform add_log(d.production_id, 'schedule', 'Checked in ' || crew_name(c) || ' for ' || to_char(d.day, 'DD Mon YYYY'), c.id);
  return crew_name(c);
end $$;

create function public.remove_checkin(p_day uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d shoot_days;
begin
  select * into d from shoot_days where id = p_day;
  perform must(d.id is not null and prod_lead(d.production_id), 'Only production leads can change check-ins');
  update checkins set removed_at = now() where day_id = p_day and user_id = p_user and removed_at is null;
  if not found then raise exception 'That person isn’t checked in'; end if;
  perform add_log(d.production_id, 'schedule', 'Removed ' || pname(p_user) || '’s check-in for ' || to_char(d.day, 'DD Mon YYYY'));
end $$;

-- ================================================================ invoices and payments

create function public.submit_invoice(p_production uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare c crew; me profiles; amt bigint; g bigint; t bigint; gr numeric := coalesce((p ->> 'gst_rate')::numeric, 0); q numeric := (p ->> 'qty')::numeric; i crew_invoices;
        rates jsonb := '{"194C-1":1,"194C-2":2,"194J-10":10,"194J-2":2,"none":0}';
begin
  select * into c from crew where production_id = p_production and user_id = auth.uid() and active;
  perform must(c.id is not null, 'Join the production before invoicing it');
  perform must(c.ag_status = 'countersigned', 'You can raise invoices once your agreement is approved');
  perform must(c.rate is not null, 'Your deal isn’t set yet');
  select * into me from profiles where id = auth.uid();
  perform must(q > 0, 'Enter the quantity');
  if gr > 0 and me.gstin is null then raise exception 'Add your GSTIN to your profile to charge GST'; end if;
  amt := round(q * c.rate); g := round(amt * gr / 100); t := round(amt * (rates ->> c.tds)::numeric / 100);
  insert into crew_invoices (production_id, crew_id, user_id, dept, no, period_from, period_to, qty, rate, unit, descr, amount, gst_rate, gst, tds_key, tds, payable)
  values (p_production, c.id, auth.uid(), c.dept, trim(p ->> 'no'), (p ->> 'from')::date, (p ->> 'to')::date, q, c.rate, c.unit,
          coalesce(nullif(trim(p ->> 'desc'), ''), c.job || ', ' || to_char((p ->> 'from')::date, 'DD Mon') || ' to ' || to_char((p ->> 'to')::date, 'DD Mon YYYY')),
          amt, gr, g, c.tds, t, amt + g - t)
  returning * into i;
  perform add_log(p_production, 'invoice', 'Submitted invoice ' || i.no || ' for ₹' || (i.amount + i.gst), c.id, i.id);
  return i.id;
exception when unique_violation then
  raise exception 'You’ve already used invoice number % on this production', trim(p ->> 'no');
end $$;

create function public.hod_approve(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i crew_invoices; r text;
begin
  select * into i from crew_invoices where id = p_id;
  perform must(i.id is not null, 'No such invoice');
  r := prod_role(i.production_id);
  perform must(r in ('cfo','commercial','hop','lp') or (r = 'hod' and i.dept = (select dept from crew where production_id = i.production_id and user_id = auth.uid())),
               'Only the head of this department or the Line Producer can approve at this step');
  perform must(i.user_id <> auth.uid(), 'You can’t approve your own invoice');
  if i.status <> 'submitted' then raise exception 'This invoice has already moved on'; end if;
  update crew_invoices set status = 'hod_ok', hod_by = auth.uid(), hod_at = now() where id = p_id;
  perform add_log(i.production_id, 'invoice', 'HOD step approved ' || i.no || ' (' || pname(i.user_id) || ')', i.crew_id, i.id);
end $$;

create function public.final_approve(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i crew_invoices;
begin
  select * into i from crew_invoices where id = p_id;
  perform must(i.id is not null and prod_owner(i.production_id), 'Only the CFO or Commercial Head gives final approval');
  perform must(i.user_id <> auth.uid(), 'You can’t approve your own invoice');
  if i.status <> 'hod_ok' then raise exception 'This invoice is waiting for the HOD step first'; end if;
  update crew_invoices set status = 'approved', approved_by = auth.uid(), approved_at = now() where id = p_id;
  perform add_log(i.production_id, 'invoice', 'Approved ' || i.no || ' for payment', i.crew_id, i.id);
end $$;

create function public.reject_invoice(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare i crew_invoices; r text;
begin
  select * into i from crew_invoices where id = p_id;
  perform must(i.id is not null, 'No such invoice');
  r := prod_role(i.production_id);
  perform must(r in ('cfo','commercial','hop','lp') or (r = 'hod' and i.status = 'submitted' and i.dept = (select dept from crew where production_id = i.production_id and user_id = auth.uid())),
               'You can’t reject this invoice');
  perform must(i.user_id <> auth.uid(), 'You can’t reject your own invoice');
  if i.status not in ('submitted','hod_ok') then raise exception 'Only an invoice still in approval can be rejected'; end if;
  perform must(length(trim(coalesce(p_reason, ''))) >= 4, 'Say why, so they can fix it and resubmit');
  update crew_invoices set status = 'rejected', reason = trim(p_reason) where id = p_id;
  perform add_log(i.production_id, 'invoice', 'Rejected ' || i.no || ': ' || trim(p_reason), i.crew_id, i.id);
end $$;

create function public.pay_invoices(p_production uuid, p_ids uuid[], p_ref text) returns int
language plpgsql security definer set search_path = public as $$
declare n int; nos text; total bigint;
begin
  perform must(prod_finance(p_production), 'Only Finance, the CFO or the Commercial Head can record payments');
  perform must(length(trim(coalesce(p_ref, ''))) >= 6, 'Enter the bank reference (UTR or batch ID)');
  select count(*), string_agg(no, ', ' order by no), sum(payable) into n, nos, total
    from crew_invoices where id = any(p_ids) and production_id = p_production and status = 'approved';
  perform must(n > 0 and n = cardinality(p_ids), 'Pick approved invoices that haven’t been paid yet');
  update crew_invoices set status = 'paid', paid_at = now(), utr = trim(p_ref) where id = any(p_ids);
  perform add_log(p_production, 'payment', case when n = 1 then 'Marked ' || nos || ' paid · UTR ' || trim(p_ref) else 'Paid ' || nos || ' in one run · ₹' || total || ' · ref ' || trim(p_ref) end,
                  null, case when n = 1 then p_ids[1] end);
  return n;
end $$;

create function public.tally_mark(p_production uuid) returns text
language plpgsql security definer set search_path = public as $$
declare b text; np int; nq int; v bigint;
begin
  perform must(prod_finance(p_production), 'Only Finance, the CFO or the Commercial Head can send vouchers to Tally');
  b := 'TX-' || lpad(((select count(*) from tally_exports where production_id = p_production) + 1)::text, 3, '0');
  select count(*), coalesce(sum(amount + gst), 0) into np, v from crew_invoices where production_id = p_production and status in ('approved','paid') and tally_purchase is null;
  select count(*) into nq from crew_invoices where production_id = p_production and status = 'paid' and tally_payment is null;
  if np + nq = 0 then raise exception 'Nothing new to send to Tally'; end if;
  update crew_invoices set tally_purchase = b where production_id = p_production and status in ('approved','paid') and tally_purchase is null;
  update crew_invoices set tally_payment = b where production_id = p_production and status = 'paid' and tally_payment is null;
  insert into tally_exports (production_id, batch, by, purchases, payments, value) values (p_production, b, auth.uid(), np, nq, v);
  perform add_log(p_production, 'finance', 'Sent ' || np || ' purchase and ' || nq || ' payment vouchers to Tally (' || b || ')');
  return b;
end $$;

-- ================================================================ read access

alter table public.companies      enable row level security;
alter table public.company_admins enable row level security;
alter table public.productions    enable row level security;
alter table public.crew           enable row level security;
alter table public.join_attempts  enable row level security;
alter table public.shoot_days     enable row level security;
alter table public.checkins       enable row level security;
alter table public.crew_invoices  enable row level security;
alter table public.tally_exports  enable row level security;
alter table public.activity       enable row level security;

-- companies is read through company_info(), which hides the bank account from people who don't need it
create policy "signed-in see owners" on public.company_admins for select using (auth.uid() is not null);
create policy "members see production" on public.productions for select using (prod_member(id));
create policy "own row or staff" on public.crew for select using (user_id = auth.uid() or prod_staff(production_id));
create policy "members see schedule" on public.shoot_days for select using (prod_member(production_id));
create policy "own or staff" on public.checkins for select
  using (user_id = auth.uid() or exists (select 1 from shoot_days d where d.id = day_id and prod_staff(d.production_id)));
create policy "own, leads and finance, or HOD's department" on public.crew_invoices for select using (
  user_id = auth.uid() or prod_role(production_id) in ('cfo','commercial','hop','lp','accounts')
  or (prod_role(production_id) = 'hod' and dept = (select c.dept from crew c where c.production_id = crew_invoices.production_id and c.user_id = auth.uid())));
create policy "finance" on public.tally_exports for select using (prod_finance(production_id));
create policy "auditors" on public.activity for select
  using ((production_id is not null and prod_audit(production_id)) or (production_id is null and admin_role() is not null));
-- No insert, update or delete policies: row-level security refuses every direct write.

-- ================================================================ first owner

-- The Commercial Head who created this project is the first owner, so nobody else can claim the company.
insert into public.company_admins (user_id, role, added_by)
select id, 'commercial', id from auth.users where lower(email) = 'fowzan@swastikstories.com'
on conflict (user_id) do nothing;
