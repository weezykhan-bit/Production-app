-- Approval chain, attendance confirmation, locked days and the task tracker.
--
-- Roles: Auditor, and Commercial Manager (the Commercial Head's associate). Accounts stays the CFO's associate.
--
-- Invoices move through one chain, and each step notifies the next people in it:
--   submitted → Auditor approves against confirmed attendance → Head of Production confirms
--   → Commercial Head or Commercial Manager approves → CFO or Accounts pays.
-- If a show has nobody in a role, the step falls back (no auditor or HOP: the owners and Line Producer;
-- nobody on the commercial side: the CFO). Nobody approves their own invoice.
--
-- Attendance: the Auditor confirms each shoot day's check-ins. A confirmed day is locked, and so is any day
-- once the day after it is over. Changing a locked day (call sheet, check-ins, status) needs permission from
-- the Commercial Head or a Commercial Manager, which opens it for 24 hours; they can also change it themselves.
-- A change to a confirmed day's check-ins sends it back to the Auditor.
--
-- Tasks: heads assign production tasks and issues; issues collect proposed solutions and one is accepted.

-- ---------------------------------------------------------------- roles
alter table public.crew drop constraint crew_role_check;
alter table public.crew add constraint crew_role_check check (role in ('hop','lp','accounts','hod','crew','vendor','auditor','commercial_mgr'));

create or replace function public.prod_finance(p uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(prod_role(p) in ('cfo','commercial','commercial_mgr','accounts'), false) $$;
create or replace function public.prod_audit(p uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(prod_role(p) in ('cfo','commercial','commercial_mgr','hop','lp','accounts','auditor'), false) $$;
-- crew can see the names and photos of the production office on their own show (tasks, approvals)
create or replace function public.person_visible(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    p_user = auth.uid()
    or exists (select 1 from company_admins where user_id = auth.uid())
    or exists (select 1 from company_admins where user_id = p_user)
    or exists (select 1 from crew me join crew them using (production_id)
               where me.user_id = auth.uid() and me.active and them.user_id = p_user
                 and (me.role not in ('crew','vendor') or them.role not in ('crew','vendor')))) $$;

-- someone holds this role on the show (owners count for their company role)
create function public.has_role(p uuid, roles text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from crew where production_id = p and active and removed_at is null and user_id is not null and role = any (roles))
      or exists (select 1 from company_admins where role = any (roles)) $$;
create function public.people_in(p uuid, roles text[]) returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct u), '{}') from (
    select user_id u from crew where production_id = p and active and removed_at is null and user_id is not null and role = any (roles)
    union select user_id from company_admins where role = any (roles)) x $$;

-- new staff roles are given by the owners
create or replace function public.onboard(p_production uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare r text := coalesce(nullif(p ->> 'role', ''), 'crew'); c crew; existing uuid; em text := nullif(lower(trim(p ->> 'email')), '');
begin
  perform must(prod_lead(p_production), 'Only the Line Producer, Head of Production, CFO or Commercial Head can onboard people');
  if r in ('hop','lp','accounts','auditor','commercial_mgr') then perform must(prod_owner(p_production), 'Only the CFO or Commercial Head can give that access'); end if;
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

-- ---------------------------------------------------------------- attendance and locked days
alter table public.shoot_days
  add column att_confirmed_at timestamptz,
  add column att_confirmed_by uuid references auth.users on delete set null;

create table public.day_unlocks (
  id            uuid primary key default gen_random_uuid(),
  production_id uuid not null references public.productions on delete cascade,
  day_id        uuid not null references public.shoot_days on delete cascade,
  requested_by  uuid references auth.users on delete set null,
  reason        text not null check (length(reason) between 4 and 500),
  at            timestamptz not null default now(),
  status        text not null default 'pending' check (status in ('pending','approved','declined')),
  decided_by    uuid references auth.users on delete set null,
  decided_at    timestamptz,
  expires_at    timestamptz,
  note          text
);
create unique index day_unlocks_one_pending on public.day_unlocks (day_id) where status = 'pending';
create index day_unlocks_prod_idx on public.day_unlocks (production_id);
alter table public.day_unlocks enable row level security;
create policy "staff" on public.day_unlocks for select using (prod_staff(production_id));

create function public.day_locked(d public.shoot_days) returns boolean language sql stable set search_path = public as $$
  select d.att_confirmed_at is not null or d.day < today_ist() - 1 $$;
-- may the caller change this day now? (open, the commercial side, or an approved permission still running)
create function public.day_editable(d public.shoot_days) returns boolean language sql stable security definer set search_path = public as $$
  select not day_locked(d) or coalesce(prod_role(d.production_id) in ('commercial','commercial_mgr'), false)
      or exists (select 1 from day_unlocks u where u.day_id = d.id and u.status = 'approved' and u.expires_at > now()) $$;
create function public.must_edit_day(d public.shoot_days) returns void language plpgsql stable set search_path = public as $$
begin
  if not day_editable(d) then
    raise exception '% is locked%. Ask the Commercial Head or a Commercial Manager for permission to change it',
      to_char(d.day, 'DD Mon'), case when d.att_confirmed_at is not null then ' (attendance confirmed)' else '' end;
  end if;
end $$;

create function public.confirm_attendance(p_day uuid) returns int
language plpgsql security definer set search_path = public as $$
declare d shoot_days; n int;
begin
  select * into d from shoot_days where id = p_day;
  perform must(d.id is not null and (prod_role(d.production_id) = 'auditor' or (not has_role(d.production_id, array['auditor']) and prod_owner(d.production_id))),
               'Only the Auditor confirms attendance');
  perform must(d.day <= today_ist(), 'Attendance can be confirmed on or after the day');
  perform must(d.status <> 'cancelled', 'This day was cancelled');
  perform must(d.att_confirmed_at is null, 'Attendance for this day is already confirmed');
  select count(*) into n from checkins where day_id = p_day and removed_at is null;
  update shoot_days set att_confirmed_at = now(), att_confirmed_by = auth.uid(), status = case when n > 0 then 'shot' else status end where id = p_day;
  perform add_log(d.production_id, 'schedule', 'Confirmed attendance for ' || to_char(d.day, 'DD Mon YYYY') || ': ' || n || ' checked in');
  return n;
end $$;

create function public.request_day_unlock(p_day uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare d shoot_days; why text := trim(coalesce(p_reason, '')); rid uuid;
begin
  select * into d from shoot_days where id = p_day;
  perform must(d.id is not null and (prod_lead(d.production_id) or prod_role(d.production_id) = 'auditor'), 'Only production leads and the Auditor can ask to change a locked day');
  perform must(day_locked(d), 'This day isn’t locked; change it directly');
  perform must(length(why) >= 4, 'Say what needs changing and why');
  begin
    insert into day_unlocks (production_id, day_id, requested_by, reason) values (d.production_id, d.id, auth.uid(), left(why, 500)) returning id into rid;
  exception when unique_violation then raise exception 'Permission for this day has already been asked for';
  end;
  perform add_log(d.production_id, 'schedule', 'Asked to change locked day ' || to_char(d.day, 'DD Mon YYYY') || ': ' || why);
  perform notify(people_in(d.production_id, array['commercial','commercial_mgr']), d.production_id, 'unlock',
    pname(auth.uid()) || ' asks to change ' || day_label(d.day), why, 'schedule');
  return rid;
end $$;

create function public.decide_day_unlock(p_request uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare q day_unlocks; d shoot_days; n text := nullif(trim(coalesce(p_note, '')), '');
begin
  select * into q from day_unlocks where id = p_request;
  perform must(q.id is not null and prod_role(q.production_id) in ('commercial','commercial_mgr'), 'Only the Commercial Head or a Commercial Manager can give this permission');
  perform must(q.status = 'pending', 'This request has already been dealt with');
  select * into d from shoot_days where id = q.day_id;
  if p_approve then
    update day_unlocks set status = 'approved', decided_by = auth.uid(), decided_at = now(), expires_at = now() + interval '24 hours', note = n where id = q.id;
    perform add_log(q.production_id, 'schedule', 'Allowed changes to ' || to_char(d.day, 'DD Mon YYYY') || ' for 24 hours' || coalesce(': ' || n, ''));
    perform notify(array[q.requested_by], q.production_id, 'unlock', 'You can change ' || day_label(d.day) || ' for 24 hours', coalesce(n, 'Permission given.'), 'schedule');
  else
    perform must(n is not null and length(n) >= 4, 'Say why, so the person who asked knows');
    update day_unlocks set status = 'declined', decided_by = auth.uid(), decided_at = now(), note = n where id = q.id;
    perform add_log(q.production_id, 'schedule', 'Refused changes to ' || to_char(d.day, 'DD Mon YYYY') || ': ' || n);
    perform notify(array[q.requested_by], q.production_id, 'unlock', 'No permission to change ' || day_label(d.day), n, 'schedule');
  end if;
end $$;

-- the schedule functions now respect locked days
create or replace function public.update_day(p_day uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare d shoot_days; n shoot_days; what text[] := '{}';
begin
  select * into d from shoot_days where id = p_day;
  perform must(d.id is not null and (prod_lead(d.production_id) or prod_role(d.production_id) = 'commercial_mgr'), 'Only the Line Producer, Head of Production, CFO or Commercial Head can change the schedule');
  perform must_edit_day(d);
  n := d;
  n.call_time := coalesce(nullif(p ->> 'call', ''), d.call_time); n.wrap_time := coalesce(nullif(p ->> 'wrap', ''), d.wrap_time);
  n.location := case when p ? 'location' then nullif(trim(p ->> 'location'), '') else d.location end;
  n.note := case when p ? 'note' then nullif(trim(p ->> 'note'), '') else d.note end;
  n.ep_from := case when p ? 'ep_from' then nullif(p ->> 'ep_from', '')::int else d.ep_from end;
  n.ep_to := case when p ? 'ep_to' then coalesce(nullif(p ->> 'ep_to', '')::int, n.ep_from) else d.ep_to end;
  perform must(n.call_time ~ '^[0-2][0-9]:[0-5][0-9]$' and n.wrap_time ~ '^[0-2][0-9]:[0-5][0-9]$', 'Enter times like 07:30');
  perform must(n.ep_from is null or n.ep_to >= n.ep_from, 'The last episode can’t be before the first');
  update shoot_days set call_time = n.call_time, wrap_time = n.wrap_time, location = n.location, note = n.note, ep_from = n.ep_from, ep_to = n.ep_to,
         reminded_at = case when n.call_time is distinct from d.call_time or n.location is distinct from d.location then null else reminded_at end
   where id = p_day;
  if n.call_time is distinct from d.call_time then what := what || ('call ' || d.call_time || ' → ' || n.call_time); end if;
  if n.wrap_time is distinct from d.wrap_time then what := what || ('wrap ' || d.wrap_time || ' → ' || n.wrap_time); end if;
  if n.location is distinct from d.location then what := what || ('location ' || coalesce(d.location, '—') || ' → ' || coalesce(n.location, '—')); end if;
  if (n.ep_from, n.ep_to) is distinct from (d.ep_from, d.ep_to) then what := what || ('episodes ' || coalesce(n.ep_from::text, '—') || coalesce('–' || nullif(n.ep_to, n.ep_from)::text, '')); end if;
  if n.note is distinct from d.note then what := what || 'note'::text; end if;
  if cardinality(what) = 0 then return; end if;
  perform add_log(d.production_id, 'schedule', 'Changed ' || to_char(d.day, 'DD Mon YYYY') || ': ' || array_to_string(what, ', ') || case when day_locked(d) then ' (locked day, with permission)' else '' end);
  if d.status = 'planned' and d.day >= today_ist() and (n.call_time, n.wrap_time, n.location) is distinct from (d.call_time, d.wrap_time, d.location) then
    perform notify(schedule_people(d.production_id), d.production_id, 'schedule',
      case when n.call_time is distinct from d.call_time then 'Call time changed: ' || day_label(d.day) else 'Schedule changed: ' || day_label(d.day) end,
      'Call ' || n.call_time || case when n.call_time is distinct from d.call_time then ' (was ' || d.call_time || ')' else '' end
        || ' · wrap ~' || n.wrap_time || coalesce(' · ' || n.location, '') || coalesce(' · ' || n.note, ''), 'schedule');
  end if;
end $$;

create or replace function public.set_day_status(p_day uuid, p_status text, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare d shoot_days; why text := nullif(trim(coalesce(p_note, '')), '');
begin
  select * into d from shoot_days where id = p_day;
  perform must(d.id is not null and prod_lead(d.production_id), 'Only the Line Producer, Head of Production, CFO or Commercial Head can change the schedule');
  perform must(p_status in ('planned','shot','cancelled'), 'Unknown status');
  if p_status = d.status then return; end if;
  perform must_edit_day(d);
  if p_status = 'shot' and d.day > today_ist() then raise exception 'A day can be marked shot only on or after its date'; end if;
  if p_status <> 'shot' and exists (select 1 from checkins where day_id = p_day and removed_at is null) then
    raise exception 'People are checked in on this day. Remove their check-ins first, or their days drop off their invoices';
  end if;
  update shoot_days set status = p_status, note = case when p_status = 'cancelled' then coalesce(why, note) else note end where id = p_day;
  perform add_log(d.production_id, 'schedule', 'Marked ' || to_char(d.day, 'DD Mon YYYY') || ' as ' || case p_status when 'planned' then 'scheduled' else p_status end || coalesce(': ' || why, ''));
  if d.day >= today_ist() and p_status = 'cancelled' then
    perform notify(schedule_people(d.production_id), d.production_id, 'schedule', 'Shoot cancelled: ' || day_label(d.day), coalesce(why, 'No shoot on this day.') , 'schedule');
  elsif d.day >= today_ist() and p_status = 'planned' and d.status = 'cancelled' then
    perform notify(schedule_people(d.production_id), d.production_id, 'schedule', 'Shoot is back on: ' || day_label(d.day),
      'Call ' || d.call_time || coalesce(' · ' || d.location, ''), 'schedule');
  end if;
end $$;

create or replace function public.check_in(p_day uuid, p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare d shoot_days; c crew;
begin
  select * into d from shoot_days where id = p_day;
  perform must(d.id is not null and prod_lead(d.production_id), 'Only the Line Producer, Head of Production, CFO or Commercial Head can check crew in');
  if d.status = 'cancelled' then raise exception 'This day is cancelled'; end if;
  if d.day > today_ist() then raise exception 'Check-in opens on the day'; end if;
  perform must_edit_day(d);
  select * into c from crew where production_id = d.production_id and crew_code = upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  if c.id is null or c.user_id is null then raise exception 'No one on this production has that Crew ID'; end if;
  if not c.active then raise exception '% is no longer active on this production', crew_name(c); end if;
  if c.ag_status <> 'countersigned' then raise exception '% isn’t fully onboarded yet', crew_name(c); end if;
  if exists (select 1 from checkins where day_id = p_day and user_id = c.user_id and removed_at is null) then raise exception '% is already checked in', crew_name(c); end if;
  insert into checkins (day_id, user_id, by) values (p_day, c.user_id, auth.uid())
  on conflict (day_id, user_id) do update set removed_at = null, at = now(), by = auth.uid();
  update shoot_days set status = case when status = 'planned' then 'shot' else status end, att_confirmed_at = null, att_confirmed_by = null where id = p_day;
  perform add_log(d.production_id, 'schedule', 'Checked in ' || crew_name(c) || ' for ' || to_char(d.day, 'DD Mon YYYY')
    || case when d.att_confirmed_at is not null then ' (confirmed day, sent back to the Auditor)' else '' end, c.id);
  return crew_name(c);
end $$;

create or replace function public.remove_checkin(p_day uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d shoot_days;
begin
  select * into d from shoot_days where id = p_day;
  perform must(d.id is not null and prod_lead(d.production_id), 'Only production leads can change check-ins');
  perform must_edit_day(d);
  update checkins set removed_at = now() where day_id = p_day and user_id = p_user and removed_at is null;
  if not found then raise exception 'That person isn’t checked in'; end if;
  update shoot_days set att_confirmed_at = null, att_confirmed_by = null where id = p_day;
  perform add_log(d.production_id, 'schedule', 'Removed ' || pname(p_user) || '’s check-in for ' || to_char(d.day, 'DD Mon YYYY')
    || case when d.att_confirmed_at is not null then ' (confirmed day, sent back to the Auditor)' else '' end);
end $$;

-- ---------------------------------------------------------------- the invoice chain
alter table public.crew_invoices drop constraint crew_invoices_status_check;
update public.crew_invoices set status = 'audited' where status = 'hod_ok';
alter table public.crew_invoices add constraint crew_invoices_status_check check (status in ('submitted','audited','hop_ok','approved','paid','rejected'));
alter table public.crew_invoices
  add column audited_by uuid references auth.users on delete set null, add column audited_at timestamptz,
  add column hop_by uuid references auth.users on delete set null, add column hop_at timestamptz;
update public.crew_invoices set audited_by = hod_by, audited_at = hod_at where hod_at is not null;

drop function public.hod_approve(uuid);
drop function public.final_approve(uuid);

-- who may act on an invoice at its current step
create function public.invoice_step_ok(i public.crew_invoices) returns boolean
language sql stable security definer set search_path = public as $$
  select case i.status
    when 'submitted' then prod_role(i.production_id) = 'auditor'
      or (not has_role(i.production_id, array['auditor']) and prod_role(i.production_id) in ('cfo','commercial','lp'))
    when 'audited' then prod_role(i.production_id) = 'hop'
      or (not has_role(i.production_id, array['hop']) and prod_role(i.production_id) in ('cfo','commercial','lp'))
    when 'hop_ok' then prod_role(i.production_id) in ('commercial','commercial_mgr')
      or (not has_role(i.production_id, array['commercial','commercial_mgr']) and prod_role(i.production_id) = 'cfo')
    else false end $$;
create function public.step_people(p uuid, st text) returns uuid[]
language sql stable security definer set search_path = public as $$
  select case st
    when 'submitted' then case when has_role(p, array['auditor']) then people_in(p, array['auditor']) else people_in(p, array['cfo','commercial','lp']) end
    when 'audited' then case when has_role(p, array['hop']) then people_in(p, array['hop']) else people_in(p, array['cfo','commercial','lp']) end
    when 'hop_ok' then case when has_role(p, array['commercial','commercial_mgr']) then people_in(p, array['commercial','commercial_mgr']) else people_in(p, array['cfo']) end
    when 'approved' then people_in(p, array['cfo','accounts'])
    else '{}' end $$;

create function public.advance_invoice(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare i crew_invoices; ok int; nxt text;
begin
  select * into i from crew_invoices where id = p_id;
  perform must(i.id is not null, 'No such invoice');
  perform must(i.status in ('submitted','audited','hop_ok'), 'This invoice isn’t waiting for an approval');
  perform must(i.user_id <> auth.uid(), 'You can’t approve your own invoice');
  perform must(invoice_step_ok(i), case i.status when 'submitted' then 'The Auditor approves this step' when 'audited' then 'The Head of Production confirms this step'
                                    else 'The Commercial Head or a Commercial Manager approves this step' end);
  if i.status = 'submitted' and i.unit = 'day' then
    select count(*) into ok from checkins k join shoot_days d on d.id = k.day_id
     where k.user_id = i.user_id and k.removed_at is null and d.production_id = i.production_id
       and d.day between i.period_from and i.period_to and d.att_confirmed_at is not null;
    if ok < i.qty then
      raise exception 'Only % confirmed day% at the gate for % in this period, but the invoice claims %. Confirm the attendance first, or reject it',
        ok, case when ok = 1 then '' else 's' end, pname(i.user_id), i.qty;
    end if;
  end if;
  nxt := case i.status when 'submitted' then 'audited' when 'audited' then 'hop_ok' else 'approved' end;
  update crew_invoices set status = nxt,
    audited_by = case when nxt = 'audited' then auth.uid() else audited_by end, audited_at = case when nxt = 'audited' then now() else audited_at end,
    hop_by = case when nxt = 'hop_ok' then auth.uid() else hop_by end, hop_at = case when nxt = 'hop_ok' then now() else hop_at end,
    approved_by = case when nxt = 'approved' then auth.uid() else approved_by end, approved_at = case when nxt = 'approved' then now() else approved_at end
  where id = p_id;
  perform add_log(i.production_id, 'invoice', case nxt when 'audited' then 'Audited ' when 'hop_ok' then 'HOP confirmed ' else 'Approved for payment ' end || i.no || ' (' || pname(i.user_id) || ')', i.crew_id, i.id);
  return nxt;
end $$;

create or replace function public.reject_crew_invoice(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare i crew_invoices;
begin
  select * into i from crew_invoices where id = p_id;
  perform must(i.id is not null, 'No such invoice');
  perform must(i.status in ('submitted','audited','hop_ok'), 'Only an invoice still in approval can be rejected');
  perform must(i.user_id <> auth.uid(), 'You can’t reject your own invoice');
  perform must(invoice_step_ok(i) or prod_owner(i.production_id), 'You can’t reject this invoice at this step');
  perform must(length(trim(coalesce(p_reason, ''))) >= 4, 'Say why, so they can fix it and resubmit');
  update crew_invoices set status = 'rejected', reason = trim(p_reason) where id = p_id;
  perform add_log(i.production_id, 'invoice', 'Rejected ' || i.no || ': ' || trim(p_reason), i.crew_id, i.id);
end $$;

create or replace function public.pay_invoices(p_production uuid, p_ids uuid[], p_ref text) returns int
language plpgsql security definer set search_path = public as $$
declare n int; nos text; total bigint;
begin
  perform must(prod_role(p_production) in ('cfo','accounts'), 'Only the CFO or Accounts can record payments');
  perform must(length(trim(coalesce(p_ref, ''))) >= 6, 'Enter the bank reference (UTR or batch ID)');
  select count(*), string_agg(no, ', ' order by no), sum(payable) into n, nos, total
    from crew_invoices where id = any(p_ids) and production_id = p_production and status = 'approved';
  perform must(n > 0 and n = cardinality(p_ids), 'Pick approved invoices that haven’t been paid yet');
  update crew_invoices set status = 'paid', paid_at = now(), utr = trim(p_ref) where id = any(p_ids);
  perform add_log(p_production, 'payment', case when n = 1 then 'Marked ' || nos || ' paid · UTR ' || trim(p_ref) else 'Paid ' || nos || ' in one run · ₹' || total || ' · ref ' || trim(p_ref) end,
                  null, case when n = 1 then p_ids[1] end);
  return n;
end $$;

create or replace function public.set_invoice_adjustments(p_id uuid, p_items jsonb, p_remarks text) returns bigint
language plpgsql security definer set search_path = public as $$
declare i crew_invoices; it jsonb; clean jsonb := '[]'; total bigint := 0; a bigint; k text; n text;
        labels jsonb := '{"advance":"Advance recovered","damage":"Loss or damage","stay":"Food, stay or travel","penalty":"Late or penalty","other":"Other"}';
        rem text := nullif(trim(coalesce(p_remarks, '')), ''); before text;
begin
  select * into i from crew_invoices where id = p_id;
  perform must(i.id is not null, 'No such invoice');
  perform must(prod_role(i.production_id) in ('cfo','commercial','commercial_mgr','hop','lp','accounts','auditor'),
               'Only the production office can add deductions');
  perform must(i.user_id <> auth.uid(), 'You can’t adjust your own invoice');
  perform must(i.status in ('submitted','audited','hop_ok','approved'), 'Deductions can only change before the invoice is paid');
  perform must(i.tally_purchase is null, 'This invoice is already in Tally. Reject it and have it raised again, or adjust it in Tally');
  perform must(jsonb_typeof(coalesce(p_items, '[]')) = 'array' and jsonb_array_length(coalesce(p_items, '[]')) <= 10, 'Up to 10 deductions');
  perform must(rem is null or length(rem) <= 500, 'Keep the remark under 500 characters');
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]')) loop
    k := it ->> 'type'; n := nullif(trim(coalesce(it ->> 'note', '')), '');
    perform must(labels ? k, 'Pick what each deduction is for');
    begin a := (it ->> 'amount')::numeric::bigint; exception when others then a := null; end;
    perform must(a > 0, 'Each deduction needs an amount in rupees');
    perform must(n is not null and length(n) >= 3, 'Say what each deduction is for, so the person understands it');
    perform must(length(n) <= 200, 'Keep each note under 200 characters');
    clean := clean || jsonb_build_object('type', k, 'label', labels ->> k, 'amount', a, 'note', n);
    total := total + a;
  end loop;
  perform must(total <= i.amount + i.gst - i.tds, 'Deductions can’t be more than the amount payable (₹' || (i.amount + i.gst - i.tds) || ')');
  before := 'deductions ₹' || i.deduction || coalesce(', remark “' || i.remarks || '”', '');
  update crew_invoices set deductions = clean, deduction = total, remarks = rem, payable = amount + gst - tds - total,
         adjusted_by = auth.uid(), adjusted_at = now()
   where id = p_id;
  perform add_log(i.production_id, 'invoice',
    'Updated ' || i.no || ' (' || pname(i.user_id) || '): deductions ₹' || total || coalesce(', remark “' || rem || '”', '') || '; was ' || before,
    i.crew_id, i.id);
  return i.amount + i.gst - i.tds - total;
end $$;

-- removing someone: any invoice still in the chain blocks it
create or replace function public.remove_person(p_crew uuid, p_reason text) returns text
language plpgsql security definer set search_path = public as $$
declare c crew; why text := trim(coalesce(p_reason, '')); pn text; who text; keep boolean; outcome text;
begin
  select * into c from crew where id = p_crew;
  perform must(c.id is not null and prod_owner(c.production_id), 'Only the CFO or Commercial Head can remove someone');
  perform must(c.removed_at is null, 'They’re already removed');
  perform must(c.user_id is distinct from auth.uid(), 'You can’t remove yourself');
  perform must(length(why) >= 4, 'Say why they’re being removed');
  perform must(not exists (select 1 from crew_invoices where crew_id = c.id and status in ('submitted','audited','hop_ok','approved')),
               'They have an invoice in approval or waiting for payment. Pay or reject it first');
  pn := (select name from productions where id = c.production_id); who := crew_name(c);
  keep := c.ag_status in ('signed','countersigned') or exists (select 1 from crew_invoices where crew_id = c.id)
          or (c.user_id is not null and exists (select 1 from checkins k join shoot_days d on d.id = k.day_id where k.user_id = c.user_id and d.production_id = c.production_id));
  update removal_requests set status = 'approved', decided_by = auth.uid(), decided_at = now() where crew_id = c.id and status = 'pending';
  if c.user_id is not null then
    perform notify(array[c.user_id], c.production_id, 'removed', 'You were removed from ' || pn, 'Ask the production office if you think this is a mistake.', 'home');
  end if;
  if keep then
    update crew set active = false, removed_at = now(), removed_by = auth.uid(), removed_reason = why where id = c.id;
    perform add_log(c.production_id, 'onboard', 'Removed ' || who || ' from the production: ' || why || ' (their invoices and agreement stay on record)', c.id);
    outcome := 'removed';
  else
    perform add_log(c.production_id, 'onboard', 'Deleted ' || who || ' (' || coalesce(c.job, 'no role') || '): ' || why, null);
    delete from crew where id = c.id;
    outcome := 'deleted';
  end if;
  return outcome;
end $$;

-- each step tells the person where their invoice is, and the next people what's waiting for them
create or replace function public.invoice_notify() returns trigger
language plpgsql set search_path = public as $$
declare who text := coalesce(pname(new.user_id), 'Crew'); amt text := inr(new.payable);
begin
  if tg_op = 'INSERT' then
    perform notify(array[new.user_id], new.production_id, 'invoice', 'Invoice ' || new.no || ' submitted', amt || ' payable · next: the Auditor checks your days.', 'invoices', true);
    perform notify(step_people(new.production_id, 'submitted'), new.production_id, 'invoice', 'Invoice ' || new.no || ' to audit', who || ' · ' || amt || ' · check the days against confirmed attendance', 'invoices');
  elsif new.status is distinct from old.status then
    if new.status = 'audited' then
      perform notify(array[new.user_id], new.production_id, 'invoice', 'Invoice ' || new.no || ' passed the audit', 'Step 2 of 4: with the Head of Production.', 'invoices');
      perform notify(step_people(new.production_id, 'audited'), new.production_id, 'invoice', 'Invoice ' || new.no || ' to confirm', who || ' · ' || amt || ' · audited', 'invoices');
    elsif new.status = 'hop_ok' then
      perform notify(array[new.user_id], new.production_id, 'invoice', 'Invoice ' || new.no || ' confirmed by the Head of Production', 'Step 3 of 4: with the Commercial Head.', 'invoices');
      perform notify(step_people(new.production_id, 'hop_ok'), new.production_id, 'invoice', 'Invoice ' || new.no || ' needs commercial approval', who || ' · ' || amt, 'invoices');
    elsif new.status = 'approved' then
      perform notify(array[new.user_id], new.production_id, 'invoice', 'Invoice ' || new.no || ' approved for payment', 'Step 4 of 4: ' || amt || ' will be paid within your payment terms.', 'invoices');
      perform notify(step_people(new.production_id, 'approved'), new.production_id, 'invoice', 'Invoice ' || new.no || ' ready to pay', who || ' · ' || amt, 'finance');
    elsif new.status = 'paid' then
      perform notify(array[new.user_id], new.production_id, 'payment', 'Invoice ' || new.no || ' paid', amt || ' · bank reference ' || coalesce(new.utr, '—'), 'invoices');
    elsif new.status = 'rejected' then
      perform notify(array[new.user_id], new.production_id, 'invoice', 'Invoice ' || new.no || ' was rejected', coalesce(new.reason, '') || ' · fix it and submit again.', 'invoices');
    end if;
  end if;
  return null;
end $$;

alter policy "own, leads and finance, or HOD's department" on public.crew_invoices using (user_id = (select auth.uid())
  or prod_role(production_id) = any (array['cfo','commercial','commercial_mgr','hop','lp','accounts','auditor'])
  or (prod_role(production_id) = 'hod' and dept = (select c.dept from crew c where c.production_id = crew_invoices.production_id and c.user_id = (select auth.uid()))));

-- ---------------------------------------------------------------- tasks
create table public.tasks (
  id            uuid primary key default gen_random_uuid(),
  production_id uuid not null references public.productions on delete cascade,
  title         text not null check (length(trim(title)) between 3 and 140),
  details       text check (details is null or length(details) <= 4000),
  kind          text not null default 'task' check (kind in ('task','issue')),
  status        text not null default 'todo' check (status in ('todo','working','stuck','done')),
  priority      text not null default 'medium' check (priority in ('low','medium','high','critical')),
  dept          text,
  due           date,
  day_id        uuid references public.shoot_days on delete set null,
  created_by    uuid references auth.users on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  done_at       timestamptz,
  reminded_on   date
);
create index tasks_prod_idx on public.tasks (production_id, status);
create table public.task_assignees (
  task_id uuid not null references public.tasks on delete cascade,
  user_id uuid not null references auth.users on delete cascade,
  primary key (task_id, user_id)
);
create index task_assignees_user_idx on public.task_assignees (user_id);
create table public.task_updates (
  id       bigint generated always as identity primary key,
  task_id  uuid not null references public.tasks on delete cascade,
  by       uuid references auth.users on delete set null,
  at       timestamptz not null default now(),
  kind     text not null check (kind in ('comment','solution','status','assign','accepted')),
  body     text not null check (length(body) between 1 and 2000),
  accepted boolean not null default false
);
create index task_updates_task_idx on public.task_updates (task_id, id);

create function public.task_visible(t uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from tasks x where x.id = t and (prod_staff(x.production_id) or x.created_by = auth.uid()
           or exists (select 1 from task_assignees a where a.task_id = x.id and a.user_id = auth.uid()))) $$;
alter table public.tasks enable row level security;
alter table public.task_assignees enable row level security;
alter table public.task_updates enable row level security;
create policy "staff, creator or assignee" on public.tasks for select using (task_visible(id));
create policy "with the task" on public.task_assignees for select using (task_visible(task_id));
create policy "with the task" on public.task_updates for select using (task_visible(task_id));

create function public.task_head(p uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(prod_role(p) in ('cfo','commercial','commercial_mgr','hop','lp','auditor','hod'), false) $$;
create function public.my_dept(p uuid) returns text language sql stable security definer set search_path = public as $$
  select dept from crew where production_id = p and user_id = auth.uid() and active limit 1 $$;
create function public.task_people(t uuid) returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct u), '{}') from (select created_by u from tasks where id = t union select user_id from task_assignees where task_id = t) x where u is not null $$;

-- create or edit a task; heads only (an HOD within their department)
create function public.save_task(p_production uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare t tasks; tid uuid := nullif(p ->> 'id', '')::uuid; r text := prod_role(p_production); d text := nullif(trim(p ->> 'dept'), '');
        want uuid[]; had uuid[] := '{}'; added uuid[]; u uuid; v_title text := trim(coalesce(p ->> 'title', ''));
begin
  perform must(task_head(p_production), 'Only heads of the production assign tasks');
  if r = 'hod' then d := my_dept(p_production); end if;
  perform must(length(v_title) >= 3, 'Give the task a title');
  select coalesce(array_agg(distinct x::uuid), '{}') into want from jsonb_array_elements_text(coalesce(p -> 'assignees', '[]')) x;
  foreach u in array want loop
    perform must(exists (select 1 from crew where production_id = p_production and user_id = u and active and removed_at is null)
                 or exists (select 1 from company_admins where user_id = u), 'Assign people who are on this production');
    if r = 'hod' then perform must(exists (select 1 from crew where production_id = p_production and user_id = u and dept = d) or u = auth.uid(),
                                   'Heads of department assign tasks within their own department'); end if;
  end loop;
  if tid is null then
    insert into tasks (production_id, title, details, kind, priority, dept, due, day_id, created_by)
    values (p_production, v_title, nullif(trim(p ->> 'details'), ''), coalesce(nullif(p ->> 'kind', ''), 'task'), coalesce(nullif(p ->> 'priority', ''), 'medium'),
            d, nullif(p ->> 'due', '')::date, nullif(p ->> 'day_id', '')::uuid, auth.uid())
    returning * into t;
    perform add_log(p_production, 'task', 'Created ' || case t.kind when 'issue' then 'issue' else 'task' end || ' “' || t.title || '”');
  else
    select * into t from tasks where id = tid and production_id = p_production;
    perform must(t.id is not null, 'No such task');
    perform must(r <> 'hod' or t.dept is not distinct from d, 'Heads of department edit tasks in their own department');
    select coalesce(array_agg(user_id), '{}') into had from task_assignees where task_id = tid;
    update tasks set title = v_title, details = nullif(trim(p ->> 'details'), ''), kind = coalesce(nullif(p ->> 'kind', ''), kind),
      priority = coalesce(nullif(p ->> 'priority', ''), priority), dept = d, due = nullif(p ->> 'due', '')::date, day_id = nullif(p ->> 'day_id', '')::uuid, updated_at = now()
    where id = tid returning * into t;
    delete from task_assignees where task_id = tid and not (user_id = any (want));
  end if;
  insert into task_assignees (task_id, user_id) select t.id, x from unnest(want) x on conflict do nothing;
  select coalesce(array_agg(x), '{}') into added from unnest(want) x where not (x = any (had));
  if cardinality(added) > 0 then
    insert into task_updates (task_id, by, kind, body) values (t.id, auth.uid(), 'assign', 'Assigned ' || (select string_agg(coalesce(pname(x), 'someone'), ', ') from unnest(added) x));
    perform notify(added, p_production, 'task', case t.kind when 'issue' then 'New issue for you: ' else 'New task for you: ' end || t.title,
      initcap(t.priority) || ' priority' || coalesce(' · due ' || to_char(t.due, 'Dy DD Mon'), '') || ' · from ' || coalesce(pname(auth.uid()), 'the office'), 'tasks');
  end if;
  return t.id;
end $$;

create function public.set_task_status(p_task uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare t tasks; labels jsonb := '{"todo":"To do","working":"Working on it","stuck":"Stuck","done":"Done"}';
begin
  select * into t from tasks where id = p_task;
  perform must(t.id is not null and (task_head(t.production_id) or t.created_by = auth.uid()
               or exists (select 1 from task_assignees where task_id = t.id and user_id = auth.uid())), 'Only the people on this task can change it');
  perform must(labels ? p_status, 'Unknown status');
  if p_status = t.status then return; end if;
  update tasks set status = p_status, updated_at = now(), done_at = case when p_status = 'done' then now() else null end where id = p_task;
  insert into task_updates (task_id, by, kind, body) values (p_task, auth.uid(), 'status', (labels ->> t.status) || ' → ' || (labels ->> p_status));
  perform add_log(t.production_id, 'task', '“' || t.title || '”: ' || (labels ->> p_status));
  perform notify(task_people(p_task), t.production_id, 'task', '“' || t.title || '” is ' || lower(labels ->> p_status),
    'Changed by ' || coalesce(pname(auth.uid()), 'someone'), 'tasks');
end $$;

create function public.add_task_update(p_task uuid, p_body text, p_kind text default 'comment') returns bigint
language plpgsql security definer set search_path = public as $$
declare t tasks; b text := trim(coalesce(p_body, '')); nid bigint;
begin
  select * into t from tasks where id = p_task;
  perform must(t.id is not null and task_visible(p_task), 'No such task');
  perform must(p_kind in ('comment','solution'), 'Post an update or a proposed solution');
  perform must(p_kind = 'comment' or t.kind = 'issue', 'Solutions are proposed on issues');
  perform must(length(b) >= 2, 'Write something first');
  insert into task_updates (task_id, by, kind, body) values (p_task, auth.uid(), p_kind, left(b, 2000)) returning id into nid;
  update tasks set updated_at = now() where id = p_task;
  perform add_log(t.production_id, 'task', case p_kind when 'solution' then 'Proposed a solution on “' else 'Updated “' end || t.title || '”');
  perform notify(task_people(p_task), t.production_id, 'task',
    coalesce(pname(auth.uid()), 'Someone') || case p_kind when 'solution' then ' proposed a solution: ' else ' on ' end || t.title, left(b, 140), 'tasks');
  return nid;
end $$;

create function public.accept_solution(p_update bigint) returns void
language plpgsql security definer set search_path = public as $$
declare u task_updates; t tasks;
begin
  select * into u from task_updates where id = p_update;
  select * into t from tasks where id = u.task_id;
  perform must(u.id is not null and u.kind = 'solution', 'Pick a proposed solution');
  perform must(task_head(t.production_id) or t.created_by = auth.uid(), 'Heads or whoever raised the issue accept a solution');
  update task_updates set accepted = (id = p_update) where task_id = t.id and kind = 'solution';
  update tasks set status = 'done', done_at = now(), updated_at = now() where id = t.id;
  insert into task_updates (task_id, by, kind, body) values (t.id, auth.uid(), 'accepted', 'Accepted a solution and closed the issue');
  perform add_log(t.production_id, 'task', 'Accepted a solution for “' || t.title || '”');
  perform notify(task_people(t.id) || array[u."by"], t.production_id, 'task', 'Solution accepted: ' || t.title, left(u.body, 140), 'tasks');
end $$;

create function public.delete_task(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t tasks;
begin
  select * into t from tasks where id = p_task;
  perform must(t.id is not null and (t.created_by = auth.uid() or prod_owner(t.production_id) or prod_lead(t.production_id)), 'Only whoever created it or production leads can delete a task');
  delete from tasks where id = p_task;
  perform add_log(t.production_id, 'task', 'Deleted task “' || t.title || '”');
end $$;

-- due tomorrow: a nudge at 6 pm IST with the call reminders
create function public.send_task_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare t tasks; n int := 0;
begin
  for t in select * from tasks where due = today_ist() + 1 and status <> 'done' and reminded_on is distinct from today_ist() loop
    perform notify((select coalesce(array_agg(user_id), '{}') from task_assignees where task_id = t.id), t.production_id, 'task',
      'Due tomorrow: ' || t.title, initcap(t.priority) || ' priority · ' || case t.status when 'stuck' then 'marked stuck' when 'working' then 'in progress' else 'not started' end, 'tasks', true);
    update tasks set reminded_on = today_ist() where id = t.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.send_task_reminders() from public, anon, authenticated;
do $$ begin
  perform cron.schedule('crewdesk-task-reminders', '31 12 * * *', 'select public.send_task_reminders()');
exception when others then raise notice 'pg_cron not available here; task reminders are not scheduled (%)', sqlerrm;
end $$;

-- live updates: task changes reach open screens through the activity pulse; new functions stay off-limits to visitors
revoke execute on all functions in schema public from public, anon;
grant execute on function public.login_email(text), public.username_available(text) to anon;
revoke execute on function public.send_call_reminders(), public.send_task_reminders() from authenticated;
