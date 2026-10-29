-- Google sign-in and invite matching. Runs last.
\set ON_ERROR_STOP 1
\set QUIET 1
\set ritika '22222222-2222-2222-2222-222222222222'
\set g1 'a1111111-0000-0000-0000-000000000001'
\set g2 'a1111111-0000-0000-0000-000000000002'
\set g3 'a1111111-0000-0000-0000-000000000003'
\set g4 'a1111111-0000-0000-0000-000000000004'
select id as pid, code from productions limit 1 \gset
insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at) values
 (:'g1', 'g1@gmail.com', '{"name":"Gita One","avatar_url":"https://x"}', now()),
 (:'g2', 'g2@gmail.com', '{"full_name":"Gopal Two"}', now()),
 (:'g3', 'g3@test.in', '{"full_name":"Unconfirmed Three"}', null),
 (:'g4', 'g4@test.in', '{"full_name":"Confirmed Four"}', now());
select ok((select full_name from profiles where id = :'g1') = 'Gita One' and (select username from profiles where id = :'g1') is null, 'Google name becomes the profile name; no username needed');
select as_user(:'ritika'); set role authenticated;
select onboard(:'pid', '{"name":"Head Prod","phone":"+91 90000 11111","role":"hop","dept":"Production","job":"Head of Production","rate":20000,"joining":"2026-01-01"}') as hop_inv \gset
select onboard(:'pid', '{"name":"Gopal Two","phone":"90000 22222","role":"crew","dept":"Camera","job":"Camera Attendant","rate":2500,"joining":"2026-01-01"}') as crew_inv \gset
select onboard(:'pid', '{"name":"Accounts Person","email":"g3@test.in","role":"accounts","dept":"Accounts & Legal","job":"Production Accountant","rate":4000,"joining":"2026-01-01"}') as acc_inv \gset
select onboard(:'pid', '{"name":"Accounts Four","email":"G4@test.in","role":"accounts","dept":"Accounts & Legal","job":"Accounts Assistant","rate":3000,"joining":"2026-01-01"}') as acc4_inv \gset
reset role;
select as_user(:'g1'); set role authenticated;
select refused($$select set_my_phone('123')$$, '10-digit');
select set_my_phone('+91 90000 11111');
select ok((join_production(:'code') ->> 'ok')::boolean, 'Google user joins with the code');
select ok((select role from crew where user_id = :'g1') = 'crew', 'a mobile number alone can’t take a Head of Production invite');
reset role;
select ok((select user_id from crew where id = :'hop_inv') is null, 'the staff invite is still waiting');
select as_user(:'g2'); set role authenticated;
select set_my_phone('9000022222');
select join_production(:'code');
reset role;
select ok((select user_id from crew where id = :'crew_inv') = :'g2', 'a crew invite is matched on mobile');
select as_user(:'g3'); set role authenticated;
select join_production(:'code');
reset role;
select ok((select user_id from crew where id = :'acc_inv') is null, 'an unconfirmed email can’t take an invite');
select as_user(:'g4'); set role authenticated;
select join_production(:'code');
reset role;
select ok((select user_id from crew where id = :'acc4_inv') = :'g4', 'a confirmed email takes a staff invite (any letter case)');
select as_user(:'ritika'); set role authenticated;
select refused($$select add_admin('nobody@gmail.com', 'cfo')$$, 'No CrewDesk account');
select add_admin('G1@gmail.com', 'commercial');
reset role;
select ok((select role from company_admins where user_id = :'g1') = 'commercial', 'owner access can be given by email');
\echo ALL GOOGLE SIGN-IN TESTS PASSED
