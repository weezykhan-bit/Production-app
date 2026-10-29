-- Sign in with Google, and invites that can't be taken by the wrong person.
-- * Google accounts arrive without a username or mobile: take their name from Google, and let them add
--   a mobile number when they join, so invites made by mobile still find them.
-- * An invite is matched on email only once that email is confirmed (Google confirms it; password accounts
--   confirm by link). A mobile number is never checked, so a mobile match is allowed only for crew and vendor
--   invites; staff access (HOD, Line Producer, Head of Production, Accounts) needs the invited email.
-- * Onboarding someone by email links their existing account only if that email is confirmed.
-- * Owner access can be given by email as well as by username.

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare u text := nullif(lower(coalesce(new.raw_user_meta_data ->> 'username', '')), '');
begin
  if u is not null and (u !~ '^[a-z0-9_.]{3,30}$' or exists (select 1 from public.profiles where username = u)) then u := null; end if;
  insert into public.profiles (id, email, username, full_name, phone)
  values (new.id, new.email, u, nullif(coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'), ''), nullif(new.raw_user_meta_data ->> 'phone', ''))
  on conflict do nothing;
  return new;
end $$;

create function public.set_my_phone(p_phone text) returns void
language plpgsql security definer set search_path = public as $$
declare d text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  perform must(auth.uid() is not null, 'Sign in first');
  perform must(length(d) between 10 and 13, 'Enter your 10-digit mobile number');
  update profiles set phone = trim(p_phone), updated_at = now() where id = auth.uid();
end $$;

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
  if exists (select 1 from crew where production_id = pr.id and user_id = auth.uid()) then
    update crew set active = true where production_id = pr.id and user_id = auth.uid();
    return jsonb_build_object('ok', true, 'production_id', pr.id, 'name', pr.name, 'already', true);
  end if;
  select * into me from profiles where id = auth.uid();
  select lower(email) into em from auth.users where id = auth.uid() and email_confirmed_at is not null;
  ph := right(regexp_replace(coalesce(me.phone, ''), '\D', '', 'g'), 10);
  -- an invite made for this person: a confirmed email matches any invite; a mobile number only crew and vendor ones
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

create or replace function public.add_admin(p_username text, p_role text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid; k text := lower(trim(coalesce(p_username, '')));
begin
  perform must(admin_role() is not null, 'Only the CFO or Commercial Head can give owner access');
  perform must(p_role in ('cfo','commercial'), 'Owner access is for the CFO or the Commercial Head');
  select id into u from profiles where username = k or (position('@' in k) > 0 and lower(email) = k) limit 1;
  if u is null then raise exception 'No CrewDesk account with the username or email %', p_username; end if;
  insert into company_admins (user_id, role, added_by) values (u, p_role, auth.uid())
  on conflict (user_id) do update set role = excluded.role;
  perform add_log(null, 'company', 'Gave ' || pname(u) || ' owner access as ' || case p_role when 'cfo' then 'CFO' else 'Commercial Head' end);
end $$;

create or replace function public.onboard(p_production uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare r text := coalesce(nullif(p ->> 'role', ''), 'crew'); c crew; existing uuid; em text := nullif(lower(trim(p ->> 'email')), '');
begin
  perform must(prod_lead(p_production), 'Only the Line Producer, Head of Production, CFO or Commercial Head can onboard people');
  if r in ('hop','lp','accounts') then perform must(prod_owner(p_production), 'Only the CFO or Commercial Head can give that access'); end if;
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
