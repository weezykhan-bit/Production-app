-- Notifications and live-update checks. Runs after central_test.sql, on the state it leaves.
\set ON_ERROR_STOP 1
\set QUIET 1
\set ritika '22222222-2222-2222-2222-222222222222'
\set manoj  '33333333-3333-3333-3333-333333333333'
\set neha   '44444444-4444-4444-4444-444444444444'
\set asha   '55555555-5555-5555-5555-555555555555'
\set imran  '66666666-6666-6666-6666-666666666666'
\set stranger '77777777-7777-7777-7777-777777777777'
\set kiran  '88888888-8888-8888-8888-888888888888'
select as_user(:'imran'); set role authenticated;
select ok(exists (select 1 from notifications where title = 'Your agreement is ready to sign'), 'crew told their agreement is ready');
select ok(exists (select 1 from notifications where title = 'Your agreement is approved'), 'crew told their agreement is approved');
select ok(exists (select 1 from notifications where title = 'Agreement signed'), 'crew get a confirmation when they sign');
select ok(exists (select 1 from notifications where title = 'Invoice IS-1 submitted'), 'crew get “invoice submitted”');
select ok(exists (select 1 from notifications where title = 'Invoice IS-1 passed the HOD check'), 'crew told when the HOD approves');
select ok(exists (select 1 from notifications where title = 'Invoice IS-1 approved for payment'), 'crew told when it is approved');
select ok(exists (select 1 from notifications where title = 'Invoice IS-1 paid' and body like '%HDFCR520261022%'), 'crew told when paid, with the bank reference');
select ok(exists (select 1 from notifications where title like 'Checked in for%'), 'crew told when checked in at the gate');
select ok(exists (select 1 from notifications where title = 'Your deal was updated'), 'crew told when their deal changes');
select ok((select count(*) from notifications where user_id <> :'imran') = 0, 'people see only their own notifications');
select ok(mark_notifications_read() > 0, 'mark all as read');
select ok((select count(*) from notifications where read_at is null) = 0, 'nothing left unread');
select refused(format($$select notify(array[%L]::uuid[], null, 'x', 'Fake')$$, :'manoj'), 'row-level security');
select refused($$insert into notifications (user_id, kind, title) values (auth.uid(), 'x', 'Fake')$$, 'row-level security');
select ok((select count(*) from production_pulse) = 1, 'crew can see their production’s live-update signal');
reset role;
select as_user(:'asha'); set role authenticated;
select ok(exists (select 1 from notifications where title = 'Invoice IS-1 to check'), 'the department HOD is asked to check the invoice');
reset role;
select as_user(:'ritika'); set role authenticated;
select ok(exists (select 1 from notifications where title like '% signed their agreement'), 'owners asked to approve a signed agreement');
select ok(exists (select 1 from notifications where title = 'Invoice IS-1 needs final approval'), 'owners asked for final approval');
reset role;
select as_user(:'neha'); set role authenticated;
select ok(exists (select 1 from notifications where title = 'Invoice IS-1 ready to pay'), 'Finance told an invoice is ready to pay');
reset role;
select as_user(:'manoj'); set role authenticated;
select ok(exists (select 1 from notifications where title like 'Kiran Lights joined%'), 'Line Producer told when someone joins');
select ok(not exists (select 1 from notifications where title = 'Invoice IS-1 to check'), 'the LP isn’t asked when the department has a HOD');
reset role;
select as_user(:'stranger'); set role authenticated;
select ok((select count(*) from notifications) = 0 and (select count(*) from production_pulse) = 0, 'outsiders get nothing');
reset role;
\echo ALL NOTIFICATION TESTS PASSED
