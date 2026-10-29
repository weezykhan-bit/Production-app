\set ON_ERROR_STOP 1
\set QUIET 1
-- CrewDesk end-to-end rules, exercised as each role. Run after supabase_stub.sql and the migration.
create function public.t_eq(actual anyelement, expected anyelement, label text) returns void language plpgsql as $$
begin
  if actual is distinct from expected then raise exception 'FAIL %: got %, expected %', label, actual, expected; end if;
  raise notice 'ok  %', label;
end $$;
create function public.t_err(stmt text, pattern text, label text) returns void language plpgsql as $$
begin
  begin execute stmt; exception when others then
    if sqlerrm not ilike '%' || pattern || '%' then raise exception 'FAIL %: wrong error: %', label, sqlerrm; end if;
    raise notice 'ok  % (%)', label, sqlerrm; return;
  end;
  raise exception 'FAIL %: no error raised', label;
end $$;
create function public.t_as(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, false) $$;
create function public.uid(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000000' || n)::uuid $$;
grant execute on function public.t_eq, public.t_err, public.t_as, public.uid to authenticated, anon;

insert into auth.users (id, email, raw_user_meta_data) values
  (uid('01'), 'priya@prod.test',  '{"username":"priya","full_name":"Priya Producer"}'),
  (uid('02'), 'manav@prod.test',  '{"username":"manav","full_name":"Manav Manager"}'),
  (uid('03'), 'asha@prod.test',   '{"username":"asha","full_name":"Asha Accounts"}'),
  (uid('04'), 'hari@crew.test',   '{"username":"hari","full_name":"Hari DOP"}'),
  (uid('05'), 'chetan@crew.test', '{"username":"chetan","full_name":"Chetan Focus Puller"}'),
  (uid('06'), 'vik@vendor.test',  '{"username":"vikram","full_name":"Vikram Rentals"}'),
  (uid('07'), 'xavier@else.test', '{"username":"xavier","full_name":"Xavier Outsider"}');
select t_eq((select count(*)::int from profiles where username is not null), 7, 'profile + username created at sign-up');
select t_eq(login_email('Priya'), 'priya@prod.test', 'username login resolves to email');
select t_eq(login_email('nobody'), null::text, 'unknown username resolves to nothing');
insert into auth.users (id, email, raw_user_meta_data) values (uid('09'), 'copy@cat.test', '{"username":"priya","full_name":"Copy Cat"}');
select t_eq((select username from profiles where id = uid('09')), null::text, 'taken username does not block sign-up');
select t_eq(username_available('priya'), false, 'username_available: taken');
select t_eq(username_available('new.person'), true, 'username_available: free');
delete from auth.users where id = uid('09');

-- ---------- producer sets up a project
select t_as(uid('01')::text); set role authenticated;
select t_err($$select create_project('X','film','Co','27AAPCS7679M1Z4',null,null,null)$$, 'gstin', 'bad GSTIN checksum rejected');
create temp table ctx as select id as project, invite_code from create_project('Monsoon Diaries','series','Kites Pictures Pvt Ltd','27AAPCS7679M1Z5','Andheri West, Mumbai', current_date, current_date + 40);
grant select on ctx to authenticated;
select t_eq((select role::text from members where project_id = (select project from ctx) and user_id = uid('01')), 'producer', 'creator becomes producer');
select t_eq((select company_state_code from projects where id = (select project from ctx)), '27', 'state taken from company GSTIN');
reset role;

-- everyone else joins with the invite code
do $$ declare u text; begin
  foreach u in array array['02','03','04','05'] loop
    perform t_as(uid(u)::text); execute 'set role authenticated';
    perform join_project((select invite_code from ctx));
    execute 'reset role';
  end loop;
  perform t_as(uid('06')::text); execute 'set role authenticated';
  perform join_project(lower((select invite_code from ctx)), true);
  execute 'reset role';
end $$;
select t_eq((select count(*)::int from members where project_id = (select project from ctx)), 6, 'five people joined by invite code');
select t_eq((select role::text from members where user_id = uid('06')), 'vendor', 'vendor joins as vendor');

-- roles
select t_as(uid('02')::text); set role authenticated;
select t_err($$select update_member((select project from ctx), uid('03'), '{"role":"accounts"}')$$, 'Only the producer', 'manager cannot grant accounts');
reset role;
select t_as(uid('01')::text); set role authenticated;
select update_member((select project from ctx), uid('02'), '{"role":"manager","department":"Production","designation":"Line Producer"}');
select update_member((select project from ctx), uid('03'), '{"role":"accounts","department":"Production","designation":"Accountant"}');
select update_member((select project from ctx), uid('04'), '{"role":"hod","department":"Camera","designation":"DOP","rate":25000,"rate_unit":"day"}');
select update_member((select project from ctx), uid('05'), '{"department":"Camera","designation":"1st AC","rate":6000,"rate_unit":"day"}');
select update_member((select project from ctx), uid('06'), '{"department":"Camera","designation":"Camera rentals"}');
select t_err($$select update_member((select project from ctx), uid('01'), '{"role":"crew"}')$$, 'at least one producer', 'last producer cannot step down');
reset role;
select t_as(uid('05')::text); set role authenticated;
select t_err($$select update_member((select project from ctx), uid('05'), '{"rate":99999}')$$, 'Only the producer or production manager', 'crew cannot change own rate');
update members set rate = 99999 where user_id = auth.uid();
select t_eq((select rate from members where user_id = uid('05')), 6000::bigint, 'direct edit of own deal changes nothing');
select t_eq((select count(*)::int from members), 6, 'crew sees the crew list');
select t_eq((select bank_account from directory where id = uid('04')), null::text, 'crew cannot see a colleague''s bank details');
reset role;

-- outsider sees nothing
select t_as(uid('07')::text); set role authenticated;
select t_eq((select count(*)::int from projects), 0, 'outsider sees no projects');
select t_eq((select count(*)::int from directory), 1, 'outsider sees only themselves');
select t_err($$select join_project('NOPE1234')$$, 'No project', 'wrong invite code');
reset role;

-- ---------- KYC, contracts
select t_as(uid('05')::text); set role authenticated;
select t_err($$update profiles set pan = 'BAD' where id = auth.uid()$$, 'check constraint', 'bad PAN rejected');
select t_err($$update profiles set bank_ifsc = 'ICIC000038' where id = auth.uid()$$, 'check constraint', 'bad IFSC rejected');
reset role;

select t_as(uid('02')::text); set role authenticated;
create temp table c1 as select id from create_contract((select project from ctx), uid('05'), (select id from contract_templates where project_id is null limit 1));
grant select on c1 to authenticated;
select t_eq((select fields ->> 'rate' from contracts where id = (select id from c1)), '₹6,000', 'contract pre-filled with the deal rate');
select t_eq((select fields ->> 'designation' from contracts where id = (select id from c1)), '1st AC', 'contract pre-filled with the role');
select edit_contract((select id from c1), '{"start_date":"01 Dec 2026"}');
select send_contract((select id from c1));
reset role;

select t_as(uid('05')::text); set role authenticated;
select t_err($$select sign_contract((select id from c1), 'Chetan Kumar', 'data:image/png;base64,AAAA')$$, 'Complete your profile', 'cannot sign without KYC');
update profiles set legal_name = 'Chetan Kumar', pan = 'ABCPK1234F', address = 'Goregaon East, Mumbai', state_code = '27',
  bank_holder = 'Chetan Kumar', bank_name = 'HDFC Bank', bank_account = '50100123456789', bank_ifsc = 'HDFC0000123', phone = '+91 98200 11111'
  where id = auth.uid();
select t_err($$select sign_contract((select id from c1), 'Chetan Kumar', 'not-a-picture')$$, 'Draw your signature', 'drawn signature required');
select t_eq((select status::text from sign_contract((select id from c1), 'Chetan Kumar', 'data:image/png;base64,iVBORw0KGgo=')), 'signed', 'crew signs');
select t_eq((select signed_text like '%Chetan Kumar, PAN ABCPK1234F%' from contracts where id = (select id from c1)), true, 'signed text carries latest KYC');
select t_eq((select length(signed_hash) from contracts where id = (select id from c1)), 64, 'signature fingerprint (SHA-256) stored');
select t_eq((select signed_text like '%01 Dec 2026%' from contracts where id = (select id from c1)), true, 'manager''s edit is in the signed text');
reset role;

select t_as(uid('04')::text); set role authenticated;
select t_eq((select count(*)::int from contracts), 0, 'HOD cannot read other people''s contracts');
reset role;
select t_as(uid('02')::text); set role authenticated;
select t_err($$select countersign_contract((select id from c1))$$, 'Only the producer', 'manager cannot countersign');
reset role;
select t_as(uid('01')::text); set role authenticated;
select t_eq((select status::text from countersign_contract((select id from c1))), 'countersigned', 'producer countersigns');
select t_err($$select edit_contract((select id from c1), '{"rate":"₹1"}')$$, 'can''t be edited', 'signed contract is locked');
select t_eq((select count(*)::int from contract_events where contract_id = (select id from c1)), 5, 'audit trail: created, edited, sent, signed, countersigned');
reset role;

-- ---------- invoices: crew -> HOD -> accounts -> payment run
select t_as(uid('05')::text); set role authenticated;
create temp table i1 as select id from submit_invoice((select project from ctx), 'CK-001', current_date, current_date - 4, current_date, '1st AC, 5 shoot days', 5, 6000, 0);
grant select on i1 to authenticated;
select t_eq((select array[amount, gst, total, payable] from invoices where id = (select id from i1)), array[30000,0,30000,30000]::bigint[], '5 days x ₹6,000');
select t_err($$select submit_invoice((select project from ctx), 'CK-001', current_date, null, null, 'dup', 1, 100, 0)$$, 'already used invoice number', 'duplicate invoice number blocked');
select t_err($$select submit_invoice((select project from ctx), 'CK-002', current_date, null, null, 'x', 1, 100, 18)$$, 'GSTIN', 'no GST without a GSTIN');
select t_err($$select hod_approve_invoice((select id from i1))$$, 'Only the head', 'crew cannot approve');
reset role;

select t_as(uid('03')::text); set role authenticated;
select t_err($$select approve_invoice((select id from i1))$$, 'head of department first', 'accounts waits for the HOD');
reset role;
select t_as(uid('04')::text); set role authenticated;
select t_eq((select count(*)::int from invoices), 1, 'HOD sees own department''s invoices');
select t_eq((select status::text from hod_approve_invoice((select id from i1))), 'hod_approved', 'HOD approves');
reset role;
select t_as(uid('03')::text); set role authenticated;
select t_eq((select array[tds, payable] from approve_invoice((select id from i1), 10)), array[3000, 27000]::bigint[], 'accounts approves with 10% TDS');
reset role;

-- vendor with GST
select t_as(uid('06')::text); set role authenticated;
update profiles set legal_name = 'Vikram Camera Rentals LLP', pan = 'AAPCS7679M', gstin = '27AAPCS7679M1Z5', address = 'Film City Road, Mumbai',
  bank_holder = 'Vikram Camera Rentals LLP', bank_name = 'ICICI Bank', bank_account = '003805014250', bank_ifsc = 'ICIC0000038' where id = auth.uid();
create temp table i2 as select id from submit_invoice((select project from ctx), 'VCR/26/118', current_date, null, null, 'ALEXA kit hire', 3, 40000, 18);
grant select on i2 to authenticated;
select t_eq((select array[amount, gst, total] from invoices where id = (select id from i2)), array[120000, 21600, 141600]::bigint[], 'GST 18% on a vendor invoice');
reset role;
select t_as(uid('02')::text); set role authenticated;
select t_eq((select array[tds, payable] from approve_invoice((select id from i2), 2)), array[2400, 139200]::bigint[], 'manager approves directly; TDS on pre-GST amount');
reset role;

-- payment run
select t_as(uid('04')::text); set role authenticated;
select t_err($$select create_payment_batch((select project from ctx), array[(select id from i1)])$$, 'Only accounts', 'HOD cannot create payments');
reset role;
select t_as(uid('03')::text); set role authenticated;
create temp table b1 as select id, amount from create_payment_batch((select project from ctx), array[(select id from i1), (select id from i2)]);
grant select on b1 to authenticated;
select t_eq((select amount from b1), 166200::bigint, 'payment run totals payable amounts');
select t_err($$select create_payment_batch((select project from ctx), array[(select id from i1)])$$, 'not already in a payment run', 'invoice cannot be paid twice');
select t_err($$select reject_invoice((select id from i1), 'oops')$$, 'can''t be rejected', 'invoice in a payment run is locked');
select mark_batch_paid((select id from b1), 'UTR123456');
select t_eq((select count(*)::int from invoices where status = 'paid'), 2, 'invoices marked paid with the bank reference');
reset role;
select t_as(uid('05')::text); set role authenticated;
select t_eq((select payment_ref from invoices where id = (select id from i1)), 'UTR123456', 'crew sees their payment reference');
select t_eq((select count(*)::int from invoices), 1, 'crew sees only their own invoices');
reset role;

-- rejection loop
select t_as(uid('05')::text); set role authenticated;
create temp table i3 as select id from submit_invoice((select project from ctx), 'CK-002', current_date, null, null, 'Prep day', 1, 6000, 0);
grant select on i3 to authenticated;
reset role;
select t_as(uid('04')::text); set role authenticated;
select t_err($$select reject_invoice((select id from i3), '  ')$$, 'Say why', 'rejection needs a reason');
select t_eq((select status::text from reject_invoice((select id from i3), 'Prep day not approved')), 'rejected', 'HOD rejects with a reason');
reset role;

-- ---------- budget and cost report
select t_as(uid('03')::text); set role authenticated;
select set_budget((select project from ctx), 'Camera', 500000);
select t_eq((select array[budget, committed, paid, pending] from cost_report((select project from ctx)) where department = 'Camera'),
            array[500000, 150000, 150000, 0]::bigint[], 'cost report: budget vs committed vs paid');
reset role;
select t_as(uid('05')::text); set role authenticated;
select t_eq((select count(*)::int from cost_report((select project from ctx))), 0, 'crew cannot see the cost report');
reset role;

-- ---------- call sheets, day reports, attendance
select t_as(uid('02')::text); set role authenticated;
create temp table cs as select id from save_call_sheet((select project from ctx),
  '{"shoot_date":"2026-12-01","day_no":1,"location":"Film City, Goregaon","general_call":"07:00","scenes":[{"scene":"12","description":"Rooftop chase"}],"calls":[{"name":"Chetan","department":"Camera","call":"06:30"}]}');
grant select on cs to authenticated;
reset role;
select t_as(uid('05')::text); set role authenticated;
select t_eq((select count(*)::int from call_sheets), 0, 'crew can''t see a draft call sheet');
reset role;
select t_as(uid('02')::text); set role authenticated;
select publish_call_sheet((select id from cs));
reset role;
select t_as(uid('05')::text); set role authenticated;
select t_eq((select location from call_sheets), 'Film City, Goregaon', 'published call sheet visible to crew');
select mark_call_sheet_viewed((select id from cs));
reset role;
select t_as(uid('02')::text); set role authenticated;
select t_eq((select count(*)::int from call_sheet_views), 1, 'manager sees who has read the call sheet');
select pg_sleep(0.01);
select publish_call_sheet((select id from cs));
select t_eq((select count(*)::int from call_sheet_views v join call_sheets c on c.id = v.call_sheet_id where v.viewed_at >= c.published_at), 0, 're-publishing asks everyone to read again');
select save_day_report((select project from ctx), '{"shoot_date":"2026-12-01","first_shot":"08:10","wrap":"19:45","scenes_done":"12, 14","setups":22}');
select t_eq((select (scan_id_card((select project from ctx), (select card_code from members where user_id = uid('05')))) ->> 'name'), 'Chetan Focus Puller', 'ID card scan checks crew in');
select t_eq((select (scan_id_card((select project from ctx), lower((select card_code from members where user_id = uid('05'))))) ->> 'out' is not null), true, 'second scan checks out');
select t_err($$select scan_id_card((select project from ctx), 'ZZZZZZZZZZ')$$, 'isn''t on this project', 'unknown ID card');
reset role;
select t_as(uid('05')::text); set role authenticated;
select t_err($$select scan_id_card((select project from ctx), 'ABC')$$, 'Only the producer', 'crew cannot check people in');
select t_eq((select count(*)::int from attendance), 1, 'crew sees own attendance');
select t_eq((select count(*)::int from day_reports), 1, 'crew can read day reports');
reset role;

-- direct writes are closed
select t_as(uid('01')::text); set role authenticated;
update invoices set payable = 1;
select t_eq((select count(*)::int from invoices where payable = 1), 0, 'direct invoice edits change nothing (row-level security)');
select t_err($$insert into projects (name, company_name) values ('Sneaky', 'X')$$, 'row-level security', 'no direct project inserts');
select t_err($$select log_contract((select id from c1), 'forged')$$, 'row-level security', 'cannot forge contract history');
select t_err($$update profiles set email = 'x@y.z' where id = auth.uid()$$, 'can''t be changed', 'email is not user-editable');
select t_eq((select contract_fields((select project from ctx), uid('05'))), null::jsonb, 'producer cannot pull KYC through contract_fields directly');
reset role;
select t_as(uid('07')::text); set role authenticated;
select t_eq((select contract_fields((select project from ctx), uid('05'))), null::jsonb, 'outsider cannot read KYC via contract_fields');
reset role;
select t_as(''); set role anon;
select t_eq((select count(*)::int from projects), 0, 'anonymous sees nothing');
reset role;
\echo ALL CREWDESK TESTS PASSED
