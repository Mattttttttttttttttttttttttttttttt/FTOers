-- Inspection skips belong to online average windows without creating a local time.
alter table public.attempts drop constraint attempts_invalid_reason_check;
alter table public.attempts add constraint attempts_invalid_reason_check check(invalid_reason in ('undo','abandoned','skipped'));
create or replace function public.record_online_attempt(attempt uuid, replay jsonb default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.attempts; bad boolean:=true; value double precision; n integer; sample jsonb; candidate uuid; results jsonb:='[]'; window_count integer; invalid_pb boolean:=false;
begin
 perform 1 from public.profiles where id=auth.uid() for update;
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 select * into a from public.attempts where id=attempt and user_id=auth.uid() for update;
 if a.id is null or a.completed_at is not null then raise exception 'Attempt missing or already submitted'; end if;
 if a.started_at<now()-interval '1 day' then raise exception 'Attempt expired'; end if;
 if replay is not null then
  perform public.check_recording_quota(0);
  if octet_length(replay::text)>2000000 or (replay->>'format') is distinct from 'fto-replay-v1' or (replay->>'size') is distinct from '3' or (replay->>'complete') is distinct from 'true' or jsonb_typeof(replay->'events') is distinct from 'array' or jsonb_array_length(replay->'events')>20000 then raise exception 'Invalid 3×3 recording (2 MB limit)'; end if;
  value:=(replay->>'solveMs')::double precision;
  if value is null or value<=0 or value>=86400000 or value>extract(epoch from (clock_timestamp()-a.started_at))*1000+2000 then raise exception 'Invalid solve time'; end if;
  bad:=coalesce((replay->>'dnf')::boolean,false) or coalesce((replay->>'usedUndo')::boolean,false) or exists(select 1 from jsonb_array_elements(replay->'events') e where (e->>'type'='accept' and e->>'action'='undo') or (e->>'type'='sound' and e->>'kind'='undo'));
  replay:=jsonb_set(replay,'{solver}',(select jsonb_build_object('id',id,'username',username) from public.profiles where id=auth.uid()));
 end if;
 invalid_pb:=bad and not coalesce((replay->>'dnf')::boolean,false) and value is not null and not exists(select 1 from public.submissions where user_id=a.user_id and metric='single' and status='approved' and ms<=value);
 update public.attempts set completed_at=clock_timestamp(),ms=value,dnf=bad,invalid_reason=case when not bad then null when replay is null or coalesce((replay->>'dnf')::boolean,false) then coalesce(a.invalid_reason,'abandoned') else 'undo' end,recording_hash=case when bad then null else public.store_recording(replay,true) end where id=a.id;
 for n in select unnest(array[1,5,12]) loop
  select count(*) into window_count from (select id from public.attempts where user_id=a.user_id and session_id=a.session_id and started_at<=a.started_at order by started_at desc limit n) w;
  if window_count<n then continue; end if;
  -- Keep every attempt in the window; undo, abandonment and unfinished attempts are DNFs.
  with recent as (select * from public.attempts where user_id=a.user_id and session_id=a.session_id and started_at<=a.started_at order by started_at desc limit n), ranked as (select *,row_number() over(order by dnf,ms nulls last,started_at) rank from recent)
  select case when bool_or(dnf) then null else avg(ms) end into value from ranked where n=1 or rank between 2 and n-1;
  if value is null then continue; end if;
  if exists(select 1 from public.submissions where user_id=a.user_id and metric=case when n=1 then 'single' else 'ao'||n end and status='approved' and ms<=value) then continue; end if;
  select jsonb_agg(jsonb_build_object('ms',ms,'dnf',dnf,'reason',invalid_reason,'recording_hash',recording_hash) order by started_at) into sample from (select * from public.attempts where user_id=a.user_id and session_id=a.session_id and started_at<=a.started_at order by started_at desc limit n) w;
  if not public.leaderboard_evidence_available(sample,case when n=1 then 'single' else 'ao'||n end) then continue; end if;
  -- Keep just the latest private draft for each metric; the review queue is untouched.
  delete from public.submissions where user_id=a.user_id and metric=case when n=1 then 'single' else 'ao'||n end and status='draft';
  insert into public.submissions(user_id,metric,ms,status,evidence_refs) values(a.user_id,case when n=1 then 'single' else 'ao'||n end,value,'draft',sample) returning id into candidate;
  results:=results||jsonb_build_array(jsonb_build_object('id',candidate,'metric',case when n=1 then 'single' else 'ao'||n end,'ms',value));
 end loop;
 delete from public.attempts where user_id=a.user_id and id not in (select id from public.attempts where user_id=a.user_id order by started_at desc limit 12);
 perform public.collect_recordings();
 perform public.check_recording_quota(0);
 return jsonb_build_object('dnf',bad,'invalid_pb',invalid_pb,'candidates',public.my_leaderboard_candidates(),'submitted','[]'::jsonb);
end; $$;


create function public.skip_online_scramble(session uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare attempt uuid;
begin
 attempt:=public.begin_attempt(session);
 update public.attempts set invalid_reason='skipped' where id=attempt;
 return public.record_online_attempt(attempt,null);
end; $$;
revoke all on function public.skip_online_scramble(uuid) from public,anon,authenticated;
grant execute on function public.skip_online_scramble(uuid) to authenticated;
