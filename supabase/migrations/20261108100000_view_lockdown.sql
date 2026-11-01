-- Views are read-only. Supabase grants anon and authenticated every privilege on new tables and views, and a
-- simple view such as `people` passes an UPDATE or DELETE straight through to `profiles` with its owner's rights,
-- skipping row-level security. All writes go through the checked functions, so nobody needs to write to a view.
do $$ declare v record; begin
  for v in select viewname from pg_views where schemaname = 'public' loop
    execute format('revoke insert, update, delete, truncate, references, trigger on public.%I from public, anon, authenticated', v.viewname);
    execute format('revoke select on public.%I from public, anon', v.viewname);
  end loop;
end $$;
-- `directory` is from the first prototype: it lists every user's name, phone and email with no filter. The app
-- reads `people` (filtered by person_visible) instead, so nobody may read `directory`.
revoke select on public.directory from authenticated;
-- tables and views made later start without write access for app users either
alter default privileges in schema public revoke insert, update, delete, truncate, references, trigger on tables from anon, authenticated;
