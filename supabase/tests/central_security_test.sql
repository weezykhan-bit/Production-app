-- Encrypted PAN and bank numbers, two-step login for money actions, mobile sign-up, IMDb links. Runs last.
\set ON_ERROR_STOP 1
\set QUIET 1
\set fowzan '11111111-1111-1111-1111-111111111111'
\set ritika '22222222-2222-2222-2222-222222222222'
\set manoj  '33333333-3333-3333-3333-333333333333'
\set neha   '44444444-4444-4444-4444-444444444444'
\set imran  '66666666-6666-6666-6666-666666666666'
select id as pid from productions limit 1 \gset
reset role;
-- stored encrypted: no plain PAN or account number left in the table
select ok((select count(*) from profiles where pan is not null or bank_account is not null) = 0, 'no plain PAN or account number in the table');
select ok((select count(*) > 0 and bool_and(position(convert_to(kyc_dec(pan_enc), 'UTF8') in pan_enc) = 0) from profiles where pan_enc is not null), 'PANs are stored as ciphertext, not readable in the table');
select refused($$update profiles set pan = 'ABCDE1234F' where true$$, 'profiles_kyc_encrypted');
-- the person sees their own; the owner sees others only after two-step login
select set_config('request.jwt.claims', '{"aal":"aal1"}', false) \g /dev/null
select as_user(:'imran'); set role authenticated;
select ok((select pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$' and bank_account ~ '^[0-9]+$' from people where id = :'imran'), 'crew see their own PAN and account in full');
select refused($$select kyc_dec(pan_enc) from profiles$$, 'permission denied');
select refused($$select kyc_key()$$, 'permission denied');
reset role;
select as_user(:'ritika'); set role authenticated;
select ok((select pan is null and bank_account is null and bank_tail ~ '^[0-9]{4}$' from people where id = :'imran'), 'without two-step login the CFO sees only the last 4 digits');
select refused(format($$select pay_invoices(%L, array[gen_random_uuid()], 'UTRTEST01')$$, :'pid'), 'two-step login');
select refused(format($$select tally_mark(%L)$$, :'pid'), 'two-step login');
select refused(format($$select set_deal(%L, '{"rate":1}')$$, (select id from crew where user_id = :'imran')), 'two-step login');
select refused($$select add_admin('manoj', 'cfo')$$, 'two-step login');
reset role;
select as_user(:'neha'); set role authenticated;
select refused(format($$select give_petty_float(%L, %L, 100)$$, :'pid', :'manoj'), 'two-step login');
reset role;
select as_user(:'manoj'); set role authenticated;   -- the Line Producer isn't asked for it
select ok(exists (select 1 from crew), 'others carry on with a password');
reset role;
select set_config('request.jwt.claims', '{"aal":"aal2"}', false) \g /dev/null
select as_user(:'ritika'); set role authenticated;
select ok((select pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$' from people where id = :'imran'), 'after two-step login the CFO sees the full PAN');
select refused(format($$select pay_invoices(%L, array[gen_random_uuid()], 'UTRTEST01')$$, :'pid'), 'Pick approved invoices');   -- gets past the two-step check
reset role;
-- saving keeps it encrypted, validates, and the bank-change alert still shows the old last digits
select as_user(:'imran'); set role authenticated;
select refused($$select save_profile('{"legal":"Imran Shaikh","pan":"BAD","address":"Mumbai","bank_holder":"Imran","bank_account":"123456789","bank_ifsc":"HDFC0001234"}')$$, 'PAN is 10 characters');
select refused($$select save_profile('{"legal":"Imran Shaikh","pan":"ABCPS1234K","address":"Mumbai","bank_holder":"Imran","bank_account":"12AB","bank_ifsc":"HDFC0001234"}')$$, 'Account numbers');
select refused($$select save_profile('{"legal":"Imran Shaikh","pan":"ABCPS1234K","address":"Mumbai","bank_holder":"Imran","bank_account":"123456789","bank_ifsc":"HDFC0001234","imdb":"https://evil.example/nm1"}')$$, 'IMDb page link');
select (select bank_tail from people where id = :'imran') as oldtail \gset
select save_profile('{"legal":"Imran Shaikh","pan":"ABCPS1234K","address":"Mumbai","bank_holder":"Imran Shaikh","bank_account":"998877665544","bank_ifsc":"HDFC0001234","imdb":"https://www.imdb.com/name/nm1234567/"}');
select ok((select bank_account = '998877665544' and pan = 'ABCPS1234K' and imdb_url = 'https://www.imdb.com/name/nm1234567/' from people where id = :'imran'), 'new details saved and read back');
reset role;
select ok((select pan is null and bank_account is null and bank_tail = '5544' from profiles where id = :'imran'), 'still encrypted in the table');
select ok(exists (select 1 from activity where text like 'Changed bank account: ••' || :'oldtail' || '%→ ••5544%'), 'bank change logged with old and new last digits');
select as_user(:'manoj'); set role authenticated;
select ok((select imdb_url from people where id = :'imran') like 'https://www.imdb.com/name/nm%', 'the production office sees the IMDb link');
reset role;
-- mobile sign-up: the verified number lands on the profile
insert into auth.users (id, email, phone, raw_user_meta_data) values ('c1111111-0000-0000-0000-000000000001', null, '919820099999', '{}');
select ok((select phone from profiles where id = 'c1111111-0000-0000-0000-000000000001') = '+919820099999', 'a mobile sign-up gets their verified number on their profile');
update crew set user_id = 'c1111111-0000-0000-0000-000000000001' where id = (select id from crew where user_id is null limit 1) returning invite_name as iname \gset
select ok((select full_name from profiles where id = 'c1111111-0000-0000-0000-000000000001') = :'iname', 'taking up an invite gives a mobile-only account the invited name');
\echo ALL SECURITY TESTS PASSED
