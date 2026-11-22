-- Manual recovery is admin-only and never creates a fictitious online attempt.
alter table public.submissions add column recovery_source text;
alter table public.submissions add column recovery_flags jsonb;
alter table public.submissions add column recovery_recording_hash text check(recovery_recording_hash ~ '^[0-9a-f]{64}$');
create unique index submissions_recovered_single on public.submissions(user_id,metric,recovery_recording_hash) where recovery_recording_hash is not null and status='approved';
create function public.inspect_leaderboard_recovery(source text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare payload jsonb; owner uuid; fingerprint text; trusted boolean; original public.submissions; profile public.profiles; flags jsonb:='[]'; value double precision; canonical text; existing uuid;
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
create function public.recover_leaderboard_single(source text,reason text,reviewed boolean,acknowledge_warnings boolean default false) returns jsonb language plpgsql security definer set search_path='' as $$
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
 select id into candidate from public.submissions where user_id=owner and metric='single' and status in ('draft','pending') and evidence_refs->0->>'recording_hash'=fingerprint order by created_at desc limit 1;
 if candidate is null then
  insert into public.submissions(user_id,metric,ms,status,submitted_at,evidence_refs,recovery_source,recovery_flags,recovery_recording_hash) values(owner,'single',value,'pending',clock_timestamp(),jsonb_build_array(jsonb_build_object('ms',value,'dnf',false,'recording_hash',fingerprint)),preview->>'source_label',flags,fingerprint) returning id into candidate;
 else
  update public.submissions set status='pending',ms=value,evidence_refs=jsonb_build_array(jsonb_build_object('ms',value,'dnf',false,'recording_hash',fingerprint)),submitted_at=clock_timestamp(),recovery_source=preview->>'source_label',recovery_flags=flags,recovery_recording_hash=fingerprint where id=candidate;
 end if;
 perform public.review_submission(candidate,true,'Recovered by an administrator: '||left(reason,470));
 return jsonb_build_object('id',candidate,'status','approved','already_added',false);
end; $$;
revoke all on function public.inspect_leaderboard_recovery(text),public.recover_leaderboard_single(text,text,boolean,boolean) from public,anon,authenticated;
grant execute on function public.inspect_leaderboard_recovery(text),public.recover_leaderboard_single(text,text,boolean,boolean) to authenticated;
