-- Removing people from a production.
-- * Only the CFO or Commercial Head removes someone. The Line Producer or Head of Production asks them to,
--   with a reason; the owner approves or declines, and the person who asked is told either way.
-- * Someone with no invoices, check-ins or signed agreement is deleted outright (a wrong or duplicate invite).
--   Anyone with history is taken off the production instead: they lose access and drop off the lists, but their
--   invoices, payments, TDS and agreement stay on record, and an owner can restore them.
-- * Nobody can be removed while an invoice of theirs is still in approval or waiting for payment.

alter table public.crew
  add column removed_at     timestamptz,
  add column removed_by     uuid references auth.users on delete set null,
  add column removed_reason text;

create table public.removal_requests (
  id            uuid primary key default gen_random_uuid(),
  production_id uuid not null references public.productions on delete cascade,
  crew_id       uuid references public.crew on delete set null,
  person        text not null,
  requested_by  uuid references auth.users on delete set null,
  reason        text not null check (length(reason) between 4 and 500),
  at            timestamptz not null default now(),
  status        text not null default 'pending' check (status in ('pending','approved','declined','withdrawn')),
  decided_by    uuid references auth.users on delete set null,
  decided_at    timestamptz,
  note          text
);
create unique index removal_requests_one_pending on public.removal_requests (crew_id) where status = 'pending';
alter table public.removal_requests enable row level security;
create policy "leads and owners" on public.removal_requests for select using (prod_lead(production_id));

create function public.remove_person(p_crew uuid, p_reason text) returns text
language plpgsql security definer set search_path = public as $$
declare c crew; why text := trim(coalesce(p_reason, '')); pn text; who text; keep boolean; outcome text;
begin
  select * into c from crew where id = p_crew;
  perform must(c.id is not null and prod_owner(c.production_id), 'Only the CFO or Commercial Head can remove someone');
  perform must(c.removed_at is null, 'They’re already removed');
  perform must(c.user_id is distinct from auth.uid(), 'You can’t remove yourself');
  perform must(length(why) >= 4, 'Say why they’re being removed');
  perform must(not exists (select 1 from crew_invoices where crew_id = c.id and status in ('submitted','hod_ok','approved')),
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

create function public.restore_person(p_crew uuid) returns void
language plpgsql security definer set search_path = public as $$
declare c crew;
begin
  select * into c from crew where id = p_crew;
  perform must(c.id is not null and prod_owner(c.production_id), 'Only the CFO or Commercial Head can restore someone');
  perform must(c.removed_at is not null, 'They aren’t removed');
  update crew set active = true, removed_at = null, removed_by = null, removed_reason = null where id = c.id;
  perform add_log(c.production_id, 'onboard', 'Restored ' || crew_name(c) || ' to the production', c.id);
  if c.user_id is not null then
    perform notify(array[c.user_id], c.production_id, 'restored', 'You’re back on ' || (select name from productions where id = c.production_id), null, 'home');
  end if;
end $$;

create function public.request_removal(p_crew uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare c crew; why text := trim(coalesce(p_reason, '')); rid uuid; who text;
begin
  select * into c from crew where id = p_crew;
  perform must(c.id is not null and prod_role(c.production_id) in ('hop','lp'), 'Only the Line Producer or Head of Production can ask for someone to be removed');
  perform must(c.removed_at is null, 'They’re already removed');
  perform must(c.user_id is distinct from auth.uid(), 'You can’t ask to remove yourself');
  perform must(length(why) >= 4, 'Say why, so the CFO or Commercial Head can decide');
  who := crew_name(c);
  begin
    insert into removal_requests (production_id, crew_id, person, requested_by, reason) values (c.production_id, c.id, who, auth.uid(), left(why, 500)) returning removal_requests.id into rid;
  exception when unique_violation then raise exception 'Removal of % has already been asked for', who;
  end;
  perform add_log(c.production_id, 'onboard', 'Asked to remove ' || who || ': ' || why, c.id);
  perform notify(owners_of(), c.production_id, 'removal', pname(auth.uid()) || ' asks to remove ' || who, why, 'people');
  return rid;
end $$;

create function public.decide_removal(p_request uuid, p_approve boolean, p_note text default null) returns text
language plpgsql security definer set search_path = public as $$
declare q removal_requests; outcome text; n text := nullif(trim(coalesce(p_note, '')), '');
begin
  select * into q from removal_requests where id = p_request;
  perform must(q.id is not null and prod_owner(q.production_id), 'Only the CFO or Commercial Head decides removals');
  perform must(q.status = 'pending', 'This request has already been dealt with');
  if p_approve then
    outcome := remove_person(q.crew_id, q.reason || coalesce(' · ' || n, ''));
    update removal_requests set note = n where id = q.id;
    perform notify(array[q.requested_by], q.production_id, 'removal', q.person || ' was removed', coalesce(n, 'Your request was approved.'), 'people');
  else
    perform must(n is not null and length(n) >= 4, 'Say why you’re keeping them, so the person who asked knows');
    update removal_requests set status = 'declined', decided_by = auth.uid(), decided_at = now(), note = n where id = q.id;
    perform add_log(q.production_id, 'onboard', 'Kept ' || q.person || ' on the production: ' || n, q.crew_id);
    perform notify(array[q.requested_by], q.production_id, 'removal', 'Request to remove ' || q.person || ' declined', n, 'people');
    outcome := 'declined';
  end if;
  return outcome;
end $$;

create function public.withdraw_removal(p_request uuid) returns void
language plpgsql security definer set search_path = public as $$
declare q removal_requests;
begin
  select * into q from removal_requests where id = p_request;
  perform must(q.id is not null and q.requested_by = auth.uid(), 'Only the person who asked can withdraw this');
  perform must(q.status = 'pending', 'This request has already been dealt with');
  update removal_requests set status = 'withdrawn', decided_at = now() where id = q.id;
  perform add_log(q.production_id, 'onboard', 'Withdrew the request to remove ' || q.person, q.crew_id);
end $$;

-- a removed person can't put themselves back with the production code
create or replace function public.join_production(p_code text, p_kind text default 'crew') returns jsonb
language plpgsql security definer set search_path = public as $$
declare pr productions; c crew; me profiles; tries int; ph text; em text;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'Sign in first'); end if;
  select count(*) into tries from join_attempts where user_id = auth.uid() and at > now() - interval '1 hour';
  if tries >= 10 then return jsonb_build_object('ok', false, 'error', 'Too many wrong codes. Try again in an hour, or ask your Line Producer for the code.'); end if;
  select * into pr from productions where code = upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  if pr.id is null then
    insert into join_attempts (user_id) values (auth.uid());
    return jsonb_build_object('ok', false, 'error', 'No production has that code. Check it with your Line Producer.');
  end if;
  if exists (select 1 from crew where production_id = pr.id and user_id = auth.uid() and removed_at is not null) then
    return jsonb_build_object('ok', false, 'error', 'You were removed from this production. Ask the production office if you think this is a mistake.');
  end if;
  if exists (select 1 from crew where production_id = pr.id and user_id = auth.uid()) then
    update crew set active = true where production_id = pr.id and user_id = auth.uid();
    return jsonb_build_object('ok', true, 'production_id', pr.id, 'name', pr.name, 'already', true);
  end if;
  select * into me from profiles where id = auth.uid();
  select lower(email) into em from auth.users where id = auth.uid() and email_confirmed_at is not null;
  ph := right(regexp_replace(coalesce(me.phone, ''), '\D', '', 'g'), 10);
  select * into c from crew where production_id = pr.id and user_id is null and (
      (em is not null and lower(invite_email) = em)
      or (role in ('crew','vendor') and length(ph) = 10 and right(regexp_replace(coalesce(invite_phone, ''), '\D', '', 'g'), 10) = ph))
    order by (em is not null and lower(invite_email) = em) desc, joined_at limit 1;
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
