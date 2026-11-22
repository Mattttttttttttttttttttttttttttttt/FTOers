-- Recording an online attempt never submits it for administrator review.
-- Drafts are private PB candidates; only an explicit owner RPC makes one pending.
alter table public.submissions drop constraint submissions_status_check;
alter table public.submissions add constraint submissions_status_check check(status in ('draft','pending','approved','rejected'));
alter table public.submissions alter column status set default 'draft';
alter table public.submissions add column submitted_at timestamptz;
update public.submissions set submitted_at=created_at where status in ('approved','rejected');
-- Older pending rows were created automatically; restore owner consent.
update public.submissions set status='draft',submitted_at=null where status='pending';
alter table public.attempts add column invalid_reason text check(invalid_reason in ('undo','abandoned'));
create index submissions_online_bests on public.submissions(user_id,metric,ms) where status in ('draft','pending','approved');
create index submissions_review_pending on public.submissions(submitted_at,created_at,id) where status='pending';
-- Every non-DNF member needs trusted recording evidence, including trimmed
-- members. Old timer-only entries must never become submit-ready averages.
create function public.leaderboard_evidence_available(refs jsonb,kind text) returns boolean language plpgsql stable security definer set search_path='' as $$
declare entry jsonb; object public.recording_objects; expected integer; duration double precision; dnfs integer:=0;
begin
 expected:=case kind when 'single' then 1 when 'ao5' then 5 when 'ao12' then 12 else 0 end;
 if expected=0 or refs is null or jsonb_typeof(refs)<>'array' or jsonb_array_length(refs)<>expected then return false; end if;
 for entry in select * from jsonb_array_elements(refs) loop
  if coalesce((entry->>'dnf')::boolean,false) then dnfs:=dnfs+1;if expected=1 or dnfs>1 then return false; end if;continue; end if;
  duration:=(entry->>'ms')::double precision;
  if duration is null or duration<=0 or duration>=86400000 then return false; end if;
  select * into object from public.recording_objects where hash=entry->>'recording_hash';
  if not found or not object.verified or (object.payload->>'format') is distinct from 'fto-replay-v1' or (object.payload->>'size') is distinct from '3' or (object.payload->>'complete') is distinct from 'true' or jsonb_typeof(object.payload->'events') is distinct from 'array' or (object.payload->>'solveMs')::double precision is distinct from duration or coalesce((object.payload->>'dnf')::boolean,false) or coalesce((object.payload->>'usedUndo')::boolean,false) then return false; end if;
 end loop;
 return true;
exception when invalid_text_representation or numeric_value_out_of_range then return false;
end; $$;
revoke all on function public.leaderboard_evidence_available(jsonb,text) from public,anon,authenticated;
create function public.record_online_attempt(attempt uuid, replay jsonb default null) returns jsonb language plpgsql security definer set search_path='' as $$
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
 update public.attempts set completed_at=clock_timestamp(),ms=value,dnf=bad,invalid_reason=case when not bad then null when replay is null or coalesce((replay->>'dnf')::boolean,false) then 'abandoned' else 'undo' end,recording_hash=case when bad then null else public.store_recording(replay,true) end where id=a.id;
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

-- Older clients also stop auto-submitting after this migration. New clients use
-- the new RPC name, so they cannot accidentally auto-submit on the old backend.
create or replace function public.finish_attempt(attempt uuid,replay jsonb default null) returns jsonb language sql security definer set search_path='' as $$
 select public.record_online_attempt(attempt,replay);
$$;
create function public.my_leaderboard_candidates() returns jsonb language sql volatile security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'metric',s.metric,'ms',s.ms,'created_at',s.created_at,'evidence_complete',true,
 'leaderboard_ms',(select min(ms) from public.submissions where user_id=s.user_id and metric=s.metric and status='approved'),
 'pending_ms',(select ms from public.submissions where user_id=s.user_id and metric=s.metric and status='pending' limit 1)) order by s.metric),'[]')
 from public.submissions s where user_id=auth.uid() and status='draft' and evidence_refs is not null and created_at>now()-interval '30 days'
 and public.leaderboard_evidence_available(s.evidence_refs,s.metric)
 and not exists(select 1 from public.submissions approved where approved.user_id=s.user_id and approved.metric=s.metric and approved.status='approved' and approved.ms<=s.ms);
$$;
create function public.submit_leaderboard(submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare candidate public.submissions;
begin
 if auth.uid() is null then raise exception 'Sign in to submit a leaderboard result'; end if;
 perform 1 from public.profiles where id=auth.uid() for update;
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 select * into candidate from public.submissions where id=submission and user_id=auth.uid() for update;
 if candidate.id is null then raise exception 'This PB has been replaced or is unavailable'; end if;
 if candidate.status in ('pending','approved') then return jsonb_build_object('id',candidate.id,'status',candidate.status); end if;
 if candidate.status<>'draft' then raise exception 'This result cannot be resubmitted'; end if;
 if candidate.evidence_refs is null or candidate.created_at<=now()-interval '30 days' then raise exception 'This PB recording has expired'; end if;
 if not public.leaderboard_evidence_available(candidate.evidence_refs,candidate.metric) then raise exception 'One or more recordings are missing. This result cannot be submitted'; end if;
 if exists(select 1 from public.submissions where user_id=auth.uid() and metric=candidate.metric and status='approved' and ms<=candidate.ms) then raise exception 'Your leaderboard result is already equal or faster'; end if;
 delete from public.submissions where user_id=auth.uid() and metric=candidate.metric and status='pending';
 update public.submissions set status='pending',submitted_at=clock_timestamp() where id=candidate.id;
 return jsonb_build_object('id',candidate.id,'status','pending');
end; $$;
create or replace function public.review_queue() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not public.is_admin() then raise exception 'Administrator access required'; end if;
 return coalesce((select jsonb_agg(row_to_json(q)) from (
 select s.id,p.username,s.metric,s.ms,s.created_at,s.submitted_at from public.submissions s join public.profiles p on p.id=s.user_id where status='pending' order by s.submitted_at,s.created_at,s.id limit 100) q),'[]');
end; $$;
create or replace function public.prune_recordings() returns void language plpgsql security definer set search_path='' as $$
begin
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 delete from public.short_links where expires_at<=now();
 delete from public.attempts where started_at<now()-interval '2 days';
 -- Keep bounded draft metadata, but free expired recordings. An existing
 -- newer draft takes precedence over a pending result that expires.
 delete from public.submissions expired where status='pending' and coalesce(submitted_at,created_at)<now()-interval '30 days' and exists(select 1 from public.submissions draft where draft.user_id=expired.user_id and draft.metric=expired.metric and draft.status='draft');
 update public.submissions set status='draft',evidence_refs=null where status='pending' and coalesce(submitted_at,created_at)<now()-interval '30 days';
 delete from public.submissions s using (select id,row_number() over(partition by user_id,metric order by created_at desc,id) as rank from public.submissions where status='draft') ranked where s.id=ranked.id and ranked.rank>1;
 update public.submissions set evidence_refs=null where status='draft' and created_at<now()-interval '30 days' and evidence_refs is not null;
 update public.submissions set evidence_refs=null where status in ('approved','rejected') and evidence_refs is not null and id not in(select l.id from public.leaderboard('single') with ordinality l where l.ordinality<=10);
 perform public.collect_recordings();
end; $$;
create or replace function public.review_submission(submission uuid,approve boolean,note text default '') returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.is_admin() then raise exception 'Administrator access required'; end if;
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 update public.submissions set status=case when approve then 'approved' else 'rejected' end,reviewed_at=now(),reviewed_by=auth.uid(),review_note=left(note,500) where id=submission and status='pending';
 if not found then raise exception 'Pending submission not found'; end if;
 perform public.prune_recordings();
end; $$;
revoke all on function public.record_online_attempt(uuid,jsonb),public.my_leaderboard_candidates(),public.submit_leaderboard(uuid) from public,anon,authenticated;
grant execute on function public.record_online_attempt(uuid,jsonb),public.my_leaderboard_candidates(),public.submit_leaderboard(uuid) to authenticated;
