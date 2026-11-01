-- Overtime, pro rata after 12 hours. Runs after the cost checks.
\set ON_ERROR_STOP 1
\set QUIET 1
\set imran '66666666-6666-6666-6666-666666666666'
\set aud 'b1111111-0000-0000-0000-000000000001'
select id as pid from productions limit 1 \gset
reset role;
insert into shoot_days (production_id, day, status, act_call, act_wrap, dpr_at) values
  (:'pid', '2026-09-10', 'shot', '07:00', '20:30', now()),   -- 13 h 30 m: 90 min over
  (:'pid', '2026-09-11', 'shot', '08:00', '19:00', now()),   -- 11 h: none
  (:'pid', '2026-09-12', 'shot', '18:00', '08:30', now());   -- night shoot, 14 h 30 m: 150 min over
insert into checkins (day_id, user_id) select id, :'imran' from shoot_days where day between '2026-09-10' and '2026-09-12';
select ok((select array_agg(day_ot_minutes(d) order by day) from shoot_days d where day between '2026-09-10' and '2026-09-12') = '{90,0,150}', 'minutes over 12 hours per day, night shoot included');
select ok((select minutes = 0 and amount = 0 from invoice_ot(:'pid', :'imran', '2026-09-10', '2026-09-12', 90000, 'month')), 'monthly deals get no overtime');
select as_user(:'imran'); set role authenticated;
select refused(format($$select apply_invoice_ot(%L)$$, gen_random_uuid()), 'permission denied');
select submit_crew_invoice(:'pid', '{"no":"IS-OT","from":"2026-09-10","to":"2026-09-12","qty":3}') as inv \gset
select ok((select ot_minutes = 240 and ot_amount = 1500 and amount = 15000 and tds = 150 and payable = 14850 from crew_invoices where id = :'inv'),
          '3 days × ₹4,500 plus 4 h over at ₹4,500 ÷ 12 an hour');
reset role;
-- the daily report is corrected before the audit; the Auditor's step works it out again
update shoot_days set act_wrap = '21:30' where day = '2026-09-10';
update shoot_days set att_confirmed_at = now() where day between '2026-09-10' and '2026-09-12';
select as_user(:'aud'); set role authenticated;
select ok(advance_invoice(:'inv') = 'audited', 'the Auditor approves');
reset role;
select ok((select ot_minutes = 300 and ot_amount = 1875 and amount = 15375 and payable = 15375 - 154 from crew_invoices where id = :'inv'), 'overtime follows the corrected report at the audit');
select ok(exists (select 1 from activity where text like 'Overtime on IS-OT: 5h 00m · ₹1875 (was ₹1500)'), 'the change is logged');
select ok(exists (select 1 from activity where text like 'Submitted invoice IS-OT for ₹15000 (incl. ₹1500 overtime)'), 'the submission shows its overtime');
-- uploaded invoice files
select as_user(:'imran'); set role authenticated;
select refused(format($$select submit_crew_invoice(%L, '{"no":"IS-F1","from":"2026-09-10","to":"2026-09-10","qty":1,"doc_path":"11111111-1111-1111-1111-111111111111/inv.pdf"}')$$, :'pid'), 'Upload the invoice file again');
select submit_crew_invoice(:'pid', jsonb_build_object('no','IS-F2','from','2026-09-11','to','2026-09-11','qty',1,'doc_path', :'imran' || '/inv-1.pdf')) as finv \gset
select ok((select doc_path from crew_invoices where id = :'finv') = :'imran' || '/inv-1.pdf', 'the uploaded file is on the invoice');
reset role;
insert into storage.objects (bucket_id, name) values ('invoices', :'imran' || '/inv-1.pdf'), ('invoices', :'imran' || '/stray.pdf');
select as_user(:'aud'); set role authenticated;
select ok((select count(*) from storage.objects where bucket_id = 'invoices') = 1, 'the Auditor opens the file on an invoice they check, not other uploads');
reset role;
select as_user('77777777-7777-7777-7777-777777777777'); set role authenticated;
select ok((select count(*) from storage.objects where bucket_id = 'invoices') = 0, 'someone off the production sees no invoice files');
reset role;
\echo ALL OVERTIME TESTS PASSED
