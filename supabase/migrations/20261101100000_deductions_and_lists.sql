-- Payment deductions and remarks on invoices, and artists / crew / vendors kept apart.
-- * An invoice can carry deductions taken off what is paid (advance recovered, loss or damage, food or stay,
--   late or penalty, other), each with a note, and one remark for the person. TDS stays worked out on the fee.
--   Wrong days or rate are not a deduction: reject the invoice so the fee, GST and TDS are worked out again.
-- * Whether someone is an artist, crew or a vendor now follows their department, so the lists never drift.

alter table public.crew_invoices
  add column deductions jsonb not null default '[]' check (jsonb_typeof(deductions) = 'array'),
  add column deduction  bigint not null default 0 check (deduction >= 0),
  add column remarks    text check (remarks is null or length(remarks) <= 500),
  add column adjusted_by uuid references auth.users on delete set null,
  add column adjusted_at timestamptz;

-- ---------------------------------------------------------------- artist, crew or vendor
create function public.crew_kind() returns trigger
language plpgsql set search_path = public as $$
begin
  new.kind := case when new.role = 'vendor' or new.dept = 'Vendors & Services' then 'vendor'
                   when new.dept = 'Cast' then 'cast'
                   when coalesce(new.dept, '') <> '' then 'crew'
                   else new.kind end;
  return new;
end $$;
create trigger crew_kind before insert or update of dept, role, kind on public.crew for each row execute function public.crew_kind();
update public.crew set kind = kind;   -- bring existing rows in line

-- ---------------------------------------------------------------- deductions and remarks
create function public.set_invoice_adjustments(p_id uuid, p_items jsonb, p_remarks text) returns bigint
language plpgsql security definer set search_path = public as $$
declare i crew_invoices; it jsonb; clean jsonb := '[]'; total bigint := 0; a bigint; k text; n text;
        labels jsonb := '{"advance":"Advance recovered","damage":"Loss or damage","stay":"Food, stay or travel","penalty":"Late or penalty","other":"Other"}';
        rem text := nullif(trim(coalesce(p_remarks, '')), ''); before text;
begin
  select * into i from crew_invoices where id = p_id;
  perform must(i.id is not null, 'No such invoice');
  perform must(prod_role(i.production_id) in ('cfo','commercial','hop','lp','accounts'),
               'Only the Line Producer, Head of Production, Accounts, CFO or Commercial Head can add deductions');
  perform must(i.user_id <> auth.uid(), 'You can’t adjust your own invoice');
  perform must(i.status in ('submitted','hod_ok','approved'), 'Deductions can only change before the invoice is paid');
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

-- tell the person when what they'll be paid changes, or a remark is added
create function public.invoice_adjust_notify() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.deduction is distinct from old.deduction then
    perform notify(array[new.user_id], new.production_id, 'invoice',
      case when new.deduction > 0 then 'Deduction on invoice ' || new.no else 'Deductions removed from invoice ' || new.no end,
      coalesce((select string_agg((d ->> 'label') || ' ' || inr((d ->> 'amount')::bigint) || ': ' || (d ->> 'note'), ' · ') || ' · '
                  from jsonb_array_elements(new.deductions) d), '') || 'You’ll be paid ' || inr(new.payable) || '.' || coalesce(' Remark: ' || new.remarks, ''), 'invoices');
  elsif new.remarks is distinct from old.remarks and new.remarks is not null then
    perform notify(array[new.user_id], new.production_id, 'invoice', 'Remark on invoice ' || new.no, new.remarks, 'invoices');
  end if;
  return null;
end $$;
create trigger invoice_adjust_notify after update of deduction, remarks on public.crew_invoices for each row execute function public.invoice_adjust_notify();
