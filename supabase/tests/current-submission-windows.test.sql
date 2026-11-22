begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();
insert into auth.users(id,email,email_confirmed_at) values('11111111-1111-4111-8111-111111111111','current-window@example.invalid',now());
insert into public.profiles(id,username) values('11111111-1111-4111-8111-111111111111','CurrentWindow');
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
create temp sequence receipt;
create function pg_temp.record_result(value double precision,bad boolean default false,session uuid default 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') returns jsonb
language plpgsql as $$
declare ticket uuid; serial bigint:=nextval('pg_temp.receipt');
begin
 ticket:=public.begin_attempt(session);
 -- Give every attempt a distinct, ordered start even on the WASM test clock.
 update public.attempts set started_at=now()-interval '1 minute'+serial*interval '1 millisecond' where id=ticket;
 return public.record_online_attempt(ticket,jsonb_build_object('format','fto-replay-v1','size',3,'complete',true,'solveMs',value,'usedUndo',bad,'completedAt',now()+serial*interval '1 millisecond','events','[]'::jsonb));
end; $$;
select pg_temp.record_result(288) from generate_series(1,5);
select public.submit_leaderboard((select (entry->>'id')::uuid from jsonb_array_elements(public.my_leaderboard_candidates()) entry where entry->>'metric'='ao5'));
select pg_temp.record_result(316) from generate_series(1,5);
create temp table old_offer as select * from public.submissions where metric='ao5' and status='draft';
select is((select ms from old_offer),316::double precision,'Current slower average is offered despite the faster pending result');
select pg_temp.record_result(180,true) from generate_series(1,2);
select is((select count(*)::int from jsonb_array_elements(public.my_leaderboard_candidates()) entry where entry->>'metric'='ao5'),0,'Two leaderboard DNFs hide the old average immediately');
select is((select entry->>'ineligible_reason' from jsonb_array_elements(public.my_leaderboard_results()->'ineligible') entry where entry->>'metric'='ao5'),'leaderboard_dnfs','Current average explains why the leaderboard window is invalid');
select is((select count(*)::int from public.submissions where status='draft' and metric='ao5'),0,'Invalid windows remove old private drafts');
-- Simulate a pre-update stale draft surviving on an old client. The submit RPC
-- must reject it independently of whether the UI displays it.
insert into public.submissions(id,user_id,metric,ms,status,evidence_refs) select id,user_id,metric,ms,'draft',evidence_refs from old_offer;
select throws_ok($$select public.submit_leaderboard((select id from old_offer))$$,'P0001','This result is no longer the current window','A cached old draft cannot be submitted through the RPC');
select pg_temp.record_result(180,true) from generate_series(1,4);
select is((select count(*)::int from jsonb_array_elements(public.my_leaderboard_candidates()) entry where entry->>'metric'='ao5'),0,'Six solves later an invalid window still never falls back to the old average');
select is((select ms from public.submissions where metric='ao5' and status='pending'),288::double precision,'An invalid current window leaves the existing pending result intact');
select pg_temp.record_result(298) from generate_series(1,4);
select is((select (entry->>'ms')::double precision from jsonb_array_elements(public.my_leaderboard_candidates()) entry where entry->>'metric'='ao5'),298::double precision,'The new eligible window offers its own time rather than the old 316 result');
select is((select (entry->>'pending_ms')::double precision from jsonb_array_elements(public.my_leaderboard_candidates()) entry where entry->>'metric'='ao5'),288::double precision,'A deliberately slower replacement still compares with the pending result');
select public.submit_leaderboard((select (entry->>'id')::uuid from jsonb_array_elements(public.my_leaderboard_candidates()) entry where entry->>'metric'='ao5'));
select is((select ms from public.submissions where metric='ao5' and status='pending'),298::double precision,'Explicit consent replaces the faster pending average with the current slower average');
select is((select count(*)::int from public.submissions where metric='ao5' and status='pending'),1,'Replacing an average keeps only one pending submission');
select pg_temp.record_result(500,false,'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb') from generate_series(1,12);
select is((select (entry->>'ms')::double precision from jsonb_array_elements(public.my_leaderboard_candidates()) entry where entry->>'metric'='ao12'),500::double precision,'A complete current ao12 is offered');
select pg_temp.record_result(180,true,'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb') from generate_series(1,6);
select is((select count(*)::int from jsonb_array_elements(public.my_leaderboard_candidates()) entry where entry->>'metric'='ao12'),0,'An invalid current ao12 cannot offer an older ao12 either');
select is((select entry->>'ineligible_reason' from jsonb_array_elements(public.my_leaderboard_results()->'ineligible') entry where entry->>'metric'='ao12'),'leaderboard_dnfs','The ao12 explanation survives a fresh results query');
select pg_temp.record_result(200,false,'cccccccc-cccc-4ccc-8ccc-cccccccccccc');
select is((select entry->>'ineligible_reason' from jsonb_array_elements(public.my_leaderboard_results()->'ineligible') entry where entry->>'metric'='ao5'),'insufficient_online_solves','A broken online sequence explains the missing consecutive attempts');
select pg_temp.record_result(200,false,'cccccccc-cccc-4ccc-8ccc-cccccccccccc') from generate_series(1,4);
update public.recording_objects set verified=false where hash=(select recording_hash from public.attempts order by started_at desc limit 1);
select is((select entry->>'ineligible_reason' from jsonb_array_elements(public.my_leaderboard_results()->'ineligible') entry where entry->>'metric'='ao5'),'missing_recordings','Missing or invalid evidence explains the current window instead of showing old evidence');
select is((select count(*)::int from public.attempts),12,'Current-window tracking keeps bounded attempt retention');
select set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
select is(public.my_leaderboard_results(),'{"candidates":[],"ineligible":[]}'::jsonb,'Another account cannot read the current-window results');
set local role anon;
select throws_ok($$select public.my_leaderboard_results()$$,'42501',null,'Anonymous callers cannot read private current windows');
reset role;
select * from finish();
rollback;
