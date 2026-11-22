begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();
insert into auth.users(id,email,email_confirmed_at) values
 ('11111111-1111-4111-8111-111111111111','solver@example.test',now()),
 ('22222222-2222-4222-8222-222222222222','other@example.test',now()),
 ('33333333-3333-4333-8333-333333333333','alias@example.test',now());
insert into public.profiles(id,username) values
 ('11111111-1111-4111-8111-111111111111','SolverOld'),
 ('22222222-2222-4222-8222-222222222222','TakenName'),
 ('33333333-3333-4333-8333-333333333333','LegacyName');
insert into public.account_members(auth_user_id,profile_id) values
 ('11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111111'),
 ('33333333-3333-4333-8333-333333333333','11111111-1111-4111-8111-111111111111');
insert into auth.sessions(id,user_id) values('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','33333333-3333-4333-8333-333333333333');
insert into public.submissions(user_id,metric,ms,status) values('11111111-1111-4111-8111-111111111111','single',25000,'approved');
set local role anon;
select throws_ok($$select public.rename_username('Intruder')$$,'42501',null,'Anonymous users cannot rename profiles');
set local role authenticated;
select set_config('request.jwt.claim.sub','33333333-3333-4333-8333-333333333333',true);
select set_config('request.jwt.claims','{"session_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}',true);
select is(public.rename_username('  NewName  ')->>'username','NewName','Renaming trims whitespace and updates the canonical profile from an alias login');
select is(public.my_profile()->>'id','11111111-1111-4111-8111-111111111111','Renaming preserves account identity');
select is(public.rename_username('newName')->>'username','newName','Case-only changes are supported');
select is(public.rename_username('ThirdName')->>'username','ThirdName','Users can change names again without a cooldown');
select throws_ok($$select public.rename_username('takenname')$$,'P0001','Username already taken','Uniqueness is case-insensitive and enforced by the database');
select is(public.my_profile()->>'username','ThirdName','Failed duplicate change leaves the previous name intact');
select throws_ok($$select public.rename_username('!invalid!')$$,'P0001','Use 3–24 letters, numbers or underscores','Invalid characters are rejected');
select throws_ok($$select public.rename_username(null)$$,'P0001','Use 3–24 letters, numbers or underscores','Empty/missing names are rejected');
select is((select username from public.leaderboard('single')),'ThirdName','Leaderboard displays the new name while retaining its result');
reset role;
select is((select username from public.profiles where id='33333333-3333-4333-8333-333333333333'),'LegacyName','Retired alias names remain reserved for legacy sign-in');
select is((select count(*)::int from public.submissions),1,'Renaming does not copy or discard results');
select * from finish();rollback;
