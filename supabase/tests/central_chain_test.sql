-- Approval chain with an Auditor, HOP and Commercial Manager; locked days; tasks. Runs last.
\set ON_ERROR_STOP 1
\set QUIET 1
\set fowzan '11111111-1111-1111-1111-111111111111'
\set ritika '22222222-2222-2222-2222-222222222222'
\set manoj  '33333333-3333-3333-3333-333333333333'
\set neha   '44444444-4444-4444-4444-444444444444'
\set asha   '55555555-5555-5555-5555-555555555555'
\set imran  '66666666-6666-6666-6666-666666666666'
\set kiran  '88888888-8888-8888-8888-888888888888'
\set aud 'b1111111-0000-0000-0000-000000000001'
\set hop 'b1111111-0000-0000-0000-000000000002'
\set cm  'b1111111-0000-0000-0000-000000000003'
select id as pid from productions limit 1 \gset
insert into auth.users (id, email, raw_user_meta_data) values
 (:'aud', 'aud@test.in', '{"full_name":"Anil Auditor"}'), (:'hop', 'hop@test.in', '{"full_name":"Hema HOP"}'), (:'cm', 'cm@test.in', '{"full_name":"Chetan CM"}');
select as_user(:'manoj'); set role authenticated;
select refused(format($$select onboard(%L, '{"name":"X Y","email":"aud@test.in","role":"auditor","rate":1,"joining":"2026-01-01"}')$$, :'pid'), 'Only the CFO or Commercial Head can give that access');
reset role;
select as_user(:'fowzan'); set role authenticated;
select onboard(:'pid', '{"name":"Anil Auditor","email":"aud@test.in","role":"auditor","dept":"Accounts & Legal","job":"Auditor","rate":3000,"joining":"2026-01-01"}');
select onboard(:'pid', '{"name":"Hema HOP","email":"hop@test.in","role":"hop","dept":"Production","job":"Head of Production","rate":9000,"joining":"2026-01-01"}');
select onboard(:'pid', '{"name":"Chetan CM","email":"cm@test.in","role":"commercial_mgr","dept":"Accounts & Legal","job":"Commercial Manager","rate":6000,"joining":"2026-01-01"}');
reset role;
-- today's attendance
select id as today from shoot_days where production_id = :'pid' and day = today_ist() \gset
update shoot_days set status = 'planned', att_confirmed_at = null where id = :'today';
update checkins set removed_at = now() where day_id = :'today';
select as_user(:'manoj'); set role authenticated;
select check_in(:'today', (select crew_code from crew where user_id = :'imran'));
select refused(format($$select confirm_attendance(%L)$$, :'today'), 'Only the Auditor confirms');
reset role;
select as_user(:'imran'); set role authenticated;
select submit_crew_invoice(:'pid', jsonb_build_object('no', 'IS-9', 'from', today_ist(), 'to', today_ist(), 'qty', 1)) as inv \gset
reset role;
select as_user(:'aud'); set role authenticated;
select refused(format($$select advance_invoice(%L)$$, :'inv'), 'Only 0 confirmed days');
select ok(confirm_attendance(:'today') >= 1, 'the Auditor confirms today’s attendance');
reset role;
select as_user(:'manoj'); set role authenticated;
select refused(format($$select advance_invoice(%L)$$, :'inv'), 'The Auditor approves');
select refused(format($$select check_in(%L, 'X')$$, :'today'), 'locked');
reset role;
select as_user(:'aud'); set role authenticated;
select ok(advance_invoice(:'inv') = 'audited', 'the Auditor approves step 1');
reset role;
select as_user(:'manoj'); set role authenticated;
select refused(format($$select advance_invoice(%L)$$, :'inv'), 'Head of Production confirms');
reset role;
select as_user(:'hop'); set role authenticated;
select ok(advance_invoice(:'inv') = 'hop_ok', 'the Head of Production confirms step 2');
reset role;
select as_user(:'cm'); set role authenticated;
select ok(advance_invoice(:'inv') = 'approved', 'the Commercial Manager approves step 3');
select refused(format($$select pay_invoices(%L, array[%L]::uuid[], 'UTRCHAIN01')$$, :'pid', :'inv'), 'Only the CFO or Accounts');
reset role;
select as_user(:'neha'); set role authenticated;
select ok(pay_invoices(:'pid', array[:'inv']::uuid[], 'UTRCHAIN01') = 1, 'Accounts (the CFO’s associate) pays');
reset role;
select ok(exists (select 1 from notifications where user_id = :'aud' and title = 'Invoice IS-9 to audit'), 'the Auditor is asked first');
select ok(exists (select 1 from notifications where user_id = :'hop' and title = 'Invoice IS-9 to confirm'), 'then the Head of Production');
select ok(exists (select 1 from notifications where user_id = :'cm' and title = 'Invoice IS-9 needs commercial approval'), 'then the commercial side');
select ok(exists (select 1 from notifications where user_id = :'neha' and title = 'Invoice IS-9 ready to pay'), 'then whoever pays');
select ok((select count(*) from notifications where user_id = :'imran' and title like 'Invoice IS-9%') = 5, 'the person hears at every step');
select ok(not exists (select 1 from notifications where user_id = :'manoj' and title = 'Invoice IS-9 to audit'), 'the LP is no longer asked once there is an Auditor');
-- locked days and permission to change them
select as_user(:'manoj'); set role authenticated;
select refused(format($$select request_day_unlock(%L, 'no')$$, :'today'), 'what needs changing');
select request_day_unlock(:'today', 'Imran left at lunch, remove his check-in') as req \gset
select refused(format($$select request_day_unlock(%L, 'again please')$$, :'today'), 'already been asked');
select refused(format($$select decide_day_unlock(%L, true)$$, :'req'), 'Only the Commercial Head or a Commercial Manager');
reset role;
select ok(exists (select 1 from notifications where user_id = :'cm' and title like 'Manoj Patil asks to change%'), 'the commercial side is asked for permission');
select as_user(:'cm'); set role authenticated;
select decide_day_unlock(:'req', true, 'OK, fix it today');
reset role;
select as_user(:'manoj'); set role authenticated;
select remove_checkin(:'today', :'imran');
select ok((select att_confirmed_at is null from shoot_days where id = :'today'), 'changing a confirmed day sends it back to the Auditor');
reset role;
select ok(exists (select 1 from activity where text like 'Allowed changes to %for 24 hours: OK, fix it today'), 'the permission is in the activity log');
select id as old from shoot_days where production_id = :'pid' and day < today_ist() - 1 and status <> 'cancelled' order by day desc limit 1 \gset
select as_user(:'manoj'); set role authenticated;
select refused(format($$select update_day(%L, '{"call":"06:00"}')$$, :'old'), 'locked');
reset role;
select as_user(:'cm'); set role authenticated;
select update_day(:'old', '{"location":"Floor 3 (corrected)"}');
reset role;
select ok((select location from shoot_days where id = :'old') = 'Floor 3 (corrected)', 'the commercial side can change a locked day themselves');
-- tasks
select as_user(:'imran'); set role authenticated;
select refused(format($$select save_task(%L, '{"title":"Not mine"}')$$, :'pid'), 'Only heads');
reset role;
select as_user(:'manoj'); set role authenticated;
select save_task(:'pid', jsonb_build_object('title', 'Book the crane for the climax', 'priority', 'high', 'dept', 'Camera', 'due', today_ist() + 1, 'assignees', jsonb_build_array(:'imran', :'asha'))) as t1 \gset
select save_task(:'pid', jsonb_build_object('title', 'Generator keeps tripping', 'kind', 'issue', 'priority', 'critical', 'assignees', jsonb_build_array(:'imran'))) as t2 \gset
select save_task(:'pid', jsonb_build_object('title', 'Office-only task', 'assignees', jsonb_build_array(:'neha'))) as t3 \gset
reset role;
select as_user(:'asha'); set role authenticated;
select refused(format($$select save_task(%L, jsonb_build_object('title', 'Lights', 'assignees', jsonb_build_array(%L)))$$, :'pid', :'kiran'), 'within their own department');
select save_task(:'pid', jsonb_build_object('title', 'Clean the lenses', 'dept', 'Lighting', 'assignees', jsonb_build_array(:'imran'))) as t4 \gset
reset role;
select ok((select dept from tasks where id = :'t4') = 'Camera', 'an HOD’s task stays in their department');
select as_user(:'imran'); set role authenticated;
select ok((select count(*) from tasks) = 3, 'crew see only the tasks they’re on');
select ok(exists (select 1 from notifications where title = 'New task for you: Book the crane for the climax' and body like 'High priority · due %'), 'the assignee is told, with priority and due date');
select set_task_status(:'t1', 'working');
select add_task_update(:'t2', 'Swap to the 125 kVA unit from the vendor', 'solution') as s1 \gset
select refused(format($$select add_task_update(%L, 'x', 'solution')$$, :'t1'), 'Write something|Solutions are proposed on issues');
select refused(format($$select delete_task(%L)$$, :'t1'), 'Only whoever created it');
reset role;
select as_user(:'asha'); set role authenticated;
select add_task_update(:'t2', 'Run two smaller units in parallel', 'solution') as s2 \gset
reset role;
select as_user(:'manoj'); set role authenticated;
select ok(exists (select 1 from notifications where title = '“Book the crane for the climax” is working on it'), 'the creator hears about status changes');
select accept_solution(:'s1');
reset role;
select ok((select status from tasks where id = :'t2') = 'done' and (select accepted from task_updates where id = :'s1') and not (select accepted from task_updates where id = :'s2'), 'accepting a solution closes the issue');
select ok(exists (select 1 from notifications where user_id = :'imran' and title = 'Solution accepted: Generator keeps tripping'), 'whoever proposed it is told');
select as_user(:'kiran'); set role authenticated;
select ok((select count(*) from tasks) = 0, 'people not on a task can’t see it');
reset role;
select ok(send_task_reminders() = 1, 'tasks due tomorrow get a reminder');
select ok(send_task_reminders() = 0, 'once');
set role anon;
select refused(format($$select save_task(%L, '{}')$$, :'pid'), 'permission denied');
reset role;
\echo ALL CHAIN, LOCK AND TASK TESTS PASSED
