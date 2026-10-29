-- Notifications and live updates.
-- * notifications: one row per person per event, written by triggers when agreements, invoices,
--   check-ins and deals change. People read and mark only their own.
-- * production_pulse: touched whenever a production's activity log grows, so open screens
--   (subscribed through Supabase Realtime) know to refresh.
-- Like everything else, nothing here can be written directly through the API.

create table public.notifications (
  id            bigint generated always as identity primary key,
  user_id       uuid not null references auth.users on delete cascade,
  production_id uuid references public.productions on delete cascade,
  at            timestamptz not null default clock_timestamp(),
  kind          text not null,
  title         text not null,
  body          text,
  view          text not null default 'home',
  read_at       timestamptz
);
create index notifications_user_idx on public.notifications (user_id, id desc);

create table public.production_pulse (
  production_id uuid primary key references public.productions on delete cascade,
  at            timestamptz not null default clock_timestamp()
);

alter table public.notifications    enable row level security;
alter table public.production_pulse enable row level security;
create policy "own notifications" on public.notifications for select using (user_id = auth.uid());
create policy "members" on public.production_pulse for select using (prod_member(production_id));

-- who to tell
create function public.owners_of() returns uuid[] language sql stable set search_path = public as $$ select array_agg(user_id) from company_admins $$;
create function public.leads_of(p uuid) returns uuid[] language sql stable set search_path = public as $$
  select array_agg(user_id) from crew where production_id = p and active and user_id is not null and role in ('hop','lp') $$;
create function public.finance_of(p uuid) returns uuid[] language sql stable set search_path = public as $$
  select coalesce(owners_of(), '{}') || coalesce((select array_agg(user_id) from crew where production_id = p and active and user_id is not null and role = 'accounts'), '{}') $$;
create function public.checkers_of(p uuid, d text) returns uuid[] language sql stable set search_path = public as $$
  select coalesce((select array_agg(user_id) from crew where production_id = p and active and user_id is not null and role = 'hod' and dept = d), leads_of(p), owners_of()) $$;

-- Runs with the caller's rights: used by the triggers below (inside checked functions), refused if called directly.
create function public.notify(p_users uuid[], p_prod uuid, p_kind text, p_title text, p_body text default null, p_view text default 'home', p_self boolean default false) returns void
language sql set search_path = public as $$
  insert into notifications (user_id, production_id, kind, title, body, view)
  select distinct u, p_prod, p_kind, p_title, p_body, p_view from unnest(p_users) u
  where u is not null and (p_self or u is distinct from auth.uid())
$$;

create function public.crew_notify() returns trigger
language plpgsql set search_path = public as $$
declare pn text := (select name from productions where id = new.production_id); who text := crew_name(new);
begin
  if old.user_id is null and new.user_id is not null then
    perform notify(coalesce(leads_of(new.production_id), '{}') || coalesce(owners_of(), '{}'), new.production_id, 'joined', who || ' joined ' || pn, 'Their invite was waiting for them. Check their onboarding.', 'people');
  end if;
  if new.ag_status is distinct from old.ag_status then
    if new.ag_status = 'sent' then
      perform notify(array[new.user_id], new.production_id, 'agreement', 'Your agreement is ready to sign', pn || ': open My setup to read and sign it.');
    elsif new.ag_status = 'signed' then
      perform notify(array[new.user_id], new.production_id, 'agreement', 'Agreement signed', 'The CFO or Commercial Head approves it next.', 'home', true);
      perform notify(owners_of(), new.production_id, 'agreement', who || ' signed their agreement', pn || ': approve it to finish their onboarding.', 'people');
    elsif new.ag_status = 'countersigned' then
      perform notify(array[new.user_id], new.production_id, 'agreement', 'Your agreement is approved', 'You’re onboarded on ' || pn || '. Your Crew ID is on My setup.');
    elsif new.ag_status = 'none' and old.ag_status = 'sent' then
      perform notify(array[new.user_id], new.production_id, 'agreement', 'Your agreement was withdrawn', 'Your deal changed; a new agreement will follow.');
    end if;
  end if;
  if old.user_id is not null and (new.rate, new.unit, new.joining, new.end_date) is distinct from (old.rate, old.unit, old.joining, old.end_date) then
    perform notify(array[new.user_id], new.production_id, 'deal', 'Your deal was updated',
      inr(new.rate) || ' ' || case new.unit when 'day' then 'per day' when 'episode' then 'per episode' when 'week' then 'per week' when 'month' then 'per month' else 'lump sum' end
      || coalesce(' · joining ' || to_char(new.joining, 'DD Mon YYYY'), ''));
  end if;
  return null;
end $$;
create trigger crew_notify after update on public.crew for each row execute function public.crew_notify();

-- someone joining with the code without an invite (or added with an existing account)
create function public.crew_join_notify() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.user_id is not null then
    perform notify(coalesce(leads_of(new.production_id), '{}') || coalesce(owners_of(), '{}'), new.production_id, 'joined',
      crew_name(new) || ' joined ' || (select name from productions where id = new.production_id),
      case when new.rate is null then 'Set their deal so they can carry on with onboarding.' else 'Check their onboarding.' end, 'people');
  end if;
  return null;
end $$;
create trigger crew_join_notify after insert on public.crew for each row execute function public.crew_join_notify();

create function public.invoice_notify() returns trigger
language plpgsql set search_path = public as $$
declare who text := pname(new.user_id); amt text := inr(new.payable);
begin
  if tg_op = 'INSERT' then
    perform notify(array[new.user_id], new.production_id, 'invoice', 'Invoice ' || new.no || ' submitted', amt || ' payable · waiting for the HOD check.', 'invoices', true);
    perform notify(checkers_of(new.production_id, new.dept), new.production_id, 'invoice', 'Invoice ' || new.no || ' to check', coalesce(who, 'Crew') || ' · ' || amt, 'invoices');
  elsif new.status is distinct from old.status then
    if new.status = 'hod_ok' then
      perform notify(array[new.user_id], new.production_id, 'invoice', 'Invoice ' || new.no || ' passed the HOD check', 'Waiting for the CFO or Commercial Head.', 'invoices');
      perform notify(owners_of(), new.production_id, 'invoice', 'Invoice ' || new.no || ' needs final approval', coalesce(who, 'Crew') || ' · ' || amt, 'invoices');
    elsif new.status = 'approved' then
      perform notify(array[new.user_id], new.production_id, 'invoice', 'Invoice ' || new.no || ' approved for payment', amt || ' will be paid within your payment terms.', 'invoices');
      perform notify(finance_of(new.production_id), new.production_id, 'invoice', 'Invoice ' || new.no || ' ready to pay', coalesce(who, 'Crew') || ' · ' || amt, 'finance');
    elsif new.status = 'paid' then
      perform notify(array[new.user_id], new.production_id, 'payment', 'Invoice ' || new.no || ' paid', amt || ' · bank reference ' || coalesce(new.utr, '—'), 'invoices');
    elsif new.status = 'rejected' then
      perform notify(array[new.user_id], new.production_id, 'invoice', 'Invoice ' || new.no || ' was rejected', coalesce(new.reason, '') || ' · fix it and submit again.', 'invoices');
    end if;
  end if;
  return null;
end $$;
create trigger invoice_notify after insert or update on public.crew_invoices for each row execute function public.invoice_notify();

create function public.checkin_notify() returns trigger
language plpgsql set search_path = public as $$
declare d shoot_days;
begin
  if tg_op = 'INSERT' or (old.removed_at is not null and new.removed_at is null) then
    select * into d from shoot_days where id = new.day_id;
    perform notify(array[new.user_id], d.production_id, 'checkin', 'Checked in for ' || to_char(d.day, 'DD Mon'), 'This day counts towards your next invoice.', 'schedule');
  end if;
  return null;
end $$;
create trigger checkin_notify after insert or update on public.checkins for each row execute function public.checkin_notify();

create function public.activity_pulse() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.production_id is not null then
    insert into production_pulse (production_id, at) values (new.production_id, clock_timestamp())
    on conflict (production_id) do update set at = excluded.at;
  end if;
  return null;
end $$;
create trigger activity_pulse after insert on public.activity for each row execute function public.activity_pulse();

create function public.mark_notifications_read(p_ids bigint[] default null) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update notifications set read_at = now() where user_id = auth.uid() and read_at is null and (p_ids is null or id = any(p_ids));
  get diagnostics n = row_count;
  return n;
end $$;

-- live updates: Supabase Realtime sends inserts and changes on these tables, filtered by the policies above
do $$ begin
  alter publication supabase_realtime add table public.notifications, public.production_pulse;
exception when undefined_object then null;   -- local test databases have no Realtime
end $$;
