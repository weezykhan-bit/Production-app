-- Schedule alerts, and fixes from a security and correctness review.
--
-- Schedule: cast, crew and vendors on a show are told when shoot days are planned, when a day's call time,
-- wrap or location changes, when a day is cancelled or put back, and the evening before each shoot day
-- (6 pm IST) with tomorrow's call time and location. Shoot days can now be edited after planning.
--
-- Fixes:
-- * profiles had an "edit own profile" policy left from the first version of the app, so anyone could change
--   their own bank account, PAN or document paths through the API without the checks or the activity log.
--   Profiles now change only through the checked functions.
-- * A changed bank account is logged with the old and new last digits, and Finance is told, so a payment
--   can't quietly go to a different account.
-- * A day with people checked in can no longer be cancelled or moved back to scheduled (it dropped their
--   days from their invoices).
-- * Signed-out visitors can no longer call the app's functions (only the two the sign-in screen needs),
--   and the old app's functions can no longer be called at all.
-- * Row-level security checks the signed-in user once per query instead of once per row, and the busiest
--   foreign keys are indexed.

-- ---------------------------------------------------------------- who hears about the schedule
create function public.schedule_people(p uuid) returns uuid[]
language sql stable set search_path = public as $$
  select coalesce(array_agg(distinct user_id), '{}') from crew where production_id = p and active and removed_at is null and user_id is not null $$;

create function public.day_label(d date) returns text language sql immutable as $$ select to_char(d, 'Dy DD Mon') $$;

-- plan_days: same as before, plus one notice to everyone on the show (not one per day)
create or replace function public.plan_days(p_production uuid, p jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare d date := (p ->> 'from')::date; t date := (p ->> 'to')::date; per int := greatest(0, coalesce((p ->> 'eps_per_day')::int, 0));
        ep int := greatest(1, coalesce((p ->> 'start_ep')::int, 1)); n int := 0; ins int; first shoot_days; last shoot_days;
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
  select * into first from shoot_days where production_id = p_production and day between (p ->> 'from')::date and t and status = 'planned' order by day limit 1;
  select * into last from shoot_days where production_id = p_production and day between (p ->> 'from')::date and t and status = 'planned' order by day desc limit 1;
  perform notify(schedule_people(p_production), p_production, 'schedule',
    case when n = 1 then 'New shoot day: ' || day_label(first.day) else n || ' new shoot days: ' || to_char(first.day, 'DD Mon') || ' – ' || to_char(last.day, 'DD Mon') end,
    'First call ' || day_label(first.day) || ' at ' || first.call_time || coalesce(' · ' || first.location, '') || coalesce(' · Ep ' || first.ep_from, '') || '. See Shoot schedule for every day.',
    'schedule');
  return n;
end $$;

-- edit a planned day: call time, wrap, location, episodes, note
create function public.update_day(p_day uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare d shoot_days; n shoot_days; what text[] := '{}';
begin
  select * into d from shoot_days where id = p_day;
  perform must(d.id is not null and prod_lead(d.production_id), 'Only the Line Producer, Head of Production, CFO or Commercial Head can change the schedule');
  perform must(d.status <> 'shot', 'This day is already shot');
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
  perform add_log(d.production_id, 'schedule', 'Changed ' || to_char(d.day, 'DD Mon YYYY') || ': ' || array_to_string(what, ', '));
  -- people only need to hear about changes that move them, on days still ahead
  if d.status = 'planned' and d.day >= today_ist() and (n.call_time, n.wrap_time, n.location) is distinct from (d.call_time, d.wrap_time, d.location) then
    perform notify(schedule_people(d.production_id), d.production_id, 'schedule',
      case when n.call_time is distinct from d.call_time then 'Call time changed: ' || day_label(d.day) else 'Schedule changed: ' || day_label(d.day) end,
      'Call ' || n.call_time || case when n.call_time is distinct from d.call_time then ' (was ' || d.call_time || ')' else '' end
        || ' · wrap ~' || n.wrap_time || coalesce(' · ' || n.location, '') || coalesce(' · ' || n.note, ''), 'schedule');
  end if;
end $$;

-- cancel, put back or mark shot; a reason travels with a cancellation
drop function public.set_day_status(uuid, text);
create function public.set_day_status(p_day uuid, p_status text, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare d shoot_days; why text := nullif(trim(coalesce(p_note, '')), '');
begin
  select * into d from shoot_days where id = p_day;
  perform must(d.id is not null and prod_lead(d.production_id), 'Only the Line Producer, Head of Production, CFO or Commercial Head can change the schedule');
  perform must(p_status in ('planned','shot','cancelled'), 'Unknown status');
  if p_status = d.status then return; end if;
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

-- the evening-before reminder, run at 6 pm IST by pg_cron (and safe to run more than once)
alter table public.shoot_days add column reminded_at timestamptz;
create function public.send_call_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare d shoot_days; n int := 0;
begin
  for d in select * from shoot_days where day = today_ist() + 1 and status = 'planned' and reminded_at is null loop
    perform notify(schedule_people(d.production_id), d.production_id, 'call', 'Tomorrow: call ' || d.call_time || coalesce(' at ' || d.location, ''),
      day_label(d.day) || coalesce(' · Ep ' || d.ep_from || coalesce('–' || nullif(d.ep_to, d.ep_from), ''), '') || ' · wrap ~' || d.wrap_time
        || coalesce(' · ' || d.note, '') || '. Show your Crew ID at the gate.', 'schedule', true);
    update shoot_days set reminded_at = now() where id = d.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.send_call_reminders() from public, anon, authenticated;
do $$ begin
  create extension if not exists pg_cron;
  perform cron.schedule('crewdesk-call-reminders', '30 12 * * *', 'select public.send_call_reminders()');   -- 12:30 UTC = 18:00 IST
exception when others then raise notice 'pg_cron not available here; call reminders are not scheduled (%)', sqlerrm;
end $$;

-- ---------------------------------------------------------------- profiles change only through the checked functions
drop policy if exists "edit own profile" on public.profiles;

-- a new bank account is logged and Finance is told
create or replace function public.save_profile(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare was boolean; old profiles; v_pan text := upper(trim(p ->> 'pan')); v_g text := nullif(upper(trim(p ->> 'gstin')), '');
        v_acct text := regexp_replace(coalesce(p ->> 'bank_account', ''), '\s', '', 'g'); v_ifsc text := upper(trim(p ->> 'bank_ifsc')); c crew;
begin
  perform must(auth.uid() is not null, 'Sign in first');
  if v_g is not null then perform must(substr(v_g, 3, 10) = v_pan, 'Your GSTIN must contain your PAN (characters 3 to 12)'); end if;
  select * into old from profiles where id = auth.uid();
  was := profile_ready(old);
  update profiles set legal_name = trim(p ->> 'legal'), phone = nullif(trim(p ->> 'phone'), ''), emergency = nullif(trim(p ->> 'emergency'), ''),
    address = trim(p ->> 'address'), pan = v_pan, gstin = v_g, state_code = coalesce(substr(v_g, 1, 2), state_code),
    bank_holder = trim(p ->> 'bank_holder'), bank_name = nullif(trim(p ->> 'bank_name'), ''),
    bank_account = v_acct, bank_ifsc = v_ifsc,
    full_name = coalesce(nullif(trim(p ->> 'full_name'), ''), full_name)
  where id = auth.uid();
  for c in select * from crew where user_id = auth.uid() and removed_at is null loop
    if old.bank_account is not null and (old.bank_account, old.bank_ifsc) is distinct from (v_acct, v_ifsc) then
      perform add_log(c.production_id, 'profile', 'Changed bank account: ••' || right(old.bank_account, 4) || ' (' || coalesce(old.bank_ifsc, '') || ') → ••' || right(v_acct, 4) || ' (' || v_ifsc || ')', c.id);
      perform notify(finance_of(c.production_id), c.production_id, 'bank', pname(auth.uid()) || ' changed their bank account',
        'Now ••' || right(v_acct, 4) || ' · ' || v_ifsc || ' (was ••' || right(old.bank_account, 4) || '). Check it before the next payment run.', 'finance');
    else
      perform add_log(c.production_id, 'profile', case when was then 'Updated profile and bank details' else 'Completed profile and bank details' end, c.id);
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------- who may call what
-- signed-out visitors: only what the sign-in screen needs (functions are callable by everyone by default)
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated, service_role;
grant execute on function public.login_email(text), public.username_available(text) to anon;
alter default privileges in schema public revoke execute on functions from public, anon;
alter default privileges in schema public grant execute on functions to authenticated, service_role;
-- the reminder job is for pg_cron only
revoke execute on function public.send_call_reminders() from authenticated;
-- the first version of the app is retired; its functions stay for its data but nobody can call them
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = any (array['approve_invoice','can_manage','can_pay','can_see_kyc','contract_fields','cost_report',
             'countersign_contract','create_contract','create_payment_batch','create_project','edit_contract','hod_approve_invoice','is_member',
             'join_project','log_contract','mark_batch_paid','mark_call_sheet_viewed','my_role','publish_call_sheet','reject_invoice','render_template',
             'save_call_sheet','save_day_report','save_template','scan_id_card','send_contract','set_budget','shares_project','sign_contract',
             'submit_invoice','update_member','update_project','void_contract'])
  loop execute format('revoke execute on function %s from public, anon, authenticated', f.sig); end loop;
end $$;

-- ---------------------------------------------------------------- row-level security: check the user once per query
alter policy "own profile" on public.profiles using (id = (select auth.uid()));
alter policy "own notifications" on public.notifications using (user_id = (select auth.uid()));
alter policy "signed-in see owners" on public.company_admins using ((select auth.uid()) is not null);
alter policy "own row or staff" on public.crew using (user_id = (select auth.uid()) or prod_staff(production_id));
alter policy "own or staff" on public.checkins using (user_id = (select auth.uid())
  or exists (select 1 from shoot_days d where d.id = checkins.day_id and prod_staff(d.production_id)));
alter policy "own, leads and finance, or HOD's department" on public.crew_invoices using (user_id = (select auth.uid())
  or prod_role(production_id) = any (array['cfo','commercial','hop','lp','accounts'])
  or (prod_role(production_id) = 'hod' and dept = (select c.dept from crew c where c.production_id = crew_invoices.production_id and c.user_id = (select auth.uid()))));

create index if not exists crew_invoices_crew_idx on public.crew_invoices (crew_id);
create index if not exists crew_invoices_user_idx on public.crew_invoices (user_id);
create index if not exists checkins_user_idx on public.checkins (user_id);
create index if not exists notifications_prod_idx on public.notifications (production_id);
create index if not exists shoot_days_reminder_idx on public.shoot_days (day) where status = 'planned' and reminded_at is null;
