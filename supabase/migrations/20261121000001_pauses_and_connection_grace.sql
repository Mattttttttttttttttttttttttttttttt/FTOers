-- Pause markers survive pause-free playback. Receipts make retrying a lost
-- start/finish response idempotent without storing another recording payload.
alter table public.attempts drop constraint attempts_invalid_reason_check;
alter table public.attempts add constraint attempts_invalid_reason_check check(invalid_reason in ('undo','abandoned','skipped','pause'));
alter table public.attempts add column finish_fingerprint text;
-- The existing one-argument begin_attempt remains compatible with older clients.
create function public.begin_attempt(session uuid,request_id uuid,start_delay_ms double precision) returns uuid language plpgsql security definer set search_path='' as $$
declare existing public.attempts;
begin
 if not exists(select 1 from public.profiles where id=auth.uid()) then raise exception 'Choose a username first'; end if;
 if request_id is null or start_delay_ms is null or start_delay_ms<0 or start_delay_ms>5000 then raise exception 'Invalid attempt request'; end if;
 perform 1 from public.profiles where id=auth.uid() for update;
 select * into existing from public.attempts where id=request_id;
 if found then
  if existing.user_id<>auth.uid() or existing.session_id<>session then raise exception 'Invalid attempt request'; end if;
  return existing.id;
 end if;
 if (select count(*) from public.attempts where user_id=auth.uid() and started_at>now()-interval '1 minute')>=30 then raise exception 'Too many attempts'; end if;
 update public.attempts set completed_at=clock_timestamp(),dnf=true where user_id=auth.uid() and session_id=session and completed_at is null;
 insert into public.attempts(id,user_id,session_id,started_at) values(request_id,auth.uid(),session,clock_timestamp()-start_delay_ms*interval '1 millisecond');
 return request_id;
end; $$;
revoke all on function public.begin_attempt(uuid,uuid,double precision) from public,anon,authenticated;
grant execute on function public.begin_attempt(uuid,uuid,double precision) to authenticated;
create or replace function public.leaderboard_evidence_available(refs jsonb,kind text) returns boolean language plpgsql stable security definer set search_path='' as $$
declare entry jsonb; object public.recording_objects; expected integer; duration double precision; dnfs integer:=0;
begin
 expected:=case kind when 'single' then 1 when 'ao5' then 5 when 'ao12' then 12 else 0 end;
 if expected=0 or refs is null or jsonb_typeof(refs)<>'array' or jsonb_array_length(refs)<>expected then return false; end if;
 for entry in select * from jsonb_array_elements(refs) loop
  if coalesce((entry->>'dnf')::boolean,false) then dnfs:=dnfs+1;if expected=1 or dnfs>1 then return false; end if;continue; end if;
  duration:=(entry->>'ms')::double precision;
  if duration is null or duration<=0 or duration>=86400000 then return false; end if;
  select * into object from public.recording_objects where hash=entry->>'recording_hash';
  if not found or not object.verified or (object.payload->>'format') is distinct from 'fto-replay-v1' or (object.payload->>'size') is distinct from '3' or (object.payload->>'complete') is distinct from 'true' or jsonb_typeof(object.payload->'events') is distinct from 'array' or (object.payload->>'solveMs')::double precision is distinct from duration or coalesce((object.payload->>'dnf')::boolean,false) or coalesce((object.payload->>'usedUndo')::boolean,false) or coalesce((object.payload->>'usedPause')::boolean,false) or exists(select 1 from jsonb_array_elements(object.payload->'events') e where e->>'type'='pause') then return false; end if;
 end loop;
 return true;
exception when invalid_text_representation or numeric_value_out_of_range then return false;
end; $$;
revoke all on function public.leaderboard_evidence_available(jsonb,text) from public,anon,authenticated;
create or replace function public.record_online_attempt(attempt uuid, replay jsonb default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.attempts; bad boolean:=true; value double precision; n integer; sample jsonb; candidate uuid; results jsonb:='[]'; window_count integer; invalid_pb boolean:=false; paused boolean:=false; incoming_hash text:=encode(extensions.digest(coalesce(replay,'null'::jsonb)::text,'sha256'),'hex');
begin
 perform 1 from public.profiles where id=auth.uid() for update;
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 select * into a from public.attempts where id=attempt and user_id=auth.uid() for update;
 if a.id is null then raise exception 'Attempt missing or already submitted'; end if;
 if a.completed_at is not null then
  if a.finish_fingerprint is distinct from incoming_hash then raise exception 'Attempt missing or already submitted'; end if;
  return jsonb_build_object('dnf',a.dnf,'invalid_pb',a.invalid_reason in ('undo','pause'),'invalid_reason',a.invalid_reason,'candidates',public.my_leaderboard_candidates(),'submitted','[]'::jsonb);
 end if;
 if a.started_at<now()-interval '1 day' then raise exception 'Attempt expired'; end if;
 if replay is not null then
  perform public.check_recording_quota(0);
  if octet_length(replay::text)>2000000 or (replay->>'format') is distinct from 'fto-replay-v1' or (replay->>'size') is distinct from '3' or (replay->>'complete') is distinct from 'true' or jsonb_typeof(replay->'events') is distinct from 'array' or jsonb_array_length(replay->'events')>20000 then raise exception 'Invalid 3×3 recording (2 MB limit)'; end if;
  value:=(replay->>'solveMs')::double precision;
  if value is null or value<=0 or value>=86400000 or value>extract(epoch from (clock_timestamp()-a.started_at))*1000+2000 then raise exception 'Invalid solve time'; end if;
  paused:=coalesce((replay->>'usedPause')::boolean,false) or exists(select 1 from jsonb_array_elements(replay->'events') e where e->>'type'='pause');
  bad:=paused or coalesce((replay->>'dnf')::boolean,false) or coalesce((replay->>'usedUndo')::boolean,false) or exists(select 1 from jsonb_array_elements(replay->'events') e where (e->>'type'='accept' and e->>'action'='undo') or (e->>'type'='sound' and e->>'kind'='undo'));
  replay:=jsonb_set(replay,'{solver}',(select jsonb_build_object('id',id,'username',username) from public.profiles where id=auth.uid()));
 end if;
 invalid_pb:=bad and not coalesce((replay->>'dnf')::boolean,false) and value is not null and not exists(select 1 from public.submissions where user_id=a.user_id and metric='single' and status='approved' and ms<=value);
 update public.attempts set completed_at=clock_timestamp(),ms=value,dnf=bad,finish_fingerprint=incoming_hash,invalid_reason=case when not bad then null when paused then 'pause' when replay is null or coalesce((replay->>'dnf')::boolean,false) then coalesce(a.invalid_reason,'abandoned') else 'undo' end,recording_hash=case when bad then null else public.store_recording(replay,true) end where id=a.id;
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
 return jsonb_build_object('dnf',bad,'invalid_pb',invalid_pb,'invalid_reason',case when paused then 'pause' else null end,'candidates',public.my_leaderboard_candidates(),'submitted','[]'::jsonb);
end; $$;



-- Retrying a skipped inspection also uses the same bounded attempt receipt.
create function public.skip_online_scramble(session uuid,request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare attempt uuid;
begin
 attempt:=public.begin_attempt(session,request_id,0);
 update public.attempts set invalid_reason='skipped' where id=attempt and completed_at is null;
 return public.record_online_attempt(attempt,null);
end; $$;
revoke all on function public.skip_online_scramble(uuid,uuid) from public,anon,authenticated;
grant execute on function public.skip_online_scramble(uuid,uuid) to authenticated;
