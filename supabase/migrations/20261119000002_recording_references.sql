-- Payloads live once, regardless of recent/PB/average/share memberships.
create table public.recording_objects (
 hash text primary key check(hash ~ '^[0-9a-f]{64}$'),
 payload jsonb not null, verified boolean not null default false
);
alter table public.recording_objects enable row level security;
revoke all on public.recording_objects from anon,authenticated;
-- Trusted solve evidence takes precedence over an unverified imported share.
insert into public.recording_objects(hash,payload,verified)
 select public.recording_fingerprint(recording),recording,true from public.attempts where recording is not null on conflict do nothing;
insert into public.recording_objects(hash,payload,verified)
 select public.recording_fingerprint(e->'recording'),e->'recording',true from public.submissions s cross join lateral jsonb_array_elements(s.evidence) e where e->'recording' is not null and e->'recording'<>'null'::jsonb on conflict do nothing;
insert into public.recording_objects(hash,payload,verified)
 select recording_hash,recording,false from public.short_links on conflict do nothing;
alter table public.attempts add column recording_hash text references public.recording_objects(hash);
update public.attempts set recording_hash=public.recording_fingerprint(recording) where recording is not null;
alter table public.submissions add column evidence_refs jsonb;
update public.submissions s set evidence_refs=(select jsonb_agg((e-'recording')||jsonb_build_object('recording_hash',case when e->'recording' is null or e->'recording'='null'::jsonb then null else public.recording_fingerprint(e->'recording') end) order by ordinal) from jsonb_array_elements(s.evidence) with ordinality a(e,ordinal)) where evidence is not null;
alter table public.short_links add constraint short_links_recording_object foreign key(recording_hash) references public.recording_objects(hash);
alter table public.attempts drop column recording;
alter table public.submissions drop column evidence;
alter table public.short_links drop column recording;
create index attempts_recording_hash on public.attempts(recording_hash);

create or replace function public.check_recording_quota(incoming bigint) returns void language plpgsql security definer set search_path='' as $$
declare used bigint;
begin
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 select coalesce(sum(octet_length(payload::text)),0) into used from public.recording_objects;
 if used+coalesce(incoming,0)>100000000 then raise exception 'Recording storage is temporarily full'; end if;
end; $$;
create function public.store_recording(replay jsonb,trusted boolean default false) returns text language plpgsql security definer set search_path='' as $$
declare fingerprint text:=public.recording_fingerprint(replay); was_verified boolean; previous_bytes integer;
begin
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 select verified,octet_length(payload::text) into was_verified,previous_bytes from public.recording_objects where hash=fingerprint;
 if found and (was_verified or not trusted) then return fingerprint; end if;
 perform public.check_recording_quota(greatest(0,octet_length(replay::text)-coalesce(previous_bytes,0)));
 insert into public.recording_objects(hash,payload,verified) values(fingerprint,replay,trusted) on conflict(hash) do update set payload=excluded.payload,verified=true where not public.recording_objects.verified and excluded.verified;
 return fingerprint;
end; $$;
create function public.resolve_evidence(refs jsonb) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_agg((e-'recording_hash')||jsonb_build_object('recording',(select payload from public.recording_objects where hash=e->>'recording_hash')) order by ordinal) from jsonb_array_elements(refs) with ordinality a(e,ordinal);
$$;
create function public.collect_recordings() returns void language sql security definer set search_path='' as $$
 delete from public.recording_objects o where
 not exists(select 1 from public.attempts a where a.recording_hash=o.hash) and
 not exists(select 1 from public.short_links l where l.recording_hash=o.hash) and
 not exists(select 1 from public.submissions s cross join lateral jsonb_array_elements(s.evidence_refs) e where e->>'recording_hash'=o.hash);
$$;
create or replace function public.finish_attempt(attempt uuid, replay jsonb default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.attempts; bad boolean:=true; value double precision; n integer; sample jsonb; candidate uuid; results jsonb:='[]'; window_count integer;
begin
 perform 1 from public.profiles where id=auth.uid() for update;
 select * into a from public.attempts where id=attempt and user_id=auth.uid() for update;
 if a.id is null or a.completed_at is not null then raise exception 'Attempt missing or already submitted'; end if;
 if a.started_at<now()-interval '1 day' then raise exception 'Attempt expired'; end if;
 if replay is not null then
  perform public.check_recording_quota(0);
  if octet_length(replay::text)>2000000 or (replay->>'format') is distinct from 'fto-replay-v1' or (replay->>'size') is distinct from '3' or (replay->>'complete') is distinct from 'true' or jsonb_typeof(replay->'events') is distinct from 'array' or jsonb_array_length(replay->'events')>20000 then raise exception 'Invalid 3×3 recording (2 MB limit)'; end if;
  value:=(replay->>'solveMs')::double precision;
  if value is null or value<=0 or value>=86400000 or value>extract(epoch from (clock_timestamp()-a.started_at))*1000+2000 then raise exception 'Invalid solve time'; end if;
  bad:=coalesce((replay->>'usedUndo')::boolean,false) or exists(select 1 from jsonb_array_elements(replay->'events') e where (e->>'type'='accept' and e->>'action'='undo') or (e->>'type'='sound' and e->>'kind'='undo'));
  replay:=jsonb_set(replay,'{solver}',(select jsonb_build_object('id',id,'username',username) from public.profiles where id=auth.uid()));
 end if;
 update public.attempts set completed_at=clock_timestamp(),ms=value,dnf=bad,recording_hash=case when bad then null else public.store_recording(replay,true) end where id=a.id;
 for n in select unnest(array[1,5,12]) loop
  select count(*) into window_count from (select id from public.attempts where user_id=a.user_id and session_id=a.session_id and started_at<=a.started_at order by started_at desc limit n) w;
  if window_count<n then continue; end if;
  -- Keep every attempt in the window; undo, abandonment and unfinished attempts are DNFs.
  with recent as (select * from public.attempts where user_id=a.user_id and session_id=a.session_id and started_at<=a.started_at order by started_at desc limit n), ranked as (select *,row_number() over(order by dnf,ms nulls last,started_at) rank from recent)
  select case when bool_or(dnf) then null else avg(ms) end into value from ranked where n=1 or rank between 2 and n-1;
  if value is null then continue; end if;
  if exists(select 1 from public.submissions where user_id=a.user_id and metric=case when n=1 then 'single' else 'ao'||n end and status in ('approved','pending') and ms<=value) then continue; end if;
  select jsonb_agg(jsonb_build_object('ms',ms,'dnf',dnf,'recording_hash',recording_hash) order by started_at) into sample from (select * from public.attempts where user_id=a.user_id and session_id=a.session_id and started_at<=a.started_at order by started_at desc limit n) w;
  -- Replace older pending PBs of this metric rather than accumulating recordings.
  delete from public.submissions where user_id=a.user_id and metric=case when n=1 then 'single' else 'ao'||n end and status='pending';
  insert into public.submissions(user_id,metric,ms,evidence_refs) values(a.user_id,case when n=1 then 'single' else 'ao'||n end,value,sample) returning id into candidate;
  results:=results||jsonb_build_array(jsonb_build_object('id',candidate,'metric',case when n=1 then 'single' else 'ao'||n end,'ms',value));
 end loop;
 delete from public.attempts where user_id=a.user_id and id not in (select id from public.attempts where user_id=a.user_id order by started_at desc limit 12);
 perform public.collect_recordings();
 perform public.check_recording_quota(0);
 return jsonb_build_object('dnf',bad,'submitted',results);
end; $$;
create or replace function public.leaderboard(kind text default 'single') returns table(id uuid,username text,ms double precision,created_at timestamptz,has_replay boolean) language sql stable security definer set search_path='' as $$
 with best as (select distinct on(s.user_id) s.* from public.submissions s where s.status='approved' and s.metric=kind order by s.user_id,s.ms,s.created_at)
 select b.id,p.username,b.ms,b.created_at,(kind='single' and b.evidence_refs is not null) from best b join public.profiles p on p.id=b.user_id order by b.ms,b.created_at limit 100;
$$;
create or replace function public.public_replay(submission uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not exists(select 1 from public.leaderboard('single') with ordinality l where l.id=submission and l.ordinality<=10) then raise exception 'Only the top 10 single recordings are public'; end if;
 return (select o.payload from public.submissions s join public.recording_objects o on o.hash=s.evidence_refs->0->>'recording_hash' where s.id=submission);
end; $$;
create or replace function public.review_evidence(submission uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not public.is_admin() then raise exception 'Administrator access required'; end if;
 return (select public.resolve_evidence(evidence_refs) from public.submissions where id=submission);
end; $$;
create or replace function public.prune_recordings() returns void language plpgsql security definer set search_path='' as $$
begin
 delete from public.short_links where expires_at<=now();
 delete from public.attempts where started_at<now()-interval '2 days';
 delete from public.submissions where status='pending' and created_at<now()-interval '30 days';
 -- Approved PB metadata stays; only current top ten singles retain permanent replay evidence.
 update public.submissions set evidence_refs=null where status<>'pending' and evidence_refs is not null and id not in (select l.id from public.leaderboard('single') with ordinality l where l.ordinality<=10);
 perform public.collect_recordings();
end; $$;
create or replace function public.create_short_link(replay jsonb) returns text language plpgsql security definer set search_path='' as $$
declare result text; fingerprint text;
begin
 if auth.uid() is null then raise exception 'Sign in to create a temporary link'; end if;
 if (replay->>'format') is distinct from 'fto-replay-v1' or (replay->>'size') is distinct from '3' or (replay->>'complete') is distinct from 'true' or octet_length(replay::text)>2000000 then raise exception 'Only complete 3×3 recordings up to 2 MB can use short links'; end if;
 perform 1 from public.profiles where id=auth.uid() for update;
 if not found then raise exception 'Choose a username first'; end if;
 -- Match quota-lock ordering and serialize deduplication across accounts/tabs.
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 fingerprint:=public.recording_fingerprint(replay);
 select id into result from public.short_links where recording_hash=fingerprint and expires_at>now();
 if result is not null then return result; end if;
 -- Expired recordings may be recreated, at the same deterministic URL.
 delete from public.short_links where expires_at<=now();
 perform public.collect_recordings();
 if (select count(*) from public.short_links where user_id=auth.uid())>=20 then raise exception 'Limit: 20 active temporary links per account'; end if;
 if (select count(*) from public.short_links)>=1000 then raise exception 'Temporary link storage is full'; end if;
 result:=left(fingerprint,32);
 fingerprint:=public.store_recording(replay,false);
 insert into public.short_links(id,recording_hash,user_id) values(result,fingerprint,auth.uid());
 return result;
end; $$;
create or replace function public.get_short_link(code text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare replay jsonb;
begin
 select o.payload into replay from public.short_links l join public.recording_objects o on o.hash=l.recording_hash where l.id=code and l.expires_at>now();
 if replay is null then raise exception 'This link has expired or does not exist'; end if;return replay;
end; $$;
revoke execute on function public.store_recording(jsonb,boolean),public.resolve_evidence(jsonb),public.collect_recordings() from public,anon,authenticated;
-- CREATE OR REPLACE retains the existing RPC grants.
select public.collect_recordings();
