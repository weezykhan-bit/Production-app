-- Sign in with a mobile number, two-step login for the people who move money, encrypted PAN and bank numbers,
-- and an IMDb link on profiles.
--
-- Encryption: PAN and bank account numbers are stored encrypted (pgcrypto) with a key kept in Supabase Vault, not in
-- the table. A copy of the table or a backup shows only ciphertext and the last 4 characters. The people view decrypts
-- them for the person themselves, and for others who may see KYC (owners, Accounts) only after two-step login.
--
-- Two-step login: the CFO, Commercial Head and Accounts must confirm with an authenticator app (Supabase MFA, session
-- level aal2) before paying, sending to Tally, giving petty cash, changing a deal, approving an agreement, removing
-- someone or adding an owner. Everything else works with the password alone.
--
-- Mobile sign-in: Supabase phone (OTP) users get their verified number on their profile, so they are linked to the
-- invite that has that number when they join with the production code.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
do $$ begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'crewdesk_kyc_key') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'base64'), 'crewdesk_kyc_key', 'Encrypts PAN and bank account numbers in profiles');
  end if;
end $$;

-- ---------------------------------------------------------------- encryption helpers (never callable from the app)
create function public.kyc_key() returns text language sql stable security definer set search_path = public as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'crewdesk_kyc_key' limit 1 $$;
create function public.kyc_enc(t text) returns bytea language sql stable security definer set search_path = public as $$
  select case when nullif(t, '') is null then null else extensions.pgp_sym_encrypt(t, kyc_key()) end $$;
create function public.kyc_dec(b bytea) returns text language sql stable security definer set search_path = public as $$
  select case when b is null then null else extensions.pgp_sym_decrypt(b, kyc_key()) end $$;

-- the session has passed two-step login
create function public.strong_auth() returns boolean language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'aal', 'aal1') = 'aal2' $$;
create function public.must_mfa(p uuid) returns void language plpgsql stable security definer set search_path = public as $$
declare r text := case when p is null then (select role from company_admins where user_id = auth.uid()) else prod_role(p) end;
begin
  if r in ('cfo','commercial','accounts') and not strong_auth() then
    raise exception 'Confirm it’s you with two-step login first: your name menu → Two-step login';
  end if;
end $$;

-- ---------------------------------------------------------------- profiles: encrypt what is there, then keep it encrypted
alter table public.profiles
  add column pan_enc bytea, add column pan_tail text, add column bank_account_enc bytea, add column bank_tail text,
  add column imdb_url text check (imdb_url is null or imdb_url ~ '^https://(www\.|m\.)?imdb\.com/name/nm[0-9]{5,10}/?$');
update public.profiles set pan_enc = kyc_enc(pan), pan_tail = right(pan, 4), bank_account_enc = kyc_enc(bank_account), bank_tail = right(bank_account, 4)
 where pan is not null or bank_account is not null;
update public.profiles set pan = null, bank_account = null where pan is not null or bank_account is not null;
alter table public.profiles add constraint profiles_kyc_encrypted check (pan is null and bank_account is null);

-- a person's PAN or bank account, decrypted only for someone allowed to see it
create function public.kyc_reveal(p_user uuid, p_field text) returns text language sql stable security definer set search_path = public as $$
  select case when p_user = auth.uid() or (kyc_visible(p_user) and strong_auth())
              then kyc_dec(case p_field when 'pan' then x.pan_enc when 'bank' then x.bank_account_enc end) end
    from profiles x where x.id = p_user $$;


create or replace function public.kyc_missing(p public.profiles) returns text[]
language sql immutable as $$
  select array_remove(array[
    case when coalesce(trim(p.legal_name), '') = '' then 'legal name' end,
    case when p.pan_enc is null then 'PAN' end,
    case when coalesce(trim(p.address), '') = '' then 'address' end,
    case when p.bank_account_enc is null then 'bank account' end,
    case when p.bank_ifsc is null then 'IFSC' end,
    case when coalesce(trim(p.bank_holder), '') = '' then 'account holder' end
  ], null)
$$;

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
         case when kyc_visible(p.id) then p.bank_tail end     as bank_tail
  from profiles p
  where person_visible(p.id);

create or replace function public.save_profile(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare was boolean; old profiles; v_pan text := upper(trim(p ->> 'pan')); v_g text := nullif(upper(trim(p ->> 'gstin')), '');
        v_acct text := regexp_replace(coalesce(p ->> 'bank_account', ''), '\s', '', 'g'); v_ifsc text := upper(trim(p ->> 'bank_ifsc')); c crew; old_acct text; v_imdb text := nullif(trim(coalesce(p ->> 'imdb', '')), '');
begin
  perform must(auth.uid() is not null, 'Sign in first');
  perform must(v_pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$', 'PAN is 10 characters: 5 letters, 4 numbers, 1 letter (like ABCDE1234F).');
  perform must(v_acct ~ '^[0-9]{6,20}$', 'Account numbers are 6 to 20 digits.');
  perform must(v_imdb is null or v_imdb ~ '^https://(www\.|m\.)?imdb\.com/name/nm[0-9]{5,10}/?$', 'Paste your IMDb page link, like https://www.imdb.com/name/nm1234567');
  if v_g is not null then perform must(substr(v_g, 3, 10) = v_pan, 'Your GSTIN must contain your PAN (characters 3 to 12)'); end if;
  select * into old from profiles where id = auth.uid();
  old_acct := kyc_dec(old.bank_account_enc);
  was := profile_ready(old);
  update profiles set legal_name = trim(p ->> 'legal'), phone = nullif(trim(p ->> 'phone'), ''), emergency = nullif(trim(p ->> 'emergency'), ''),
    address = trim(p ->> 'address'), pan_enc = kyc_enc(v_pan), pan_tail = right(v_pan, 4), gstin = v_g, state_code = coalesce(substr(v_g, 1, 2), state_code),
    bank_holder = trim(p ->> 'bank_holder'), bank_name = nullif(trim(p ->> 'bank_name'), ''),
    bank_account_enc = kyc_enc(v_acct), bank_tail = right(v_acct, 4), bank_ifsc = v_ifsc,
    imdb_url = case when p ? 'imdb' then v_imdb else imdb_url end,
    full_name = coalesce(nullif(trim(p ->> 'full_name'), ''), full_name)
  where id = auth.uid();
  for c in select * from crew where user_id = auth.uid() and removed_at is null loop
    if old_acct is not null and (old_acct, old.bank_ifsc) is distinct from (v_acct, v_ifsc) then
      perform add_log(c.production_id, 'profile', 'Changed bank account: ••' || right(old_acct, 4) || ' (' || coalesce(old.bank_ifsc, '') || ') → ••' || right(v_acct, 4) || ' (' || v_ifsc || ')', c.id);
      perform notify(finance_of(c.production_id), c.production_id, 'bank', pname(auth.uid()) || ' changed their bank account',
        'Now ••' || right(v_acct, 4) || ' · ' || v_ifsc || ' (was ••' || right(old_acct, 4) || '). Check it before the next payment run.', 'finance');
    else
      perform add_log(c.production_id, 'profile', case when was then 'Updated profile and bank details' else 'Completed profile and bank details' end, c.id);
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------- mobile sign-in: the verified number goes on the profile
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare u text := nullif(lower(coalesce(new.raw_user_meta_data ->> 'username', '')), '');
begin
  if u is not null and (u !~ '^[a-z0-9_.]{3,30}$' or exists (select 1 from public.profiles where username = u)) then u := null; end if;
  insert into public.profiles (id, email, username, full_name, phone)
  values (new.id, new.email, u, nullif(coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'), ''),
          coalesce(nullif(new.raw_user_meta_data ->> 'phone', ''), case when nullif(new.phone, '') is not null then '+' || ltrim(new.phone, '+') end))
  on conflict do nothing;
  return new;
end $$;

-- someone who signed up with only a mobile number has no name yet: taking up an invite gives them the invited name
create function public.name_from_invite() returns trigger language plpgsql security definer set search_path = public as $$
begin
  update profiles set full_name = new.invite_name where id = new.user_id and coalesce(trim(full_name), '') = '' and coalesce(trim(new.invite_name), '') <> '';
  return null;
end $$;
create trigger crew_name_from_invite after update of user_id on public.crew for each row
  when (new.user_id is not null and old.user_id is null) execute function public.name_from_invite();

-- ---------------------------------------------------------------- money and people actions need two-step login
create or replace function public.pay_invoices(p_production uuid, p_ids uuid[], p_ref text) returns int
language plpgsql security definer set search_path = public as $$
declare n int; nos text; total bigint;
begin
  perform must_mfa(p_production);
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

create or replace function public.tally_mark(p_production uuid) returns text
language plpgsql security definer set search_path = public as $$
declare b text; np int; nq int; v bigint;
begin
  perform must_mfa(p_production);
  perform must(prod_finance(p_production), 'Only Finance, the CFO or the Commercial Head can send vouchers to Tally');
  b := 'TX-' || lpad(((select count(*) from tally_exports where production_id = p_production) + 1)::text, 3, '0');
  select count(*), coalesce(sum(amount + gst), 0) into np, v from crew_invoices where production_id = p_production and status in ('approved','paid') and tally_purchase is null;
  select count(*) into nq from crew_invoices where production_id = p_production and status = 'paid' and tally_payment is null;
  if np + nq = 0 then raise exception 'Nothing new to send to Tally'; end if;
  update crew_invoices set tally_purchase = b where production_id = p_production and status in ('approved','paid') and tally_purchase is null;
  update crew_invoices set tally_payment = b where production_id = p_production and status = 'paid' and tally_payment is null;
  insert into tally_exports (production_id, batch, by, purchases, payments, value) values (p_production, b, auth.uid(), np, nq, v);
  perform add_log(p_production, 'finance', 'Sent ' || np || ' purchase and ' || nq || ' payment vouchers to Tally (' || b || ')');
  return b;
end $$;

create or replace function public.give_petty_float(p_production uuid, p_holder uuid, p_amount bigint, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform must_mfa(p_production);
  perform must(prod_role(p_production) in ('cfo','accounts','commercial','commercial_mgr'), 'Only the CFO, Accounts or the commercial side give petty cash');
  perform must(p_amount <> 0, 'Enter an amount (negative if cash came back)');
  perform must(exists (select 1 from crew where production_id = p_production and user_id = p_holder and active), 'Give petty cash to someone on this production');
  insert into petty_floats (production_id, holder, amount, note, given_by) values (p_production, p_holder, p_amount, nullif(trim(coalesce(p_note, '')), ''), auth.uid());
  perform add_log(p_production, 'cost', case when p_amount > 0 then 'Gave ₹' || p_amount || ' petty cash to ' else 'Took back ₹' || abs(p_amount) || ' petty cash from ' end || coalesce(pname(p_holder), 'someone'));
  perform notify(array[p_holder], p_production, 'cost', case when p_amount > 0 then 'Petty cash ₹' || p_amount || ' given to you' else 'Petty cash ₹' || abs(p_amount) || ' returned' end,
    coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Record what you spend from it in Daily costs.'), 'costs');
end $$;

create or replace function public.set_deal(p_crew uuid, p jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare c crew; n crew; k text; changed int := 0;
begin
  perform must_mfa((select production_id from crew where id = p_crew));
  select * into c from crew where id = p_crew;
  perform must(c.id is not null and prod_owner(c.production_id), 'Only the CFO or Commercial Head can change a deal');
  perform must(c.user_id is distinct from auth.uid() or coalesce(p ->> 'role', c.role) = c.role, 'You can’t change your own access');
  n := c;
  n.rate := coalesce((p ->> 'rate')::bigint, c.rate); n.unit := coalesce(nullif(p ->> 'unit', ''), c.unit);
  n.joining := coalesce(nullif(p ->> 'joining', '')::date, c.joining);
  n.end_date := case when p ? 'end' then nullif(p ->> 'end', '')::date else c.end_date end;
  n.tds := coalesce(nullif(p ->> 'tds', ''), c.tds); n.terms := coalesce((p ->> 'terms')::int, c.terms);
  n.dept := coalesce(nullif(p ->> 'dept', ''), c.dept); n.job := coalesce(nullif(p ->> 'job', ''), c.job); n.role := coalesce(nullif(p ->> 'role', ''), c.role);
  perform must(n.rate > 0, 'Enter the rate in rupees');
  if c.ag_status in ('signed','countersigned') and (n.rate is distinct from c.rate or n.unit is distinct from c.unit) then
    raise exception 'The fee is in a signed agreement. Agree the change in writing, then issue a new agreement';
  end if;
  update crew set rate = n.rate, unit = n.unit, joining = n.joining, end_date = n.end_date, tds = n.tds, terms = n.terms, dept = n.dept, job = n.job, role = n.role
   where id = p_crew;
  foreach k in array array['rate','unit','joining','end_date','tds','terms','dept','job','role'] loop
    if to_jsonb(c) -> k is distinct from to_jsonb(n) -> k then
      changed := changed + 1;
      perform add_log(c.production_id, 'deal', 'Changed ' || crew_name(c) || '’s ' || replace(k, '_', ' '), c.id, null, k, to_jsonb(c) -> k, to_jsonb(n) -> k);
    end if;
  end loop;
  -- a sent but unsigned agreement no longer matches the deal: withdraw it so it is re-sent with the new terms
  if changed > 0 and c.ag_status = 'sent' then
    update crew set ag_status = 'none', ag_text = null, ag_sent_at = null where id = p_crew;
    perform add_log(c.production_id, 'agreement', 'Withdrew ' || crew_name(c) || '’s unsigned agreement because the deal changed', c.id);
  end if;
  return changed;
end $$;

create or replace function public.countersign(p_crew uuid) returns void
language plpgsql security definer set search_path = public as $$
declare c crew;
begin
  perform must_mfa((select production_id from crew where id = p_crew));
  select * into c from crew where id = p_crew;
  perform must(c.id is not null and prod_owner(c.production_id), 'Only the CFO or Commercial Head can approve agreements');
  if c.ag_status <> 'signed' then raise exception 'Only a signed agreement can be approved'; end if;
  update crew set ag_status = 'countersigned', ag_counter_at = now(), ag_counter_by = auth.uid() where id = p_crew;
  perform add_log(c.production_id, 'agreement', 'Approved ' || crew_name(c) || '’s agreement', c.id);
end $$;

create or replace function public.remove_person(p_crew uuid, p_reason text) returns text
language plpgsql security definer set search_path = public as $$
declare c crew; why text := trim(coalesce(p_reason, '')); pn text; who text; keep boolean; outcome text;
begin
  perform must_mfa((select production_id from crew where id = p_crew));
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

create or replace function public.add_admin(p_username text, p_role text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid; k text := lower(trim(coalesce(p_username, '')));
begin
  perform must_mfa(null);
  perform must(admin_role() is not null, 'Only the CFO or Commercial Head can give owner access');
  perform must(p_role in ('cfo','commercial'), 'Owner access is for the CFO or the Commercial Head');
  select id into u from profiles where username = k or (position('@' in k) > 0 and lower(email) = k) limit 1;
  if u is null then raise exception 'No CrewDesk account with the username or email %', p_username; end if;
  insert into company_admins (user_id, role, added_by) values (u, p_role, auth.uid())
  on conflict (user_id) do update set role = excluded.role;
  perform add_log(null, 'company', 'Gave ' || pname(u) || ' owner access as ' || case p_role when 'cfo' then 'CFO' else 'Commercial Head' end);
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.login_email(text), public.username_available(text) to anon;
revoke execute on function public.kyc_key(), public.kyc_enc(text), public.kyc_dec(bytea), public.apply_invoice_ot(uuid) from authenticated;
revoke execute on function public.send_call_reminders(), public.send_task_reminders(), public.send_dpr_reminders() from authenticated;
