-- Investigation is a private review state. New submissions cannot erase a held case.
alter table public.submissions drop constraint submissions_status_check;
alter table public.submissions add constraint submissions_status_check check(status in ('draft','pending','investigating','approved','rejected'));
alter table public.submissions add column investigation_note text not null default '' check(length(investigation_note)<=500);
alter table public.submissions add column investigation_at timestamptz;
alter table public.submissions add column investigation_by uuid references auth.users on delete set null;
alter table public.submission_notifications drop constraint submission_notifications_decision_check;
alter table public.submission_notifications add constraint submission_notifications_decision_check check(decision in ('approved','rejected','held'));
alter table public.submission_notifications drop constraint submission_notifications_submission_id_key;
alter table public.submission_notifications add constraint submission_notifications_submission_decision_key unique(submission_id,decision);
create function public.hold_submission(submission uuid,note text) returns jsonb language plpgsql security definer set search_path='' as $$
declare held public.submissions; owner uuid;
begin
 if not public.is_admin() then raise exception 'Administrator access required';end if;
 note:=trim(note);if note is null or length(note)<3 or length(note)>500 then raise exception 'Explain the investigation hold in 3–500 characters';end if;
 select user_id into owner from public.submissions where id=submission;
 if not found then raise exception 'Pending submission not found';end if;
 perform 1 from public.profiles where id=owner for update;
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 select * into held from public.submissions where id=submission and status in ('pending','investigating') for update;
 if not found then raise exception 'Pending submission not found';end if;
 if held.status='investigating' and held.investigation_note=note then return jsonb_build_object('id',held.id,'status','investigating');end if;
 update public.submissions set status='investigating',investigation_note=note,investigation_at=clock_timestamp(),investigation_by=auth.uid() where id=held.id;
 insert into public.submission_notifications(user_id,submission_id,metric,ms,decision,note,created_at) values(held.user_id,held.id,held.metric,held.ms,'held',note,clock_timestamp())
 on conflict(submission_id,decision) do update set note=excluded.note,created_at=excluded.created_at,read_at=null;
 perform public.prune_submission_notifications();
 return jsonb_build_object('id',held.id,'status','investigating');
end; $$;
create or replace function public.review_submission(submission uuid,approve boolean,note text default '') returns void language plpgsql security definer set search_path='' as $$
declare reviewed public.submissions; owner uuid;
begin
 if not public.is_admin() then raise exception 'Administrator access required';end if;
 note:=trim(coalesce(note,''));
 if approve is null then raise exception 'Choose an approval or rejection';end if;
 if not approve and length(note)<3 then raise exception 'Write an explanation for the rejection';end if;
 if length(note)>500 then raise exception 'Messages must be at most 500 characters';end if;
 select user_id into owner from public.submissions where id=submission;
 if not found then raise exception 'Pending submission not found';end if;
 perform 1 from public.profiles where id=owner for update;
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 update public.submissions set status=case when approve then 'approved' else 'rejected' end,reviewed_at=clock_timestamp(),reviewed_by=auth.uid(),review_note=note where id=submission and status in ('pending','investigating') returning * into reviewed;
 if not found then raise exception 'Pending submission not found';end if;
 insert into public.submission_notifications(user_id,submission_id,metric,ms,decision,note,created_at) values(reviewed.user_id,reviewed.id,reviewed.metric,reviewed.ms,reviewed.status,note,reviewed.reviewed_at);
 perform public.prune_recordings();
end; $$;
create or replace function public.review_queue() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not public.is_admin() then raise exception 'Administrator access required';end if;
 return coalesce((select jsonb_agg(row_to_json(q)) from (
 select s.id,p.username,s.metric,s.ms,s.status,s.created_at,s.submitted_at,s.investigation_note,s.investigation_at from public.submissions s join public.profiles p on p.id=s.user_id where s.status in ('pending','investigating') order by s.submitted_at,s.created_at,s.id limit 100) q),'[]');
end; $$;
revoke all on function public.hold_submission(uuid,text) from public,anon,authenticated;
grant execute on function public.hold_submission(uuid,text) to authenticated;

-- Keep held evidence within the existing 30-day review-retention window.
create or replace function public.prune_recording_data() returns void language plpgsql security definer set search_path='' as $$
begin
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 delete from public.short_links where expires_at<=now();
 delete from public.attempts where started_at<now()-interval '2 days';
 -- Keep bounded draft metadata, but free expired recordings. An existing
 -- newer draft takes precedence over a pending result that expires.
 delete from public.submissions expired where status in ('pending','investigating') and coalesce(investigation_at,submitted_at,created_at)<now()-interval '30 days' and exists(select 1 from public.submissions draft where draft.user_id=expired.user_id and draft.metric=expired.metric and draft.status='draft');
 update public.submissions set status='draft',evidence_refs=null where status in ('pending','investigating') and coalesce(investigation_at,submitted_at,created_at)<now()-interval '30 days';
 delete from public.submissions s using (select id,row_number() over(partition by user_id,metric order by created_at desc,id) as rank from public.submissions where status='draft') ranked where s.id=ranked.id and ranked.rank>1;
 update public.submissions set evidence_refs=null where status='draft' and created_at<now()-interval '30 days' and evidence_refs is not null;
 update public.submissions set evidence_refs=null where status in ('approved','rejected') and evidence_refs is not null and id not in(select l.id from public.leaderboard('single') with ordinality l where l.ordinality<=10);
 perform public.collect_recordings();
end; $$;

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
 delete from public.submissions where user_id=auth.uid() and metric=candidate.metric and status='pending';
 update public.submissions set status='pending',submitted_at=clock_timestamp() where id=candidate.id;
 return jsonb_build_object('id',candidate.id,'status','pending');
end; $$;

create or replace function public.recover_leaderboard_single(source text,reason text,reviewed boolean,acknowledge_warnings boolean default false) returns jsonb language plpgsql security definer set search_path='' as $$
declare preview jsonb; fingerprint text; payload jsonb; owner uuid; candidate uuid; flags jsonb; value double precision;
begin
 if not public.is_admin() then raise exception 'Administrator access required'; end if;
 if reviewed is distinct from true then raise exception 'Review the replay and keyboard layout before adding this solve'; end if;
 reason:=trim(reason);if reason is null or length(reason)<3 or length(reason)>500 then raise exception 'Explain the recovery in 3–500 characters'; end if;
 preview:=public.inspect_leaderboard_recovery(source);owner:=(preview->>'solver_id')::uuid;
 perform 1 from public.profiles where id=owner for update;
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 -- Reinspect on every write; client warnings and eligibility are never trusted.
 preview:=public.inspect_leaderboard_recovery(source);flags:=preview->'flags';
 if not (preview->>'can_recover')::boolean then raise exception 'This recording has disqualifying evidence and cannot be added'; end if;
 if exists(select 1 from jsonb_array_elements(flags) f where f->>'severity'='warning') and acknowledge_warnings is distinct from true then raise exception 'Acknowledge the recording warnings before adding this solve'; end if;
 if preview->>'existing_approved' is not null then return jsonb_build_object('id',preview->>'existing_approved','status','approved','already_added',true);end if;
 owner:=(preview->>'solver_id')::uuid;value:=(preview->>'ms')::double precision;
 perform 1 from public.profiles where id=owner for update;
 payload:=jsonb_set(preview->'recording','{solver}',jsonb_build_object('id',owner,'username',preview->>'username'));
 fingerprint:=public.store_recording(payload,true);
 if not public.leaderboard_evidence_available(jsonb_build_array(jsonb_build_object('ms',value,'dnf',false,'recording_hash',fingerprint)),'single') then raise exception 'The recovered recording failed evidence validation';end if;
 -- Preserve reviewed decisions and their notifications; reuse only an unreviewed row.
 select id into candidate from public.submissions where user_id=owner and metric='single' and status in ('draft','pending','investigating') and evidence_refs->0->>'recording_hash'=fingerprint order by created_at desc limit 1;
 if candidate is null then
  insert into public.submissions(user_id,metric,ms,status,submitted_at,evidence_refs,recovery_source,recovery_flags,recovery_recording_hash) values(owner,'single',value,'pending',clock_timestamp(),jsonb_build_array(jsonb_build_object('ms',value,'dnf',false,'recording_hash',fingerprint)),preview->>'source_label',flags,fingerprint) returning id into candidate;
 else
  update public.submissions set status='pending',ms=value,evidence_refs=jsonb_build_array(jsonb_build_object('ms',value,'dnf',false,'recording_hash',fingerprint)),submitted_at=clock_timestamp(),recovery_source=preview->>'source_label',recovery_flags=flags,recovery_recording_hash=fingerprint where id=candidate;
 end if;
 perform public.review_submission(candidate,true,'Recovered by an administrator: '||left(reason,470));
 return jsonb_build_object('id',candidate,'status','approved','already_added',false);
end; $$;

-- Recovery must also disclose an existing investigation before manual approval.
create or replace function public.inspect_leaderboard_recovery(source text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare payload jsonb; owner uuid; fingerprint text; trusted boolean; original public.submissions; profile public.profiles; flags jsonb:='[]'; value double precision; canonical text; existing uuid; investigation text;
begin
 if not public.is_admin() then raise exception 'Administrator access required'; end if;
 source:=lower(trim(source));
 if source ~ '^[0-9a-f]{32}$' then
  canonical:='short:'||source;
  select l.user_id,l.recording_hash,o.payload,o.verified into owner,fingerprint,payload,trusted from public.short_links l join public.recording_objects o on o.hash=l.recording_hash where l.id=source and l.expires_at>now();
 elsif source ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
  canonical:='submission:'||source;
  select * into original from public.submissions where id=source::uuid;
  if original.metric is distinct from 'single' then raise exception 'Recovery currently supports single solves. Use a single recording link'; end if;
  owner:=original.user_id;fingerprint:=original.evidence_refs->0->>'recording_hash';
  select o.payload,o.verified into payload,trusted from public.recording_objects o where o.hash=fingerprint;
 else raise exception 'Paste a temporary recording link or a single submission ID';
 end if;
 if payload is null then raise exception 'Recording is unavailable or expired. Ask the solver for a current recording link'; end if;
 -- A trusted recording belongs to its server-attributed solver, not a later sharer.
 if trusted and payload->'solver'->>'id' is not null then
  select * into profile from public.profiles where id::text=payload->'solver'->>'id';
  if profile.id is null then raise exception 'The recorded solver account is unavailable'; end if;
  if original.id is not null and original.user_id<>profile.id then raise exception 'Submission and recording solver do not match'; end if;
  owner:=profile.id;
 else
  select * into profile from public.profiles where id=owner;
  if profile.id is null then raise exception 'The recording owner account is unavailable'; end if;
  flags:=flags||jsonb_build_array(jsonb_build_object('code','unverified','severity','warning','label','No trusted online recording. Verify the solver identity and timing yourself.'));
  if payload->'solver'->>'id' is not null and payload->'solver'->>'id'<>owner::text then
   flags:=flags||jsonb_build_array(jsonb_build_object('code','identity','severity','block','label','The recorded solver does not match the link owner. Ask the solver to share their own recording.'));
  end if;
 end if;
 select investigation_note into investigation from public.submissions where user_id=owner and metric='single' and status='investigating' and (evidence_refs->0->>'recording_hash'=fingerprint or recovery_recording_hash=fingerprint) order by investigation_at desc limit 1;
 if investigation is not null then flags:=flags||jsonb_build_array(jsonb_build_object('code','investigating','severity','warning','label','This recording is on hold: '||investigation));end if;
 if octet_length(payload::text)>2000000 or payload->>'format' is distinct from 'fto-replay-v1' or payload->>'size' is distinct from '3' or payload->>'complete' is distinct from 'true' or jsonb_typeof(payload->'events') is distinct from 'array' then
  flags:=flags||jsonb_build_array(jsonb_build_object('code','format','severity','block','label','A complete 3 × 3 FTO recording is required.'));
 else
  if jsonb_array_length(payload->'events')>20000 then flags:=flags||jsonb_build_array(jsonb_build_object('code','size','severity','block','label','Recording exceeds the leaderboard event limit.'));end if;
  if coalesce((payload->>'usedUndo')::boolean,false) or exists(select 1 from jsonb_array_elements(payload->'events') e where e->>'type'='accept' and e->>'action'='undo' or e->>'type'='sound' and e->>'kind'='undo') then
   flags:=flags||jsonb_build_array(jsonb_build_object('code','undo','severity','block','label','Undo was used. This solve is ineligible for the leaderboard.'));
  end if;
  if coalesce((payload->>'usedPause')::boolean,false) or exists(select 1 from jsonb_array_elements(payload->'events') e where e->>'type'='pause') then
   flags:=flags||jsonb_build_array(jsonb_build_object('code','pause','severity','block','label','The solve was paused. This solve is ineligible for the leaderboard.'));
  elsif not payload ? 'usedPause' then
   flags:=flags||jsonb_build_array(jsonb_build_object('code','legacy-pause','severity','warning','label','Older recording: an explicit pause-history flag is missing. Check its timing and replay.'));
  end if;
 end if;
 if coalesce((payload->>'dnf')::boolean,false) then flags:=flags||jsonb_build_array(jsonb_build_object('code','dnf','severity','block','label','This recording is marked DNF.'));end if;
 begin value:=(payload->>'solveMs')::double precision;exception when invalid_text_representation or numeric_value_out_of_range then value:=null;end;
 if value is null or value<=0 or value>=86400000 then flags:=flags||jsonb_build_array(jsonb_build_object('code','duration','severity','block','label','The recording has no valid solve time.'));end if;
 if jsonb_typeof(payload->'initial'->'keyboard'->'modes') is distinct from 'array' then flags:=flags||jsonb_build_array(jsonb_build_object('code','keyboard','severity','warning','label','No keyboard layout was recorded. Check the input and solver explanation.'));end if;
 select id into existing from public.submissions where user_id=owner and metric='single' and status='approved' and (evidence_refs->0->>'recording_hash'=fingerprint or recovery_recording_hash=fingerprint) order by reviewed_at desc limit 1;
 return jsonb_build_object('source',source,'source_label',canonical,'solver_id',owner,'username',profile.username,'ms',value,'recording_hash',fingerprint,'recording',payload,'trusted',trusted,'flags',flags,'can_recover',not exists(select 1 from jsonb_array_elements(flags) f where f->>'severity'='block'),'existing_approved',existing,'leaderboard_ms',(select min(ms) from public.submissions where user_id=owner and metric='single' and status='approved'));
exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'Malformed recording flags. This recording cannot be recovered';
end; $$;

-- Older tabs only understand final decisions. Hide holds from that legacy RPC
-- instead of letting an unknown decision render as "Rejected" in old clients.
create or replace function public.my_submission_notifications() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(row_to_json(n) order by n.created_at desc,n.id desc),'[]') from (
 select id,metric,ms,decision,note,created_at,read_at from public.submission_notifications where user_id=auth.uid() and decision in ('approved','rejected') and created_at>now()-interval '90 days' order by created_at desc,id desc limit 50
 ) n;
$$;
create function public.my_submission_notifications(include_investigations boolean) returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(row_to_json(n) order by n.created_at desc,n.id desc),'[]') from (
 select id,metric,ms,decision,note,created_at,read_at from public.submission_notifications where user_id=auth.uid() and (coalesce(include_investigations,false) or decision in ('approved','rejected')) and created_at>now()-interval '90 days' order by created_at desc,id desc limit 50
 ) n;
$$;
revoke all on function public.my_submission_notifications(boolean) from public,anon,authenticated;
grant execute on function public.my_submission_notifications(boolean) to authenticated;
