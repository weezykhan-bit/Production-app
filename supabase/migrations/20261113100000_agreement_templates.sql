-- Agreement templates from Legal, and clause-by-clause questions before signing.
--
-- 1. Template library. Legal (a new role) or the CFO/Commercial Head keep the company's agreement templates: typed,
--    pasted or uploaded (.docx/.txt, converted to text in the browser), with {{blanks}} CrewDesk fills from the deal,
--    the person's profile, the company and the production. A template is used only after it is approved, and a change
--    to an approved template needs approving again. Legal cannot approve their own change; the CFO/Commercial Head can.
--    Each production picks a template for each list (crew, cast, vendors); without one, the built-in text is used.
-- 2. Questions on clauses. The person can ask about any clause before signing. Legal, the Line Producer or the Head of
--    Production replies, changes the agreement (a new version, with a note of what changed) or keeps the clause with
--    a reason. Signing waits until every question is closed, and a signature is tied to the version the person read.
--
-- PAN and bank numbers are encrypted, and staff can read agreement text, so the blanks show only their last digits.

-- ================================================================ Legal role

alter table public.crew drop constraint crew_role_check;
alter table public.crew add constraint crew_role_check check (role in ('hop','lp','accounts','hod','crew','vendor','auditor','commercial_mgr','controller','legal'));

create or replace function public.onboard(p_production uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare r text := coalesce(nullif(p ->> 'role', ''), 'crew'); c crew; existing uuid; em text := nullif(lower(trim(p ->> 'email')), '');
begin
  perform must(prod_lead(p_production), 'Only the Line Producer, Head of Production, CFO or Commercial Head can onboard people');
  if r in ('hop','lp','accounts','auditor','commercial_mgr','controller','legal') then perform must(prod_owner(p_production), 'Only the CFO or Commercial Head can give that access'); end if;
  perform must(length(trim(coalesce(p ->> 'name', ''))) > 1, 'Enter the person’s full name');
  perform must((p ->> 'rate')::bigint > 0, 'Enter the rate in rupees');
  perform must(nullif(p ->> 'joining', '') is not null, 'Pick a joining date');
  if em is not null then select id into existing from auth.users where lower(email) = em and email_confirmed_at is not null limit 1; end if;
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

-- who handles agreements on a show
create function public.ag_staff(p uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(prod_role(p) in ('cfo','commercial','hop','lp','legal'), false) $$;
-- who keeps the template library: the owners, or anyone holding the Legal role on a show
create function public.template_editor() returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (exists (select 1 from company_admins where user_id = auth.uid())
    or exists (select 1 from crew where user_id = auth.uid() and active and removed_at is null and role = 'legal')) $$;
-- staff anywhere can read templates (to pick one); crew and vendors only see their own filled-in agreement
create function public.template_reader() returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (exists (select 1 from company_admins where user_id = auth.uid())
    or exists (select 1 from crew where user_id = auth.uid() and active and removed_at is null and role not in ('crew','vendor'))) $$;
-- who answers questions on a show: Legal, else the Line Producer and Head of Production, else the owners
create function public.ag_answerers(p uuid) returns uuid[] language sql stable security definer set search_path = public as $$
  select case when has_role(p, array['legal']) then people_in(p, array['legal']) || people_in(p, array['lp','hop'])
              when has_role(p, array['lp','hop']) then people_in(p, array['lp','hop'])
              else people_in(p, array['cfo','commercial']) end $$;

-- ================================================================ template library

create table public.agreement_templates (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) between 3 and 80),
  kind        text not null check (kind in ('crew','cast','vendor','nda','other')),
  body        text not null check (length(body) between 200 and 60000),
  version     int not null default 1,
  source      text not null default 'typed' check (source in ('sample','upload','typed')),
  file_name   text check (file_name is null or length(file_name) <= 200),
  approved_at timestamptz,
  approved_by uuid references auth.users on delete set null,
  archived    boolean not null default false,
  created_by  uuid references auth.users on delete set null,
  created_at  timestamptz not null default now(),
  updated_by  uuid references auth.users on delete set null,
  updated_at  timestamptz not null default now()
);
create table public.agreement_template_versions (
  template_id uuid not null references public.agreement_templates on delete cascade,
  version     int not null,
  body        text not null,
  by          uuid references auth.users on delete set null,
  at          timestamptz not null default now(),
  primary key (template_id, version)
);
create table public.production_templates (
  production_id uuid not null references public.productions on delete cascade,
  kind          text not null check (kind in ('crew','cast','vendor')),
  template_id   uuid not null references public.agreement_templates on delete cascade,
  set_by        uuid references auth.users on delete set null,
  at            timestamptz not null default now(),
  primary key (production_id, kind)
);

-- the blanks a template may use
create function public.tpl_keys() returns text[] language sql immutable as $$
  select array['name','legal_name','party','pan','gstin','address','phone','email','bank','job','dept','fee','rate','unit',
               'joining','end_date','terms','tds','overtime_rule','company','company_address','company_pan','company_gstin',
               'signatory','designation','production','format','city','today'] $$;
-- {{ Name }} and {{name}} are the same blank
create function public.tpl_normalise(b text) returns text language sql immutable as $$
  select regexp_replace(b, '\{\{\s*([A-Za-z_]+)\s*\}\}', '{{\1}}', 'g') $$;
create function public.template_blanks(b text) returns text[] language sql immutable as $$
  select coalesce(array_agg(distinct m[1]) filter (where lower(m[1]) <> all (tpl_keys()) or m[1] <> lower(m[1])), '{}')
    from regexp_matches(tpl_normalise(b), '\{\{([^}]*)\}\}', 'g') m $$;
create function public.tpl_lower(b text) returns text language plpgsql immutable as $$
declare k text; out text := tpl_normalise(b);
begin
  for k in select distinct m[1] from regexp_matches(out, '\{\{([A-Za-z_]+)\}\}', 'g') m loop
    out := replace(out, '{{' || k || '}}', '{{' || lower(k) || '}}');
  end loop;
  return out;
end $$;

-- p: {id?, name, kind, body, source?, file_name?}. A new body is a new version and clears the approval.
create function public.save_template(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare t agreement_templates; b text := tpl_lower(coalesce(p ->> 'body', '')); bad text[];
begin
  perform must(template_editor(), 'Only Legal, the CFO or the Commercial Head can edit agreement templates');
  perform must(length(trim(coalesce(p ->> 'name', ''))) between 3 and 80, 'Give the template a name');
  perform must(coalesce(p ->> 'kind', '') in ('crew','cast','vendor','nda','other'), 'Pick who the template is for');
  perform must(length(b) between 200 and 60000, 'The template needs at least 200 characters of text');
  bad := template_blanks(b);
  if cardinality(bad) > 0 then
    raise exception 'CrewDesk can’t fill {{%}}. Use one of: %', array_to_string(bad, '}}, {{'), array_to_string(tpl_keys(), ', ');
  end if;
  if nullif(p ->> 'id', '') is null then
    insert into agreement_templates (name, kind, body, source, file_name, created_by, updated_by)
    values (trim(p ->> 'name'), p ->> 'kind', b, coalesce(nullif(p ->> 'source', ''), 'typed'), nullif(trim(coalesce(p ->> 'file_name', '')), ''), auth.uid(), auth.uid())
    returning * into t;
    insert into agreement_template_versions (template_id, version, body, by) values (t.id, 1, b, auth.uid());
    return t.id;
  end if;
  select * into t from agreement_templates where id = (p ->> 'id')::uuid for update;
  perform must(t.id is not null, 'No such template');
  perform must(not t.archived, 'This template is archived');
  if b is distinct from t.body then
    update agreement_templates set name = trim(p ->> 'name'), kind = p ->> 'kind', body = b, version = t.version + 1,
           source = case when nullif(p ->> 'source', '') = 'upload' then 'upload' when t.source = 'sample' then 'typed' else t.source end,
           file_name = coalesce(nullif(trim(coalesce(p ->> 'file_name', '')), ''), t.file_name),
           approved_at = null, approved_by = null, updated_by = auth.uid(), updated_at = now()
     where id = t.id;
    insert into agreement_template_versions (template_id, version, body, by) values (t.id, t.version + 1, b, auth.uid());
  else
    perform must(p ->> 'kind' = t.kind or not exists (select 1 from production_templates where template_id = t.id),
                 'This template is in use; make a copy for a different list');
    update agreement_templates set name = trim(p ->> 'name'), kind = p ->> 'kind', updated_at = now() where id = t.id;
  end if;
  return t.id;
end $$;

create function public.approve_template(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t agreement_templates;
begin
  perform must(template_editor(), 'Only Legal, the CFO or the Commercial Head can approve agreement templates');
  select * into t from agreement_templates where id = p_id for update;
  perform must(t.id is not null and not t.archived, 'No such template');
  perform must(t.approved_at is null, 'This version is already approved');
  perform must(admin_role() is not null or t.updated_by is distinct from auth.uid(),
               'Someone else approves your own changes: another lawyer, the CFO or the Commercial Head');
  update agreement_templates set approved_at = now(), approved_by = auth.uid() where id = p_id;
end $$;

create function public.archive_template(p_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform must(template_editor(), 'Only Legal, the CFO or the Commercial Head can archive agreement templates');
  update agreement_templates set archived = true, updated_at = now() where id = p_id and not archived;
  perform must(found, 'No such template');
  delete from production_templates where template_id = p_id;
  get diagnostics n = row_count;
  return n;  -- lists that go back to the built-in text
end $$;

-- p_template null: the list goes back to the built-in text
create function public.set_production_template(p_production uuid, p_kind text, p_template uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t agreement_templates;
begin
  perform must(ag_staff(p_production), 'Only Legal, the Line Producer, Head of Production, CFO or Commercial Head can choose agreement templates');
  perform must(p_kind in ('crew','cast','vendor'), 'Pick the crew, cast or vendor list');
  if p_template is null then
    delete from production_templates where production_id = p_production and kind = p_kind;
    perform add_log(p_production, 'agreement', 'The ' || p_kind || ' list uses the built-in agreement again');
    return;
  end if;
  select * into t from agreement_templates where id = p_template;
  perform must(t.id is not null and not t.archived, 'No such template');
  perform must(t.approved_at is not null, 'Approve the template before using it');
  perform must(t.kind in (p_kind, 'other'), 'That template is for a different list');
  insert into production_templates (production_id, kind, template_id, set_by) values (p_production, p_kind, p_template, auth.uid())
  on conflict (production_id, kind) do update set template_id = excluded.template_id, set_by = excluded.set_by, at = now();
  perform add_log(p_production, 'agreement', 'The ' || p_kind || ' list now uses “' || t.name || '” (v' || t.version || ')');
end $$;

-- ================================================================ filling in a template

create function public.agreement_fields(p_crew uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'name', crew_name(c),
    'legal_name', coalesce(nullif(trim(pr.legal_name), ''), crew_name(c)),
    'party', case c.kind when 'vendor' then 'Service Provider' when 'cast' then 'Artist' else 'Crew Member' end,
    'pan', coalesce('••••••' || pr.pan_tail, '—'),
    'gstin', coalesce(pr.gstin, 'not registered for GST'),
    'address', coalesce(nullif(trim(pr.address), ''), '—'),
    'phone', coalesce(pr.phone, '—'),
    'email', coalesce(pr.email, '—'),
    'bank', case when pr.bank_tail is null then 'the bank account in their CrewDesk profile'
                 else concat_ws(', ', nullif(trim(pr.bank_holder), ''), nullif(trim(pr.bank_name), ''), 'account ending ' || pr.bank_tail, 'IFSC ' || pr.bank_ifsc) end,
    'job', coalesce(c.job, '—'),
    'dept', coalesce(c.dept, '—'),
    'rate', inr(c.rate),
    'unit', case c.unit when 'day' then 'per day' when 'episode' then 'per episode' when 'week' then 'per week' when 'month' then 'per month' else 'lump sum' end,
    'fee', inr(c.rate) || ' ' || case c.unit when 'day' then 'per day' when 'episode' then 'per episode' when 'week' then 'per week' when 'month' then 'per month' else 'lump sum' end,
    'joining', to_char(c.joining, 'DD Mon YYYY'),
    'end_date', coalesce(to_char(c.end_date, 'DD Mon YYYY'), 'the end of the production schedule'),
    'terms', c.terms || ' days',
    'tds', case when c.tds = 'none' then 'where the law requires it' else 'under section ' || split_part(c.tds, '-', 1) || ' at ' || split_part(c.tds, '-', 2) || '%' end,
    'overtime_rule', 'A working day is ' || trim_scale(round(p.ot_after_min / 60.0, 1)) || ' hours including a meal break. Time beyond that is paid pro rata: the day rate divided by '
                     || trim_scale(round(p.ot_after_min / 60.0, 1)) || ' for each extra hour, worked out from gate check-in and pack-up times.',
    'company', co.legal,
    'company_address', co.address,
    'company_pan', co.pan,
    'company_gstin', coalesce(co.gstin, 'not registered for GST'),
    'signatory', co.signatory,
    'designation', coalesce(co.designation, 'Authorised Signatory'),
    'production', p.name,
    'format', p.format,
    'city', p.city,
    'today', to_char(today_ist(), 'DD Mon YYYY'))
  from crew c join productions p on p.id = c.production_id left join profiles pr on pr.id = c.user_id cross join companies co
  where c.id = p_crew $$;

-- the template this person's agreement would use, if any
create function public.template_for(p_crew uuid) returns uuid language sql stable security definer set search_path = public as $$
  select pt.template_id from crew c join production_templates pt on pt.production_id = c.production_id and pt.kind = c.kind where c.id = p_crew $$;

-- what the person will receive; staff preview it before sending
create function public.preview_agreement(p_crew uuid, p_template uuid default null) returns text
language plpgsql stable security definer set search_path = public as $$
declare c crew; t agreement_templates;
begin
  select * into c from crew where id = p_crew;
  perform must(c.id is not null and ag_staff(c.production_id), 'Only Legal, the Line Producer, Head of Production, CFO or Commercial Head can prepare agreements');
  select * into t from agreement_templates where id = coalesce(p_template, template_for(p_crew));
  if t.id is null then return null; end if;   -- the built-in text applies
  return render_template(t.body, agreement_fields(p_crew));
end $$;

-- ================================================================ sent agreements: versions and questions

alter table public.crew add column ag_version int, add column ag_template uuid references public.agreement_templates on delete set null,
  add column ag_template_version int;

create table public.agreement_versions (
  crew_id   uuid not null references public.crew on delete cascade,
  version   int not null,
  body      text not null,
  note      text,
  by        uuid references auth.users on delete set null,
  at        timestamptz not null default now(),
  primary key (crew_id, version)
);
create table public.agreement_queries (
  id            uuid primary key default gen_random_uuid(),
  crew_id       uuid not null references public.crew on delete cascade,
  production_id uuid not null references public.productions on delete cascade,
  version       int not null,
  clause        text not null check (length(clause) between 1 and 40),
  excerpt       text check (excerpt is null or length(excerpt) <= 600),
  body          text not null check (length(trim(body)) between 2 and 2000),
  status        text not null default 'open' check (status in ('open','changed','kept','withdrawn')),
  by            uuid references auth.users on delete set null,
  at            timestamptz not null default now(),
  resolved_by   uuid references auth.users on delete set null,
  resolved_at   timestamptz,
  outcome       text check (outcome is null or length(outcome) <= 2000)
);
create index agreement_queries_crew_idx on public.agreement_queries (crew_id, status);
create table public.agreement_query_notes (
  id        bigint generated always as identity primary key,
  query_id  uuid not null references public.agreement_queries on delete cascade,
  by        uuid references auth.users on delete set null,
  at        timestamptz not null default now(),
  body      text not null check (length(trim(body)) between 1 and 2000)
);
create index agreement_query_notes_q_idx on public.agreement_query_notes (query_id);

drop function public.send_agreement(uuid, text);
-- p_text is the built-in text from the app; when a template applies, the server fills it in instead
create function public.send_agreement(p_crew uuid, p_text text, p_template uuid default null) returns int
language plpgsql security definer set search_path = public as $$
declare c crew; pr profiles; t agreement_templates; body text := p_text; v int;
begin
  select * into c from crew where id = p_crew for update;
  perform must(c.id is not null and ag_staff(c.production_id), 'Only Legal, the Line Producer, Head of Production, CFO or Commercial Head can send agreements');
  perform must(c.user_id is not null, 'This person hasn’t joined yet');
  perform must(c.ag_status = 'none', 'An agreement has already been sent');
  perform must(c.rate is not null and c.joining is not null and c.dept is not null and c.job is not null, 'Set the deal first');
  select * into pr from profiles where id = c.user_id;
  perform must(profile_ready(pr), 'Their profile and bank details aren’t complete yet');
  perform must(docs_ready(pr), 'Their Aadhaar and PAN documents aren’t complete yet');
  select * into t from agreement_templates where id = coalesce(p_template, template_for(p_crew));
  if t.id is not null then
    perform must(not t.archived, 'That template is archived');
    perform must(t.approved_at is not null, '“' || t.name || '” was changed and needs approving again before it is sent');
    body := render_template(t.body, agreement_fields(p_crew));
  end if;
  perform must(length(coalesce(body, '')) between 200 and 60000, 'The agreement text is missing');
  v := coalesce((select max(version) from agreement_versions where crew_id = p_crew), 0) + 1;
  update agreement_queries set status = 'withdrawn', resolved_at = now(), resolved_by = auth.uid(), outcome = 'A new agreement was sent'
   where crew_id = p_crew and status = 'open';
  insert into agreement_versions (crew_id, version, body, note, by) values (p_crew, v, body, coalesce('From “' || t.name || '” v' || t.version, 'Built-in agreement'), auth.uid());
  update crew set ag_status = 'sent', ag_text = body, ag_sent_at = now(), ag_version = v, ag_template = t.id, ag_template_version = t.version where id = p_crew;
  perform add_log(c.production_id, 'agreement', 'Sent the agreement to ' || crew_name(c) || coalesce(' (“' || t.name || '” v' || t.version || ')', ''), c.id);
  return v;
end $$;

-- the person (or staff) asks about a clause
create function public.raise_agreement_query(p_crew uuid, p_clause text, p_excerpt text, p_body text) returns uuid
language plpgsql security definer set search_path = public as $$
declare c crew; q uuid; mine boolean;
begin
  select * into c from crew where id = p_crew;
  mine := c.user_id = auth.uid();
  perform must(c.id is not null and (mine or ag_staff(c.production_id)), 'Only the person or the people handling agreements can ask about this agreement');
  perform must(c.ag_status = 'sent', 'Questions can be asked only before the agreement is signed');
  perform must(length(trim(coalesce(p_clause, ''))) between 1 and 40, 'Pick the clause you are asking about');
  perform must(length(trim(coalesce(p_body, ''))) between 2 and 2000, 'Write your question');
  perform must((select count(*) from agreement_queries where crew_id = p_crew and status = 'open') < 30, 'Too many open questions; wait for answers first');
  insert into agreement_queries (crew_id, production_id, version, clause, excerpt, body, by)
  values (p_crew, c.production_id, c.ag_version, trim(p_clause), nullif(left(trim(coalesce(p_excerpt, '')), 600), ''), trim(p_body), auth.uid())
  returning id into q;
  if mine then
    perform notify(ag_answerers(c.production_id), c.production_id, 'agreement', crew_name(c) || ' asked about clause ' || trim(p_clause),
                   left(trim(p_body), 160), 'agreements');
  else
    perform notify(array[c.user_id], c.production_id, 'agreement', 'A question on clause ' || trim(p_clause) || ' of your agreement',
                   left(trim(p_body), 160) || ' · Reply from My setup.', 'home');
  end if;
  perform add_log(c.production_id, 'agreement', 'Question on clause ' || trim(p_clause) || ' of ' || crew_name(c) || '’s agreement', c.id);
  return q;
end $$;

create function public.note_agreement_query(p_query uuid, p_body text) returns bigint
language plpgsql security definer set search_path = public as $$
declare q agreement_queries; c crew; mine boolean; n bigint;
begin
  select * into q from agreement_queries where id = p_query;
  select * into c from crew where id = q.crew_id;
  mine := c.user_id = auth.uid();
  perform must(q.id is not null and (mine or ag_staff(c.production_id)), 'Only the person or the people handling agreements can reply here');
  perform must(q.status = 'open', 'This question is closed');
  perform must(length(trim(coalesce(p_body, ''))) between 1 and 2000, 'Write a reply');
  insert into agreement_query_notes (query_id, by, body) values (p_query, auth.uid(), trim(p_body)) returning id into n;
  if mine then
    perform notify(ag_answerers(c.production_id), c.production_id, 'agreement', crew_name(c) || ' replied on clause ' || q.clause, left(trim(p_body), 160), 'agreements');
  else
    perform notify(array[c.user_id], c.production_id, 'agreement', 'Reply on clause ' || q.clause || ' of your agreement', left(trim(p_body), 160), 'home');
  end if;
  return n;
end $$;

-- change the agreement: a new version; the listed questions are closed as changed
create function public.revise_agreement(p_crew uuid, p_text text, p_note text, p_resolve uuid[] default '{}') returns int
language plpgsql security definer set search_path = public as $$
declare c crew; v int; closed int;
begin
  select * into c from crew where id = p_crew for update;
  perform must(c.id is not null and ag_staff(c.production_id), 'Only Legal, the Line Producer, Head of Production, CFO or Commercial Head can change agreements');
  perform must(c.ag_status = 'sent', 'Only an agreement waiting for a signature can be changed');
  perform must(length(coalesce(p_text, '')) between 200 and 60000, 'The agreement text is missing');
  perform must(p_text is distinct from c.ag_text, 'Nothing changed in the text');
  perform must(length(trim(coalesce(p_note, ''))) between 3 and 500, 'Say what changed, for the record');
  v := c.ag_version + 1;
  insert into agreement_versions (crew_id, version, body, note, by) values (p_crew, v, p_text, trim(p_note), auth.uid());
  update crew set ag_text = p_text, ag_version = v where id = p_crew;
  update agreement_queries set status = 'changed', resolved_at = now(), resolved_by = auth.uid(), outcome = trim(p_note)
   where crew_id = p_crew and status = 'open' and id = any (coalesce(p_resolve, '{}'));
  get diagnostics closed = row_count;
  perform notify(array[c.user_id], c.production_id, 'agreement', 'Your agreement was updated (version ' || v || ')',
                 trim(p_note) || ' · Read it again before signing.', 'home');
  perform add_log(c.production_id, 'agreement', 'Changed ' || crew_name(c) || '’s agreement to version ' || v || ': ' || trim(p_note)
                  || case when closed > 0 then ' (' || closed || ' question' || case when closed = 1 then '' else 's' end || ' answered)' else '' end, c.id);
  return v;
end $$;

-- staff keep the clause as it is (with a reason); the person can withdraw their own question
create function public.close_agreement_query(p_query uuid, p_reason text) returns text
language plpgsql security definer set search_path = public as $$
declare q agreement_queries; c crew; st text;
begin
  select * into q from agreement_queries where id = p_query for update;
  select * into c from crew where id = q.crew_id;
  perform must(q.id is not null, 'No such question');
  perform must(q.status = 'open', 'This question is already closed');
  if ag_staff(c.production_id) and c.user_id is distinct from auth.uid() then
    perform must(length(trim(coalesce(p_reason, ''))) between 3 and 2000, 'Explain why the clause stays as it is');
    st := 'kept';
  else
    perform must(q."by" = auth.uid(), 'Only the people handling agreements can close this question');
    st := 'withdrawn';
  end if;
  update agreement_queries set status = st, resolved_at = now(), resolved_by = auth.uid(),
         outcome = coalesce(nullif(trim(coalesce(p_reason, '')), ''), 'Withdrawn') where id = p_query;
  if st = 'kept' then
    perform notify(array[c.user_id], c.production_id, 'agreement', 'Clause ' || q.clause || ' stays as it is', left(trim(p_reason), 160), 'home');
  else
    perform notify(ag_answerers(c.production_id), c.production_id, 'agreement', crew_name(c) || ' withdrew their question on clause ' || q.clause, null, 'agreements');
  end if;
  return st;
end $$;

-- signing waits for every question, and binds to the version the person read
drop function public.sign_agreement(uuid, text, text);
create function public.sign_agreement(p_crew uuid, p_name text, p_signature text, p_version int default null) returns void
language plpgsql security definer set search_path = public as $$
declare c crew; pr profiles; open_n int;
begin
  select * into c from crew where id = p_crew for update;
  perform must(c.id is not null and c.user_id = auth.uid(), 'Only the person named in the agreement can sign it');
  if c.ag_status <> 'sent' then raise exception 'This agreement isn’t waiting for your signature'; end if;
  select count(*) into open_n from agreement_queries where crew_id = p_crew and status = 'open';
  if open_n > 0 then
    raise exception '% question% on this agreement % still open. Sign once they are answered or withdrawn',
      open_n, case when open_n = 1 then '' else 's' end, case when open_n = 1 then 'is' else 'are' end;
  end if;
  perform must(p_version is null or p_version = c.ag_version, 'The agreement changed while you were reading it. Read version ' || c.ag_version || ' and sign again');
  select * into pr from profiles where id = auth.uid();
  perform must(profile_ready(pr) and docs_ready(pr), 'Complete your profile and documents before signing');
  perform must(length(trim(coalesce(p_name, ''))) >= 2, 'Type your full name to sign');
  perform must(coalesce(p_signature, '') ~ '^data:image/png;base64,', 'Draw your signature');
  update crew set ag_status = 'signed', ag_signed_at = now(), ag_signed_name = trim(p_name), ag_signature = p_signature,
         ag_hash = encode(sha256(convert_to(ag_text || '|' || trim(p_name) || '|' || p_signature, 'UTF8')), 'hex')
   where id = p_crew;
  perform add_log(c.production_id, 'agreement', crew_name(c) || ' signed the engagement agreement' || coalesce(' (version ' || c.ag_version || ')', ''), c.id);
end $$;

-- a deal change withdraws a sent agreement: its open questions close with it
create function public.agreement_reset() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.ag_status = 'sent' and new.ag_status = 'none' then
    update agreement_queries set status = 'withdrawn', resolved_at = now(), outcome = 'The deal changed; a new agreement will follow'
     where crew_id = new.id and status = 'open';
  end if;
  return null;
end $$;
create trigger agreement_reset after update of ag_status on public.crew for each row execute function public.agreement_reset();

-- Legal hears when someone is ready for their agreement too
create or replace function public.profile_ready_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare c crew;
begin
  if (profile_ready(new) and docs_ready(new)) and not (profile_ready(old) and docs_ready(old)) then
    for c in select * from crew where user_id = new.id and active and removed_at is null and ag_status = 'none' and rate is not null loop
      perform notify(people_in(c.production_id, array['lp','hop','legal']), c.production_id, 'onboard', crew_name(c) || ' is ready for their agreement',
        'Profile, bank and documents are complete. Send the agreement from Agreements.', 'agreements');
    end loop;
  end if;
  return null;
end $$;

-- ================================================================ who can read what

alter table public.agreement_templates enable row level security;
alter table public.agreement_template_versions enable row level security;
alter table public.production_templates enable row level security;
alter table public.agreement_versions enable row level security;
alter table public.agreement_queries enable row level security;
alter table public.agreement_query_notes enable row level security;

create policy "staff read templates" on public.agreement_templates for select using (template_reader());
create policy "staff read template history" on public.agreement_template_versions for select using (template_reader());
create policy "members see the show's templates" on public.production_templates for select using (prod_staff(production_id));
create policy "the person or staff" on public.agreement_versions for select using (
  exists (select 1 from crew c where c.id = crew_id and (c.user_id = (select auth.uid()) or prod_staff(c.production_id))));
create policy "the person or staff" on public.agreement_queries for select using (
  exists (select 1 from crew c where c.id = crew_id and (c.user_id = (select auth.uid()) or prod_staff(c.production_id))));
create policy "the person or staff" on public.agreement_query_notes for select using (
  exists (select 1 from agreement_queries q join crew c on c.id = q.crew_id where q.id = query_id and (c.user_id = (select auth.uid()) or prod_staff(c.production_id))));

revoke insert, update, delete, truncate on public.agreement_templates, public.agreement_template_versions, public.production_templates,
  public.agreement_versions, public.agreement_queries, public.agreement_query_notes from anon, authenticated;
revoke select on public.agreement_templates, public.agreement_template_versions, public.production_templates,
  public.agreement_versions, public.agreement_queries, public.agreement_query_notes from anon;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.login_email(text), public.username_available(text) to anon;
revoke execute on function public.kyc_key(), public.kyc_enc(text), public.kyc_dec(bytea), public.apply_invoice_ot(uuid) from authenticated;
revoke execute on function public.send_call_reminders(), public.send_task_reminders(), public.send_dpr_reminders(), public.send_attendance_reminders() from authenticated;
-- the filled-in fields carry contact details; only the checked functions above use them
revoke execute on function public.agreement_fields(uuid), public.agreement_reset() from authenticated;

-- ================================================================ sample templates (a lawyer must review before approving)

insert into public.agreement_templates (name, kind, source, body) values
('Sample: crew engagement (day rate)', 'crew', 'sample', $t$CREW ENGAGEMENT AGREEMENT
{{production}} · {{format}}

Date: {{today}}

BETWEEN {{company}}, PAN {{company_pan}}, GSTIN {{company_gstin}}, of {{company_address}} ("the Production")

AND {{legal_name}}, PAN {{pan}}, GSTIN {{gstin}}, of {{address}} ("the {{party}}").

1. ENGAGEMENT. The {{party}} is engaged as {{job}} in the {{dept}} department from {{joining}} until {{end_date}}, unless ended earlier under clause 8.

2. FEE. {{fee}}, plus GST where the {{party}} is registered, against invoices raised in CrewDesk. Days worked are confirmed by gate check-in and the Auditor. Tax is deducted at source {{tds}}.

3. PAYMENT. Within {{terms}} of the invoice being approved, to {{bank}}.

4. WORKING DAY AND OVERTIME. {{overtime_rule}} Travel days and holidays are paid only as agreed in writing in advance.

5. CONDUCT AND SAFETY. The {{party}} follows the call sheet, safety briefings and the Production's policies on set, including the policy against sexual harassment.

6. CONFIDENTIALITY. Scripts, story, cast, locations and unreleased material stay confidential during and after the engagement. Nothing from set is posted or shared without written permission.

7. RIGHTS. All work, footage and material created for the Production belong to the Production, worldwide, in all media and for the full term of copyright.

8. TERMINATION. Either side may end this agreement with 3 days' written notice. The Production may end it at once for misconduct. Fees for days already worked remain payable.

9. LAW. Governed by the laws of India; courts at {{city}} have jurisdiction.

For the Production: {{signatory}}, {{designation}}

Signed electronically in CrewDesk. The record keeps the typed name, drawn signature, time and a SHA-256 fingerprint of this text.$t$),
('Sample: artist engagement (per episode)', 'cast', 'sample', $t$ARTIST ENGAGEMENT AGREEMENT
{{production}} · {{format}}

Date: {{today}}

BETWEEN {{company}}, PAN {{company_pan}}, of {{company_address}} ("the Producer")

AND {{legal_name}}, PAN {{pan}}, GSTIN {{gstin}}, of {{address}} ("the Artist").

1. ROLE. The Artist plays {{job}} in {{production}}, available for shooting, dubbing and promotion from {{joining}} until {{end_date}}.

2. FEE. {{fee}}, plus GST where applicable. Per-episode fees are paid for each episode in which the Artist is called and works. Tax is deducted at source {{tds}}.

3. PAYMENT. Within {{terms}} of the invoice being approved, to {{bank}}.

4. CALL TIMES. The Artist reports at the call time on the call sheet. {{overtime_rule}}

5. DUBBING AND PROMOTION. The Artist dubs their own part and joins reasonable promotional activity agreed in advance, at no extra fee unless agreed in writing.

6. RIGHTS AND LIKENESS. The Producer owns all rights in the Artist's performance and may use the Artist's name, voice and likeness to make, distribute and promote the production, worldwide and in all media.

7. EXCLUSIVITY. During shooting days the Artist does not change their look (hair, beard, weight) without the Producer's written consent.

8. CONFIDENTIALITY. The script, story and unreleased material stay confidential. The Artist posts nothing from set without written permission.

9. TERMINATION. Either side may end this agreement with 7 days' written notice. Fees for work already done remain payable.

10. LAW. Governed by the laws of India; courts at {{city}} have jurisdiction.

For the Producer: {{signatory}}, {{designation}}

Signed electronically in CrewDesk.$t$),
('Sample: vendor services', 'vendor', 'sample', $t$SERVICES AGREEMENT
{{production}}

Date: {{today}}

BETWEEN {{company}}, PAN {{company_pan}}, GSTIN {{company_gstin}}, of {{company_address}} ("the Production")

AND {{legal_name}}, PAN {{pan}}, GSTIN {{gstin}}, of {{address}} ("the Service Provider").

1. SERVICES. The Service Provider supplies {{job}} ({{dept}}) from {{joining}} until {{end_date}}, as ordered by the Production in writing or in CrewDesk.

2. CHARGES. {{fee}}, plus GST, against tax invoices uploaded in CrewDesk. Tax is deducted at source {{tds}}.

3. PAYMENT. Within {{terms}} of the invoice being approved, to {{bank}}.

4. EQUIPMENT AND STAFF. The Service Provider is responsible for its equipment, vehicles, staff, their wages, insurance and statutory dues. Loss or damage caused by the Service Provider is its cost.

5. QUALITY AND TIMING. Services are delivered on time and in working order. Delay or failure that costs the Production shooting time may be deducted from the charges, after notice.

6. CONFIDENTIALITY. Everything seen or heard on the production stays confidential.

7. TERMINATION. Either side may end this agreement with 7 days' written notice. Services already supplied remain payable.

8. LAW. Governed by the laws of India; courts at {{city}} have jurisdiction.

For the Production: {{signatory}}, {{designation}}

Signed electronically in CrewDesk.$t$),
('Sample: non-disclosure agreement', 'nda', 'sample', $t$NON-DISCLOSURE AGREEMENT

Date: {{today}}

BETWEEN {{company}}, of {{company_address}} ("the Company")

AND {{legal_name}}, of {{address}} ("the Recipient").

1. PURPOSE. The Recipient will see confidential material about {{production}} while working as {{job}}.

2. CONFIDENTIAL MATERIAL. Scripts, story, cast, locations, schedules, budgets, footage, and anything marked or obviously confidential.

3. DUTY. The Recipient keeps the material confidential, uses it only for the production, and does not copy, post or share it without the Company's written permission.

4. EXCEPTIONS. Material that is already public through no fault of the Recipient, or that the law requires to be disclosed, after telling the Company first.

5. RETURN. On request or at the end of the engagement, the Recipient returns or deletes the material.

6. TERM. This agreement lasts during the engagement and for 3 years after the production is first released.

7. REMEDIES. The Company may seek an injunction as well as damages for a breach.

8. LAW. Governed by the laws of India; courts at {{city}} have jurisdiction.

For the Company: {{signatory}}, {{designation}}

Signed electronically in CrewDesk.$t$);
insert into public.agreement_template_versions (template_id, version, body) select id, 1, body from public.agreement_templates;
