-- Notification choices and the new pings to the next in line. Runs last.
\set ON_ERROR_STOP 1
\set QUIET 1
\set manoj  '33333333-3333-3333-3333-333333333333'
\set imran  '66666666-6666-6666-6666-666666666666'
\set aud 'b1111111-0000-0000-0000-000000000001'
select id as pid from productions limit 1 \gset
select as_user(:'imran'); set role authenticated;
select refused($$select set_notify_prefs(array['payment'])$$, 'can’t be switched off');
select ok(set_notify_prefs(array['invoice_step','schedule','invoice_step']) = array['invoice_step','schedule'], 'crew switch off invoice steps and schedule updates');
select ok((select notify_off from people where id = :'imran') = array['invoice_step','schedule'], 'they see their own choices');
reset role;
select as_user(:'manoj'); set role authenticated;
select ok((select notify_off from people where id = :'imran') is null, 'nobody else sees them');
reset role;
-- an invoice moving along no longer pings Imran, but approvers are still asked and payment still arrives
delete from notifications;
select as_user(:'imran'); set role authenticated;
select submit_crew_invoice(:'pid', '{"no":"IS-NP","from":"2026-09-10","to":"2026-09-10","qty":1}') as inv \gset
reset role;
select ok(not exists (select 1 from notifications where user_id = :'imran'), 'no “submitted” notice for someone who switched it off');
select ok(exists (select 1 from notifications where user_id = :'aud' and title = 'Invoice IS-NP to audit'), 'the Auditor is still asked');
select as_user(:'aud'); set role authenticated;
select advance_invoice(:'inv');
reset role;
select ok(not exists (select 1 from notifications where user_id = :'imran'), 'no step notice');
update crew_invoices set status = 'rejected', reason = 'Wrong dates' where id = :'inv';
select ok(exists (select 1 from notifications where user_id = :'imran' and title = 'Invoice IS-NP was rejected'), 'a rejection always arrives');
-- schedule changes are muted for him, still sent to others
delete from notifications;
select as_user(:'manoj'); set role authenticated;
select plan_days(:'pid', jsonb_build_object('from', today_ist() + 60, 'to', today_ist() + 60, 'skip_sundays', false));
reset role;
select ok(not exists (select 1 from notifications where user_id = :'imran' and kind = 'schedule'), 'schedule update muted for him');
select ok(exists (select 1 from notifications where kind = 'schedule'), 'others still hear about it');
select as_user(:'imran'); set role authenticated;
select set_notify_prefs('{}');
reset role;
-- profile and documents complete: the LP is told to send the agreement
delete from notifications;
insert into auth.users (id, email, raw_user_meta_data) values ('d1111111-0000-0000-0000-000000000001', 'tara@test.in', '{"full_name":"Tara Shah"}');
update crew set user_id = 'd1111111-0000-0000-0000-000000000001', ag_status = 'none' where id = (select id from crew where user_id is null and rate is not null and production_id = :'pid' limit 1);
select as_user('d1111111-0000-0000-0000-000000000001'); set role authenticated;
select save_profile('{"legal":"Tara Shah","pan":"ABCPS7777K","address":"Mumbai","bank_holder":"Tara Shah","bank_account":"123456789012","bank_ifsc":"HDFC0001234"}');
reset role;
select ok(not exists (select 1 from notifications where title like '%ready for their agreement'), 'not yet: documents are missing');
update profiles set aadhaar_path = 'd1111111-0000-0000-0000-000000000001/a.jpg', pan_path = 'd1111111-0000-0000-0000-000000000001/p.jpg', aadhaar_last4 = '1234', consent_at = now() where id = 'd1111111-0000-0000-0000-000000000001';
select ok(exists (select 1 from notifications where user_id = :'manoj' and title like '% is ready for their agreement' and view = 'agreements'), 'the Line Producer is told to send the agreement');
-- check-ins waiting for the Auditor
delete from notifications;
update shoot_days set att_confirmed_at = null, status = 'shot' where production_id = :'pid' and day = today_ist();
insert into checkins (day_id, user_id) select id, :'imran' from shoot_days where production_id = :'pid' and day = today_ist() on conflict (day_id, user_id) do update set removed_at = null;
select ok(send_attendance_reminders() >= 1, 'the evening job finds today’s unconfirmed check-ins');
select ok(exists (select 1 from notifications where user_id = :'aud' and title like 'Confirm today’s attendance: %'), 'the Auditor is asked to confirm');
-- the daily report reminder is work, so a muted schedule doesn't hide it
select as_user(:'manoj'); set role authenticated;
select set_notify_prefs(array['schedule']);
reset role;
update shoot_days set dpr_at = null where production_id = :'pid' and day = today_ist();
select send_dpr_reminders();
select ok(exists (select 1 from notifications where user_id = :'manoj' and title = 'File today’s daily report'), 'the daily report reminder still reaches the LP');
\echo ALL NOTIFICATION CHOICE TESTS PASSED
