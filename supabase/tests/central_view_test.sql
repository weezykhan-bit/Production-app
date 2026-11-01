-- Views can't be written to or read anonymously. Runs last.
\set ON_ERROR_STOP 1
\set QUIET 1
\set imran '66666666-6666-6666-6666-666666666666'
reset role;
grant select, insert, update, delete on public.directory, public.people to anon, authenticated;   -- what Supabase grants by default
\i supabase/migrations/20261108100000_view_lockdown.sql
select as_user(:'imran'); set role authenticated;
select refused($$update public.people set full_name = 'HACKED' where true$$, 'permission denied');
select refused($$delete from public.people where true$$, 'permission denied');
select refused($$select count(*) from public.directory$$, 'permission denied');
select ok((select count(*) from public.people) > 0, 'crew still read the people they may see');
reset role;
set role anon;
select refused($$select count(*) from public.people$$, 'permission denied');
select refused($$update public.directory set phone = 'x' where true$$, 'permission denied');
reset role;
select ok(not exists (select 1 from profiles where full_name = 'HACKED'), 'no profile was changed');
\echo ALL VIEW TESTS PASSED
