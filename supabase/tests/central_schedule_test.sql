-- Schedule alerts and the review fixes. Runs last.
\set ON_ERROR_STOP 1
\set QUIET 1
\set manoj  '33333333-3333-3333-3333-333333333333'
\set neha   '44444444-4444-4444-4444-444444444444'
\set imran  '66666666-6666-6666-6666-666666666666'
\set g2 'a1111111-0000-0000-0000-000000000002'
select id as pid from productions limit 1 \gset
select as_user(:'manoj'); set role authenticated;
select ok(plan_days(:'pid', jsonb_build_object('from', today_ist() + 30, 'to', today_ist() + 32, 'skip_sundays', false, 'call', '07:00', 'location', 'Film City · Floor 9', 'eps_per_day', 1, 'start_ep', 500)) = 3, 'LP plans three days');
select id as d1 from shoot_days where day = today_ist() + 30 \gset
select id as d2 from shoot_days where day = today_ist() + 31 \gset
select update_day(:'d1', '{"call":"06:30","location":"Film City · Floor 9"}');
select refused(format($$select update_day(%L, '{"call":"7am"}')$$, :'d1'), 'times like 07:30');
select set_day_status(:'d2', 'cancelled', 'Lead actor unwell');
select ok((select note from shoot_days where id = :'d2') = 'Lead actor unwell', 'the cancellation reason is kept');
-- a day with people checked in can't be cancelled or moved back
select id as past from shoot_days d where exists (select 1 from checkins k where k.day_id = d.id and k.removed_at is null) limit 1 \gset
select refused(format($$select set_day_status(%L, 'cancelled')$$, :'past'), 'checked in on this day');
select refused(format($$select set_day_status(%L, 'planned')$$, :'past'), 'checked in on this day');
reset role;
select as_user(:'imran'); set role authenticated;
select ok(exists (select 1 from notifications where title = '3 new shoot days: ' || to_char(today_ist() + 30, 'DD Mon') || ' – ' || to_char(today_ist() + 32, 'DD Mon') and body like 'First call % at 07:00 · Film City · Floor 9 · Ep 500%'), 'crew are told about new shoot days with the call time');
select ok(exists (select 1 from notifications where title like 'Call time changed:%' and body like 'Call 06:30 (was 07:00)%'), 'crew are told when a call time changes');
select ok(exists (select 1 from notifications where title like 'Shoot cancelled:%' and body = 'Lead actor unwell'), 'crew are told when a day is cancelled, with the reason');
select ok((select count(*) from notifications where title like '%new shoot day%' and body like '%Film City%') = 1, 'one notice for the block, not one per day');
select refused(format($$select update_day(%L, '{"call":"05:00"}')$$, :'d1'), 'Only the Line Producer');
reset role;
-- the evening-before reminder
update shoot_days set day = today_ist() + 1 where id = :'d1' and not exists (select 1 from shoot_days where production_id = :'pid' and day = today_ist() + 1);
update shoot_days set status = 'planned', reminded_at = null where production_id = :'pid' and day = today_ist() + 1;
select ok(send_call_reminders() >= 1, 'reminders go out for tomorrow');
select ok(send_call_reminders() = 0, 'and only once');
select ok(exists (select 1 from notifications where user_id = :'imran' and kind = 'call' and title like 'Tomorrow: call %'), 'crew get tomorrow’s call time');
-- profiles change only through the checked functions
select as_user(:'imran'); set role authenticated;
update profiles set bank_account = '111111111111', aadhaar_path = 'x/y.jpg' where id = :'imran';
select ok((select bank_account from profiles where id = :'imran') = '917010023456789', 'a profile can’t be edited directly through the API');
select save_profile('{"legal":"Imran Shaikh","pan":"FHSPS3349D","address":"Jogeshwari, Mumbai","bank_holder":"Imran Shaikh","bank_name":"HDFC","bank_account":"50100223344556","bank_ifsc":"HDFC0000123","phone":"9930018842"}');
reset role;
select ok(exists (select 1 from activity where text like 'Changed bank account: ••6789 (UTIB0000071) → ••4556 (HDFC0000123)%'), 'a bank change is logged with old and new');
select ok(exists (select 1 from notifications where user_id = :'neha' and title = 'Imran Shaikh changed their bank account'), 'Finance is told about a bank change');
-- who may call what
set role anon;
select refused(format($$select plan_days(%L, '{}')$$, :'pid'), 'permission denied');
select ok(username_available('someone_new'), 'the sign-up screen can still check usernames');
reset role;
select as_user(:'imran'); set role authenticated;
select refused($$select is_member(gen_random_uuid())$$, 'permission denied');
select refused($$select send_call_reminders()$$, 'permission denied');
reset role;
\echo ALL SCHEDULE AND FIX TESTS PASSED
