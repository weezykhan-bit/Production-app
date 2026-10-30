-- Removing people, and asking for removals. Runs last.
\set ON_ERROR_STOP 1
\set QUIET 1
\set ritika '22222222-2222-2222-2222-222222222222'
\set manoj  '33333333-3333-3333-3333-333333333333'
\set asha   '55555555-5555-5555-5555-555555555555'
\set imran  '66666666-6666-6666-6666-666666666666'
\set g1 'a1111111-0000-0000-0000-000000000001'
\set g2 'a1111111-0000-0000-0000-000000000002'
select id as pid, code from productions limit 1 \gset
select id as g1c from crew where user_id = :'g1' \gset
select id as g2c from crew where user_id = :'g2' \gset
select id as imc from crew where user_id = :'imran' \gset
select as_user(:'asha'); set role authenticated;
select refused(format($$select request_removal(%L, 'not needed')$$, :'g1c'), 'Only the Line Producer or Head of Production');
select refused(format($$select remove_person(%L, 'not needed')$$, :'g1c'), 'Only the CFO or Commercial Head');
reset role;
select as_user(:'manoj'); set role authenticated;
select refused(format($$select request_removal(%L, 'no')$$, :'g1c'), 'Say why');
select refused(format($$select remove_person(%L, 'no-show')$$, :'g1c'), 'Only the CFO or Commercial Head');
select request_removal(:'g1c', 'No-show for three days') as req1 \gset
select refused(format($$select request_removal(%L, 'again please')$$, :'g1c'), 'already been asked');
select ok((select count(*) from removal_requests) = 1, 'the LP sees the request');
reset role;
select as_user(:'imran'); set role authenticated;
select ok((select count(*) from removal_requests) = 0, 'crew can’t see removal requests');
reset role;
select as_user(:'ritika'); set role authenticated;
select ok(exists (select 1 from notifications where title = 'Manoj Patil asks to remove Gita One' and body = 'No-show for three days'), 'owners are asked, with the reason');
select refused(format($$select decide_removal(%L, false, null)$$, :'req1'), 'Say why you’re keeping them');
select ok(decide_removal(:'req1', false, 'She called in sick; keep her') = 'declined', 'owner declines with a note');
reset role;
select as_user(:'manoj'); set role authenticated;
select ok(exists (select 1 from notifications where title = 'Request to remove Gita One declined' and body like 'She called in sick%'), 'the LP is told it was declined, and why');
select request_removal(:'g1c', 'Still not turning up') as req2 \gset
reset role;
select as_user(:'ritika'); set role authenticated;
select ok(decide_removal(:'req2', true, null) = 'deleted', 'approved: someone with no history is deleted outright');
reset role;
select ok(not exists (select 1 from crew where id = :'g1c'), 'their place on the production is gone');
select ok((select status from removal_requests where id = :'req2') = 'approved', 'the request is marked approved');
select ok(exists (select 1 from notifications where user_id = :'g1' and title like 'You were removed from%'), 'the person is told');
select ok(exists (select 1 from notifications where user_id = :'manoj' and title = 'Gita One was removed'), 'the LP is told it was approved');
-- someone with invoices: blocked while one is open, then taken off but kept on record
select as_user(:'imran'); set role authenticated;
select submit_crew_invoice(:'pid', '{"no":"IS-3","from":"2026-10-09","to":"2026-10-09","qty":1}') as inv3 \gset
reset role;
select as_user(:'ritika'); set role authenticated;
select refused(format($$select remove_person(%L, 'Wrapped early')$$, :'imc'), 'Pay or reject it first');
select reject_crew_invoice(:'inv3', 'Raised by mistake');
select ok(remove_person(:'imc', 'Wrapped early') = 'removed', 'someone with invoices is taken off, not deleted');
select refused(format($$select remove_person(%L, 'again now')$$, :'imc'), 'already removed');
reset role;
select ok((select not active and removed_reason = 'Wrapped early' from crew where id = :'imc'), 'their record stays, marked removed');
select as_user(:'imran'); set role authenticated;
select ok(prod_role(:'pid') is null, 'a removed person loses access');
select ok((join_production(:'code') ->> 'error') like 'You were removed%', 'and can’t rejoin with the code');
select ok((select count(*) from crew_invoices) >= 3, 'they still see their own invoices and payments');
reset role;
select as_user(:'ritika'); set role authenticated;
select restore_person(:'imc');
reset role;
select as_user(:'imran'); set role authenticated;
select ok(prod_role(:'pid') = 'crew', 'an owner can restore them');
reset role;
-- withdrawing a request
select as_user(:'manoj'); set role authenticated;
select request_removal(:'g2c', 'Moving to another show') as req3 \gset
select withdraw_removal(:'req3');
reset role;
select as_user(:'ritika'); set role authenticated;
select refused(format($$select decide_removal(%L, true)$$, :'req3'), 'already been dealt with');
reset role;
\echo ALL REMOVAL TESTS PASSED
-- welcome video seen once
select as_user(:'imran'); set role authenticated;
select ok(tour_status() is null, 'the welcome video has not been seen yet');
select tour_done();
select ok(tour_status() is not null, 'it is marked as seen');
reset role;
select as_user(:'manoj'); set role authenticated;
select ok(tour_status() is null, 'each person has their own');
reset role;
\echo ALL WELCOME TESTS PASSED
