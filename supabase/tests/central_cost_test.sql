-- Daily costs, Excel import, petty cash, locked dates and the daily production report. Runs after the chain checks.
\set ON_ERROR_STOP 1
\set QUIET 1
\set fowzan '11111111-1111-1111-1111-111111111111'
\set ritika '22222222-2222-2222-2222-222222222222'
\set manoj  '33333333-3333-3333-3333-333333333333'
\set neha   '44444444-4444-4444-4444-444444444444'
\set asha   '55555555-5555-5555-5555-555555555555'
\set imran  '66666666-6666-6666-6666-666666666666'
\set aud 'b1111111-0000-0000-0000-000000000001'
\set cm  'b1111111-0000-0000-0000-000000000003'
select id as pid from productions limit 1 \gset
-- who may enter costs
select as_user(:'imran'); set role authenticated;
select refused(format($$select add_cost_entries(%L, '[{"date":"%s","head":"Transport","amount":100}]')$$, :'pid', today_ist()), 'Only the production office');
select ok((select count(*) from cost_entries) = 0, 'crew see no cost lines');
reset role;
select as_user(:'asha'); set role authenticated;
select refused(format($$select add_cost_entries(%L, '[{"date":"%s","head":"Transport","amount":100}]')$$, :'pid', today_ist()), 'Only the production office');
reset role;
-- row checks, all or nothing
select as_user(:'manoj'); set role authenticated;
select refused(format($$select add_cost_entries(%L, '[]')$$, :'pid'), 'between 1 and 2,000');
select refused(format($$select add_cost_entries(%L, '[{"date":"%s","head":"Transport","amount":100},{"date":"soon","head":"Food","amount":50}]')$$, :'pid', today_ist()), 'Row 2: the date');
select refused(format($$select add_cost_entries(%L, '[{"date":"%s","head":"","amount":100}]')$$, :'pid', today_ist()), 'Row 1: pick the cost head');
select refused(format($$select add_cost_entries(%L, '[{"date":"%s","head":"Food","qty":"two","rate":5}]')$$, :'pid', today_ist()), 'must be numbers');
select refused(format($$select add_cost_entries(%L, '[{"date":"%s","head":"Food"}]')$$, :'pid', today_ist()), 'add the amount');
select refused(format($$select add_cost_entries(%L, '[{"date":"%s","head":"Food","amount":10,"mode":"barter"}]')$$, :'pid', today_ist()), 'Bank, Cash, Credit or Petty');
select refused(format($$select add_cost_entries(%L, '[{"date":"%s","head":"Food","amount":10,"mode":"Petty cash","holder_name":"Nobody"}]')$$, :'pid', today_ist()), 'whose petty cash');
select refused(format($$select add_cost_entries(%L, '[{"date":"%s","head":"Food","amount":10}]')$$, :'pid', today_ist() + 60), 'too far ahead');
select refused(format($$select add_cost_entries(%L, '[{"date":"%s","head":"Food","amount":10}]')$$, :'pid', today_ist() - 5), 'is locked');
select ok((select count(*) from cost_entries) = 0, 'a bad row stops the whole batch');
select ok(add_cost_entries(:'pid', jsonb_build_array(
  jsonb_build_object('date', today_ist(), 'head', 'Catering', 'item', 'Lunch', 'payee', 'Annapurna Caterers', 'qty', 62, 'rate', 180, 'mode', 'UPI'),
  jsonb_build_object('date', today_ist(), 'head', 'Transport', 'item', 'Innova x3', 'amount', '9000', 'mode', 'Credit (unpaid)')), 'manual') = 2, 'LP adds two lines');
select ok((select amount from cost_entries where item = 'Lunch') = 11160 and (select mode from cost_entries where item = 'Lunch') = 'bank', 'amount is qty × rate; UPI is a bank payment');
select ok((select mode from cost_entries where item = 'Innova x3') = 'credit', 'credit is understood');
reset role;
-- petty cash
select as_user(:'manoj'); set role authenticated;
select refused(format($$select give_petty_float(%L, %L, 5000)$$, :'pid', :'imran'), 'Only the CFO, Accounts');
reset role;
select as_user(:'neha'); set role authenticated;
select refused(format($$select give_petty_float(%L, %L, 5000)$$, :'pid', 'c0000000-0000-0000-0000-000000000000'), 'someone on this production');
select give_petty_float(:'pid', :'manoj', 20000, 'Set petty for the week');
reset role;
select as_user(:'manoj'); set role authenticated;
select ok(exists (select 1 from notifications where title = 'Petty cash ₹20000 given to you'), 'the holder is told');
select ok((select sum(amount) from petty_floats where holder = :'manoj') = 20000, 'the holder sees their float');
-- Excel import with a petty cash row, then undo
select ok(add_cost_entries(:'pid', jsonb_build_array(
  jsonb_build_object('date', today_ist(), 'head', 'Art', 'item', 'Props hire', 'amount', 4500, 'mode', 'Petty cash', 'holder_name', 'Manoj Patil'),
  jsonb_build_object('date', today_ist() - 1, 'head', 'Location', 'item', 'Society NOC', 'amount', 15000, 'mode', 'cash', 'bill_no', 'R-22')), 'excel') = 2, 'Excel rows go in');
select ok((select count(distinct batch) from cost_entries where source = 'excel') = 1, 'one import, one batch');
select ok((select petty_holder from cost_entries where item = 'Props hire') = :'manoj', 'petty holder found by name');
select batch as b from cost_entries where source = 'excel' limit 1 \gset
reset role;
select as_user(:'imran'); set role authenticated;
select refused(format($$select undo_cost_import(%L)$$, :'b'), 'No such import');
reset role;
select as_user(:'manoj'); set role authenticated;
select ok(undo_cost_import(:'b') = 2, 'the import can be undone');
select ok((select count(*) from cost_entries) = 2, 'only the manual lines are left');
select id as lunch from cost_entries where item = 'Lunch' \gset
select update_cost_entry(:'lunch', '{"qty":60}');
select ok((select amount from cost_entries where id = :'lunch') = 10800, 'changing qty recomputes the amount');
reset role;
-- the auditor sees and enters; locks follow attendance
select as_user(:'aud'); set role authenticated;
select ok((select count(*) from cost_entries) = 2, 'the Auditor sees the day’s costs');
reset role;
select id as today from shoot_days where production_id = :'pid' and day = today_ist() \gset
update shoot_days set att_confirmed_at = now() where id = :'today';
update day_unlocks set expires_at = now() - interval '1 minute' where status = 'approved';
select as_user(:'manoj'); set role authenticated;
select refused(format($$select delete_cost_entry(%L)$$, :'lunch'), 'is locked');
select refused(format($$select request_date_unlock(%L, %L, 'x')$$, :'pid', today_ist() + 3), 'isn’t locked');
select refused(format($$select request_date_unlock(%L, %L, 'x')$$, :'pid', today_ist()), 'Say what needs changing');
select request_date_unlock(:'pid', today_ist() - 9, 'Missed a generator bill from that day') as rq \gset
select refused(format($$select request_date_unlock(%L, %L, 'again please')$$, :'pid', today_ist() - 9), 'already been asked');
select refused(format($$select decide_day_unlock(%L, true)$$, :'rq'), 'Only the Commercial Head');
reset role;
select ok(exists (select 1 from notifications where user_id = :'cm' and title like 'Manoj Patil asks to change%' and view = 'costs'), 'the commercial side is asked');
select as_user(:'cm'); set role authenticated;
select decide_day_unlock(:'rq', true, 'ok');
reset role;
select as_user(:'manoj'); set role authenticated;
select ok(add_cost_entries(:'pid', jsonb_build_array(jsonb_build_object('date', today_ist() - 9, 'head', 'Generator', 'amount', 7000)), 'manual') = 1, 'with permission an old date takes a line');
select refused(format($$select add_cost_entries(%L, '[{"date":"%s","head":"Food","amount":10}]')$$, :'pid', today_ist() - 8), 'is locked');
reset role;
select as_user(:'fowzan'); set role authenticated;
select delete_cost_entry(:'lunch');
select ok(not exists (select 1 from cost_entries where id = :'lunch'), 'the Commercial Head can change a locked day');
reset role;
-- DPR
select as_user(:'imran'); set role authenticated;
select refused(format($$select save_dpr(%L, '{}')$$, :'today'), 'Only the Line Producer');
reset role;
update shoot_days set att_confirmed_at = null where id = :'today';
select as_user(:'manoj'); set role authenticated;
select refused(format($$select save_dpr(%L, '{"act_call":"7.30"}')$$, :'today'), 'like 07:30');
select save_dpr(:'today', '{"act_call":"07:00","first_shot":"08:40","lunch_min":45,"act_wrap":"20:30","scenes_planned":8,"scenes_shot":6,"minutes_shot":4.5,"delay":"Rain from 2 to 3"}');
select ok((select scenes_shot = 6 and act_wrap = '20:30' and dpr_at is not null from shoot_days where id = :'today'), 'the daily report is stored');
reset role;
update shoot_days set att_confirmed_at = now() where id = :'today';
select as_user(:'manoj'); set role authenticated;
select refused(format($$select save_dpr(%L, '{"act_call":"07:10","act_wrap":"20:00"}')$$, :'today'), 'locked');
reset role;
select id as yday from shoot_days where production_id = :'pid' and day = today_ist() - 1 \gset
update shoot_days set att_confirmed_at = now(), dpr_at = null, status = 'shot' where id = :'yday';
select as_user(:'manoj'); set role authenticated;
select save_dpr(:'yday', '{"act_call":"08:00","act_wrap":"21:00"}');
select ok((select act_wrap from shoot_days where id = :'yday') = '21:00', 'the first report can be filed after attendance is confirmed');
select refused(format($$select save_dpr(%L, '{}')$$, (select id from shoot_days where production_id = :'pid' and day > today_ist() order by day limit 1)), 'on or after the shoot day');
reset role;
select ok(send_dpr_reminders() = 0, 'no reminder once the report is filed');
select ok(exists (select 1 from activity where type = 'cost' and text like 'Gave ₹20000 petty cash to Manoj%'), 'petty cash is in the log');
\echo ALL COST TESTS PASSED
