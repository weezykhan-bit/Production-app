-- Hardening from the Supabase security scan.
alter function public.today_ist() set search_path = public;
-- names only for people the caller is allowed to see (inside the checked functions this is always true)
create or replace function public.pname(p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(full_name, ''), username, 'Someone') from profiles where id = p_user and person_visible(p_user) $$;
