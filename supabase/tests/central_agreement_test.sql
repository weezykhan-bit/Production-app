-- Agreement templates from Legal, and questions on clauses before signing. Runs after the notification-choices test,
-- which leaves Tara with a finished profile and documents and no agreement yet.
\set ON_ERROR_STOP 1
\set QUIET 1
\set fowzan '11111111-1111-1111-1111-111111111111'
\set ritika '22222222-2222-2222-2222-222222222222'
\set manoj  '33333333-3333-3333-3333-333333333333'
\set asha   '55555555-5555-5555-5555-555555555555'
\set imran  '66666666-6666-6666-6666-666666666666'
\set tara   'd1111111-0000-0000-0000-000000000001'
\set leela  'e1111111-0000-0000-0000-000000000001'
\set lex    'e1111111-0000-0000-0000-000000000002'
\set tina   'e1111111-0000-0000-0000-000000000003'
select id as pid from productions limit 1 \gset
select id as tara_crew from crew where user_id = :'tara' \gset
-- that test picks any waiting invite, so pin the list it is on
update crew set role = 'crew', dept = 'Camera', job = 'Camera Attendant', kind = 'crew', joining = coalesce(joining, '2026-01-01') where id = :'tara_crew';

-- ---------------------------------------------------------------- Legal role
insert into auth.users (id, email, raw_user_meta_data) values
  (:'leela', 'leela@test.in', '{"username":"leela","full_name":"Leela Rao"}'),
  (:'lex', 'lex@test.in', '{"username":"lex","full_name":"Lex Dsouza"}'),
  (:'tina', 'tina@test.in', '{"username":"tina","full_name":"Tina Gomes"}');
update auth.users set email_confirmed_at = now() where id in (:'leela', :'lex', :'tina');
select as_user(:'manoj'); set role authenticated;
select refused($$select onboard((select id from productions limit 1), '{"name":"Leela Rao","email":"leela@test.in","role":"legal","dept":"Accounts & Legal","job":"Legal Counsel","rate":5000,"joining":"2026-01-01"}')$$, 'Only the CFO or Commercial Head');
reset role;
select as_user(:'fowzan'); set role authenticated;
select onboard(:'pid', '{"name":"Leela Rao","email":"leela@test.in","role":"legal","dept":"Accounts & Legal","job":"Legal Counsel","rate":5000,"joining":"2026-01-01"}');
select onboard(:'pid', '{"name":"Lex Dsouza","email":"lex@test.in","role":"legal","dept":"Accounts & Legal","job":"Legal Associate","rate":3000,"joining":"2026-01-01"}');
reset role;
select ok((select role from crew where user_id = :'leela') = 'legal', 'the owners give the Legal role');

-- ---------------------------------------------------------------- the library
select ok((select count(*) from agreement_templates where source = 'sample' and approved_at is null) = 4, 'four sample templates arrive unapproved');
select as_user(:'imran'); set role authenticated;
select ok((select count(*) from agreement_templates) = 0, 'crew can’t read templates');
select refused($$select save_template('{"name":"Mine","kind":"crew","body":"x"}')$$, 'Only Legal');
reset role;
select as_user(:'asha'); set role authenticated;
select ok((select count(*) from agreement_templates) = 4, 'staff can read templates to pick one');
select refused($$select save_template(jsonb_build_object('name','HOD draft','kind','crew','body',repeat('Clause text. ', 30)))$$, 'Only Legal');
reset role;

select as_user(:'leela'); set role authenticated;
select refused($$select save_template('{"name":"Short","kind":"crew","body":"Too short"}')$$, 'at least 200 characters');
select refused($$select save_template(jsonb_build_object('name','Bad blanks','kind','crew','body','Hello {{nickname}} and {{ Name }}. ' || repeat('Clause text. ', 20)))$$, 'can’t fill \{\{nickname\}\}');
select save_template(jsonb_build_object('name','Swastik crew standard','kind','crew','source','upload','file_name','crew-standard.docx','body',
  E'CREW AGREEMENT for {{ Production }}\n\nBetween {{company}} and {{legal_name}} (PAN {{pan}}).\n\n1. ROLE. {{job}}, {{dept}}, from {{joining}} to {{end_date}}.\n\n2. FEE. {{fee}}. Tax is deducted at source {{tds}}.\n\n3. PAYMENT. Within {{terms}}, to {{bank}}.\n\n4. HOURS. {{overtime_rule}}\n\n5. CONFIDENTIALITY. Everything on set stays confidential.\n\n6. LAW. Courts at {{city}}.')) as tpl \gset
select ok((select body like '%{{production}}%' and version = 1 and approved_at is null and source = 'upload' from agreement_templates where id = :'tpl'), 'blanks are tidied, the upload is kept as version 1, unapproved');
select refused(format('select approve_template(%L)', :'tpl'), 'Someone else approves your own changes');
select refused($$select approve_template((select id from agreement_templates where source = 'sample' limit 1))$$, 'sample text');
select refused($$select send_agreement((select id from crew where user_id = 'e1111111-0000-0000-0000-000000000001'), repeat('Built-in agreement text. ', 12))$$, 'Someone else sends your own agreement');
reset role;
select as_user(:'manoj'); set role authenticated;
select refused(format('select set_production_template(%L, %L, %L)', :'pid', 'crew', :'tpl'), 'Approve the template before using it');
reset role;
select as_user(:'lex'); set role authenticated;
select approve_template(:'tpl');
select refused(format('select approve_template(%L)', :'tpl'), 'already approved');
reset role;
select as_user(:'manoj'); set role authenticated;
select refused(format('select set_production_template(%L, %L, %L)', :'pid', 'cast', :'tpl'), 'different list');
select set_production_template(:'pid', 'crew', :'tpl');
select ok((select template_id from production_templates where production_id = :'pid' and kind = 'crew') = :'tpl', 'the crew list uses the approved template');
select ok(preview_agreement(:'tara_crew') like '%Between %Tara Shah (PAN ••••••777K)%', 'the preview fills the blanks, PAN shown only by its last digits');
select ok(preview_agreement(:'tara_crew') like '%account ending 9012, IFSC HDFC0001234%', 'the bank is shown only by its last digits');
select ok(preview_agreement(:'tara_crew') like '%12 hours including a meal break%divided by 12%', 'the overtime rule comes from the production');
select ok(preview_agreement(:'tara_crew') not like '%{{%', 'nothing is left blank');
reset role;
select as_user(:'imran'); set role authenticated;
select refused($$select preview_agreement((select id from crew where user_id = 'd1111111-0000-0000-0000-000000000001'))$$, 'Only Legal');
select refused($$select agreement_fields((select id from crew where user_id = 'd1111111-0000-0000-0000-000000000001'))$$, 'permission denied');
reset role;

-- editing an approved template needs approving again; sending waits for it
select as_user(:'leela'); set role authenticated;
select save_template(jsonb_build_object('id', :'tpl', 'name','Swastik crew standard','kind','crew','body',
  (select body from agreement_templates where id = :'tpl') || E'\n\n7. NOTICE. Notices go to the email in CrewDesk.'));
select ok((select version = 2 and approved_at is null from agreement_templates where id = :'tpl'), 'a change is version 2 and clears the approval');
select ok((select count(*) from agreement_template_versions where template_id = :'tpl') = 2, 'both versions are kept');
reset role;
select as_user(:'manoj'); set role authenticated;
select refused($$select send_agreement((select id from crew where user_id = 'd1111111-0000-0000-0000-000000000001'), null)$$, 'needs approving again');
reset role;
select as_user(:'ritika'); set role authenticated;
select approve_template(:'tpl');
reset role;

-- ---------------------------------------------------------------- sending, questions, versions
select as_user(:'leela'); set role authenticated;
select ok(send_agreement(:'tara_crew', null) = 1, 'Legal sends the agreement, filled in by the server, as version 1');
reset role;
select ok((select ag_status = 'sent' and ag_template = :'tpl' and ag_template_version = 2 and ag_text like '%7. NOTICE%' from crew where id = :'tara_crew'), 'the agreement records the template and its version');
select ok(exists (select 1 from notifications where user_id = :'tara' and title = 'Your agreement is ready to sign'), 'Tara is told');

delete from notifications;
select as_user(:'imran'); set role authenticated;
select refused($$select raise_agreement_query((select id from crew where user_id = 'd1111111-0000-0000-0000-000000000001'), '2', null, 'Why?')$$, 'Only the person');
reset role;
select as_user(:'tara'); set role authenticated;
select raise_agreement_query(:'tara_crew', '2', '2. FEE.', 'Can the fee be paid weekly?') as q1 \gset
select raise_agreement_query(:'tara_crew', '5', null, 'Can I post behind-the-scenes photos after release?') as q2 \gset
select raise_agreement_query(:'tara_crew', '6', null, 'Is Mumbai the only court?') as q3 \gset
select refused($$select sign_agreement((select id from crew where user_id = 'd1111111-0000-0000-0000-000000000001'), 'Tara Shah', 'data:image/png;base64,AAA', 1)$$, '3 questions on this agreement are still open');
reset role;
select ok(exists (select 1 from notifications where user_id = :'leela' and title = 'Tara Shah asked about clause 2' and view = 'agreements'), 'Legal is asked');
select ok(not exists (select 1 from notifications where user_id = :'asha'), 'a Head of Department isn’t');

select as_user(:'asha'); set role authenticated;
select ok((select count(*) from agreement_queries where crew_id = :'tara_crew') = 3, 'staff can follow the questions');
select refused($$select note_agreement_query('$$ || :'q1' || $$', 'No')$$, 'Only the person');
reset role;
select as_user(:'leela'); set role authenticated;
select note_agreement_query(:'q1', 'Weekly works if your invoices are weekly. I will change clause 3.');
reset role;
select ok(exists (select 1 from notifications where user_id = :'tara' and title = 'Reply on clause 2 of your agreement'), 'Tara hears the reply');
select as_user(:'tara'); set role authenticated;
select ok((select count(*) from agreement_query_notes where query_id = :'q1') = 1, 'Tara sees the reply');
select note_agreement_query(:'q1', 'Thank you.');
reset role;

-- change the agreement: version 2 closes the fee question
select as_user(:'leela'); set role authenticated;
select refused($$select revise_agreement((select id from crew where user_id = 'd1111111-0000-0000-0000-000000000001'), (select ag_text from crew where user_id = 'd1111111-0000-0000-0000-000000000001'), 'nothing', '{}')$$, 'Nothing changed');
select refused($$select revise_agreement((select id from crew where user_id = 'd1111111-0000-0000-0000-000000000001'), (select ag_text || ' x' from crew where user_id = 'd1111111-0000-0000-0000-000000000001'), '', '{}')$$, 'Say what changed');
select ok(revise_agreement(:'tara_crew', (select replace(ag_text, '3. PAYMENT. Within', '3. PAYMENT. Weekly invoices are allowed. Within') from crew where id = :'tara_crew'),
          'Clause 3: weekly invoices allowed', array[:'q1']::uuid[]) = 2, 'Legal changes the agreement to version 2');
-- keep a clause as it is, with a reason
select refused($$select close_agreement_query('$$ || :'q2' || $$', '')$$, 'Explain why');
select ok(close_agreement_query(:'q2', 'Posting stays off until the Production allows it in writing.') = 'kept', 'Legal keeps clause 5 with a reason');
reset role;
select ok((select status from agreement_queries where id = :'q1') = 'changed' and (select outcome from agreement_queries where id = :'q1') = 'Clause 3: weekly invoices allowed', 'the fee question closes as changed');
select ok((select ag_version from crew where id = :'tara_crew') = 2 and (select count(*) from agreement_versions where crew_id = :'tara_crew') = 2, 'both versions are kept');
select ok(exists (select 1 from notifications where user_id = :'tara' and title = 'Your agreement was updated (version 2)'), 'Tara is told about version 2');
select ok(exists (select 1 from notifications where user_id = :'tara' and title = 'Clause 5 stays as it is'), 'and about the kept clause');

select as_user(:'tara'); set role authenticated;
select refused($$select note_agreement_query('$$ || :'q2' || $$', 'Please?')$$, 'This question is closed');
select ok(close_agreement_query(:'q3', null) = 'withdrawn', 'Tara withdraws her own question');
select refused($$select sign_agreement((select id from crew where user_id = 'd1111111-0000-0000-0000-000000000001'), 'Tara Shah', 'data:image/png;base64,AAA', 1)$$, 'changed while you were reading it. Read version 2');
select refused($$select sign_agreement((select id from crew where user_id = 'd1111111-0000-0000-0000-000000000001'), 'Tara Shah', 'data:image/png;base64,AAA')$$, 'was updated. Reload CrewDesk, read version 2');
select set_config('request.headers', '{"x-forwarded-for":"203.0.113.9, 10.0.0.1","user-agent":"TestBrowser/1.0"}', false);
select sign_agreement(:'tara_crew', 'Tara Shah', 'data:image/png;base64,AAA', 2);
select set_config('request.headers', 'not json', false);
select ok((select ip = '203.0.113.9' and user_agent = 'TestBrowser/1.0' from agreement_evidence where crew_id = :'tara_crew' and event = 'signed'), 'with the network address and browser it came from');
select ok((select count(*) from agreement_evidence where crew_id = :'tara_crew' and event = 'signed' and version = 2 and hash is not null and "by" = :'tara') = 1, 'the signature leaves an evidence record she can read');
select ok(agreement_intact(:'tara_crew'), 'the stored text matches the fingerprint');
select refused($$select raise_agreement_query((select id from crew where user_id = 'd1111111-0000-0000-0000-000000000001'), '1', null, 'Late question')$$, 'before the agreement is signed');
reset role;
select ok((select ag_status = 'signed' and ag_text like '%Weekly invoices are allowed%' from crew where id = :'tara_crew'), 'Tara signs version 2');
select as_user(:'asha'); set role authenticated;
select ok((select count(*) from agreement_evidence where crew_id = :'tara_crew') = 0, 'a Head of Department can’t read someone else’s signing evidence');
reset role;
select as_user(:'leela'); set role authenticated;
select ok((select count(*) from agreement_evidence where crew_id = :'tara_crew') = 1, 'Legal can');
reset role;
update crew set ag_text = ag_text || ' (edited behind the scenes)' where id = :'tara_crew';
select as_user(:'leela'); set role authenticated;
select ok(not agreement_intact(:'tara_crew'), 'a change to signed text is caught by the fingerprint');
reset role;
update crew set ag_text = replace(ag_text, ' (edited behind the scenes)', '') where id = :'tara_crew';

-- a deal change withdraws a sent agreement and its open questions
select as_user(:'fowzan'); set role authenticated;
select onboard(:'pid', '{"name":"Tina Gomes","email":"tina@test.in","role":"crew","dept":"Camera","job":"Trainee","rate":1500,"joining":"2026-01-01"}') as lex_crew \gset
reset role;
update profiles p set legal_name = t.legal_name, address = t.address, bank_holder = t.bank_holder, bank_name = t.bank_name, bank_ifsc = t.bank_ifsc,
  bank_account_enc = t.bank_account_enc, bank_tail = t.bank_tail, pan_enc = t.pan_enc, pan_tail = t.pan_tail, aadhaar_last4 = '4321', consent_at = now(),
  aadhaar_path = :'tina' || '/a.jpg', pan_path = :'tina' || '/p.jpg'
  from profiles t where t.id = :'tara' and p.id = :'tina';
select as_user(:'manoj'); set role authenticated;
select send_agreement(:'lex_crew', repeat('Built-in agreement text. ', 12));
reset role;
select ok((select ag_template from crew where id = :'lex_crew') = :'tpl', 'the list’s template is used even when the app sends its built-in text');
select as_user(:'tina'); set role authenticated;
select raise_agreement_query(:'lex_crew', '1', null, 'Can I start a week later?') as q4 \gset
reset role;
select as_user(:'fowzan'); set role authenticated;
select set_deal(:'lex_crew', '{"rate":1800}');
reset role;
select ok((select ag_status from crew where id = :'lex_crew') = 'none' and (select status from agreement_queries where id = :'q4') = 'withdrawn', 'the deal change closes the open question with the agreement');

-- going back to the built-in text, and archiving
select as_user(:'manoj'); set role authenticated;
select set_production_template(:'pid', 'crew', null);
select ok(not exists (select 1 from production_templates where production_id = :'pid'), 'the crew list uses the built-in agreement again');
select set_production_template(:'pid', 'crew', :'tpl');
reset role;
select as_user(:'leela'); set role authenticated;
select ok(archive_template(:'tpl') = 1, 'archiving a template frees the lists that used it');
select refused($$select save_template(jsonb_build_object('id', '$$ || :'tpl' || $$', 'name','x y z','kind','crew','body',repeat('Clause text. ', 30)))$$, 'archived');
reset role;
select as_user(:'manoj'); set role authenticated;
select ok(send_agreement(:'lex_crew', repeat('Built-in agreement text. ', 12)) = 2, 'with no template, the built-in text is sent as the next version');
reset role;
select ok((select ag_template is null and ag_text like 'Built-in agreement text.%' from crew where id = :'lex_crew'), 'and records no template');

-- reminders go to whoever's turn it is, once a question has waited a day
select as_user(:'tina'); set role authenticated;
select raise_agreement_query(:'lex_crew', '1', null, 'Still hoping to start a week later.') as q5 \gset
reset role;
delete from notifications;
select ok(send_agreement_reminders() = 0, 'no reminder on the first day');
update agreement_queries set at = now() - interval '2 days' where id = :'q5';
select ok(send_agreement_reminders() = 1, 'after a day, one reminder goes out');
select ok(exists (select 1 from notifications where user_id = :'leela' and title = 'Tina Gomes is waiting for an answer on clause 1'), 'to Legal, whose turn it is');
select as_user(:'leela'); set role authenticated;
select note_agreement_query(:'q5', 'Which date works?');
reset role;
update agreement_query_notes set at = now() - interval '2 days' where query_id = :'q5';
delete from notifications;
select send_agreement_reminders();
select ok(exists (select 1 from notifications where user_id = :'tina' and title like 'Your agreement: a reply is waiting%') and not exists (select 1 from notifications where user_id = :'leela'), 'once Legal replies, the reminder goes to the person instead');
select as_user(:'leela'); set role authenticated;
select refused(format('select revise_agreement(%L, repeat(''My own terms. '', 20), ''self'', ''{}'')', (select id from crew where user_id = :'leela')), 'Only an agreement waiting|Someone else changes your own');
reset role;
select ok(not has_function_privilege('anon', 'public.agreement_intact(uuid)', 'execute') and not has_function_privilege('authenticated', 'public.send_agreement_reminders()', 'execute'), 'new functions are closed to the public');
select ok(not has_function_privilege('authenticated', 'public.agreement_fields(uuid)', 'execute'), 'the filled-in fields can’t be read directly');
select ok(not has_table_privilege('authenticated', 'public.agreement_queries', 'insert'), 'questions are written only through the checked functions');
\echo ALL AGREEMENT TESTS PASSED
