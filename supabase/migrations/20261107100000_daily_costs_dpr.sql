-- Daily costs, petty cash and the daily production report.
--
-- Daily costs: the production office enters each day's spend by cost head (the same heads the budget uses):
-- one at a time, or many at once from the CrewDesk Excel template. Only the CFO, Commercial Head, Commercial
-- Manager, Head of Production, Line Producer, Accounts and the Auditor see or enter them. A past day locks like
-- the call sheet (the day after it, or once its attendance is confirmed); changing it then needs the Commercial
-- Head's or a Commercial Manager's permission, which can now be asked for any date, shoot day or not.
--
-- Petty cash: Accounts or the CFO give a cash float to someone; what they pay in cash comes off it.
--
-- Daily production report (DPR): actual call, first shot, lunch and wrap, scenes and minutes shot, and the
-- reason for any delay, filed for each shoot day. Overtime past a 12-hour shift is worked out from it.

-- ---------------------------------------------------------------- who works with costs
create function public.cost_role(p uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(prod_role(p) in ('cfo','commercial','commercial_mgr','hop','lp','accounts','auditor'), false) $$;

-- permission to change a locked date, for dates with no shoot day too
alter table public.day_unlocks alter column day_id drop not null, add column on_date date;
update public.day_unlocks u set on_date = d.day from public.shoot_days d where d.id = u.day_id;
alter table public.day_unlocks alter column on_date set not null;
drop index public.day_unlocks_one_pending;
create unique index day_unlocks_one_pending on public.day_unlocks (production_id, on_date) where status = 'pending';

create function public.date_locked(p uuid, d date) returns boolean language sql stable security definer set search_path = public as $$
  select d < today_ist() - 1 or exists (select 1 from shoot_days where production_id = p and day = d and att_confirmed_at is not null) $$;
create function public.date_editable(p uuid, d date) returns boolean language sql stable security definer set search_path = public as $$
  select not date_locked(p, d) or coalesce(prod_role(p) in ('commercial','commercial_mgr'), false)
      or exists (select 1 from day_unlocks u where u.production_id = p and u.on_date = d and u.status = 'approved' and u.expires_at > now()) $$;
create or replace function public.day_editable(d public.shoot_days) returns boolean language sql stable security definer set search_path = public as $$
  select not day_locked(d) or coalesce(prod_role(d.production_id) in ('commercial','commercial_mgr'), false)
      or exists (select 1 from day_unlocks u where u.production_id = d.production_id and u.on_date = d.day and u.status = 'approved' and u.expires_at > now()) $$;

create or replace function public.request_day_unlock(p_day uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare d shoot_days;
begin
  select * into d from shoot_days where id = p_day;
  perform must(d.id is not null, 'No such day');
  return request_date_unlock(d.production_id, d.day, p_reason);
end $$;
create function public.request_date_unlock(p_production uuid, p_date date, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare why text := trim(coalesce(p_reason, '')); rid uuid; dd uuid := (select id from shoot_days where production_id = p_production and day = p_date);
begin
  perform must(prod_lead(p_production) or prod_role(p_production) in ('auditor','accounts'), 'Only production leads, Accounts and the Auditor can ask to change a locked day');
  perform must(date_locked(p_production, p_date), 'This day isn’t locked; change it directly');
  perform must(length(why) >= 4, 'Say what needs changing and why');
  begin
    insert into day_unlocks (production_id, day_id, on_date, requested_by, reason) values (p_production, dd, p_date, auth.uid(), left(why, 500)) returning id into rid;
  exception when unique_violation then raise exception 'Permission for this day has already been asked for';
  end;
  perform add_log(p_production, 'schedule', 'Asked to change locked day ' || to_char(p_date, 'DD Mon YYYY') || ': ' || why);
  perform notify(people_in(p_production, array['commercial','commercial_mgr']), p_production, 'unlock',
    pname(auth.uid()) || ' asks to change ' || day_label(p_date), why, 'costs');
  return rid;
end $$;
create or replace function public.decide_day_unlock(p_request uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare q day_unlocks; n text := nullif(trim(coalesce(p_note, '')), '');
begin
  select * into q from day_unlocks where id = p_request;
  perform must(q.id is not null and prod_role(q.production_id) in ('commercial','commercial_mgr'), 'Only the Commercial Head or a Commercial Manager can give this permission');
  perform must(q.status = 'pending', 'This request has already been dealt with');
  if p_approve then
    update day_unlocks set status = 'approved', decided_by = auth.uid(), decided_at = now(), expires_at = now() + interval '24 hours', note = n where id = q.id;
    perform add_log(q.production_id, 'schedule', 'Allowed changes to ' || to_char(q.on_date, 'DD Mon YYYY') || ' for 24 hours' || coalesce(': ' || n, ''));
    perform notify(array[q.requested_by], q.production_id, 'unlock', 'You can change ' || day_label(q.on_date) || ' for 24 hours', coalesce(n, 'Permission given.'), 'costs');
  else
    perform must(n is not null and length(n) >= 4, 'Say why, so the person who asked knows');
    update day_unlocks set status = 'declined', decided_by = auth.uid(), decided_at = now(), note = n where id = q.id;
    perform add_log(q.production_id, 'schedule', 'Refused changes to ' || to_char(q.on_date, 'DD Mon YYYY') || ': ' || n);
    perform notify(array[q.requested_by], q.production_id, 'unlock', 'No permission to change ' || day_label(q.on_date), n, 'costs');
  end if;
end $$;

-- ---------------------------------------------------------------- daily costs
create table public.cost_entries (
  id            uuid primary key default gen_random_uuid(),
  production_id uuid not null references public.productions on delete cascade,
  on_date       date not null,
  head          text not null check (length(trim(head)) between 2 and 60),
  item          text check (item is null or length(item) <= 80),
  descr         text check (descr is null or length(descr) <= 300),
  payee         text check (payee is null or length(payee) <= 120),
  qty           numeric(10,2) not null default 1 check (qty > 0),
  rate          numeric(12,2),
  amount        bigint not null check (amount > 0),
  mode          text not null default 'bank' check (mode in ('bank','cash','credit','petty')),
  petty_holder  uuid references auth.users on delete set null,
  bill_no       text check (bill_no is null or length(bill_no) <= 40),
  notes         text check (notes is null or length(notes) <= 300),
  source        text not null default 'manual' check (source in ('manual','excel')),
  batch         uuid,
  created_by    uuid references auth.users on delete set null,
  created_at    timestamptz not null default now(),
  check (mode <> 'petty' or petty_holder is not null)
);
create index cost_entries_prod_date_idx on public.cost_entries (production_id, on_date);
create index cost_entries_batch_idx on public.cost_entries (batch) where batch is not null;
alter table public.cost_entries enable row level security;
create policy "production office" on public.cost_entries for select using (cost_role(production_id));

create table public.petty_floats (
  id            uuid primary key default gen_random_uuid(),
  production_id uuid not null references public.productions on delete cascade,
  holder        uuid not null references auth.users on delete cascade,
  amount        bigint not null check (amount <> 0),
  on_date       date not null default today_ist(),
  note          text check (note is null or length(note) <= 200),
  given_by      uuid references auth.users on delete set null,
  at            timestamptz not null default now()
);
create index petty_floats_prod_idx on public.petty_floats (production_id, holder);
alter table public.petty_floats enable row level security;
create policy "production office or holder" on public.petty_floats for select using (cost_role(production_id) or holder = (select auth.uid()));

-- add one or many entries; every row is checked and the whole batch goes in, or none of it
create function public.add_cost_entries(p_production uuid, p_rows jsonb, p_source text default 'manual') returns int
language plpgsql security definer set search_path = public as $$
declare r jsonb; n int := 0; bad text; d date; q numeric; rt numeric; amt bigint; m text; h uuid; b uuid := case when p_source = 'excel' then gen_random_uuid() end; total bigint := 0;
        dates date[] := '{}';
begin
  perform must(cost_role(p_production), 'Only the production office enters costs');
  perform must(jsonb_typeof(p_rows) = 'array' and jsonb_array_length(p_rows) between 1 and 2000, 'Add between 1 and 2,000 rows at a time');
  for r in select * from jsonb_array_elements(p_rows) loop
    n := n + 1;
    begin d := (r ->> 'date')::date; exception when others then raise exception 'Row %: the date isn’t a date', n; end;
    if d is null then raise exception 'Row %: add the date', n; end if;
    if d > today_ist() + 30 then raise exception 'Row %: % is too far ahead', n, to_char(d, 'DD Mon YYYY'); end if;
    if not date_editable(p_production, d) then
      raise exception 'Row %: % is locked. Ask the Commercial Head or a Commercial Manager for permission first', n, to_char(d, 'DD Mon YYYY');
    end if;
    if length(trim(coalesce(r ->> 'head', ''))) < 2 then raise exception 'Row %: pick the cost head', n; end if;
    begin q := coalesce(nullif(r ->> 'qty', '')::numeric, 1); rt := nullif(r ->> 'rate', '')::numeric; amt := round(coalesce(nullif(r ->> 'amount', '')::numeric, q * rt));
    exception when others then raise exception 'Row %: quantity, rate and amount must be numbers', n; end;
    if amt is null or amt <= 0 then raise exception 'Row %: add the amount (or quantity and rate)', n; end if;
    if q <= 0 then raise exception 'Row %: quantity must be more than zero', n; end if;
    m := lower(coalesce(nullif(trim(r ->> 'mode'), ''), 'bank'));
    m := case when m like 'petty%' then 'petty' when m like 'cash%' then 'cash' when m like 'credit%' or m like 'unpaid%' then 'credit' when m like 'bank%' or m in ('upi','neft','rtgs','imps','cheque') then 'bank' else m end;
    if m not in ('bank','cash','credit','petty') then raise exception 'Row %: “Paid by” must be Bank, Cash, Credit or Petty cash', n; end if;
    h := null;
    if m = 'petty' then
      h := coalesce(nullif(r ->> 'holder', '')::uuid, (select x.id from profiles x join crew c on c.user_id = x.id where c.production_id = p_production
               and lower(coalesce(x.full_name, '')) = lower(trim(coalesce(r ->> 'holder_name', ''))) limit 1));
      if h is null then raise exception 'Row %: say whose petty cash paid this', n; end if;
    end if;
    insert into cost_entries (production_id, on_date, head, item, descr, payee, qty, rate, amount, mode, petty_holder, bill_no, notes, source, batch, created_by)
    values (p_production, d, trim(r ->> 'head'), nullif(trim(r ->> 'item'), ''), nullif(trim(r ->> 'descr'), ''), nullif(trim(r ->> 'payee'), ''),
            q, rt, amt, m, h, nullif(trim(r ->> 'bill_no'), ''), nullif(trim(r ->> 'notes'), ''), case when p_source = 'excel' then 'excel' else 'manual' end, b, auth.uid());
    total := total + amt;
    if not d = any (dates) then dates := dates || d; end if;
  end loop;
  perform add_log(p_production, 'cost', case when p_source = 'excel' then 'Imported ' || n || ' cost lines from Excel' else 'Added ' || n || ' cost line' || case when n > 1 then 's' else '' end end
    || ' · ₹' || total || ' · ' || (select string_agg(to_char(x, 'DD Mon'), ', ' order by x) from unnest(dates) x));
  return n;
end $$;

create function public.update_cost_entry(p_id uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare e cost_entries; d date; q numeric; rt numeric; amt bigint;
begin
  select * into e from cost_entries where id = p_id;
  perform must(e.id is not null and cost_role(e.production_id), 'Only the production office changes costs');
  d := coalesce(nullif(p ->> 'date', '')::date, e.on_date);
  perform must(date_editable(e.production_id, e.on_date) and date_editable(e.production_id, d), to_char(e.on_date, 'DD Mon') || ' is locked. Ask the Commercial Head or a Commercial Manager for permission first');
  q := coalesce(nullif(p ->> 'qty', '')::numeric, e.qty); rt := case when p ? 'rate' then nullif(p ->> 'rate', '')::numeric else e.rate end;
  amt := round(coalesce(nullif(p ->> 'amount', '')::numeric, q * rt, e.amount));
  perform must(amt > 0 and q > 0, 'Add the amount (or quantity and rate)');
  update cost_entries set on_date = d, head = coalesce(nullif(trim(p ->> 'head'), ''), head), item = case when p ? 'item' then nullif(trim(p ->> 'item'), '') else item end,
    descr = case when p ? 'descr' then nullif(trim(p ->> 'descr'), '') else descr end, payee = case when p ? 'payee' then nullif(trim(p ->> 'payee'), '') else payee end,
    qty = q, rate = rt, amount = amt, bill_no = case when p ? 'bill_no' then nullif(trim(p ->> 'bill_no'), '') else bill_no end where id = p_id;
  perform add_log(e.production_id, 'cost', 'Changed a cost line on ' || to_char(e.on_date, 'DD Mon YYYY') || ': ' || e.head || ' ₹' || e.amount || ' → ₹' || amt);
end $$;

create function public.delete_cost_entry(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e cost_entries;
begin
  select * into e from cost_entries where id = p_id;
  perform must(e.id is not null and cost_role(e.production_id), 'Only the production office changes costs');
  perform must(date_editable(e.production_id, e.on_date), to_char(e.on_date, 'DD Mon') || ' is locked. Ask the Commercial Head or a Commercial Manager for permission first');
  delete from cost_entries where id = p_id;
  perform add_log(e.production_id, 'cost', 'Deleted a cost line on ' || to_char(e.on_date, 'DD Mon YYYY') || ': ' || e.head || coalesce(' · ' || e.payee, '') || ' ₹' || e.amount);
end $$;

-- undo a whole Excel import (only while its days are still open)
create function public.undo_cost_import(p_batch uuid) returns int
language plpgsql security definer set search_path = public as $$
declare p uuid; n int; t bigint;
begin
  select production_id, count(*), sum(amount) into p, n, t from cost_entries where batch = p_batch group by production_id;
  perform must(p is not null and cost_role(p), 'No such import');
  perform must(not exists (select 1 from cost_entries where batch = p_batch and not date_editable(production_id, on_date)), 'Some of these days are locked now. Ask the Commercial Head for permission first');
  delete from cost_entries where batch = p_batch;
  perform add_log(p, 'cost', 'Undid an Excel import of ' || n || ' cost lines · ₹' || t);
  return n;
end $$;

create function public.give_petty_float(p_production uuid, p_holder uuid, p_amount bigint, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform must(prod_role(p_production) in ('cfo','accounts','commercial','commercial_mgr'), 'Only the CFO, Accounts or the commercial side give petty cash');
  perform must(p_amount <> 0, 'Enter an amount (negative if cash came back)');
  perform must(exists (select 1 from crew where production_id = p_production and user_id = p_holder and active), 'Give petty cash to someone on this production');
  insert into petty_floats (production_id, holder, amount, note, given_by) values (p_production, p_holder, p_amount, nullif(trim(coalesce(p_note, '')), ''), auth.uid());
  perform add_log(p_production, 'cost', case when p_amount > 0 then 'Gave ₹' || p_amount || ' petty cash to ' else 'Took back ₹' || abs(p_amount) || ' petty cash from ' end || coalesce(pname(p_holder), 'someone'));
  perform notify(array[p_holder], p_production, 'cost', case when p_amount > 0 then 'Petty cash ₹' || p_amount || ' given to you' else 'Petty cash ₹' || abs(p_amount) || ' returned' end,
    coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Record what you spend from it in Daily costs.'), 'costs');
end $$;

-- ---------------------------------------------------------------- daily production report
alter table public.shoot_days
  add column act_call text check (act_call is null or act_call ~ '^[0-2][0-9]:[0-5][0-9]$'),
  add column first_shot text check (first_shot is null or first_shot ~ '^[0-2][0-9]:[0-5][0-9]$'),
  add column lunch_min int check (lunch_min is null or lunch_min between 0 and 240),
  add column act_wrap text check (act_wrap is null or act_wrap ~ '^[0-2][0-9]:[0-5][0-9]$'),
  add column scenes_planned int check (scenes_planned is null or scenes_planned >= 0),
  add column scenes_shot int check (scenes_shot is null or scenes_shot >= 0),
  add column minutes_shot numeric(6,1) check (minutes_shot is null or minutes_shot >= 0),
  add column delay text check (delay is null or length(delay) <= 300),
  add column dpr_by uuid references auth.users on delete set null,
  add column dpr_at timestamptz;

create function public.save_dpr(p_day uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare d shoot_days; t text;
begin
  select * into d from shoot_days where id = p_day;
  perform must(d.id is not null and (prod_lead(d.production_id) or prod_role(d.production_id) = 'commercial_mgr'), 'Only the Line Producer or Head of Production files the daily report');
  perform must(d.day <= today_ist(), 'File the report on or after the shoot day');
  perform must(d.status <> 'cancelled', 'This day was cancelled');
  -- the first report may be filed after the Auditor confirms attendance; changing a filed one follows the day lock
  if d.dpr_at is not null or d.day < today_ist() - 1 then perform must_edit_day(d); end if;
  foreach t in array array['act_call','first_shot','act_wrap'] loop
    perform must(coalesce(nullif(p ->> t, ''), '00:00') ~ '^[0-2][0-9]:[0-5][0-9]$', 'Enter times like 07:30');
  end loop;
  update shoot_days set act_call = nullif(p ->> 'act_call', ''), first_shot = nullif(p ->> 'first_shot', ''), lunch_min = nullif(p ->> 'lunch_min', '')::int,
    act_wrap = nullif(p ->> 'act_wrap', ''), scenes_planned = nullif(p ->> 'scenes_planned', '')::int, scenes_shot = nullif(p ->> 'scenes_shot', '')::int,
    minutes_shot = nullif(p ->> 'minutes_shot', '')::numeric, delay = nullif(trim(coalesce(p ->> 'delay', '')), ''), dpr_by = auth.uid(), dpr_at = now(),
    status = case when status = 'planned' then 'shot' else status end
  where id = p_day;
  perform add_log(d.production_id, 'schedule', 'Filed the daily report for ' || to_char(d.day, 'DD Mon YYYY')
    || coalesce(': ' || (p ->> 'scenes_shot') || '/' || coalesce(nullif(p ->> 'scenes_planned', ''), '?') || ' scenes', '') || coalesce(', ' || (p ->> 'minutes_shot') || ' min', ''));
end $$;

-- the evening job also reminds leads who haven't filed today's report
create function public.send_dpr_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare d shoot_days; n int := 0;
begin
  for d in select * from shoot_days where day = today_ist() and status <> 'cancelled' and dpr_at is null loop
    perform notify(people_in(d.production_id, array['lp','hop']), d.production_id, 'schedule', 'File today’s daily report', day_label(d.day) || ' · call ' || d.call_time || '. Times, scenes, minutes and any delay.', 'schedule', true);
    n := n + 1;
  end loop;
  return n;
end $$;
do $$ begin
  perform cron.schedule('crewdesk-dpr-reminders', '30 15 * * *', 'select public.send_dpr_reminders()');   -- 21:00 IST
exception when others then raise notice 'pg_cron not available here; DPR reminders are not scheduled (%)', sqlerrm;
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.login_email(text), public.username_available(text) to anon;
revoke execute on function public.send_call_reminders(), public.send_task_reminders(), public.send_dpr_reminders() from authenticated;
