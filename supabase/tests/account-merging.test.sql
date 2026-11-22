begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();
insert into auth.users(id,email,email_confirmed_at) values
 ('11111111-1111-4111-8111-111111111111','google@example.com',now()),
 ('22222222-2222-4222-8222-222222222222',null,null),
 ('33333333-3333-4333-8333-333333333333','outsider@example.com',now());
insert into public.profiles(id,username) values
 ('11111111-1111-4111-8111-111111111111','GoogleSolver'),
 ('22222222-2222-4222-8222-222222222222','WcaSolver'),
 ('33333333-3333-4333-8333-333333333333','Outsider');
insert into auth.identities(user_id,provider,identity_data) values
 ('11111111-1111-4111-8111-111111111111','google','{"sub":"g1"}'),
 ('11111111-1111-4111-8111-111111111111','email','{"sub":"e1"}'),
 ('22222222-2222-4222-8222-222222222222','custom:wca','{"sub":"42","name":"WCA Solver","custom_claims":{"wca_id":"2015TEST01"}}');
insert into auth.sessions(id,user_id) values
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111'),
 ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','22222222-2222-4222-8222-222222222222');
insert into public.admins values('11111111-1111-4111-8111-111111111111');
insert into public.submissions(id,user_id,metric,ms,status,submitted_at,review_note) values
 ('00000000-0000-4000-8000-000000000001','11111111-1111-4111-8111-111111111111','single',25000,'approved',now()-interval '2 days','Verified Google solve'),
 ('00000000-0000-4000-8000-000000000002','22222222-2222-4222-8222-222222222222','single',24000,'approved',now()-interval '1 day','Verified WCA solve'),
 ('00000000-0000-4000-8000-000000000003','11111111-1111-4111-8111-111111111111','ao5',28000,'pending',now()-interval '1 hour',''),
 ('00000000-0000-4000-8000-000000000004','22222222-2222-4222-8222-222222222222','ao5',30000,'pending',now(),''),
 ('00000000-0000-4000-8000-000000000005','22222222-2222-4222-8222-222222222222','single',18000,'rejected',now(),'Macro rejected'),
 ('00000000-0000-4000-8000-000000000006','22222222-2222-4222-8222-222222222222','ao12',32000,'investigating',now(),'Investigating layout');
insert into public.recording_objects(hash,payload,verified) values(repeat('a',64),'{"format":"fto-replay-v1","size":3,"complete":true,"solveMs":24000,"events":[],"solver":{"id":"22222222-2222-4222-8222-222222222222","username":"WcaSolver"}}',true);
insert into public.short_links(id,recording_hash,user_id,expires_at) values('test-merge-link',repeat('a',64),'22222222-2222-4222-8222-222222222222',now()+interval '7 days');
insert into public.attempts(user_id,session_id,completed_at,ms,dnf,recording_hash) values
 ('11111111-1111-4111-8111-111111111111','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',now(),25000,false,repeat('a',64)),
 ('22222222-2222-4222-8222-222222222222','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',now(),24000,false,repeat('a',64));
insert into public.short_link_daily_usage(user_id,day,bytes) values
 ('11111111-1111-4111-8111-111111111111',(now() at time zone 'UTC')::date,400000),
 ('22222222-2222-4222-8222-222222222222',(now() at time zone 'UTC')::date,300000);
create temp table merge_test(name text,value jsonb);grant all on merge_test to service_role,authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
select throws_ok($$select public.prepare_account_merge('11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222')$$,'42501',null,'Browsers cannot prepare a merge without server-verified proofs');
select throws_ok($$select * from public.account_members$$,'42501',null,'Account mappings cannot be edited/read directly');
set local role service_role;
select throws_ok($$select public.prepare_account_merge('33333333-3333-4333-8333-333333333333','11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222')$$,'P0001','Verify the account you are currently using','Current session must own the first verified account');
insert into merge_test values('preview',public.prepare_account_merge('11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222'));
select is((select value->'secondary'->>'username' from merge_test where name='preview'),'WcaSolver','Preview identifies both profiles before any ownership changes');
select throws_ok($$select public.complete_account_merge('11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111111','33333333-3333-4333-8333-333333333333',(select (value->>'ticket')::uuid from merge_test where name='preview'),'secondary')$$,'P0001','Merge verification is missing. Start again','Cannot replace the verified second account at confirmation');
reset role;
insert into public.submissions(id,user_id,metric,ms,status) values('00000000-0000-4000-8000-000000000007','22222222-2222-4222-8222-222222222222','single',26000,'pending');
set local role service_role;
select throws_ok($$select public.complete_account_merge('11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222',(select (value->>'ticket')::uuid from merge_test where name='preview'),'secondary')$$,'P0001','Account data changed. Review a new merge preview','Changed data requires a new review before any ownership changes');
reset role;
select is((select count(*)::int from public.account_members),0,'Failed merge leaves ownership unchanged');
delete from public.submissions where id='00000000-0000-4000-8000-000000000007';
set local role service_role;
insert into merge_test values('result',public.complete_account_merge('11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222',(select (value->>'ticket')::uuid from merge_test where name='preview'),'secondary'));
select is((select value->>'username' from merge_test where name='result'),'WcaSolver','User may keep the WCA profile instead of the currently signed-in Google profile');
select is(public.complete_account_merge('11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222',(select (value->>'ticket')::uuid from merge_test where name='preview'),'secondary'),(select value from merge_test where name='result'),'Retries return the original completed merge without duplicating data');
reset role;
select is((select count(*)::int from auth.users),3,'No authentication user was deleted');
select is((select count(*)::int from auth.identities),3,'All Google, WCA and password identities remain intact');
select is((select count(*)::int from public.recording_objects),1,'Recordings are not duplicated');
select is((select payload->'solver'->>'id' from public.recording_objects),'22222222-2222-4222-8222-222222222222','Historical recording payload/hash remains untouched');
select is(public.recording_solver_owner('{"solver":{"id":"11111111-1111-4111-8111-111111111111"}}'),'22222222-2222-4222-8222-222222222222'::uuid,'Old recorded solver IDs resolve to the kept profile');
select is((select count(*)::int from public.submissions where status='approved'),2,'Both verified results are preserved');
select is((select count(*)::int from public.leaderboard('single')),1,'Merged profiles occupy only one leaderboard place');
select is((select ms from public.leaderboard('single')),24000::double precision,'Best approved result is used without approving anything new');
select is((select ms from public.submissions where metric='ao5' and status='pending'),30000::double precision,'Latest pending submission wins even if slower');
select is((select status from public.submissions where id='00000000-0000-4000-8000-000000000003'),'superseded','Other pending offers are archived rather than deleted or falsely rejected');
select is((select review_note from public.submissions where status='rejected'),'Macro rejected','Rejection history is preserved');
select is((select count(*)::int from public.submissions where status='investigating'),1,'Investigation holds are preserved');
select is((select bytes from public.short_link_daily_usage),500000,'Combined daily usage cannot grant a fresh upload allowance');
select is((select count(distinct session_id)::int from public.attempts),2,'Historical attempts cannot be stitched into a new average');
select is((select expires_at from public.short_links),now()+interval '7 days','Temporary link URL/expiry is preserved');
select is(public.username_login_email('WcaSolver'),'google@example.com','Kept WCA username resolves its merged password account');
insert into auth.sessions(id,user_id) values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc','22222222-2222-4222-8222-222222222222'),('dddddddd-dddd-4ddd-8ddd-dddddddddddd','11111111-1111-4111-8111-111111111111');
set local role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
select set_config('request.jwt.claims','{"session_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}',true);
select is(public.my_profile()->>'reauth_required','true','An old Google session cannot access the merged profile');
select throws_ok($$select public.review_queue()$$,'P0001','Administrator access required','Old admin sessions cannot review after a merge');
select set_config('request.jwt.claims','{"session_id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"}',true);
select is(public.my_profile()->>'reauth_required','true','A signed-out or nonexistent session cannot use the merged profile');
select set_config('request.jwt.claims','{"session_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"}',true);
select set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
select is(public.my_profile()->>'reauth_required','true','An old WCA session is blocked too');
select set_config('request.jwt.claims','{"session_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc"}',true);
select is(public.my_profile()->>'username','WcaSolver','A fresh WCA sign-in opens the kept profile');
select is(public.my_profile()->>'admin','true','Administrator access survives choosing the other profile');
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
select set_config('request.jwt.claims','{"session_id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd"}',true);
select is(public.my_profile()->>'id','22222222-2222-4222-8222-222222222222','A fresh Google sign-in opens exactly the same profile');
select is(public.my_profile()->>'wca_verified','true','Verified WCA identity is available through either login');
select throws_ok($$select public.set_wca_id('2024ASHR02')$$,'P0001','Your connected WCA account determines your WCA ID','Merged WCA ownership cannot be replaced with a manual ID');
insert into merge_test values('new_attempt',to_jsonb(public.begin_attempt('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee')));
select set_config('request.jwt.claim.sub','33333333-3333-4333-8333-333333333333',true);
select is(public.my_profile()->>'username','Outsider','Unrelated accounts remain isolated');
reset role;
select is((select user_id from public.attempts where id=(select (value#>>'{}')::uuid from merge_test where name='new_attempt')),'22222222-2222-4222-8222-222222222222'::uuid,'New online attempts from an alias remain owned by the canonical profile');
insert into public.recording_objects(hash,payload) values(repeat('b',64),'{"archive":"expired"}'),(repeat('c',64),'{"archive":"recent"}');
insert into public.submissions(user_id,metric,ms,status,submitted_at,evidence_refs) values
 ('22222222-2222-4222-8222-222222222222','single',29000,'superseded',now()-interval '31 days',jsonb_build_array(jsonb_build_object('recording_hash',repeat('b',64)))),
 ('22222222-2222-4222-8222-222222222222','single',30000,'superseded',now(),jsonb_build_array(jsonb_build_object('recording_hash',repeat('c',64))));
select public.prune_account_merge_requests();
select is((select count(*)::int from public.submissions where status='superseded' and ms=29000),1,'Expired merge archives retain result metadata');
select is((select evidence_refs is null from public.submissions where status='superseded' and ms=29000),true,'Archived duplicate evidence expires after 30 days');
select is((select count(*)::int from public.recording_objects where hash=repeat('b',64)),0,'Expired archive payload is collected when unreferenced');
select is((select evidence_refs is not null from public.submissions where status='superseded' and ms=30000),true,'Recent archived evidence remains available');
select is((select count(*)::int from public.recording_objects where hash=repeat('a',64)),1,'Cleanup preserves recordings still referenced by temporary links');
select * from finish();rollback;
