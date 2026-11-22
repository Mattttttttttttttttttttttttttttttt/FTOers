-- Offers describe the latest completed online window, never an older eligible window.
-- Keep the legacy candidates RPC eligible-only for older clients.
create function public.my_leaderboard_results() returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare
  owner uuid := auth.uid();
  latest public.attempts;
  draft public.submissions;
  n integer;
  metric_name text;
  sample jsonb;
  window_count integer;
  current_value double precision;
  board_value double precision;
  pending_value double precision;
  reason text;
  candidates jsonb := '[]';
  ineligible jsonb := '[]';
begin
  select * into latest from public.attempts
    where user_id=owner and completed_at is not null
    order by completed_at desc,started_at desc,id desc limit 1;
  if not found then
    return jsonb_build_object('candidates',candidates,'ineligible',ineligible);
  end if;
  foreach n in array array[1,5,12] loop
    metric_name := case n when 1 then 'single' else 'ao'||n end;
    reason := null;
    current_value := null;
    select count(*),jsonb_agg(jsonb_build_object(
      'ms',ms,'dnf',dnf,'reason',invalid_reason,'recording_hash',recording_hash
    ) order by started_at,id) into window_count,sample
    from (
      select * from public.attempts
      where user_id=owner and session_id=latest.session_id
        and (started_at,id)<=(latest.started_at,latest.id)
      order by started_at desc,id desc limit n
    ) recent;
    select min(ms) into board_value from public.submissions
      where user_id=owner and metric=metric_name and status='approved';
    select ms into pending_value from public.submissions
      where user_id=owner and metric=metric_name and status='pending' limit 1;
    if window_count<n then
      reason := 'insufficient_online_solves';
    else
      with ranked as (
        select (entry->>'ms')::double precision ms,
          coalesce((entry->>'dnf')::boolean,true) dnf,
          row_number() over(order by (entry->>'dnf')::boolean,
            (entry->>'ms')::double precision nulls last,ordinality) rank
        from jsonb_array_elements(sample) with ordinality e(entry,ordinality)
      )
      select case when bool_or(dnf) then null else avg(ms) end into current_value
        from ranked where n=1 or rank between 2 and n-1;
      if current_value is null then
        reason := case when n=1 then coalesce(latest.invalid_reason,'dnf') else 'leaderboard_dnfs' end;
      elsif board_value is not null and board_value<=current_value then
        continue;
      elsif not public.leaderboard_evidence_available(sample,metric_name) then
        reason := 'missing_recordings';
      else
        select * into draft from public.submissions
          where user_id=owner and metric=metric_name and status='draft'
            and evidence_refs=sample and created_at>now()-interval '30 days'
            and abs(ms-current_value)<=0.000001
          order by created_at desc,id desc limit 1;
        if found then
          candidates := candidates||jsonb_build_array(jsonb_build_object(
            'id',draft.id,'metric',metric_name,'ms',draft.ms,'created_at',draft.created_at,
            'evidence_complete',true,'leaderboard_ms',board_value,'pending_ms',pending_value
          ));
          continue;
        end if;
        -- A submitted/reviewed current window is no longer a new offer.
        if exists(select 1 from public.submissions where user_id=owner
          and metric=metric_name and status<>'draft' and evidence_refs=sample) then
          continue;
        end if;
        reason := 'result_unavailable';
      end if;
    end if;
    ineligible := ineligible||jsonb_build_array(jsonb_build_object(
      'metric',metric_name,'ms',case when n=1 then latest.ms else current_value end,
      'ineligible_reason',reason,'window_count',window_count,'required_count',n,
      'leaderboard_ms',board_value,'pending_ms',pending_value
    ));
  end loop;
  return jsonb_build_object('candidates',candidates,'ineligible',ineligible);
end; $$;
revoke all on function public.my_leaderboard_results() from public,anon,authenticated;
grant execute on function public.my_leaderboard_results() to authenticated;
create or replace function public.my_leaderboard_candidates() returns jsonb
language sql volatile security definer set search_path='' as $$
  select public.my_leaderboard_results()->'candidates';
$$;

create or replace function public.record_online_attempt(attempt uuid, replay jsonb default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.attempts; bad boolean:=true; value double precision; n integer; sample jsonb; current_results jsonb; window_count integer; invalid_pb boolean:=false; paused boolean:=false; incoming_hash text:=encode(extensions.digest(coalesce(replay,'null'::jsonb)::text,'sha256'),'hex');
begin
 perform 1 from public.profiles where id=auth.uid() for update;
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 select * into a from public.attempts where id=attempt and user_id=auth.uid() for update;
 if a.id is null then raise exception 'Attempt missing or already submitted'; end if;
 if a.completed_at is not null then
  if a.finish_fingerprint is distinct from incoming_hash then raise exception 'Attempt missing or already submitted'; end if;
  current_results:=public.my_leaderboard_results();
  return jsonb_build_object('dnf',a.dnf,'invalid_pb',a.invalid_reason in ('undo','pause'),'invalid_reason',a.invalid_reason,'candidates',current_results->'candidates','ineligible',current_results->'ineligible','submitted','[]'::jsonb);
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
 -- Discard every old unsubmitted offer even when the new window is invalid.
 delete from public.submissions where user_id=a.user_id and status='draft';
 for n in select unnest(array[1,5,12]) loop
  select count(*) into window_count from (select id from public.attempts where user_id=a.user_id and session_id=a.session_id and (started_at,id)<=(a.started_at,a.id) order by started_at desc,id desc limit n) w;
  if window_count<n then continue; end if;
  -- Keep every attempt in the window; undo, abandonment and unfinished attempts are DNFs.
  with recent as (select * from public.attempts where user_id=a.user_id and session_id=a.session_id and (started_at,id)<=(a.started_at,a.id) order by started_at desc,id desc limit n), ranked as (select *,row_number() over(order by dnf,ms nulls last,started_at,id) rank from recent)
  select case when bool_or(dnf) then null else avg(ms) end into value from ranked where n=1 or rank between 2 and n-1;
  if value is null then continue; end if;
  if exists(select 1 from public.submissions where user_id=a.user_id and metric=case when n=1 then 'single' else 'ao'||n end and status='approved' and ms<=value) then continue; end if;
  select jsonb_agg(jsonb_build_object('ms',ms,'dnf',dnf,'reason',invalid_reason,'recording_hash',recording_hash) order by started_at,id) into sample from (select * from public.attempts where user_id=a.user_id and session_id=a.session_id and (started_at,id)<=(a.started_at,a.id) order by started_at desc,id desc limit n) w;
  if not public.leaderboard_evidence_available(sample,case when n=1 then 'single' else 'ao'||n end) then continue; end if;
  -- Old drafts were cleared above; pending/held submissions remain untouched.
  insert into public.submissions(user_id,metric,ms,status,evidence_refs) values(a.user_id,case when n=1 then 'single' else 'ao'||n end,value,'draft',sample);
 end loop;
 delete from public.attempts where user_id=a.user_id and id not in (select id from public.attempts where user_id=a.user_id order by started_at desc,id desc limit 12);
 perform public.collect_recordings();
 perform public.check_recording_quota(0);
 current_results:=public.my_leaderboard_results();
 return jsonb_build_object('dnf',bad,'invalid_pb',invalid_pb,'invalid_reason',case when paused then 'pause' else null end,'candidates',current_results->'candidates','ineligible',current_results->'ineligible','submitted','[]'::jsonb);
end; $$;

-- Recheck freshness under the same owner lock before replacing a pending submission.
create or replace function public.submit_leaderboard(submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare candidate public.submissions;
begin
 if auth.uid() is null then raise exception 'Sign in to submit a leaderboard result'; end if;
 perform 1 from public.profiles where id=auth.uid() for update;
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 select * into candidate from public.submissions where id=submission and user_id=auth.uid() for update;
 if candidate.id is null then raise exception 'This PB has been replaced or is unavailable'; end if;
 if candidate.status in ('pending','investigating','approved') then return jsonb_build_object('id',candidate.id,'status',candidate.status); end if;
 if candidate.status<>'draft' then raise exception 'This result cannot be resubmitted'; end if;
 if candidate.evidence_refs is null or candidate.created_at<=now()-interval '30 days' then raise exception 'This PB recording has expired'; end if;
 if not public.leaderboard_evidence_available(candidate.evidence_refs,candidate.metric) then raise exception 'One or more recordings are missing. This result cannot be submitted'; end if;
 if exists(select 1 from public.submissions where user_id=auth.uid() and metric=candidate.metric and status='approved' and ms<=candidate.ms) then raise exception 'Your leaderboard result is already equal or faster'; end if;
 if not exists(select 1 from jsonb_array_elements(public.my_leaderboard_candidates()) row where row->>'id'=candidate.id::text) then raise exception 'This result is no longer the current window'; end if;
 delete from public.submissions where user_id=auth.uid() and metric=candidate.metric and status='pending';
 update public.submissions set status='pending',submitted_at=clock_timestamp() where id=candidate.id;
 return jsonb_build_object('id',candidate.id,'status','pending');
end; $$;
