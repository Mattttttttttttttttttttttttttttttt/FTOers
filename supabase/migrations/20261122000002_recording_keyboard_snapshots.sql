-- Immutable keyboard snapshots are stored once. Replay hashes and short-link
-- codes remain based on the complete original recording, preserving all links.
create table public.recording_keyboards (
 hash text primary key check(hash ~ '^[0-9a-f]{64}$'),
 keyboard jsonb not null, binding_refs jsonb not null default '{}'
);
alter table public.recording_keyboards enable row level security;
revoke all on public.recording_keyboards from anon,authenticated;
create trigger recording_keyboards_storage_guard before insert or update on public.recording_keyboards
 for each row execute function public.guard_database_write();
alter table public.recording_objects add column keyboard_hash text references public.recording_keyboards(hash);
create index recording_objects_keyboard_idx on public.recording_objects(keyboard_hash) where keyboard_hash is not null;
create table public.recording_keyboard_bindings (
 hash text primary key check(hash ~ '^[0-9a-f]{64}$'), bindings jsonb not null
);
alter table public.recording_keyboard_bindings enable row level security;
revoke all on public.recording_keyboard_bindings from anon,authenticated;
create trigger recording_keyboard_bindings_storage_guard before insert or update on public.recording_keyboard_bindings
 for each row execute function public.guard_database_write();
create or replace function public.check_recording_quota(incoming bigint) returns void language plpgsql security definer set search_path='' as $$
declare used bigint;
begin
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 select (select coalesce(sum(octet_length(payload::text)),0) from public.recording_objects)
       +(select coalesce(sum(octet_length(keyboard::text)+octet_length(binding_refs::text)),0) from public.recording_keyboards)
       +(select coalesce(sum(octet_length(bindings::text)),0) from public.recording_keyboard_bindings) into used;
 if used+greatest(coalesce(incoming,0),0)>100000000 then raise exception 'Recording storage is temporarily full'; end if;
 perform public.check_database_capacity(incoming);
end; $$;
create function public.intern_recording_keyboard(keyboard jsonb) returns text language plpgsql security definer set search_path='' as $$
declare fingerprint text:=encode(extensions.digest(keyboard::text,'sha256'),'hex'); stored jsonb:=keyboard;
 nodes jsonb:='{}'; refs jsonb:='{}'; bindings jsonb; binding_hash text; mode integer; incoming bigint;
begin
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 if exists(select 1 from public.recording_keyboards where hash=fingerprint) then return fingerprint; end if;
 if jsonb_typeof(keyboard->'modes')='array' then
  for mode in 0..jsonb_array_length(keyboard->'modes')-1 loop
   bindings:=keyboard->'modes'->mode->'bindings';
   if jsonb_typeof(bindings)='array' then
    binding_hash:=encode(extensions.digest(bindings::text,'sha256'),'hex');
    nodes:=nodes||jsonb_build_object(binding_hash,bindings);
    refs:=refs||jsonb_build_object(mode::text,binding_hash);
    stored:=jsonb_set(stored,array['modes',mode::text,'bindings'],jsonb_build_object('__ftoBindingSnapshot',binding_hash));
   end if;
  end loop;
 end if;
 select octet_length(stored::text)+octet_length(refs::text)+coalesce(sum(octet_length(n.value::text)),0) into incoming
 from jsonb_each(nodes) n where not exists(select 1 from public.recording_keyboard_bindings b where b.hash=n.key);
 perform public.check_recording_quota(incoming);
 insert into public.recording_keyboard_bindings(hash,bindings) select key,value from jsonb_each(nodes) on conflict do nothing;
 insert into public.recording_keyboards(hash,keyboard,binding_refs) values(fingerprint,stored,refs);
 return fingerprint;
end; $$;
revoke all on function public.intern_recording_keyboard(jsonb) from public,anon,authenticated;
update public.recording_objects set
 keyboard_hash=public.intern_recording_keyboard(payload->'initial'->'keyboard'),
 payload=payload #- '{initial,keyboard}'
 where jsonb_typeof(payload->'initial'->'keyboard')='object';
create function public.hydrate_recording(payload jsonb,keyboard_hash text) returns jsonb
 language plpgsql stable security definer set search_path='' as $$
declare keyboard jsonb; refs jsonb; mode integer; bindings jsonb; binding_hash text;
begin
 if keyboard_hash is null then return payload; end if;
 select k.keyboard,k.binding_refs into keyboard,refs from public.recording_keyboards k where k.hash=keyboard_hash;
 if keyboard is null then raise exception 'Recording keyboard snapshot is unavailable'; end if;
 -- Only database-created references are expanded; user JSON cannot introduce
 -- a dictionary lookup by imitating an internal marker.
 for mode,binding_hash in select key::integer,value from jsonb_each_text(refs) loop
  select b.bindings into bindings from public.recording_keyboard_bindings b where b.hash=binding_hash;
  if bindings is null then raise exception 'Recording binding snapshot is unavailable'; end if;
  keyboard:=jsonb_set(keyboard,array['modes',mode::text,'bindings'],bindings);
 end loop;
 return jsonb_set(payload,'{initial,keyboard}',keyboard);
end; $$;
revoke all on function public.hydrate_recording(jsonb,text) from public,anon,authenticated;
create or replace function public.store_recording(replay jsonb,trusted boolean default false) returns text
 language plpgsql security definer set search_path='' as $$
declare fingerprint text:=public.recording_fingerprint(replay); was_verified boolean; previous_bytes integer;
 keyboard jsonb:=replay->'initial'->'keyboard'; keyboard_id text; stored jsonb:=replay; incoming bigint;
begin
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 select verified,octet_length(payload::text) into was_verified,previous_bytes from public.recording_objects where hash=fingerprint;
 if found and (was_verified or not trusted) then return fingerprint; end if;
 incoming:=0;
 if jsonb_typeof(keyboard)='object' then
  keyboard_id:=encode(extensions.digest(keyboard::text,'sha256'),'hex');
  stored:=replay #- '{initial,keyboard}';

 end if;
 perform public.check_recording_quota(incoming+greatest(0,octet_length(stored::text)-coalesce(previous_bytes,0)));
 if keyboard_id is not null then
  keyboard_id:=public.intern_recording_keyboard(keyboard);
  perform public.check_recording_quota(greatest(0,octet_length(stored::text)-coalesce(previous_bytes,0)));
 end if;
 insert into public.recording_objects(hash,payload,verified,keyboard_hash) values(fingerprint,stored,trusted,keyboard_id)
 on conflict(hash) do update set payload=excluded.payload,verified=true,keyboard_hash=excluded.keyboard_hash
 where not public.recording_objects.verified and excluded.verified;
 return fingerprint;
end; $$;


create or replace function public.resolve_evidence(refs jsonb) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_agg((e-'recording_hash')||jsonb_build_object('recording',(select public.hydrate_recording(payload,keyboard_hash) from public.recording_objects where hash=e->>'recording_hash')) order by ordinal) from jsonb_array_elements(refs) with ordinality a(e,ordinal);
$$;

create or replace function public.public_replay(submission uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not exists(select 1 from public.leaderboard('single') with ordinality l where l.id=submission and l.ordinality<=10) then raise exception 'Only the top 10 single recordings are public'; end if;
 return (select public.hydrate_recording(o.payload,o.keyboard_hash) from public.submissions s join public.recording_objects o on o.hash=s.evidence_refs->0->>'recording_hash' where s.id=submission);
end; $$;

create or replace function public.get_short_link(code text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare replay jsonb;
begin
 select public.hydrate_recording(o.payload,o.keyboard_hash) into replay from public.short_links l join public.recording_objects o on o.hash=l.recording_hash where l.id=code and l.expires_at>now();
 if replay is null then raise exception 'This link has expired or does not exist'; end if;return replay;
end; $$;

create or replace function public.inspect_leaderboard_recovery(source text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare payload jsonb; owner uuid; fingerprint text; trusted boolean; original public.submissions; profile public.profiles; flags jsonb:='[]'; value double precision; canonical text; existing uuid; investigation text;
begin
 if not public.is_admin() then raise exception 'Administrator access required'; end if;
 source:=lower(trim(source));
 if source ~ '^[0-9a-f]{32}$' then
  canonical:='short:'||source;
  select l.user_id,l.recording_hash,public.hydrate_recording(o.payload,o.keyboard_hash),o.verified into owner,fingerprint,payload,trusted from public.short_links l join public.recording_objects o on o.hash=l.recording_hash where l.id=source and l.expires_at>now();
 elsif source ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
  canonical:='submission:'||source;
  select * into original from public.submissions where id=source::uuid;
  if original.metric is distinct from 'single' then raise exception 'Recovery currently supports single solves. Use a single recording link'; end if;
  owner:=original.user_id;fingerprint:=original.evidence_refs->0->>'recording_hash';
  select public.hydrate_recording(o.payload,o.keyboard_hash),o.verified into payload,trusted from public.recording_objects o where o.hash=fingerprint;
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

create or replace function public.collect_recordings() returns void language sql security definer set search_path='' as $$
 delete from public.recording_objects o where
 not exists(select 1 from public.attempts a where a.recording_hash=o.hash) and
 not exists(select 1 from public.short_links l where l.recording_hash=o.hash) and
 not exists(select 1 from public.submissions s cross join lateral jsonb_array_elements(s.evidence_refs) e where e->>'recording_hash'=o.hash);
delete from public.recording_keyboards k where not exists(select 1 from public.recording_objects o where o.keyboard_hash=k.hash);
 delete from public.recording_keyboard_bindings b where not exists(
  select 1 from public.recording_keyboards k cross join lateral jsonb_each_text(k.binding_refs) r where r.value=b.hash);
$$;

create or replace function public.storage_status() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not public.is_admin() and current_setting('request.jwt.claim.role',true) is distinct from 'service_role' and (coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb->>'role') is distinct from 'service_role' then raise exception 'Administrator access required'; end if;
 return jsonb_build_object('database_bytes',public.database_storage_bytes(),'database_write_stop_bytes',350000000,
 'recording_payload_bytes',(select coalesce(sum(octet_length(payload::text)),0) from public.recording_objects),
 'keyboard_snapshot_bytes',((select coalesce(sum(octet_length(keyboard::text)+octet_length(binding_refs::text)),0) from public.recording_keyboards)+(select coalesce(sum(octet_length(bindings::text)),0) from public.recording_keyboard_bindings)),'recording_payload_limit_bytes',100000000,'daily_short_link_limit_bytes',500000);
end; $$;
