-- Production Controller step, uploaded invoice files, and the Auditor mapping each invoice to the cost report.
--
-- The chain is now: submitted → Auditor (checks days against confirmed attendance and maps the invoice to a cost
-- head) → Production Controller → Head of Production → Commercial Head or Commercial Manager → CFO or Accounts pays.
-- A show with nobody in a step's role falls back as before (owners and the Line Producer; the CFO for the commercial step).
-- People can upload their own invoice (PDF or photo); it is required when they charge GST, since Accounts needs it
-- to claim the input credit. Only people who can see the invoice can open the file.

alter table public.crew drop constraint crew_role_check;
alter table public.crew add constraint crew_role_check check (role in ('hop','lp','accounts','hod','crew','vendor','auditor','commercial_mgr','controller'));
alter table public.crew_invoices drop constraint crew_invoices_status_check;
alter table public.crew_invoices add constraint crew_invoices_status_check check (status in ('submitted','audited','pc_ok','hop_ok','approved','paid','rejected'));
alter table public.crew_invoices
  add column pc_by uuid references auth.users on delete set null, add column pc_at timestamptz,
  add column cost_head text check (cost_head is null or length(cost_head) between 2 and 60),
  add column doc_path text;

create or replace function public.prod_audit(p uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(prod_role(p) in ('cfo','commercial','commercial_mgr','hop','lp','accounts','auditor','controller'), false) $$;
create or replace function public.cost_role(p uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(prod_role(p) in ('cfo','commercial','commercial_mgr','hop','lp','accounts','auditor','controller'), false) $$;
create or replace function public.task_head(p uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(prod_role(p) in ('cfo','commercial','commercial_mgr','hop','lp','auditor','controller','hod'), false) $$;
alter policy "own, leads and finance, or HOD's department" on public.crew_invoices using (user_id = (select auth.uid())
  or prod_role(production_id) = any (array['cfo','commercial','commercial_mgr','hop','lp','accounts','auditor','controller'])
  or (prod_role(production_id) = 'hod' and dept = (select c.dept from crew c where c.production_id = crew_invoices.production_id and c.user_id = (select auth.uid()))));

create or replace function public.onboard(p_production uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare r text := coalesce(nullif(p ->> 'role', ''), 'crew'); c crew; existing uuid; em text := nullif(lower(trim(p ->> 'email')), '');
begin
  perform must(prod_lead(p_production), 'Only the Line Producer, Head of Production, CFO or Commercial Head can onboard people');
  if r in ('hop','lp','accounts','auditor','commercial_mgr','controller') then perform must(prod_owner(p_production), 'Only the CFO or Commercial Head can give that access'); end if;
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

create or replace function public.invoice_step_ok(i public.crew_invoices) returns boolean
language sql stable security definer set search_path = public as $$
  select case i.status
    when 'submitted' then prod_role(i.production_id) = 'auditor'
      or (not has_role(i.production_id, array['auditor']) and prod_role(i.production_id) in ('cfo','commercial','lp'))
    when 'audited' then prod_role(i.production_id) = 'controller'
      or (not has_role(i.production_id, array['controller']) and prod_role(i.production_id) in ('cfo','commercial','lp'))
    when 'pc_ok' then prod_role(i.production_id) = 'hop'
      or (not has_role(i.production_id, array['hop']) and prod_role(i.production_id) in ('cfo','commercial','lp'))
    when 'hop_ok' then prod_role(i.production_id) in ('commercial','commercial_mgr')
      or (not has_role(i.production_id, array['commercial','commercial_mgr']) and prod_role(i.production_id) = 'cfo')
    else false end $$;
create or replace function public.step_people(p uuid, st text) returns uuid[]
language sql stable security definer set search_path = public as $$
  select case st
    when 'submitted' then case when has_role(p, array['auditor']) then people_in(p, array['auditor']) else people_in(p, array['cfo','commercial','lp']) end
    when 'audited' then case when has_role(p, array['controller']) then people_in(p, array['controller']) else people_in(p, array['cfo','commercial','lp']) end
    when 'pc_ok' then case when has_role(p, array['hop']) then people_in(p, array['hop']) else people_in(p, array['cfo','commercial','lp']) end
    when 'hop_ok' then case when has_role(p, array['commercial','commercial_mgr']) then people_in(p, array['commercial','commercial_mgr']) else people_in(p, array['cfo']) end
    when 'approved' then people_in(p, array['cfo','accounts'])
    else '{}' end $$;

-- the Auditor's step maps the invoice to a cost-report head (the department unless they pick another)
drop function public.advance_invoice(uuid);
create function public.advance_invoice(p_id uuid, p_head text default null) returns text
language plpgsql security definer set search_path = public as $$
declare i crew_invoices; ok int; nxt text; h text := nullif(trim(coalesce(p_head, '')), '');
begin
  select * into i from crew_invoices where id = p_id;
  perform must(i.id is not null, 'No such invoice');
  perform must(i.status in ('submitted','audited','pc_ok','hop_ok'), 'This invoice isn’t waiting for an approval');
  perform must(i.user_id <> auth.uid(), 'You can’t approve your own invoice');
  perform must(invoice_step_ok(i), case i.status when 'submitted' then 'The Auditor approves this step' when 'audited' then 'The Production Controller checks this step'
                                    when 'pc_ok' then 'The Head of Production confirms this step' else 'The Commercial Head or a Commercial Manager approves this step' end);
  if i.status = 'submitted' then
    perform must(h is null or length(h) between 2 and 60, 'Pick the cost head');
    if i.unit = 'day' then
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
    update crew_invoices set cost_head = coalesce(h, cost_head, dept) where id = p_id;
  end if;
  nxt := case i.status when 'submitted' then 'audited' when 'audited' then 'pc_ok' when 'pc_ok' then 'hop_ok' else 'approved' end;
  update crew_invoices set status = nxt,
    audited_by = case when nxt = 'audited' then auth.uid() else audited_by end, audited_at = case when nxt = 'audited' then now() else audited_at end,
    pc_by = case when nxt = 'pc_ok' then auth.uid() else pc_by end, pc_at = case when nxt = 'pc_ok' then now() else pc_at end,
    hop_by = case when nxt = 'hop_ok' then auth.uid() else hop_by end, hop_at = case when nxt = 'hop_ok' then now() else hop_at end,
    approved_by = case when nxt = 'approved' then auth.uid() else approved_by end, approved_at = case when nxt = 'approved' then now() else approved_at end
  where id = p_id;
  perform add_log(i.production_id, 'invoice', case nxt when 'audited' then 'Audited ' when 'pc_ok' then 'Production Controller checked ' when 'hop_ok' then 'HOP confirmed ' else 'Approved for payment ' end
    || i.no || ' (' || pname(i.user_id) || ')' || case when nxt = 'audited' then ' · cost head ' || coalesce(h, i.cost_head, i.dept, '—') else '' end, i.crew_id, i.id);
  return nxt;
end $$;

create or replace function public.reject_crew_invoice(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare i crew_invoices;
begin
  select * into i from crew_invoices where id = p_id;
  perform must(i.id is not null, 'No such invoice');
  perform must(i.status in ('submitted','audited','pc_ok','hop_ok'), 'Only an invoice still in approval can be rejected');
  perform must(i.user_id <> auth.uid(), 'You can’t reject your own invoice');
  perform must(invoice_step_ok(i) or prod_owner(i.production_id), 'You can’t reject this invoice at this step');
  perform must(length(trim(coalesce(p_reason, ''))) >= 4, 'Say why, so they can fix it and resubmit');
  update crew_invoices set status = 'rejected', reason = trim(p_reason) where id = p_id;
  perform add_log(i.production_id, 'invoice', 'Rejected ' || i.no || ': ' || trim(p_reason), i.crew_id, i.id);
end $$;

create or replace function public.remove_person(p_crew uuid, p_reason text) returns text
language plpgsql security definer set search_path = public as $$
declare c crew; why text := trim(coalesce(p_reason, '')); pn text; who text; keep boolean; outcome text;
begin
  select * into c from crew where id = p_crew;
  perform must(c.id is not null and prod_owner(c.production_id), 'Only the CFO or Commercial Head can remove someone');
  perform must(c.removed_at is null, 'They’re already removed');
  perform must(c.user_id is distinct from auth.uid(), 'You can’t remove yourself');
  perform must(length(why) >= 4, 'Say why they’re being removed');
  perform must(not exists (select 1 from crew_invoices where crew_id = c.id and status in ('submitted','audited','pc_ok','hop_ok','approved')),
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

create or replace function public.set_invoice_adjustments(p_id uuid, p_items jsonb, p_remarks text) returns bigint
language plpgsql security definer set search_path = public as $$
declare i crew_invoices; it jsonb; clean jsonb := '[]'; total bigint := 0; a bigint; k text; n text;
        labels jsonb := '{"advance":"Advance recovered","damage":"Loss or damage","stay":"Food, stay or travel","penalty":"Late or penalty","other":"Other"}';
        rem text := nullif(trim(coalesce(p_remarks, '')), ''); before text;
begin
  select * into i from crew_invoices where id = p_id;
  perform must(i.id is not null, 'No such invoice');
  perform must(prod_role(i.production_id) in ('cfo','commercial','commercial_mgr','hop','lp','accounts','auditor','controller'),
               'Only the production office can add deductions');
  perform must(i.user_id <> auth.uid(), 'You can’t adjust your own invoice');
  perform must(i.status in ('submitted','audited','pc_ok','hop_ok','approved'), 'Deductions can only change before the invoice is paid');
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

create or replace function public.apply_invoice_ot(p_id uuid) returns bigint
language plpgsql security definer set search_path = public as $$
declare i crew_invoices; o record; base bigint; amt bigint; t bigint;
        rates jsonb := '{"194C-1":1,"194C-2":2,"194J-10":10,"194J-2":2,"none":0}';
begin
  select * into i from crew_invoices where id = p_id;
  if i.id is null or i.tally_purchase is not null or i.status not in ('submitted','audited','pc_ok','hop_ok') then return 0; end if;
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

create or replace function public.submit_crew_invoice(p_production uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare c crew; me profiles; amt bigint; g bigint; t bigint; gr numeric := coalesce((p ->> 'gst_rate')::numeric, 0); q numeric := (p ->> 'qty')::numeric; i crew_invoices;
        rates jsonb := '{"194C-1":1,"194C-2":2,"194J-10":10,"194J-2":2,"none":0}'; doc text := nullif(trim(p ->> 'doc_path'), '');
begin
  select * into c from crew where production_id = p_production and user_id = auth.uid() and active;
  perform must(c.id is not null, 'Join the production before invoicing it');
  perform must(c.ag_status = 'countersigned', 'You can raise invoices once your agreement is approved');
  perform must(c.rate is not null, 'Your deal isn’t set yet');
  select * into me from profiles where id = auth.uid();
  perform must(q > 0, 'Enter the quantity');
  if gr > 0 and me.gstin is null then raise exception 'Add your GSTIN to your profile to charge GST'; end if;
  if gr > 0 then perform must(doc is not null, 'Upload your GST invoice (PDF or photo): Accounts needs it to claim the GST'); end if;
  if doc is not null then perform must(doc like auth.uid()::text || '/%', 'Upload the invoice file again'); end if;
  amt := round(q * c.rate); g := round(amt * gr / 100); t := round(amt * (rates ->> c.tds)::numeric / 100);
  insert into crew_invoices (production_id, crew_id, user_id, dept, no, period_from, period_to, qty, rate, unit, descr, amount, gst_rate, gst, tds_key, tds, payable, doc_path)
  values (p_production, c.id, auth.uid(), c.dept, trim(p ->> 'no'), (p ->> 'from')::date, (p ->> 'to')::date, q, c.rate, c.unit,
          coalesce(nullif(trim(p ->> 'desc'), ''), c.job || ', ' || to_char((p ->> 'from')::date, 'DD Mon') || ' to ' || to_char((p ->> 'to')::date, 'DD Mon YYYY')),
          amt, gr, g, c.tds, t, amt + g - t, doc)
  returning * into i;
  perform apply_invoice_ot(i.id);
  select * into i from crew_invoices where id = i.id;
  perform add_log(p_production, 'invoice', 'Submitted invoice ' || i.no || ' for ₹' || (i.amount + i.gst) || case when i.ot_amount > 0 then ' (incl. ₹' || i.ot_amount || ' overtime)' else '' end, c.id, i.id);
  return i.id;
exception when unique_violation then
  raise exception 'You’ve already used invoice number % on this production', trim(p ->> 'no');
end $$;

create or replace function public.invoice_notify() returns trigger
language plpgsql set search_path = public as $$
declare who text := coalesce(pname(new.user_id), 'Crew'); amt text := inr(new.payable);
begin
  if tg_op = 'INSERT' then
    perform notify(array[new.user_id], new.production_id, 'invoice', 'Invoice ' || new.no || ' submitted', amt || ' payable · next: the Auditor checks it against your days and the cost report.', 'invoices', true);
    perform notify(step_people(new.production_id, 'submitted'), new.production_id, 'invoice', 'Invoice ' || new.no || ' to audit', who || ' · ' || amt || ' · check the days against confirmed attendance', 'invoices');
  elsif new.status is distinct from old.status then
    if new.status = 'audited' then
      perform notify(array[new.user_id], new.production_id, 'invoice', 'Invoice ' || new.no || ' passed the audit', 'Step 2 of 5: with the Production Controller.', 'invoices');
      perform notify(step_people(new.production_id, 'audited'), new.production_id, 'invoice', 'Invoice ' || new.no || ' to check', who || ' · ' || amt || ' · audited' || coalesce(' · ' || new.cost_head, ''), 'invoices');
    elsif new.status = 'pc_ok' then
      perform notify(array[new.user_id], new.production_id, 'invoice', 'Invoice ' || new.no || ' checked by the Production Controller', 'Step 3 of 5: with the Head of Production.', 'invoices');
      perform notify(step_people(new.production_id, 'pc_ok'), new.production_id, 'invoice', 'Invoice ' || new.no || ' to confirm', who || ' · ' || amt || ' · audited and checked', 'invoices');
    elsif new.status = 'hop_ok' then
      perform notify(array[new.user_id], new.production_id, 'invoice', 'Invoice ' || new.no || ' confirmed by the Head of Production', 'Step 4 of 5: with the Commercial Head.', 'invoices');
      perform notify(step_people(new.production_id, 'hop_ok'), new.production_id, 'invoice', 'Invoice ' || new.no || ' needs commercial approval', who || ' · ' || amt, 'invoices');
    elsif new.status = 'approved' then
      perform notify(array[new.user_id], new.production_id, 'invoice', 'Invoice ' || new.no || ' approved for payment', 'Step 5 of 5: ' || amt || ' will be paid within your payment terms.', 'invoices');
      perform notify(step_people(new.production_id, 'approved'), new.production_id, 'invoice', 'Invoice ' || new.no || ' ready to pay', who || ' · ' || amt, 'finance');
    elsif new.status = 'paid' then
      perform notify(array[new.user_id], new.production_id, 'payment', 'Invoice ' || new.no || ' paid', amt || ' · bank reference ' || coalesce(new.utr, '—'), 'invoices');
    elsif new.status = 'rejected' then
      perform notify(array[new.user_id], new.production_id, 'invoice', 'Invoice ' || new.no || ' was rejected', coalesce(new.reason, '') || ' · fix it and submit again.', 'invoices');
    end if;
  end if;
  return null;
end $$;

-- uploaded invoices: a private bucket; upload into your own folder, read if you can see the invoice
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('invoices', 'invoices', false, 5242880, array['application/pdf','image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
create policy "invoices: upload into own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'invoices' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "invoices: read with the invoice" on storage.objects for select to authenticated
  using (bucket_id = 'invoices' and ((storage.foldername(name))[1] = (select auth.uid())::text
         or exists (select 1 from public.crew_invoices i where i.doc_path = objects.name)));

revoke execute on all functions in schema public from public, anon;
grant execute on function public.login_email(text), public.username_available(text) to anon;
revoke execute on function public.apply_invoice_ot(uuid) from authenticated;
