-- Test accounts for central_test.sql (the sign-up trigger creates their profiles).
insert into auth.users (id, email, raw_user_meta_data) values
 ('11111111-1111-1111-1111-111111111111','fowzan@swastikstories.com','{"username":"fowzan","full_name":"Fowzan"}'),
 ('22222222-2222-2222-2222-222222222222','ritika@test.in','{"username":"ritika","full_name":"Ritika Menon"}'),
 ('33333333-3333-3333-3333-333333333333','manoj@test.in','{"username":"manoj","full_name":"Manoj Patil"}'),
 ('44444444-4444-4444-4444-444444444444','neha@test.in','{"username":"neha","full_name":"Neha Kulkarni"}'),
 ('55555555-5555-5555-5555-555555555555','asha@test.in','{"username":"asha","full_name":"Asha D"}'),
 ('77777777-7777-7777-7777-777777777777','stranger@test.in','{"username":"stranger","full_name":"Some Stranger"}');
