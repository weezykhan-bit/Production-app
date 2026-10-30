-- Deductions, remarks and the artist / crew / vendor split. Runs after the notification checks.
\set ON_ERROR_STOP 1
\set QUIET 1
\set ritika '22222222-2222-2222-2222-222222222222'
\set manoj  '33333333-3333-3333-3333-333333333333'
\set neha   '44444444-4444-4444-4444-444444444444'
\set asha   '55555555-5555-5555-5555-555555555555'
\set imran  '66666666-6666-6666-6666-666666666666'
\set stranger '77777777-7777-7777-7777-777777777777'
select id as pid from productions limit 1 \gset
select as_user(:'imran'); set role authenticated;
select submit_crew_invoice(:'pid', '{"no":"IS-2","from":"2026-10-07","to":"2026-10-08","qty":2}') as inv \gset
select ok((select payable from crew_invoices where id = :'inv') = 8910, 'payable starts as fee + GST − TDS');
select refused(format($$select set_invoice_adjustments(%L, '[]', 'mine')$$, :'inv'), 'Only the production office');
reset role;
select as_user(:'asha'); set role authenticated;
select refused(format($$select set_invoice_adjustments(%L, '[]', 'x')$$, :'inv'), 'Only the production office');
reset role;
select as_user(:'stranger'); set role authenticated;
select refused(format($$select set_invoice_adjustments(%L, '[]', 'x')$$, :'inv'), 'Only the production office');
reset role;
select as_user(:'manoj'); set role authenticated;
select refused(format($$select set_invoice_adjustments(%L, '[{"type":"bribe","amount":10,"note":"abc"}]', null)$$, :'inv'), 'Pick what each deduction');
select refused(format($$select set_invoice_adjustments(%L, '[{"type":"advance","amount":0,"note":"abc"}]', null)$$, :'inv'), 'needs an amount');
select refused(format($$select set_invoice_adjustments(%L, '[{"type":"advance","amount":"lots","note":"abc"}]', null)$$, :'inv'), 'needs an amount');
select refused(format($$select set_invoice_adjustments(%L, '[{"type":"advance","amount":100}]', null)$$, :'inv'), 'Say what each deduction');
select refused(format($$select set_invoice_adjustments(%L, '[{"type":"advance","amount":9000,"note":"too much"}]', null)$$, :'inv'), 'more than the amount payable');
select ok(set_invoice_adjustments(:'inv', '[{"type":"advance","amount":2000,"note":"Advance paid on 2 Oct"},{"type":"damage","amount":500,"note":"Lost follow-focus whip"}]', '  Please return the whip  ') = 6410,
          'LP takes off an advance and a loss');
select ok((select deduction = 2500 and payable = 6410 and remarks = 'Please return the whip' and jsonb_array_length(deductions) = 2 and tds = 90
             from crew_invoices where id = :'inv'), 'payable, deductions and remark are stored; TDS is unchanged');
select ok(exists (select 1 from activity where text like 'Updated IS-2%deductions ₹2500%'), 'the change is in the activity log');
reset role;
insert into shoot_days (production_id, day, status, att_confirmed_at) select :'pid', d::date, 'shot', now() from generate_series('2026-10-07'::date, '2026-10-08'::date, '1 day') d;
insert into checkins (day_id, user_id) select id, :'imran' from shoot_days where day between '2026-10-07' and '2026-10-08';
select as_user(:'manoj'); set role authenticated;
select advance_invoice(:'inv'); select advance_invoice(:'inv');
reset role;
select as_user('11111111-1111-1111-1111-111111111111'); set role authenticated;
select advance_invoice(:'inv');
reset role;
select as_user(:'neha'); set role authenticated;
select ok(set_invoice_adjustments(:'inv', '[{"type":"advance","amount":2000,"note":"Advance paid on 2 Oct"}]', null) = 6910, 'Accounts can change deductions before paying');
select ok((select remarks is null from crew_invoices where id = :'inv'), 'remark can be cleared');
select ok(tally_mark(:'pid') like 'TX-%', 'approved invoice goes to Tally');
select refused(format($$select set_invoice_adjustments(%L, '[]', null)$$, :'inv'), 'already in Tally');
select ok(pay_invoices(:'pid', array[:'inv']::uuid[], 'HDFCR520261030') = 1, 'paid at the reduced amount');
select refused(format($$select set_invoice_adjustments(%L, '[]', null)$$, :'inv'), 'before the invoice is paid');
reset role;
select as_user(:'imran'); set role authenticated;
select ok(exists (select 1 from notifications where title = 'Deduction on invoice IS-2' and body like '%Advance recovered%Lost follow-focus whip%6,410%Remark: Please return the whip%'), 'the person is told about deductions and the remark');
select ok(exists (select 1 from notifications where title = 'Invoice IS-2 paid' and body like '%6,910%'), 'the paid notice shows the reduced amount');
select ok((select deduction from crew_invoices where id = :'inv') = 2000, 'the person can see their deductions');
reset role;
-- artist, crew or vendor follows the department
select as_user(:'ritika'); set role authenticated;
select onboard(:'pid', '{"name":"Rhea Kapoor","phone":"+91 98200 11111","dept":"Cast","job":"Lead Actor","rate":60000,"unit":"episode","joining":"2026-01-01","tds":"194J-10"}') as rhea \gset
select onboard(:'pid', '{"name":"Shree Vans","phone":"+91 98200 22222","role":"vendor","dept":"Vendors & Services","job":"Vanity vans","rate":8000,"joining":"2026-01-01","tds":"194C-2"}') as vans \gset
select onboard(:'pid', '{"name":"Lata Gen","phone":"+91 98200 33333","kind":"cast","dept":"Vendors & Services","job":"Generator & power","rate":6000,"joining":"2026-01-01"}') as gen \gset
select ok((select kind from crew where id = :'rhea') = 'cast', 'Cast department is an artist');
select ok((select kind from crew where id = :'vans') = 'vendor', 'vendor access is a vendor');
select ok((select kind from crew where id = :'gen') = 'vendor', 'Vendors & Services is a vendor whatever was picked');
select ok((select kind from crew where user_id = :'imran') = 'crew', 'Camera is crew');
select set_deal(:'rhea', '{"dept":"Hair & Makeup","job":"Makeup Artist"}');
select ok((select kind from crew where id = :'rhea') = 'crew', 'moving department moves the list');
reset role;
\echo ALL DEDUCTION TESTS PASSED
