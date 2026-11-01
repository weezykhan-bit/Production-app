-- Overtime, pro rata after a 12-hour shift.
--
-- A shift runs from the actual call to the actual wrap in the daily production report (lunch is part of it).
-- Past 12 hours, people on a day rate earn the day rate ÷ 12 for every hour over, counted to the minute:
-- a ₹6,000 day rate and a 13 h 30 m shift add ₹750. Episode, monthly and lump-sum deals get no overtime.
-- Gate check-in records arrival only, so everyone checked in on a day gets that day's overtime.
--
-- Overtime is added to the invoice fee (so GST and TDS apply to it) when the invoice is raised, and worked out
-- again when the Auditor approves it, in case a daily report was filed or corrected in between.

alter table public.productions add column ot_after_min int not null default 720 check (ot_after_min between 360 and 1440);
alter table public.crew_invoices add column ot_minutes int not null default 0, add column ot_amount bigint not null default 0;

-- minutes past the threshold on one shoot day (0 without a filed call and wrap)
create function public.day_ot_minutes(d public.shoot_days) returns int language sql stable set search_path = public as $$
  select case when d.act_call is null or d.act_wrap is null or d.status = 'cancelled' then 0 else greatest(0,
    ((extract(epoch from (d.act_wrap::time - d.act_call::time)) / 60)::int + 1440) % 1440   -- a wrap after midnight counts into the next day
    - (select ot_after_min from productions where id = d.production_id)) end $$;

-- a person's overtime for an invoice period: minutes and rupees
create function public.invoice_ot(p_production uuid, p_user uuid, p_from date, p_to date, p_rate bigint, p_unit text, out minutes int, out amount bigint)
language sql stable security definer set search_path = public as $$
  select coalesce(sum(day_ot_minutes(d)), 0)::int,
         case when p_unit = 'day' then round(p_rate * coalesce(sum(day_ot_minutes(d)), 0)::numeric / (select ot_after_min from productions where id = p_production))::bigint else 0 end
    from shoot_days d join checkins k on k.day_id = d.id and k.user_id = p_user and k.removed_at is null
   where d.production_id = p_production and d.day between p_from and p_to and p_unit = 'day' $$;

-- put overtime on an invoice and recompute GST, TDS and payable
create function public.apply_invoice_ot(p_id uuid) returns bigint
language plpgsql security definer set search_path = public as $$
declare i crew_invoices; o record; base bigint; amt bigint; t bigint;
        rates jsonb := '{"194C-1":1,"194C-2":2,"194J-10":10,"194J-2":2,"none":0}';
begin
  select * into i from crew_invoices where id = p_id;
  if i.id is null or i.tally_purchase is not null or i.status not in ('submitted','audited','hop_ok') then return 0; end if;
  select * into o from invoice_ot(i.production_id, i.user_id, i.period_from, i.period_to, i.rate, i.unit);
  if o.amount = i.ot_amount and o.minutes = i.ot_minutes then return o.amount; end if;
  base := i.amount - i.ot_amount; amt := base + o.amount; t := round(amt * coalesce((rates ->> i.tds_key)::numeric, 0) / 100);
  update crew_invoices set ot_minutes = o.minutes, ot_amount = o.amount, amount = amt, gst = round(amt * gst_rate / 100), tds = t,
         payable = amt + round(amt * gst_rate / 100) - t - deduction where id = p_id;
  if i.ot_amount <> 0 or o.amount <> 0 then
    perform add_log(i.production_id, 'invoice', 'Overtime on ' || i.no || ': ' || (o.minutes / 60) || 'h ' || lpad((o.minutes % 60)::text, 2, '0') || 'm · ₹' || o.amount
      || case when i.ot_amount <> 0 then ' (was ₹' || i.ot_amount || ')' else '' end, i.crew_id, i.id);
  end if;
  return o.amount;
end $$;
revoke execute on function public.apply_invoice_ot(uuid) from public, anon, authenticated;

create or replace function public.submit_crew_invoice(p_production uuid, p jsonb) returns uuid
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
  perform apply_invoice_ot(i.id);
  select * into i from crew_invoices where id = i.id;
  perform add_log(p_production, 'invoice', 'Submitted invoice ' || i.no || ' for ₹' || (i.amount + i.gst) || case when i.ot_amount > 0 then ' (incl. ₹' || i.ot_amount || ' overtime)' else '' end, c.id, i.id);
  return i.id;
exception when unique_violation then
  raise exception 'You’ve already used invoice number % on this production', trim(p ->> 'no');
end $$;

-- the Auditor's step works overtime out again from the daily reports as they stand
create or replace function public.advance_invoice(p_id uuid) returns text
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
    perform apply_invoice_ot(i.id);
    perform must(exists (select 1 from crew_invoices where id = p_id and payable >= 0), 'Deductions are now more than the amount payable; change them first');
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

revoke execute on all functions in schema public from public, anon;
grant execute on function public.login_email(text), public.username_available(text) to anon;
revoke execute on function public.apply_invoice_ot(uuid) from authenticated;
