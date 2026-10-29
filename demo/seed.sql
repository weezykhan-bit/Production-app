-- Demo data for the in-browser preview. Every change goes through the same functions the live app uses,
-- signed in as the person who would make it. Dates are relative to today so the demo always looks current.
-- All people, companies, PAN/GSTIN and bank numbers below are fictional.

insert into auth.users (id, email, raw_user_meta_data) values
  ('d0000000-0000-4000-8000-000000000001', 'priya@kites.demo',   '{"username":"priya","full_name":"Priya Menon"}'),
  ('d0000000-0000-4000-8000-000000000002', 'manav@kites.demo',   '{"username":"manav","full_name":"Manav Shah"}'),
  ('d0000000-0000-4000-8000-000000000003', 'asha@kites.demo',    '{"username":"asha","full_name":"Asha Iyer"}'),
  ('d0000000-0000-4000-8000-000000000004', 'hari@crew.demo',     '{"username":"hari","full_name":"Hari Rao"}'),
  ('d0000000-0000-4000-8000-000000000005', 'chetan@crew.demo',   '{"username":"chetan","full_name":"Chetan Kumar"}'),
  ('d0000000-0000-4000-8000-000000000006', 'vikram@vendor.demo', '{"username":"vikram","full_name":"Vikram Desai"}'),
  ('d0000000-0000-4000-8000-000000000007', 'neha@crew.demo',     '{"username":"neha","full_name":"Neha Kapoor"}'),
  ('d0000000-0000-4000-8000-000000000008', 'rohit@crew.demo',    '{"username":"rohit","full_name":"Rohit Pillai"}');

-- KYC (written directly: in the app each person fills their own profile)
update profiles set phone = '+91 90000 0000' || substr(id::text, 36, 1) where id::text like 'd0000000%';
update profiles set legal_name = 'Kites Pictures Pvt Ltd', pan = 'AAKCK1234Q', address = 'Andheri West, Mumbai', state_code = '27',
  bank_holder = 'Kites Pictures Pvt Ltd', bank_name = 'HDFC Bank', bank_account = '50200011112222', bank_ifsc = 'HDFC0000060' where username = 'priya';
update profiles set legal_name = 'Hari Rao', pan = 'AQRPR4521K', address = 'Bandra East, Mumbai', state_code = '27',
  bank_holder = 'Hari Rao', bank_name = 'ICICI Bank', bank_account = '001501234567', bank_ifsc = 'ICIC0000015' where username = 'hari';
update profiles set legal_name = 'Chetan Kumar', pan = 'BCDPK7788L', address = 'Goregaon East, Mumbai', state_code = '27',
  bank_holder = 'Chetan Kumar', bank_name = 'State Bank of India', bank_account = '30112233445', bank_ifsc = 'SBIN0001234' where username = 'chetan';
update profiles set legal_name = 'Lensworks Camera Rentals LLP', pan = 'AAJFL5566M', gstin = '27AAJFL5566M1ZM', address = 'Film City Road, Goregaon, Mumbai', state_code = '27',
  bank_holder = 'Lensworks Camera Rentals LLP', bank_name = 'Axis Bank', bank_account = '918020012345678', bank_ifsc = 'UTIB0000123' where username = 'vikram';
update profiles set legal_name = 'Neha Kapoor', pan = 'CKZPK3344N', address = 'Juhu, Mumbai', state_code = '27',
  bank_holder = 'Neha Kapoor', bank_name = 'Kotak Mahindra Bank', bank_account = '7412589630', bank_ifsc = 'KKBK0000652' where username = 'neha';
-- Rohit is new and hasn't completed KYC yet.

create table public.demo_ctx (k text primary key, v uuid);

-- Priya creates the production
select set_config('request.jwt.claim.sub', 'd0000000-0000-4000-8000-000000000001', false); set role authenticated;
insert into demo_ctx select 'project', id from create_project('Monsoon Diaries', 'series', 'Kites Pictures Pvt Ltd', '27AAKCK1234Q1Z3',
  'Kites House, Veera Desai Road, Andheri West, Mumbai 400053', current_date - 6, current_date + 30);
select set_budget((select v from demo_ctx where k = 'project'), d, a)
  from (values ('Camera', 900000), ('Lighting', 450000), ('Art', 600000), ('Costume', 250000), ('Makeup & Hair', 150000), ('Production', 400000)) x(d, a);
reset role;

-- crew joins with the invite code
do $$ declare u text; code text := (select invite_code from projects where id = (select v from demo_ctx where k = 'project')); begin
  foreach u in array array['2','3','4','5','7','8'] loop
    perform set_config('request.jwt.claim.sub', 'd0000000-0000-4000-8000-00000000000' || u, false);
    execute 'set role authenticated'; perform join_project(code); execute 'reset role';
  end loop;
  perform set_config('request.jwt.claim.sub', 'd0000000-0000-4000-8000-000000000006', false);
  execute 'set role authenticated'; perform join_project(code, true); execute 'reset role';
end $$;

select set_config('request.jwt.claim.sub', 'd0000000-0000-4000-8000-000000000001', false); set role authenticated;
select update_member((select v from demo_ctx where k = 'project'), 'd0000000-0000-4000-8000-000000000002', '{"role":"manager","department":"Production","designation":"Line Producer","rate":12000,"rate_unit":"day"}');
select update_member((select v from demo_ctx where k = 'project'), 'd0000000-0000-4000-8000-000000000003', '{"role":"accounts","department":"Production","designation":"Production Accountant","rate":6000,"rate_unit":"day"}');
select update_member((select v from demo_ctx where k = 'project'), 'd0000000-0000-4000-8000-000000000004', '{"role":"hod","department":"Camera","designation":"Director of Photography","rate":35000,"rate_unit":"day"}');
select update_member((select v from demo_ctx where k = 'project'), 'd0000000-0000-4000-8000-000000000005', '{"department":"Camera","designation":"1st Assistant Camera","rate":6500,"rate_unit":"day"}');
select update_member((select v from demo_ctx where k = 'project'), 'd0000000-0000-4000-8000-000000000006', '{"department":"Camera","designation":"Camera & lens rentals","rate_unit":"lump"}');
select update_member((select v from demo_ctx where k = 'project'), 'd0000000-0000-4000-8000-000000000007', '{"department":"Costume","designation":"Costume Designer","rate":18000,"rate_unit":"day"}');
select update_member((select v from demo_ctx where k = 'project'), 'd0000000-0000-4000-8000-000000000008', '{"department":"Lighting","designation":"Gaffer","rate":5500,"rate_unit":"day"}');

-- contracts in every state
insert into demo_ctx select 'c_chetan', id from create_contract((select v from demo_ctx where k = 'project'), 'd0000000-0000-4000-8000-000000000005', (select id from contract_templates where project_id is null limit 1));
insert into demo_ctx select 'c_hari',   id from create_contract((select v from demo_ctx where k = 'project'), 'd0000000-0000-4000-8000-000000000004', (select id from contract_templates where project_id is null limit 1));
insert into demo_ctx select 'c_neha',   id from create_contract((select v from demo_ctx where k = 'project'), 'd0000000-0000-4000-8000-000000000007', (select id from contract_templates where project_id is null limit 1));
insert into demo_ctx select 'c_rohit',  id from create_contract((select v from demo_ctx where k = 'project'), 'd0000000-0000-4000-8000-000000000008', (select id from contract_templates where project_id is null limit 1));
select send_contract((select v from demo_ctx where k = 'c_chetan'));
select send_contract((select v from demo_ctx where k = 'c_hari'));
select send_contract((select v from demo_ctx where k = 'c_neha'));
reset role;
select set_config('request.jwt.claim.sub', 'd0000000-0000-4000-8000-000000000004', false); set role authenticated;
select sign_contract((select v from demo_ctx where k = 'c_hari'), 'Hari Rao', 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');
reset role;
select set_config('request.jwt.claim.sub', 'd0000000-0000-4000-8000-000000000007', false); set role authenticated;
select sign_contract((select v from demo_ctx where k = 'c_neha'), 'Neha Kapoor', 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');
reset role;
select set_config('request.jwt.claim.sub', 'd0000000-0000-4000-8000-000000000001', false); set role authenticated;
select countersign_contract((select v from demo_ctx where k = 'c_neha'));
reset role;

-- invoices at every stage
select set_config('request.jwt.claim.sub', 'd0000000-0000-4000-8000-000000000005', false); set role authenticated;
insert into demo_ctx select 'i_chetan1', id from submit_invoice((select v from demo_ctx where k = 'project'), 'CK/001', current_date - 3, current_date - 6, current_date - 4, '1st AC, shoot days 1–3', 3, 6500, 0);
insert into demo_ctx select 'i_chetan2', id from submit_invoice((select v from demo_ctx where k = 'project'), 'CK/002', current_date, current_date - 3, current_date - 1, '1st AC, shoot days 4–6', 3, 6500, 0);
reset role;
select set_config('request.jwt.claim.sub', 'd0000000-0000-4000-8000-000000000006', false); set role authenticated;
insert into demo_ctx select 'i_vikram', id from submit_invoice((select v from demo_ctx where k = 'project'), 'LW/26-27/0412', current_date - 1, current_date - 6, current_date - 1, 'ALEXA Mini LF kit with Signature Primes, 6 days', 6, 38000, 18);
reset role;
select set_config('request.jwt.claim.sub', 'd0000000-0000-4000-8000-000000000007', false); set role authenticated;
insert into demo_ctx select 'i_neha', id from submit_invoice((select v from demo_ctx where k = 'project'), 'NK-07', current_date - 2, current_date - 6, current_date - 2, 'Costume design, 5 days', 5, 18000, 0);
reset role;
select set_config('request.jwt.claim.sub', 'd0000000-0000-4000-8000-000000000004', false); set role authenticated;
select hod_approve_invoice((select v from demo_ctx where k = 'i_chetan1'));
select hod_approve_invoice((select v from demo_ctx where k = 'i_vikram'));
reset role;
select set_config('request.jwt.claim.sub', 'd0000000-0000-4000-8000-000000000003', false); set role authenticated;
select approve_invoice((select v from demo_ctx where k = 'i_chetan1'), 10);
reset role;
select set_config('request.jwt.claim.sub', 'd0000000-0000-4000-8000-000000000002', false); set role authenticated;
select approve_invoice((select v from demo_ctx where k = 'i_neha'), 10);
reset role;
select set_config('request.jwt.claim.sub', 'd0000000-0000-4000-8000-000000000003', false); set role authenticated;
insert into demo_ctx select 'batch', id from create_payment_batch((select v from demo_ctx where k = 'project'), array[(select v from demo_ctx where k = 'i_neha')]);
select mark_batch_paid((select v from demo_ctx where k = 'batch'), 'HDFCN52026102900123');
reset role;

-- call sheets: yesterday (with a day report), today and tomorrow
select set_config('request.jwt.claim.sub', 'd0000000-0000-4000-8000-000000000002', false); set role authenticated;
select publish_call_sheet(id) from save_call_sheet((select v from demo_ctx where k = 'project'), jsonb_build_object(
  'shoot_date', current_date - 1, 'day_no', 6, 'location', 'Mehboob Studios, Bandra West', 'location_url', 'https://maps.google.com/?q=Mehboob+Studios',
  'general_call', '07:00', 'first_shot', '08:30', 'wrap_est', '20:00',
  'scenes', '[{"scene":"21","description":"INT. CAFE - DAY. Meera waits; Arjun doesn''t show","cast":"Meera","location":"Cafe set"},{"scene":"22","description":"INT. CAFE - DAY. The letter","cast":"Meera, Waiter","location":"Cafe set"}]'::jsonb,
  'calls', '[]'::jsonb, 'notes', 'Rain machine on standby from 14:00.', 'emergency', 'Lilavati Hospital, Bandra: +91 22 2675 1000'));
select save_day_report((select v from demo_ctx where k = 'project'), jsonb_build_object('shoot_date', current_date - 1, 'crew_call', '07:00', 'first_shot', '08:42',
  'lunch', '13:30', 'wrap', '20:25', 'scenes_done', '21, 22', 'scenes_left', '23 (moved to day 8)', 'setups', 26, 'notes', 'Lost 40 min to a generator fault. No injuries.'));
select publish_call_sheet(id) from save_call_sheet((select v from demo_ctx where k = 'project'), jsonb_build_object(
  'shoot_date', current_date, 'day_no', 7, 'location', 'Carter Road Promenade, Bandra West', 'location_url', 'https://maps.google.com/?q=Carter+Road',
  'general_call', '06:00', 'first_shot', '06:45', 'wrap_est', '18:30',
  'scenes', '[{"scene":"14","description":"EXT. PROMENADE - DAWN. Arjun''s run","cast":"Arjun","location":"Carter Road"},{"scene":"15","description":"EXT. PROMENADE - DAY. First meeting","cast":"Arjun, Meera","location":"Carter Road"}]'::jsonb,
  'calls', jsonb_build_array(
     jsonb_build_object('user_id', 'd0000000-0000-4000-8000-000000000004', 'name', 'Hari Rao', 'department', 'Camera', 'call', '05:30'),
     jsonb_build_object('user_id', 'd0000000-0000-4000-8000-000000000005', 'name', 'Chetan Kumar', 'department', 'Camera', 'call', '05:15'),
     jsonb_build_object('user_id', 'd0000000-0000-4000-8000-000000000008', 'name', 'Rohit Pillai', 'department', 'Lighting', 'call', '05:00'),
     jsonb_build_object('user_id', 'd0000000-0000-4000-8000-000000000007', 'name', 'Neha Kapoor', 'department', 'Costume', 'call', '05:30')),
  'notes', 'Sunrise 06:38. Permits with Manav. Keep the promenade walkable for the public.', 'emergency', 'Holy Family Hospital, Bandra: +91 22 2643 3333'));
select save_call_sheet((select v from demo_ctx where k = 'project'), jsonb_build_object(
  'shoot_date', current_date + 1, 'day_no', 8, 'location', 'Mehboob Studios, Bandra West', 'general_call', '08:00',
  'scenes', '[{"scene":"23","description":"INT. CAFE - NIGHT. Closing time","cast":"Meera, Arjun"}]'::jsonb, 'notes', 'Draft: waiting on cast confirmation.'));
reset role;
select set_config('request.jwt.claim.sub', 'd0000000-0000-4000-8000-000000000005', false); set role authenticated;
select mark_call_sheet_viewed(id) from call_sheets where shoot_date = current_date;
reset role;

drop table public.demo_ctx;
select set_config('request.jwt.claim.sub', '', false);
