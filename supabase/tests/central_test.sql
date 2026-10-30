-- Tests for 20261030100000_central.sql. Each block runs as a given person under row-level security.
-- Run after: supabase_stub.sql, storage_stub.sql, 20261029100000_crewdesk.sql, central_test_users.sql,
--            20261030100000_central.sql, 20261030100100_central_storage.sql
\set ON_ERROR_STOP 1
\set QUIET 1
create function ok(c boolean, l text) returns void language plpgsql as $$
begin if not coalesce(c, false) then raise exception 'FAILED: %', l; end if; raise notice 'ok %', l; end $$;
create function refused(q text, pat text) returns void language plpgsql as $$
begin
  begin execute q;
  exception when others then
    if sqlerrm ~* pat then raise notice 'ok refused: %', pat; return; end if;
    raise exception 'FAILED: % gave "%" instead of /%/', q, sqlerrm, pat;
  end;
  raise exception 'FAILED: % should have been refused (/%/)', q, pat;
end $$;
create function as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, false) $$;
-- a valid GSTIN for a PAN (finds the check character)
create function mk_gstin(st text, pan text) returns text language plpgsql as $$
declare c text; begin foreach c in array string_to_array('0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ', null) loop
  if gstin_valid(st || pan || '1Z' || c) then return st || pan || '1Z' || c; end if; end loop; end $$;
\set fowzan '11111111-1111-1111-1111-111111111111'
\set ritika '22222222-2222-2222-2222-222222222222'
\set manoj  '33333333-3333-3333-3333-333333333333'
\set neha   '44444444-4444-4444-4444-444444444444'
\set asha   '55555555-5555-5555-5555-555555555555'
\set imran  '66666666-6666-6666-6666-666666666666'
\set stranger '77777777-7777-7777-7777-777777777777'
\set kiran  '88888888-8888-8888-8888-888888888888'

select ok((select role from company_admins where user_id = :'fowzan') = 'commercial', 'the first owner is the Commercial Head from the migration');

-- ---------------------------------------------------------------- company
select as_user(:'stranger'); set role authenticated;
select refused($$select setup_company('{}')$$, 'Only the CFO or Commercial Head');
select ok(company_info() is null, 'no company yet');
select refused($$select create_production('{"name":"X"}')$$, 'Only the CFO or Commercial Head');
reset role;

select as_user(:'fowzan'); set role authenticated;
select refused($$select create_production('{"name":"X"}')$$, 'company details first');
select refused(format($$select setup_company(%L)$$, jsonb_build_object('legal','Test Films Pvt Ltd','pan','AABCT1234K','tan','BAD','state','27','address','Andheri, Mumbai','signatory','Fowzan','bank',jsonb_build_object('name','HDFC','acct','50200011112222','ifsc','HDFC0000212'))), 'tan_check');
select refused(format($$select setup_company(%L)$$, jsonb_build_object('legal','Test Films Pvt Ltd','pan','AABCT1234K','tan','MUMT12345A','gstin', mk_gstin('27','AABCX9999K'),'state','27','address','Andheri, Mumbai','signatory','Fowzan','bank',jsonb_build_object('name','HDFC','acct','50200011112222','ifsc','HDFC0000212'))), 'companies_check');
select setup_company(jsonb_build_object('legal','Test Films Pvt Ltd','pan','AABCT1234K','tan','MUMT12345A','gstin', mk_gstin('27','AABCT1234K'),'state','24','address','Andheri, Mumbai','signatory','Fowzan','designation','Commercial Head',
  'bank',jsonb_build_object('name','HDFC Bank','acct','5020 0011 112222','ifsc','hdfc0000212'),'tally',jsonb_build_object('company','Test Films','bankLedger','HDFC Bank - Production A/c')));
select ok(company_info() ->> 'state' = '27', 'state follows the GSTIN, not the dropdown');
select ok(company_info() -> 'bank' ->> 'acct' = '50200011112222', 'owner sees the full bank account, spaces removed');
select add_admin('ritika', 'cfo');
select refused($$select add_admin('nobody_here', 'cfo')$$, 'No (CrewDesk )?account');
select create_production('{"name":"Saath Phere","format":"Long-format fiction · daily","planned_eps":400,"status":"Shooting"}') as pid \gset
select code as code0 from productions where id = :'pid' \gset
select ok(:'code0' ~ '^SAAT[A-Z2-9]{4}$', 'production code made from the name');
-- onboard: an existing account is linked at once; a new email waits as an invite
select onboard(:'pid', '{"name":"Manoj Patil","email":"manoj@test.in","role":"lp","dept":"Production","job":"Line Producer","rate":9000,"unit":"day","joining":"2026-01-01","tds":"194C-1"}');
select onboard(:'pid', '{"name":"Neha Kulkarni","email":"neha@test.in","role":"accounts","dept":"Accounts & Legal","job":"Production Accountant","rate":4500,"joining":"2026-01-01"}');
select onboard(:'pid', '{"name":"Asha D","email":"asha@test.in","role":"hod","dept":"Camera","job":"Director of Photography","rate":25000,"joining":"2026-01-01","tds":"194J-10"}');
select onboard(:'pid', '{"name":"Imran Shaikh","phone":"+91 99300 18842","role":"crew","dept":"Camera","job":"1st AC / Focus Puller","rate":4500,"joining":"2026-01-01"}') as imran_crew \gset
select ok((select user_id from crew where id = :'imran_crew') is null, 'invite for someone without an account waits for them');
select refused($$select onboard((select id from productions limit 1), '{"name":"Manoj Again","email":"manoj@test.in","rate":1,"joining":"2026-01-01"}')$$, 'already on this production');
reset role;

-- ---------------------------------------------------------------- roles
select as_user(:'manoj'); set role authenticated;
select ok(prod_role(:'pid') = 'lp', 'Manoj is Line Producer');
select refused(format($$select onboard(%L, '{"name":"X Y","role":"accounts","rate":1,"joining":"2026-01-01"}')$$, :'pid'), 'Only the CFO or Commercial Head can give that access');
select refused(format($$select set_deal(%L, '{"rate":5000}')$$, :'imran_crew'), 'Only the CFO or Commercial Head can change a deal');
select refused(format($$select set_budgets(%L, '{"Camera":100}')$$, :'pid'), 'Only the CFO');
reset role;
select as_user(:'neha'); set role authenticated;
select set_budgets(:'pid', '{"Camera":2400000,"Cast":5200000,"Art":0}');
select ok((select budget from productions where id = :'pid') = '{"Camera":2400000,"Cast":5200000}', 'Finance sets budgets; zero lines dropped');
reset role;

-- ---------------------------------------------------------------- joining with the code
insert into auth.users (id, email, raw_user_meta_data) values (:'imran', 'imran@test.in', '{"username":"imran","full_name":"Imran Shaikh","phone":"9930018842"}');
select ok((select phone from profiles where id = :'imran') = '9930018842', 'sign-up keeps the mobile number');
select as_user(:'stranger'); set role authenticated;
select ok((join_production('ZZZZ9999') ->> 'ok')::boolean = false, 'a wrong code is refused') from generate_series(1, 10);
select ok(join_production(:'code0') ->> 'error' ~ 'Too many wrong codes', 'ten wrong codes lock joining, even with the right code');
reset role;
select as_user(:'imran'); set role authenticated;
select ok((join_production(lower(left(:'code0', 4)) || '-' || right(:'code0', 4)) ->> 'ok')::boolean, 'code works in any case, with a dash');
select ok((select user_id from crew where id = :'imran_crew') = :'imran', 'joining took up the invite matched by mobile number');
select ok((select count(*) from crew) = 1, 'crew see only their own row');
select ok((select count(*) from people) = 6 and not exists (select 1 from people p join crew c on c.user_id = p.id where c.role in ('crew','vendor') and p.id <> auth.uid()),
          'crew see themselves, the owners and the production office, but no other crew');
select ok(company_info() -> 'bank' ->> 'acct' like '••••%', 'crew see the company bank account masked');
-- profile and documents
select refused($$select save_profile('{"legal":"Imran Shaikh","pan":"BAD","address":"Mumbai","bank_holder":"Imran","bank_account":"917010023456789","bank_ifsc":"UTIB0000071"}')$$, 'pan_check');
select save_profile('{"legal":"Imran Shaikh","pan":"FHSPS3349D","address":"Jogeshwari, Mumbai","bank_holder":"Imran Shaikh","bank_name":"Axis","bank_account":"917010023456789","bank_ifsc":"utib0000071","phone":"9930018842"}');
select refused(format($$select set_document('aadhaar', %L)$$, :'asha' || '/aadhaar-1.jpg'), 'own folder');
select refused($$select save_documents('1234', true)$$, 'masked Aadhaar');
select set_document('aadhaar', :'imran' || '/aadhaar-1.jpg'), set_document('pan', :'imran' || '/pan-1.jpg'), set_document('photo', :'imran' || '/photo-1.jpg');
select refused($$select save_documents('1234', false)$$, 'consent');
select save_documents('1234', true);
select ok((select docs_ready and profile_ready from people where id = :'imran'), 'profile and documents complete');
-- direct writes are refused
with u as (update crew set rate = 1 returning 1) select ok(count(*) = 0, 'direct edit of own deal changes nothing') from u;
select refused($$insert into activity (type, text) values ('x', 'forged')$$, 'row-level security');
select refused($$select add_log(null, 'x', 'forged')$$, 'row-level security');
select refused($$insert into crew_invoices (production_id, crew_id, user_id, no, period_from, period_to, qty, rate, unit, amount, tds_key, payable) select production_id, id, user_id, 'F1', current_date, current_date, 1, 1, 'day', 1, 'none', 1 from crew$$, 'row-level security');
select refused(format($$select submit_crew_invoice(%L, '{"no":"IS-1","from":"2026-10-01","to":"2026-10-06","qty":6}')$$, :'pid'), 'once your agreement is approved');
reset role;

-- ---------------------------------------------------------------- visibility of KYC
select as_user(:'asha'); set role authenticated;
select ok((select full_name from people where id = :'imran') = 'Imran Shaikh' and (select pan from people where id = :'imran') is null, 'HOD sees the name but not the PAN');
select ok(kyc_file_visible(:'imran' || '/photo-1.jpg') and not kyc_file_visible(:'imran' || '/aadhaar-1.jpg'), 'HOD can open the photo, not the Aadhaar');
reset role;
select as_user(:'neha'); set role authenticated;
select ok((select pan from people where id = :'imran') = 'FHSPS3349D', 'Finance sees the PAN');
select ok(kyc_file_visible(:'imran' || '/aadhaar-1.jpg'), 'Finance can open the Aadhaar');
select ok(company_info() -> 'bank' ->> 'acct' = '50200011112222', 'Finance sees the company bank account');
reset role;
select as_user(:'stranger'); set role authenticated;
select ok((select count(*) from people where id = :'imran') = 0 and not kyc_file_visible(:'imran' || '/photo-1.jpg'), 'outsiders see nothing');
select ok((select count(*) from productions) = 0 and (select count(*) from crew) = 0, 'outsiders see no productions');
reset role;

-- ---------------------------------------------------------------- agreement
select as_user(:'manoj'); set role authenticated;
select refused(format($$select send_agreement(%L, 'short')$$, :'imran_crew'), 'agreement text is missing');
select send_agreement(:'imran_crew', repeat('Clause. ', 40));
reset role;
select as_user(:'fowzan'); set role authenticated;
select set_deal(:'imran_crew', '{"rate":4800}');
select ok((select ag_status from crew where id = :'imran_crew') = 'none', 'changing the deal withdraws an unsigned agreement');
select ok((select count(*) from activity where type = 'deal' and crew_id = :'imran_crew') = 1, 'the change is logged with old and new value');
select revert_change((select id from activity where type = 'deal' and crew_id = :'imran_crew'));
select ok((select rate from crew where id = :'imran_crew') = 4500, 'undo puts the old rate back');
select refused(format($$select revert_change(%s)$$, (select min(id) from activity where type = 'deal' and crew_id = :'imran_crew')), 'already been undone');
reset role;
select as_user(:'manoj'); set role authenticated;
select send_agreement(:'imran_crew', repeat('Clause. ', 40));
reset role;
select as_user(:'asha'); set role authenticated;
select refused(format($$select sign_agreement(%L, 'Asha', 'data:image/png;base64,AAA')$$, :'imran_crew'), 'Only the person named');
reset role;
select as_user(:'imran'); set role authenticated;
select refused(format($$select sign_agreement(%L, 'Imran Shaikh', 'not an image')$$, :'imran_crew'), 'Draw your signature');
select sign_agreement(:'imran_crew', 'Imran Shaikh', 'data:image/png;base64,iVBORw0KGgo=');
select ok((select length(ag_hash) = 64 from crew where id = :'imran_crew'), 'signature fingerprinted with SHA-256');
reset role;
select as_user(:'manoj'); set role authenticated;
select refused(format($$select countersign(%L)$$, :'imran_crew'), 'Only the CFO or Commercial Head');
reset role;
select as_user(:'ritika'); set role authenticated;
select countersign(:'imran_crew');
select refused(format($$select set_deal(%L, '{"rate":6000}')$$, :'imran_crew'), 'signed agreement');
select set_deal(c.id, '{}') from crew c where c.role in ('lp','accounts','hod');
update crew set ag_status = 'countersigned' where role in ('lp','accounts','hod');   -- no policy: changes nothing
reset role;
update crew set ag_status = 'countersigned' where role in ('lp','accounts','hod');   -- test setup, as the database owner

-- ---------------------------------------------------------------- schedule and check-in
insert into auth.users (id, email, raw_user_meta_data) values (:'kiran', 'kiran@test.in', '{"username":"kiran","full_name":"Kiran Lights"}');
select as_user(:'kiran'); set role authenticated;
select ok((join_production(:'code0', 'vendor') ->> 'ok')::boolean, 'a vendor joins without an invite');
select ok((select role from crew) = 'vendor', 'joined as a vendor');
reset role;
select as_user(:'manoj'); set role authenticated;
select plan_days(:'pid', jsonb_build_object('from', today_ist() - 6, 'to', today_ist() + 6, 'skip_sundays', true, 'eps_per_day', 1, 'start_ep', 300, 'location', 'Floor 3')) as n \gset
select ok(:n between 10 and 11, 'planned a fortnight without Sundays');
select refused(format($$select plan_days(%L, %L)$$, :'pid', jsonb_build_object('from', today_ist() - 6, 'to', today_ist() - 6)), 'already on the schedule');
select id as pastday from shoot_days where day <= today_ist() and day >= today_ist() - 1 order by day desc limit 1 \gset
select id as futureday from shoot_days where day > today_ist() order by day limit 1 \gset
select refused(format($$select set_day_status(%L, 'shot')$$, :'futureday'), 'on or after its date');
select refused(format($$select check_in(%L, %L)$$, :'futureday', (select crew_code from crew where id = :'imran_crew')), 'opens on the day');
select refused(format($$select check_in(%L, %L)$$, :'pastday', (select crew_code from crew where user_id = :'kiran')), 'isn’t fully onboarded');
select check_in(:'pastday', lower((select crew_code from crew where id = :'imran_crew')));
select ok((select status from shoot_days where id = :'pastday') = 'shot', 'first check-in marks the day shot');
select refused(format($$select check_in(%L, %L)$$, :'pastday', (select crew_code from crew where id = :'imran_crew')), 'already checked in');
select remove_checkin(:'pastday', :'imran');
select ok((select count(*) from checkins where removed_at is null) = 0, 'check-in removed (kept in history)');
select check_in(:'pastday', (select crew_code from crew where id = :'imran_crew'));
select ok((select count(*) from checkins where removed_at is null) = 1, 'checked in again');
reset role;
select as_user(:'imran'); set role authenticated;
select refused(format($$select check_in(%L, 'X')$$, :'pastday'), 'Only the Line Producer');
select ok((select count(*) from shoot_days) >= 10, 'crew can see the schedule');
reset role;

-- ---------------------------------------------------------------- invoices and payment
select as_user(:'imran'); set role authenticated;
select refused(format($$select submit_crew_invoice(%L, '{"no":"IS-1","from":"2026-10-01","to":"2026-10-06","qty":6,"gst_rate":18}')$$, :'pid'), 'Add your GSTIN');
select submit_crew_invoice(:'pid', '{"no":"IS-1","from":"2026-10-01","to":"2026-10-06","qty":6}') as inv \gset
select ok((select amount = 27000 and tds = 270 and payable = 26730 from crew_invoices where id = :'inv'), 'fee, 1% TDS and payable worked out by the database');
select refused(format($$select submit_crew_invoice(%L, '{"no":"IS-1","from":"2026-10-01","to":"2026-10-06","qty":1}')$$, :'pid'), 'already used invoice number');
select refused(format($$select advance_invoice(%L)$$, :'inv'), 'your own invoice');
reset role;
select as_user(:'neha'); set role authenticated;
select refused(format($$select advance_invoice(%L)$$, :'inv'), 'The Auditor approves');
select refused(format($$select pay_invoices(%L, array[%L]::uuid[], 'UTR123456')$$, :'pid', :'inv'), 'Pick approved invoices');
reset role;
select as_user(:'asha'); set role authenticated;
select ok((select count(*) from crew_invoices) = 1, 'HOD sees their department’s invoices');
select refused(format($$select advance_invoice(%L)$$, :'inv'), 'The Auditor approves');
reset role;
-- no Auditor or HOP on this show: the Line Producer takes those steps, but only against confirmed attendance
select as_user(:'manoj'); set role authenticated;
select refused(format($$select advance_invoice(%L)$$, :'inv'), 'Only 0 confirmed days');
reset role;
insert into shoot_days (production_id, day, status, att_confirmed_at) select :'pid', d::date, 'shot', now() from generate_series('2026-10-01'::date, '2026-10-06'::date, '1 day') d;
insert into checkins (day_id, user_id) select id, :'imran' from shoot_days where day between '2026-10-01' and '2026-10-06';
select as_user(:'manoj'); set role authenticated;
select ok(advance_invoice(:'inv') = 'audited', 'audited against six confirmed days');
select ok(advance_invoice(:'inv') = 'hop_ok', 'Head of Production step (the LP, with no HOP on the show)');
select refused(format($$select advance_invoice(%L)$$, :'inv'), 'Commercial Head or a Commercial Manager');
reset role;
select as_user(:'kiran'); set role authenticated;
select ok((select count(*) from crew_invoices) = 0, 'other crew can’t see the invoice');
reset role;
select as_user(:'ritika'); set role authenticated;
select refused(format($$select advance_invoice(%L)$$, :'inv'), 'Commercial Head or a Commercial Manager');
reset role;
select as_user(:'fowzan'); set role authenticated;
select ok(advance_invoice(:'inv') = 'approved', 'the Commercial Head approves for payment (the CFO can’t, while there is one)');
select refused(format($$select pay_invoices(%L, array[%L]::uuid[], 'UTR123456')$$, :'pid', :'inv'), 'Only the CFO or Accounts');
reset role;
select as_user(:'asha'); set role authenticated;
select refused(format($$select pay_invoices(%L, array[%L]::uuid[], 'UTR123456')$$, :'pid', :'inv'), 'Only the CFO or Accounts');
select refused(format($$select tally_mark(%L)$$, :'pid'), 'Only Finance');
reset role;
select as_user(:'neha'); set role authenticated;
select refused(format($$select pay_invoices(%L, array[%L]::uuid[], '12')$$, :'pid', :'inv'), 'bank reference');
select ok(pay_invoices(:'pid', array[:'inv']::uuid[], 'HDFCR520261022') = 1, 'Finance records the payment');
select ok(tally_mark(:'pid') = 'TX-001', 'first Tally batch');
select ok((select tally_purchase = 'TX-001' and tally_payment = 'TX-001' from crew_invoices where id = :'inv'), 'invoice marked as in Tally');
select refused(format($$select tally_mark(%L)$$, :'pid'), 'Nothing new');
reset role;

-- ---------------------------------------------------------------- activity log and code
select as_user(:'imran'); set role authenticated;
select ok((select count(*) from activity) = 0, 'crew can’t read the activity log');
select refused(format($$select new_production_code(%L)$$, :'pid'), 'Only the Line Producer');
reset role;
select as_user(:'manoj'); set role authenticated;
select ok((select count(*) from activity) > 15, 'Line Producer reads the activity log');
select new_production_code(:'pid') as code1 \gset
reset role;
select as_user(:'kiran'); set role authenticated;
select ok(join_production(:'code0') ->> 'error' ~ 'No production has that code', 'the old code stops working');
reset role;
select as_user(:'stranger'); set role authenticated;
select ok((select count(*) from activity) = 0 and (select count(*) from crew_invoices) = 0 and (select count(*) from tally_exports) = 0, 'outsiders read nothing');
reset role;
\echo ALL CENTRAL TESTS PASSED
