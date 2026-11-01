-- Notification choices, and pings for the two steps that waited on someone without telling them.
--
-- Anyone can switch off progress updates they don't need: each approval step of their own invoice, schedule changes,
-- the evening-before call reminder, "you were checked in", and updates on tasks they're on. What someone has to act on
-- (an invoice to approve, an agreement to sign, a day to confirm), and money and legal notices (paid, rejected,
-- deductions, deal changes, removal, bank changes) always arrive.
--
-- New pings to the next in line:
-- * when someone's profile and documents are both complete, the Line Producer and Head of Production are told to
--   send their agreement;
-- * at 9 pm IST the Auditor (or the owners, on a show without one) is asked to confirm each of today's shoot days that
--   has check-ins, since invoices wait for it.

alter table public.profiles add column notify_off text[] not null default '{}'
  check (notify_off <@ array['invoice_step','schedule','call','checkin','task_update']);

create or replace function public.notify(p_users uuid[], p_prod uuid, p_kind text, p_title text, p_body text default null, p_view text default 'home', p_self boolean default false) returns void
language sql set search_path = public as $$
  insert into notifications (user_id, production_id, kind, title, body, view)
  select distinct u, p_prod, p_kind, p_title, p_body, p_view from unnest(p_users) u
  where u is not null and (p_self or u is distinct from auth.uid())
    and not exists (select 1 from profiles x where x.id = u and p_kind = any (x.notify_off))
$$;

create function public.set_notify_prefs(p_off text[]) returns text[]
language plpgsql security definer set search_path = public as $$
declare v text[] := coalesce((select array_agg(distinct x) from unnest(coalesce(p_off, '{}')) x), '{}');
begin
  perform must(auth.uid() is not null, 'Sign in first');
  perform must(v <@ array['invoice_step','schedule','call','checkin','task_update'], 'Those notifications can’t be switched off');
  update profiles set notify_off = v where id = auth.uid();
  return v;
end $$;

create or replace view public.people with (security_invoker = false) as
  select p.id, p.username, p.full_name, p.phone, p.email, p.photo_path,
         case when kyc_visible(p.id) then p.legal_name end    as legal_name,
         kyc_reveal(p.id, 'pan')                               as pan,
         case when kyc_visible(p.id) then p.gstin end         as gstin,
         case when kyc_visible(p.id) then p.address end       as address,
         case when kyc_visible(p.id) then p.bank_holder end   as bank_holder,
         case when kyc_visible(p.id) then p.bank_name end     as bank_name,
         kyc_reveal(p.id, 'bank')                              as bank_account,
         case when kyc_visible(p.id) then p.bank_ifsc end     as bank_ifsc,
         case when kyc_visible(p.id) then p.aadhaar_last4 end as aadhaar_last4,
         case when kyc_visible(p.id) then p.aadhaar_path end  as aadhaar_path,
         case when kyc_visible(p.id) then p.pan_path end      as pan_path,
         case when kyc_visible(p.id) then p.consent_at end    as consent_at,
         case when kyc_visible(p.id) then p.emergency end     as emergency,
         profile_ready(p) as profile_ready,
         docs_ready(p)    as docs_ready,
         p.imdb_url,
         case when kyc_visible(p.id) then p.pan_tail end      as pan_tail,
         case when kyc_visible(p.id) then p.bank_tail end     as bank_tail,
         case when p.id = auth.uid() then p.notify_off end    as notify_off
  from profiles p
  where person_visible(p.id);

-- the person's own invoice moving along is a progress update ('invoice_step'); approvers' pings stay 'invoice'
create or replace function public.invoice_notify() returns trigger
language plpgsql set search_path = public as $$
declare who text := coalesce(pname(new.user_id), 'Crew'); amt text := inr(new.payable);
begin
  if tg_op = 'INSERT' then
    perform notify(array[new.user_id], new.production_id, 'invoice_step', 'Invoice ' || new.no || ' submitted', amt || ' payable · next: the Auditor checks it against your days and the cost report.', 'invoices', true);
    perform notify(step_people(new.production_id, 'submitted'), new.production_id, 'invoice', 'Invoice ' || new.no || ' to audit', who || ' · ' || amt || ' · check the days against confirmed attendance', 'invoices');
  elsif new.status is distinct from old.status then
    if new.status = 'audited' then
      perform notify(array[new.user_id], new.production_id, 'invoice_step', 'Invoice ' || new.no || ' passed the audit', 'Step 2 of 5: with the Production Controller.', 'invoices');
      perform notify(step_people(new.production_id, 'audited'), new.production_id, 'invoice', 'Invoice ' || new.no || ' to check', who || ' · ' || amt || ' · audited' || coalesce(' · ' || new.cost_head, ''), 'invoices');
    elsif new.status = 'pc_ok' then
      perform notify(array[new.user_id], new.production_id, 'invoice_step', 'Invoice ' || new.no || ' checked by the Production Controller', 'Step 3 of 5: with the Head of Production.', 'invoices');
      perform notify(step_people(new.production_id, 'pc_ok'), new.production_id, 'invoice', 'Invoice ' || new.no || ' to confirm', who || ' · ' || amt || ' · audited and checked', 'invoices');
    elsif new.status = 'hop_ok' then
      perform notify(array[new.user_id], new.production_id, 'invoice_step', 'Invoice ' || new.no || ' confirmed by the Head of Production', 'Step 4 of 5: with the Commercial Head.', 'invoices');
      perform notify(step_people(new.production_id, 'hop_ok'), new.production_id, 'invoice', 'Invoice ' || new.no || ' needs commercial approval', who || ' · ' || amt, 'invoices');
    elsif new.status = 'approved' then
      perform notify(array[new.user_id], new.production_id, 'invoice_step', 'Invoice ' || new.no || ' approved for payment', 'Step 5 of 5: ' || amt || ' will be paid within your payment terms.', 'invoices');
      perform notify(step_people(new.production_id, 'approved'), new.production_id, 'invoice', 'Invoice ' || new.no || ' ready to pay', who || ' · ' || amt, 'finance');
    elsif new.status = 'paid' then
      perform notify(array[new.user_id], new.production_id, 'payment', 'Invoice ' || new.no || ' paid', amt || ' · bank reference ' || coalesce(new.utr, '—'), 'invoices');
    elsif new.status = 'rejected' then
      perform notify(array[new.user_id], new.production_id, 'invoice', 'Invoice ' || new.no || ' was rejected', coalesce(new.reason, '') || ' · fix it and submit again.', 'invoices');
    end if;
  end if;
  return null;
end $$;

-- updates on a task are progress; a new assignment ('task') always arrives
create or replace function public.set_task_status(p_task uuid, p_status text) returns void
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
  perform notify(task_people(p_task), t.production_id, 'task_update', '“' || t.title || '” is ' || lower(labels ->> p_status),
    'Changed by ' || coalesce(pname(auth.uid()), 'someone'), 'tasks');
end $$;

create or replace function public.add_task_update(p_task uuid, p_body text, p_kind text default 'comment') returns bigint
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
  perform notify(task_people(p_task), t.production_id, 'task_update',
    coalesce(pname(auth.uid()), 'Someone') || case p_kind when 'solution' then ' proposed a solution: ' else ' on ' end || t.title, left(b, 140), 'tasks');
  return nid;
end $$;

create or replace function public.accept_solution(p_update bigint) returns void
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
  perform notify(task_people(t.id) || array[u."by"], t.production_id, 'task_update', 'Solution accepted: ' || t.title, left(u.body, 140), 'tasks');
end $$;

-- the daily report reminder is work for the Line Producer, not a schedule update
create or replace function public.send_dpr_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare d shoot_days; n int := 0;
begin
  for d in select * from shoot_days where day = today_ist() and status <> 'cancelled' and dpr_at is null loop
    perform notify(people_in(d.production_id, array['lp','hop']), d.production_id, 'dpr', 'File today’s daily report', day_label(d.day) || ' · call ' || d.call_time || '. Times, scenes, minutes and any delay.', 'schedule', true);
    n := n + 1;
  end loop;
  return n;
end $$;

-- profile and documents complete: the leads send the agreement next
create function public.profile_ready_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare c crew;
begin
  if (profile_ready(new) and docs_ready(new)) and not (profile_ready(old) and docs_ready(old)) then
    for c in select * from crew where user_id = new.id and active and removed_at is null and ag_status = 'none' and rate is not null loop
      perform notify(people_in(c.production_id, array['lp','hop']), c.production_id, 'onboard', crew_name(c) || ' is ready for their agreement',
        'Profile, bank and documents are complete. Send the agreement from Agreements.', 'agreements');
    end loop;
  end if;
  return null;
end $$;
create trigger profile_ready_notify after update on public.profiles for each row execute function public.profile_ready_notify();

-- today's check-ins wait for the Auditor
create function public.send_attendance_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare d shoot_days; k int; n int := 0;
begin
  for d in select * from shoot_days where day = today_ist() and status <> 'cancelled' and att_confirmed_at is null loop
    select count(*) into k from checkins where day_id = d.id and removed_at is null;
    continue when k = 0;
    perform notify(case when has_role(d.production_id, array['auditor']) then people_in(d.production_id, array['auditor']) else people_in(d.production_id, array['cfo','commercial']) end,
      d.production_id, 'attendance', 'Confirm today’s attendance: ' || k || ' checked in', day_label(d.day) || '. Invoices for these days wait for it.', 'schedule', true);
    n := n + 1;
  end loop;
  return n;
end $$;
do $$ begin
  perform cron.schedule('crewdesk-attendance-reminders', '35 15 * * *', 'select public.send_attendance_reminders()');   -- 21:05 IST
exception when others then raise notice 'pg_cron not available here; attendance reminders are not scheduled (%)', sqlerrm;
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.login_email(text), public.username_available(text) to anon;
revoke execute on function public.kyc_key(), public.kyc_enc(text), public.kyc_dec(bytea), public.apply_invoice_ot(uuid) from authenticated;
revoke execute on function public.send_call_reminders(), public.send_task_reminders(), public.send_dpr_reminders(), public.send_attendance_reminders() from authenticated;
