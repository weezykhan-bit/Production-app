-- CrewDesk: production management for film, TV, ads and web productions.
-- Runs on Supabase (Postgres 15+) and, unchanged, in the browser demo (PGlite).
--
-- Model: a project (production) has members. Each person keeps ONE profile (KYC, bank)
-- reused across every project they join. Writes go through the functions below;
-- row-level security decides who can read what.

-- ================================================================ helpers

create function public.gstin_valid(g text) returns boolean
language plpgsql immutable as $$
declare cs text := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'; t int := 0; p int;
begin
  if g is null then return true; end if;
  if g !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$' then return false; end if;
  for i in 1..14 loop
    p := (strpos(cs, substr(g, i, 1)) - 1) * (case when i % 2 = 0 then 2 else 1 end);
    t := t + p / 36 + p % 36;
  end loop;
  return substr(cs, ((36 - t % 36) % 36) + 1, 1) = substr(g, 15, 1);
end $$;

create function public.inr(n numeric) returns text
language sql immutable as $$ select '₹' || to_char(round(n), 'FM9,99,99,99,99,999') $$;

create function public.render_template(body text, fields jsonb) returns text
language plpgsql immutable as $$
declare k text; v text; out text := body;
begin
  for k, v in select key, value from jsonb_each_text(fields) loop
    out := replace(out, '{{' || k || '}}', coalesce(v, ''));
  end loop;
  return out;
end $$;

-- ================================================================ people

create table public.profiles (
  id            uuid primary key references auth.users on delete cascade,
  username      text unique check (username ~ '^[a-z0-9_.]{3,30}$'),
  email         text,
  full_name     text,
  phone         text,
  legal_name    text,                -- name on contracts and invoices (person or company)
  pan           text check (pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  gstin         text check (gstin_valid(gstin)),
  address       text,
  state_code    text check (state_code ~ '^[0-9]{2}$'),
  bank_holder   text,
  bank_name     text,
  bank_account  text check (bank_account ~ '^[0-9]{6,20}$'),
  bank_ifsc     text check (bank_ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$'),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create function public.kyc_missing(p public.profiles) returns text[]
language sql immutable as $$
  select array_remove(array[
    case when coalesce(trim(p.legal_name), '') = '' then 'legal name' end,
    case when p.pan is null then 'PAN' end,
    case when coalesce(trim(p.address), '') = '' then 'address' end,
    case when p.bank_account is null then 'bank account' end,
    case when p.bank_ifsc is null then 'IFSC' end,
    case when coalesce(trim(p.bank_holder), '') = '' then 'account holder' end
  ], null)
$$;

create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare u text := nullif(lower(coalesce(new.raw_user_meta_data ->> 'username', '')), '');
begin
  -- a taken or malformed username must not block sign-up; the person picks another in their profile
  if u is not null and (u !~ '^[a-z0-9_.]{3,30}$' or exists (select 1 from public.profiles where username = u)) then u := null; end if;
  insert into public.profiles (id, email, username, full_name)
  values (new.id, new.email, u, nullif(new.raw_user_meta_data ->> 'full_name', ''))
  on conflict do nothing;
  return new;
end $$;

-- lets the sign-up form say "taken" before the account is created
create function public.username_available(p_username text) returns boolean
language sql stable security definer set search_path = public as $$
  select lower(trim(p_username)) ~ '^[a-z0-9_.]{3,30}$' and not exists (select 1 from profiles where username = lower(trim(p_username)))
$$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Username sign-in: the app swaps a username for the account email, then signs in with the password.
create function public.login_email(p_login text) returns text
language sql stable security definer set search_path = public as $$
  select case when position('@' in p_login) > 0 then lower(trim(p_login))
              else (select email from profiles where username = lower(trim(p_login))) end
$$;

-- ================================================================ projects and members

create type public.member_role as enum ('producer','manager','accounts','hod','crew','vendor');

create table public.projects (
  id                   uuid primary key default gen_random_uuid(),
  name                 text not null check (length(trim(name)) > 0),
  kind                 text not null default 'film' check (kind in ('film','series','web','ad','documentary','music','other')),
  company_name         text not null,
  company_gstin        text check (gstin_valid(company_gstin)),
  company_address      text,
  company_state_code   text check (company_state_code ~ '^[0-9]{2}$'),
  start_date           date,
  end_date             date,
  departments          text[] not null default '{Direction,Production,Camera,Lighting,Art,Costume,Makeup & Hair,Sound,Editing,Cast,Transport,Catering}',
  default_tds_rate     numeric(4,2) not null default 2 check (default_tds_rate between 0 and 30),
  tally                jsonb not null default '{"expense_ledger":"Production Expenses","input_cgst":"Input CGST","input_sgst":"Input SGST","input_igst":"Input IGST","tds_ledger":"TDS Payable","creditors_group":"Sundry Creditors","bank_ledger":"Bank Account","voucher_type":"Purchase"}',
  invite_code          text not null unique default upper(substr(md5(gen_random_uuid()::text), 1, 8)),
  created_by           uuid references auth.users on delete set null,
  created_at           timestamptz not null default now()
);

create table public.members (
  project_id   uuid not null references public.projects on delete cascade,
  user_id      uuid not null references auth.users on delete cascade,
  role         public.member_role not null default 'crew',
  department   text,
  designation  text,
  rate         bigint check (rate >= 0),
  rate_unit    text not null default 'day' check (rate_unit in ('day','week','month','lump')),
  start_date   date,
  end_date     date,
  active       boolean not null default true,
  rating       smallint check (rating between 1 and 5),
  joined_at    timestamptz not null default now(),
  card_code    text not null default upper(substr(md5(gen_random_uuid()::text), 1, 8)),   -- printed on the ID card / QR
  primary key (project_id, user_id),
  unique (project_id, card_code)
);
create index members_user_idx on public.members (user_id);

create function public.my_role(p_project uuid) returns public.member_role
language sql stable security definer set search_path = public as $$
  select role from members where project_id = p_project and user_id = auth.uid() and active
$$;
create function public.is_member(p_project uuid) returns boolean
language sql stable security definer set search_path = public as $$ select my_role(p_project) is not null $$;
create function public.can_manage(p_project uuid) returns boolean
language sql stable security definer set search_path = public as $$ select coalesce(my_role(p_project) in ('producer','manager'), false) $$;
create function public.can_pay(p_project uuid) returns boolean
language sql stable security definer set search_path = public as $$ select coalesce(my_role(p_project) in ('producer','manager','accounts'), false) $$;
create function public.must(ok boolean, msg text) returns void
language plpgsql as $$ begin if not coalesce(ok, false) then raise exception '%', msg using errcode = '42501'; end if; end $$;

-- people who share a project with me (so I can see their name), or anyone if I manage them
create function public.shares_project(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members a join members b using (project_id)
                 where a.user_id = auth.uid() and b.user_id = p_user and a.active)
$$;
-- bank/KYC detail is visible to the person and to producers/managers/accounts of their projects
create function public.can_see_kyc(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_user = auth.uid() or exists (
    select 1 from members a join members b using (project_id)
    where a.user_id = auth.uid() and a.active and a.role in ('producer','manager','accounts') and b.user_id = p_user)
$$;

create view public.directory with (security_invoker = false) as
  select p.id, p.username, p.full_name, p.legal_name, p.phone, p.email,
         case when can_see_kyc(p.id) then p.pan end           as pan,
         case when can_see_kyc(p.id) then p.gstin end         as gstin,
         case when can_see_kyc(p.id) then p.address end       as address,
         case when can_see_kyc(p.id) then p.state_code end    as state_code,
         case when can_see_kyc(p.id) then p.bank_holder end   as bank_holder,
         case when can_see_kyc(p.id) then p.bank_name end     as bank_name,
         case when can_see_kyc(p.id) then p.bank_account end  as bank_account,
         case when can_see_kyc(p.id) then p.bank_ifsc end     as bank_ifsc,
         kyc_missing(p) as kyc_missing
  from profiles p
  where p.id = auth.uid() or shares_project(p.id);

create function public.create_project(
  p_name text, p_kind text, p_company text, p_company_gstin text, p_company_address text,
  p_start date, p_end date
) returns public.projects
language plpgsql security definer set search_path = public as $$
declare pr projects;
begin
  perform must(auth.uid() is not null, 'Sign in first');
  insert into projects (name, kind, company_name, company_gstin, company_address, company_state_code, start_date, end_date, created_by)
  values (trim(p_name), coalesce(p_kind, 'film'), trim(p_company), nullif(upper(trim(p_company_gstin)), ''),
          nullif(trim(p_company_address), ''), nullif(substr(upper(trim(p_company_gstin)), 1, 2), ''), p_start, p_end, auth.uid())
  returning * into pr;
  insert into members (project_id, user_id, role, department, designation)
  values (pr.id, auth.uid(), 'producer', 'Production', 'Producer');
  return pr;
end $$;

create function public.update_project(p_id uuid, p_patch jsonb) returns public.projects
language plpgsql security definer set search_path = public as $$
declare pr projects;
begin
  perform must(my_role(p_id) = 'producer', 'Only the producer can change project settings');
  update projects set
    name             = coalesce(p_patch ->> 'name', name),
    kind             = coalesce(p_patch ->> 'kind', kind),
    company_name     = coalesce(p_patch ->> 'company_name', company_name),
    company_gstin    = case when p_patch ? 'company_gstin' then nullif(upper(trim(p_patch ->> 'company_gstin')), '') else company_gstin end,
    company_address  = coalesce(p_patch ->> 'company_address', company_address),
    company_state_code = case when p_patch ? 'company_gstin' then nullif(substr(upper(trim(p_patch ->> 'company_gstin')), 1, 2), '') else company_state_code end,
    start_date       = coalesce((p_patch ->> 'start_date')::date, start_date),
    end_date         = coalesce((p_patch ->> 'end_date')::date, end_date),
    departments      = coalesce((select array_agg(x) from jsonb_array_elements_text(p_patch -> 'departments') x), departments),
    default_tds_rate = coalesce((p_patch ->> 'default_tds_rate')::numeric, default_tds_rate),
    tally            = case when p_patch ? 'tally' then tally || (p_patch -> 'tally') else tally end
  where id = p_id returning * into pr;
  return pr;
end $$;

create function public.join_project(p_code text, p_as_vendor boolean default false) returns public.projects
language plpgsql security definer set search_path = public as $$
declare pr projects;
begin
  perform must(auth.uid() is not null, 'Sign in first');
  select * into pr from projects where invite_code = upper(trim(p_code));
  if pr.id is null then raise exception 'No project with that invite code'; end if;
  insert into members (project_id, user_id, role)
  values (pr.id, auth.uid(), case when p_as_vendor then 'vendor'::member_role else 'crew'::member_role end)
  on conflict (project_id, user_id) do update set active = true;
  return pr;
end $$;

create function public.update_member(p_project uuid, p_user uuid, p_patch jsonb) returns public.members
language plpgsql security definer set search_path = public as $$
declare m members; new_role member_role := (p_patch ->> 'role')::member_role;
begin
  perform must(can_manage(p_project), 'Only the producer or production manager can edit crew');
  if new_role is not null and new_role in ('producer','manager','accounts') then
    perform must(my_role(p_project) = 'producer', 'Only the producer can give producer, manager or accounts access');
  end if;
  if p_user = auth.uid() and new_role is not null and new_role <> 'producer' and my_role(p_project) = 'producer'
     and (select count(*) from members where project_id = p_project and role = 'producer' and active) = 1 then
    raise exception 'A project needs at least one producer';
  end if;
  update members set
    role        = coalesce(new_role, role),
    department  = coalesce(p_patch ->> 'department', department),
    designation = coalesce(p_patch ->> 'designation', designation),
    rate        = coalesce((p_patch ->> 'rate')::bigint, rate),
    rate_unit   = coalesce(p_patch ->> 'rate_unit', rate_unit),
    start_date  = coalesce((p_patch ->> 'start_date')::date, start_date),
    end_date    = coalesce((p_patch ->> 'end_date')::date, end_date),
    active      = coalesce((p_patch ->> 'active')::boolean, active),
    rating      = coalesce((p_patch ->> 'rating')::smallint, rating)
  where project_id = p_project and user_id = p_user returning * into m;
  if m.user_id is null then raise exception 'Not a member of this project'; end if;
  return m;
end $$;

-- ================================================================ contracts

create table public.contract_templates (
  id          uuid primary key default gen_random_uuid(),
  project_id  uuid references public.projects on delete cascade,   -- null = built-in, available to all
  name        text not null,
  body        text not null,
  created_by  uuid references auth.users on delete set null,
  created_at  timestamptz not null default now()
);

create type public.contract_status as enum ('draft','sent','signed','countersigned','void');

create table public.contracts (
  id               uuid primary key default gen_random_uuid(),
  ref              text not null unique default 'CTR-' || upper(substr(md5(gen_random_uuid()::text), 1, 6)),
  project_id       uuid not null references public.projects on delete cascade,
  user_id          uuid not null references auth.users on delete cascade,
  template_name    text not null,
  body             text not null,            -- template text at creation; later template edits don't change it
  fields           jsonb not null default '{}',
  status           public.contract_status not null default 'draft',
  sent_at          timestamptz,
  signed_at        timestamptz,
  signed_name      text,
  signature        text check (signature is null or length(signature) < 200000),   -- drawn signature, PNG data URL
  signed_text      text,
  signed_hash      text,
  countersigned_at timestamptz,
  countersigned_by uuid references auth.users on delete set null,
  created_by       uuid references auth.users on delete set null,
  created_at       timestamptz not null default now()
);
create index contracts_project_idx on public.contracts (project_id);

create table public.contract_events (
  id           bigint generated always as identity primary key,
  contract_id  uuid not null references public.contracts on delete cascade,
  at           timestamptz not null default now(),
  actor        uuid references auth.users on delete set null,
  action       text not null
);

-- Runs with the caller's rights: inside create_contract that is the owner; called directly by a user,
-- row-level security limits it to what they can already see.
create function public.contract_fields(p_project uuid, p_user uuid) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'date',             to_char(now(), 'DD Mon YYYY'),
    'project',          pr.name,
    'company_name',     pr.company_name,
    'company_gstin',    coalesce(pr.company_gstin, '—'),
    'company_address',  coalesce(pr.company_address, '—'),
    'name',             coalesce(nullif(p.legal_name, ''), p.full_name, ''),
    'pan',              coalesce(p.pan, ''),
    'gstin',            coalesce(p.gstin, 'Not registered'),
    'address',          coalesce(p.address, ''),
    'phone',            coalesce(p.phone, ''),
    'email',            coalesce(p.email, ''),
    'department',       coalesce(m.department, ''),
    'designation',      coalesce(m.designation, ''),
    'rate',             case when m.rate is null then '' else inr(m.rate) end,
    'rate_unit',        case m.rate_unit when 'day' then 'per day' when 'week' then 'per week' when 'month' then 'per month' else 'lump sum' end,
    'start_date',       coalesce(to_char(coalesce(m.start_date, pr.start_date), 'DD Mon YYYY'), 'TBC'),
    'end_date',         coalesce(to_char(coalesce(m.end_date, pr.end_date), 'DD Mon YYYY'), 'TBC'),
    'bank',             coalesce(p.bank_holder || ', ' || p.bank_name || ', A/c ' || p.bank_account || ', IFSC ' || p.bank_ifsc, ''))
  from projects pr join members m on m.project_id = pr.id join profiles p on p.id = m.user_id
  where pr.id = p_project and m.user_id = p_user
$$;

-- Caller's rights: works inside the contract actions; a direct call is refused by row-level security.
create function public.log_contract(p_id uuid, p_action text) returns void
language sql set search_path = public as $$
  insert into contract_events (contract_id, actor, action) values (p_id, auth.uid(), p_action)
$$;

create function public.create_contract(p_project uuid, p_user uuid, p_template uuid) returns public.contracts
language plpgsql security definer set search_path = public as $$
declare t contract_templates; c contracts;
begin
  perform must(can_manage(p_project), 'Only the producer or production manager can issue contracts');
  select * into t from contract_templates where id = p_template and (project_id is null or project_id = p_project);
  if t.id is null then raise exception 'Unknown template'; end if;
  if not exists (select 1 from members where project_id = p_project and user_id = p_user) then raise exception 'Not a member of this project'; end if;
  insert into contracts (project_id, user_id, template_name, body, fields, created_by)
  values (p_project, p_user, t.name, t.body, contract_fields(p_project, p_user), auth.uid())
  returning * into c;
  perform log_contract(c.id, 'created');
  return c;
end $$;

create function public.edit_contract(p_id uuid, p_fields jsonb) returns public.contracts
language plpgsql security definer set search_path = public as $$
declare c contracts;
begin
  select * into c from contracts where id = p_id;
  perform must(can_manage(c.project_id), 'Only the producer or production manager can edit contracts');
  if c.status not in ('draft','sent') then raise exception 'A signed contract can''t be edited; void it and issue a new one'; end if;
  update contracts set fields = fields || p_fields where id = p_id returning * into c;
  perform log_contract(c.id, 'edited');
  return c;
end $$;

create function public.send_contract(p_id uuid) returns public.contracts
language plpgsql security definer set search_path = public as $$
declare c contracts;
begin
  select * into c from contracts where id = p_id;
  perform must(can_manage(c.project_id), 'Only the producer or production manager can send contracts');
  update contracts set status = 'sent', sent_at = now() where id = p_id and status = 'draft' returning * into c;
  if c.id is null then raise exception 'Only a draft can be sent'; end if;
  perform log_contract(c.id, 'sent');
  return c;
end $$;

-- The signer's own profile is re-read at signing so the contract carries their latest KYC.
create function public.sign_contract(p_id uuid, p_name text, p_signature text) returns public.contracts
language plpgsql security definer set search_path = public as $$
declare c contracts; p profiles; missing text[]; txt text;
begin
  select * into c from contracts where id = p_id;
  perform must(c.user_id = auth.uid(), 'Only the person named in the contract can sign it');
  if c.status <> 'sent' then raise exception 'This contract isn''t waiting for your signature'; end if;
  select * into p from profiles where id = auth.uid();
  missing := kyc_missing(p);
  if array_length(missing, 1) > 0 then raise exception 'Complete your profile before signing: %', array_to_string(missing, ', '); end if;
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Type your full name to sign'; end if;
  if p_signature is null or p_signature !~ '^data:image/png;base64,' then raise exception 'Draw your signature'; end if;
  c.fields := c.fields || jsonb_build_object(
    'name', p.legal_name, 'pan', p.pan, 'gstin', coalesce(p.gstin, 'Not registered'), 'address', p.address,
    'bank', p.bank_holder || ', ' || coalesce(p.bank_name, '') || ', A/c ' || p.bank_account || ', IFSC ' || p.bank_ifsc);
  txt := render_template(c.body, c.fields);
  update contracts set fields = c.fields, status = 'signed', signed_at = now(), signed_name = trim(p_name),
         signature = p_signature, signed_text = txt,
         signed_hash = encode(sha256(convert_to(txt || '|' || trim(p_name) || '|' || p_signature, 'UTF8')), 'hex')
   where id = p_id returning * into c;
  perform log_contract(c.id, 'signed by ' || trim(p_name));
  return c;
end $$;

create function public.countersign_contract(p_id uuid) returns public.contracts
language plpgsql security definer set search_path = public as $$
declare c contracts;
begin
  select * into c from contracts where id = p_id;
  perform must(my_role(c.project_id) = 'producer', 'Only the producer can countersign');
  update contracts set status = 'countersigned', countersigned_at = now(), countersigned_by = auth.uid()
   where id = p_id and status = 'signed' returning * into c;
  if c.id is null then raise exception 'Only a signed contract can be countersigned'; end if;
  perform log_contract(c.id, 'countersigned');
  return c;
end $$;

create function public.void_contract(p_id uuid) returns public.contracts
language plpgsql security definer set search_path = public as $$
declare c contracts;
begin
  select * into c from contracts where id = p_id;
  perform must(can_manage(c.project_id), 'Only the producer or production manager can void contracts');
  update contracts set status = 'void' where id = p_id and status <> 'void' returning * into c;
  perform log_contract(c.id, 'voided');
  return c;
end $$;

create function public.save_template(p_project uuid, p_name text, p_body text) returns public.contract_templates
language plpgsql security definer set search_path = public as $$
declare t contract_templates;
begin
  perform must(can_manage(p_project), 'Only the producer or production manager can add templates');
  insert into contract_templates (project_id, name, body, created_by) values (p_project, trim(p_name), p_body, auth.uid()) returning * into t;
  return t;
end $$;

-- ================================================================ invoices and payments

create type public.invoice_status as enum ('submitted','hod_approved','approved','rejected','paid');

create table public.invoices (
  id            uuid primary key default gen_random_uuid(),
  ref           text not null unique default 'INV-' || upper(substr(md5(gen_random_uuid()::text), 1, 6)),
  project_id    uuid not null references public.projects on delete cascade,
  submitted_by  uuid not null references auth.users on delete cascade,
  invoice_no    text not null,
  invoice_date  date not null,
  period_from   date,
  period_to     date,
  department    text,
  description   text not null check (length(trim(description)) > 0),
  quantity      numeric(8,2) not null default 1 check (quantity > 0),
  rate          bigint not null check (rate > 0),
  amount        bigint not null,
  gst_rate      numeric(4,2) not null default 0 check (gst_rate in (0, 5, 12, 18, 28)),
  gst           bigint not null default 0,
  total         bigint not null,
  tds_rate      numeric(4,2) not null default 0,
  tds           bigint not null default 0,
  payable       bigint not null,
  vendor        jsonb not null,          -- KYC snapshot at submission: name, PAN, GSTIN, address, bank
  status        public.invoice_status not null default 'submitted',
  hod_by        uuid references auth.users on delete set null,
  hod_at        timestamptz,
  approved_by   uuid references auth.users on delete set null,
  approved_at   timestamptz,
  rejected_by   uuid references auth.users on delete set null,
  rejected_at   timestamptz,
  reject_reason text,
  batch_id      uuid,
  paid_at       timestamptz,
  payment_ref   text,
  created_at    timestamptz not null default now(),
  unique (project_id, submitted_by, invoice_no)
);
create index invoices_project_idx on public.invoices (project_id, status);

create table public.payment_batches (
  id          uuid primary key default gen_random_uuid(),
  ref         text not null unique default 'PAY-' || upper(substr(md5(gen_random_uuid()::text), 1, 6)),
  project_id  uuid not null references public.projects on delete cascade,
  created_by  uuid references auth.users on delete set null,
  created_at  timestamptz not null default now(),
  invoices    int not null,
  amount      bigint not null,
  paid_at     timestamptz,
  payment_ref text
);
alter table public.invoices add foreign key (batch_id) references public.payment_batches on delete set null;

create function public.submit_invoice(
  p_project uuid, p_invoice_no text, p_date date, p_from date, p_to date,
  p_description text, p_quantity numeric, p_rate bigint, p_gst_rate numeric
) returns public.invoices
language plpgsql security definer set search_path = public as $$
declare p profiles; m members; pr projects; inv invoices; amt bigint; g bigint; missing text[];
begin
  select * into m from members where project_id = p_project and user_id = auth.uid() and active;
  perform must(m.user_id is not null, 'Join the project before invoicing it');
  select * into p from profiles where id = auth.uid();
  select * into pr from projects where id = p_project;
  missing := kyc_missing(p);
  if array_length(missing, 1) > 0 then raise exception 'Complete your profile before invoicing: %', array_to_string(missing, ', '); end if;
  if coalesce(p_gst_rate, 0) > 0 and p.gstin is null then raise exception 'Add your GSTIN to charge GST'; end if;
  if p_from is not null and p_to is not null and p_to < p_from then raise exception 'Period ends before it starts'; end if;
  amt := round(p_quantity * p_rate);
  g := round(amt * coalesce(p_gst_rate, 0) / 100);
  insert into invoices (project_id, submitted_by, invoice_no, invoice_date, period_from, period_to, department, description,
                        quantity, rate, amount, gst_rate, gst, total, tds_rate, tds, payable, vendor)
  values (p_project, auth.uid(), trim(p_invoice_no), p_date, p_from, p_to, m.department, trim(p_description),
          p_quantity, p_rate, amt, coalesce(p_gst_rate, 0), g, amt + g, 0, 0, amt + g,
          jsonb_build_object('name', p.legal_name, 'pan', p.pan, 'gstin', p.gstin, 'address', p.address, 'state_code',
                             coalesce(p.state_code, substr(p.gstin, 1, 2)), 'phone', p.phone, 'email', p.email,
                             'bank_holder', p.bank_holder, 'bank_name', p.bank_name, 'bank_account', p.bank_account, 'bank_ifsc', p.bank_ifsc,
                             'designation', m.designation))
  returning * into inv;
  return inv;
exception when unique_violation then
  raise exception 'You already used invoice number % on this project', trim(p_invoice_no);
end $$;

-- HOD approves invoices from their own department; producer/manager may approve at this step too.
create function public.hod_approve_invoice(p_id uuid) returns public.invoices
language plpgsql security definer set search_path = public as $$
declare inv invoices; me members;
begin
  select * into inv from invoices where id = p_id;
  select * into me from members where project_id = inv.project_id and user_id = auth.uid() and active;
  perform must(me.role in ('producer','manager') or (me.role = 'hod' and me.department = inv.department),
               'Only the head of this department can approve at this step');
  perform must(inv.submitted_by <> auth.uid() or me.role = 'producer', 'You can''t approve your own invoice');
  update invoices set status = 'hod_approved', hod_by = auth.uid(), hod_at = now()
   where id = p_id and status = 'submitted' returning * into inv;
  if inv.id is null then raise exception 'Only a newly submitted invoice can be approved here'; end if;
  return inv;
end $$;

-- Accounts sets TDS and gives final approval. Skipping the HOD step is allowed for producer/manager.
create function public.approve_invoice(p_id uuid, p_tds_rate numeric default null) returns public.invoices
language plpgsql security definer set search_path = public as $$
declare inv invoices; r numeric; t bigint; v_role member_role;
begin
  select * into inv from invoices where id = p_id;
  v_role := my_role(inv.project_id);
  perform must(v_role in ('producer','manager','accounts'), 'Only accounts, the producer or the production manager can approve payment');
  perform must(inv.submitted_by <> auth.uid() or v_role = 'producer', 'You can''t approve your own invoice');
  if inv.status = 'submitted' and v_role = 'accounts' then raise exception 'Waiting for the head of department first'; end if;
  r := coalesce(p_tds_rate, (select default_tds_rate from projects where id = inv.project_id));
  if r < 0 or r > 30 then raise exception 'TDS rate must be between 0 and 30%%'; end if;
  t := round(inv.amount * r / 100);               -- TDS is on the amount before GST
  update invoices set status = 'approved', approved_by = auth.uid(), approved_at = now(),
         tds_rate = r, tds = t, payable = total - t
   where id = p_id and status in ('submitted','hod_approved') returning * into inv;
  if inv.id is null then raise exception 'This invoice can''t be approved now'; end if;
  return inv;
end $$;

create function public.reject_invoice(p_id uuid, p_reason text) returns public.invoices
language plpgsql security definer set search_path = public as $$
declare inv invoices; me members;
begin
  select * into inv from invoices where id = p_id;
  select * into me from members where project_id = inv.project_id and user_id = auth.uid() and active;
  perform must(me.role in ('producer','manager','accounts') or (me.role = 'hod' and me.department = inv.department), 'You can''t reject this invoice');
  if length(trim(coalesce(p_reason, ''))) = 0 then raise exception 'Say why it is rejected so they can fix it'; end if;
  update invoices set status = 'rejected', rejected_by = auth.uid(), rejected_at = now(), reject_reason = trim(p_reason)
   where id = p_id and status in ('submitted','hod_approved','approved') and batch_id is null returning * into inv;
  if inv.id is null then raise exception 'This invoice can''t be rejected now'; end if;
  return inv;
end $$;

create function public.create_payment_batch(p_project uuid, p_invoices uuid[]) returns public.payment_batches
language plpgsql security definer set search_path = public as $$
declare b payment_batches; n int;
begin
  perform must(can_pay(p_project), 'Only accounts, the producer or the production manager can create payments');
  select count(*) into n from invoices where id = any(p_invoices) and project_id = p_project and status = 'approved' and batch_id is null;
  if n = 0 or n <> cardinality(p_invoices) then raise exception 'Pick approved invoices that are not already in a payment run'; end if;
  insert into payment_batches (project_id, created_by, invoices, amount)
  values (p_project, auth.uid(), n, (select sum(payable) from invoices where id = any(p_invoices)))
  returning * into b;
  update invoices set batch_id = b.id where id = any(p_invoices);
  return b;
end $$;

create function public.mark_batch_paid(p_batch uuid, p_ref text) returns public.payment_batches
language plpgsql security definer set search_path = public as $$
declare b payment_batches;
begin
  select * into b from payment_batches where id = p_batch;
  perform must(can_pay(b.project_id), 'Only accounts, the producer or the production manager can mark payments');
  if b.paid_at is not null then raise exception 'Already marked paid'; end if;
  if length(trim(coalesce(p_ref, ''))) = 0 then raise exception 'Enter the bank reference (UTR or batch ID)'; end if;
  update payment_batches set paid_at = now(), payment_ref = trim(p_ref) where id = p_batch returning * into b;
  update invoices set status = 'paid', paid_at = now(), payment_ref = trim(p_ref) where batch_id = p_batch;
  return b;
end $$;

-- ================================================================ budget and cost report

create table public.budget_lines (
  project_id  uuid not null references public.projects on delete cascade,
  department  text not null,
  amount      bigint not null check (amount >= 0),
  primary key (project_id, department)
);

create function public.set_budget(p_project uuid, p_department text, p_amount bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform must(can_manage(p_project) or my_role(p_project) = 'accounts', 'Only producer, manager or accounts can set the budget');
  insert into budget_lines values (p_project, trim(p_department), p_amount)
  on conflict (project_id, department) do update set amount = excluded.amount;
end $$;

-- committed = approved + paid; pending = submitted or HOD-approved (amounts before GST)
create function public.cost_report(p_project uuid)
returns table (department text, budget bigint, committed bigint, paid bigint, pending bigint)
language sql stable security definer set search_path = public as $$
  with depts as (
    select unnest(departments) d from projects where id = p_project
    union select department from budget_lines where project_id = p_project
    union select coalesce(department, 'Unassigned') from invoices where project_id = p_project)
  select d,
    coalesce((select amount from budget_lines b where b.project_id = p_project and b.department = d), 0),
    coalesce((select sum(amount) from invoices i where i.project_id = p_project and coalesce(i.department, 'Unassigned') = d and i.status in ('approved','paid')), 0)::bigint,
    coalesce((select sum(amount) from invoices i where i.project_id = p_project and coalesce(i.department, 'Unassigned') = d and i.status = 'paid'), 0)::bigint,
    coalesce((select sum(amount) from invoices i where i.project_id = p_project and coalesce(i.department, 'Unassigned') = d and i.status in ('submitted','hod_approved')), 0)::bigint
  from depts where can_pay(p_project) and d is not null
  order by 1
$$;

-- ================================================================ call sheets, reports, attendance

create table public.call_sheets (
  id            uuid primary key default gen_random_uuid(),
  project_id    uuid not null references public.projects on delete cascade,
  shoot_date    date not null,
  day_no        int,
  location      text,
  location_url  text,
  general_call  time,
  first_shot    time,
  wrap_est      time,
  scenes        jsonb not null default '[]',   -- [{scene, description, cast, location}]
  calls         jsonb not null default '[]',   -- [{user_id, name, department, call}]
  notes         text,
  emergency     text,
  status        text not null default 'draft' check (status in ('draft','published')),
  published_at  timestamptz,
  created_by    uuid references auth.users on delete set null,
  updated_at    timestamptz not null default now(),
  unique (project_id, shoot_date)
);

create table public.call_sheet_views (
  call_sheet_id uuid not null references public.call_sheets on delete cascade,
  user_id       uuid not null references auth.users on delete cascade,
  viewed_at     timestamptz not null default now(),
  primary key (call_sheet_id, user_id)
);

create function public.save_call_sheet(p_project uuid, p_sheet jsonb) returns public.call_sheets
language plpgsql security definer set search_path = public as $$
declare cs call_sheets;
begin
  perform must(can_manage(p_project), 'Only the producer or production manager can edit call sheets');
  insert into call_sheets (project_id, shoot_date, day_no, location, location_url, general_call, first_shot, wrap_est,
                           scenes, calls, notes, emergency, created_by)
  values (p_project, (p_sheet ->> 'shoot_date')::date, (p_sheet ->> 'day_no')::int, p_sheet ->> 'location', p_sheet ->> 'location_url',
          (p_sheet ->> 'general_call')::time, (p_sheet ->> 'first_shot')::time, (p_sheet ->> 'wrap_est')::time,
          coalesce(p_sheet -> 'scenes', '[]'), coalesce(p_sheet -> 'calls', '[]'), p_sheet ->> 'notes', p_sheet ->> 'emergency', auth.uid())
  on conflict (project_id, shoot_date) do update set
    day_no = excluded.day_no, location = excluded.location, location_url = excluded.location_url,
    general_call = excluded.general_call, first_shot = excluded.first_shot, wrap_est = excluded.wrap_est,
    scenes = excluded.scenes, calls = excluded.calls, notes = excluded.notes, emergency = excluded.emergency, updated_at = now()
  returning * into cs;
  return cs;
end $$;

create function public.publish_call_sheet(p_id uuid) returns public.call_sheets
language plpgsql security definer set search_path = public as $$
declare cs call_sheets;
begin
  select * into cs from call_sheets where id = p_id;
  perform must(can_manage(cs.project_id), 'Only the producer or production manager can publish call sheets');
  -- re-publishing asks everyone to look again: only views after published_at count
  update call_sheets set status = 'published', published_at = clock_timestamp() where id = p_id returning * into cs;
  return cs;
end $$;

create function public.mark_call_sheet_viewed(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform must(is_member((select project_id from call_sheets where id = p_id)), 'Not on this project');
  insert into call_sheet_views (call_sheet_id, user_id, viewed_at) values (p_id, auth.uid(), clock_timestamp())
  on conflict (call_sheet_id, user_id) do update set viewed_at = clock_timestamp();
end $$;

create table public.day_reports (
  id            uuid primary key default gen_random_uuid(),
  project_id    uuid not null references public.projects on delete cascade,
  shoot_date    date not null,
  crew_call     time,
  first_shot    time,
  lunch         time,
  wrap          time,
  scenes_done   text,
  scenes_left   text,
  setups        int,
  notes         text,
  created_by    uuid references auth.users on delete set null,
  updated_at    timestamptz not null default now(),
  unique (project_id, shoot_date)
);

create function public.save_day_report(p_project uuid, p_r jsonb) returns public.day_reports
language plpgsql security definer set search_path = public as $$
declare r day_reports;
begin
  perform must(can_manage(p_project), 'Only the producer or production manager can file day reports');
  insert into day_reports (project_id, shoot_date, crew_call, first_shot, lunch, wrap, scenes_done, scenes_left, setups, notes, created_by)
  values (p_project, (p_r ->> 'shoot_date')::date, (p_r ->> 'crew_call')::time, (p_r ->> 'first_shot')::time, (p_r ->> 'lunch')::time,
          (p_r ->> 'wrap')::time, p_r ->> 'scenes_done', p_r ->> 'scenes_left', (p_r ->> 'setups')::int, p_r ->> 'notes', auth.uid())
  on conflict (project_id, shoot_date) do update set
    crew_call = excluded.crew_call, first_shot = excluded.first_shot, lunch = excluded.lunch, wrap = excluded.wrap,
    scenes_done = excluded.scenes_done, scenes_left = excluded.scenes_left, setups = excluded.setups, notes = excluded.notes, updated_at = now()
  returning * into r;
  return r;
end $$;

create table public.attendance (
  project_id  uuid not null references public.projects on delete cascade,
  user_id     uuid not null references auth.users on delete cascade,
  day         date not null,
  check_in    timestamptz not null default now(),
  check_out   timestamptz,
  recorded_by uuid references auth.users on delete set null,
  primary key (project_id, user_id, day)
);

-- Scanning a crew member's ID card (or typing its code) checks them in; scanning again checks them out.
create function public.scan_id_card(p_project uuid, p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid; today date := (now() at time zone 'Asia/Kolkata')::date; a attendance; nm text;
begin
  perform must(can_manage(p_project), 'Only the producer or production manager can check crew in');
  select m.user_id into uid from members m
   where m.project_id = p_project and m.active and m.card_code = upper(trim(p_code));
  if uid is null then raise exception 'That ID card isn''t on this project'; end if;
  select coalesce(nullif(full_name, ''), legal_name, username) into nm from profiles where id = uid;
  insert into attendance (project_id, user_id, day, recorded_by) values (p_project, uid, today, auth.uid())
  on conflict (project_id, user_id, day) do update set check_out = now()
  returning * into a;
  return jsonb_build_object('name', nm, 'in', a.check_in, 'out', a.check_out);
end $$;

-- ================================================================ access control

alter table public.profiles           enable row level security;
alter table public.projects           enable row level security;
alter table public.members            enable row level security;
alter table public.contract_templates enable row level security;
alter table public.contracts          enable row level security;
alter table public.contract_events    enable row level security;
alter table public.invoices           enable row level security;
alter table public.payment_batches    enable row level security;
alter table public.budget_lines       enable row level security;
alter table public.call_sheets        enable row level security;
alter table public.call_sheet_views   enable row level security;
alter table public.day_reports        enable row level security;
alter table public.attendance         enable row level security;

create policy "own profile"        on public.profiles for select using (id = auth.uid());
create policy "edit own profile"   on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());

-- People edit their own profile, but never the account it belongs to or the email it signs in with.
create function public.guard_profile() returns trigger
language plpgsql set search_path = public as $$
begin
  if current_user in ('authenticated', 'anon') and (new.id is distinct from old.id or new.email is distinct from old.email
     or new.created_at is distinct from old.created_at) then
    raise exception 'Your account ID and email can''t be changed here' using errcode = '42501';
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger guard_profile before update on public.profiles for each row execute function public.guard_profile();

create policy "members see project"  on public.projects for select using (is_member(id));
create policy "members see crew"     on public.members  for select using (is_member(project_id));
create policy "templates"            on public.contract_templates for select using (project_id is null or is_member(project_id));
-- contracts: your own, or all of the project's if you manage it or handle accounts
create policy "contracts"            on public.contracts for select using (user_id = auth.uid() or can_pay(project_id));
create policy "contract events"      on public.contract_events for select
  using (exists (select 1 from contracts c where c.id = contract_id and (c.user_id = auth.uid() or can_pay(c.project_id))));
-- invoices: your own; HODs see their department's; producer/manager/accounts see all
create policy "invoices"             on public.invoices for select using (
  submitted_by = auth.uid() or can_pay(project_id)
  or exists (select 1 from members m where m.project_id = invoices.project_id and m.user_id = auth.uid() and m.active
             and m.role = 'hod' and m.department = invoices.department));
create policy "batches"              on public.payment_batches for select using (can_pay(project_id));
create policy "budget"               on public.budget_lines for select using (can_pay(project_id));
create policy "call sheets"          on public.call_sheets for select using (can_manage(project_id) or (status = 'published' and is_member(project_id)));
create policy "call sheet views"     on public.call_sheet_views for select
  using (user_id = auth.uid() or exists (select 1 from call_sheets c where c.id = call_sheet_id and can_manage(c.project_id)));
create policy "day reports"          on public.day_reports for select using (is_member(project_id));
create policy "attendance"           on public.attendance for select using (user_id = auth.uid() or can_pay(project_id));

-- Writes: no table above has an insert, update or delete policy (except updating your own profile),
-- so row-level security refuses every direct write. All changes go through the functions above,
-- each of which checks who is calling. Anonymous visitors fail those checks (no auth.uid()).

-- ================================================================ built-in contract template

insert into public.contract_templates (project_id, name, body) values (null, 'Crew engagement agreement',
$t$CREW ENGAGEMENT AGREEMENT

Date: {{date}}

BETWEEN
{{company_name}}, GSTIN {{company_gstin}}, of {{company_address}} ("the Producer"), for the production "{{project}}";

AND
{{name}}, PAN {{pan}}, GSTIN {{gstin}}, of {{address}} ("the Crew Member"). Phone {{phone}}, email {{email}}.

1. ENGAGEMENT. The Producer engages the Crew Member as {{designation}} in the {{department}} department for the production, from {{start_date}} to {{end_date}}, or for such further period as both parties agree in writing.

2. FEE. The Producer will pay {{rate}} {{rate_unit}}, plus GST where the Crew Member is registered, against invoices raised through CrewDesk for days actually worked. Payment is due within 30 days of the invoice being approved, less tax deducted at source as required by law.

3. WORKING DAY. A standard working day is 12 hours including a meal break. Overtime, travel days and holidays are paid only as agreed in writing in advance.

4. CONDUCT. The Crew Member will follow the call sheet, the reasonable instructions of the Producer and the head of department, and all safety rules on set and on location.

5. CONFIDENTIALITY. The Crew Member will keep the script, story, cast, locations and all unreleased material confidential, and will not post or share any photograph, video or detail of the production without written permission.

6. RIGHTS. All work and results of the Crew Member's services for the production belong to the Producer from creation, throughout the world and in all media.

7. TERMINATION. Either party may end this agreement with 3 days' written notice. The Producer may end it immediately for misconduct. Fees for days already worked remain payable.

8. PAYMENT DETAILS. Payments will be made to: {{bank}}.

9. GOVERNING LAW. This agreement is governed by the laws of India.

Signed electronically through CrewDesk. The signature record (name, drawn signature, time and document fingerprint) is attached below.$t$);

-- ================================================================ hardening

-- Pin the helper functions to this schema too, so a caller can't swap in look-alike functions.
alter function public.gstin_valid(text)             set search_path = public;
alter function public.inr(numeric)                  set search_path = public;
alter function public.render_template(text, jsonb)  set search_path = public;
alter function public.kyc_missing(public.profiles)  set search_path = public;
alter function public.must(boolean, text)           set search_path = public;
