-- One project for the entire FTOers network. All writes pass through RPCs.
create extension if not exists pgcrypto with schema extensions;
create table public.profiles (
 id uuid primary key references auth.users on delete cascade,
 username text not null check (username ~ '^[A-Za-z0-9_]{3,24}$'),
 created_at timestamptz not null default now()
);
create unique index profiles_username_unique on public.profiles(lower(username));
create table public.admins (user_id uuid primary key references auth.users on delete cascade);
create table public.attempts (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles on delete cascade,
 session_id uuid not null, started_at timestamptz not null default clock_timestamp(),
 completed_at timestamptz, ms double precision, dnf boolean not null default true,
 recording jsonb, unique(user_id,session_id,started_at)
);
create index attempts_recent on public.attempts(user_id,session_id,started_at desc);
create table public.submissions (
 id uuid primary key default gen_random_uuid(),user_id uuid not null references public.profiles on delete cascade,
 metric text not null check(metric in ('single','ao5','ao12')),ms double precision not null check(ms>0 and ms<86400000),
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 evidence jsonb, created_at timestamptz not null default now(), reviewed_at timestamptz,
 reviewed_by uuid references auth.users, review_note text not null default ''
);
create index submissions_ranking on public.submissions(metric,ms) where status='approved';
create table public.short_links (
 id text primary key, recording_hash text not null unique check(recording_hash ~ '^[0-9a-f]{64}$'),
 user_id uuid not null references public.profiles on delete cascade, recording jsonb not null,
 created_at timestamptz not null default now(), expires_at timestamptz not null default now()+interval '30 days'
);
create index short_links_expiry on public.short_links(expires_at);
alter table public.profiles enable row level security;
alter table public.admins enable row level security;
alter table public.attempts enable row level security;
alter table public.submissions enable row level security;
alter table public.short_links enable row level security;
revoke all on public.profiles,public.admins,public.attempts,public.submissions,public.short_links from anon,authenticated;
-- Admin identity depends on a confirmed Auth email, never editable user metadata.
create function public.is_admin() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.admins where user_id=auth.uid()) or exists(
 select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null and lower(email)='abid.ibn.ashraf@gmail.com');
$$;
create function public.my_profile() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',p.id,'username',p.username,'admin',public.is_admin()) from public.profiles p where p.id=auth.uid();
$$;
create function public.claim_username(name text) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 if name !~ '^[A-Za-z0-9_]{3,24}$' then raise exception 'Use 3–24 letters, numbers or underscores'; end if;
 insert into public.profiles(id,username) values(auth.uid(),name);
 return public.my_profile();
exception when unique_violation then raise exception 'Username already taken or already set';
end; $$;
-- Username sign-in resolves internally in the Edge Function; emails are never exposed by RPC.
create function public.begin_attempt(session uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 if not exists(select 1 from public.profiles where id=auth.uid()) then raise exception 'Choose a username first'; end if;
 perform 1 from public.profiles where id=auth.uid() for update;
 if (select count(*) from public.attempts where user_id=auth.uid() and started_at>now()-interval '1 minute')>=30 then raise exception 'Too many attempts'; end if;
 -- One outstanding attempt per session. An interrupted request creates a DNF boundary.
 update public.attempts set completed_at=now(),dnf=true where user_id=auth.uid() and session_id=session and completed_at is null;
 insert into public.attempts(user_id,session_id) values(auth.uid(),session) returning id into result;
 return result;
end; $$;
create function public.check_recording_quota(incoming bigint) returns void language plpgsql security definer set search_path='' as $$
declare used bigint;
begin
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 select coalesce((select sum(octet_length(recording::text)) from public.attempts),0)+coalesce((select sum(octet_length(evidence::text)) from public.submissions),0)+coalesce((select sum(octet_length(recording::text)) from public.short_links),0) into used;
 if used+coalesce(incoming,0)>100000000 then raise exception 'Recording storage is temporarily full'; end if;
end; $$;
create function public.finish_attempt(attempt uuid, replay jsonb default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.attempts; bad boolean:=true; value double precision; n integer; sample jsonb; candidate uuid; results jsonb:='[]'; window_count integer;
begin
 perform 1 from public.profiles where id=auth.uid() for update;
 select * into a from public.attempts where id=attempt and user_id=auth.uid() for update;
 if a.id is null or a.completed_at is not null then raise exception 'Attempt missing or already submitted'; end if;
 if a.started_at<now()-interval '1 day' then raise exception 'Attempt expired'; end if;
 if replay is not null then
  perform public.check_recording_quota(octet_length(replay::text));
  if octet_length(replay::text)>2000000 or (replay->>'format') is distinct from 'fto-replay-v1' or (replay->>'size') is distinct from '3' or (replay->>'complete') is distinct from 'true' or jsonb_typeof(replay->'events') is distinct from 'array' or jsonb_array_length(replay->'events')>20000 then raise exception 'Invalid 3×3 recording (2 MB limit)'; end if;
  value:=(replay->>'solveMs')::double precision;
  if value is null or value<=0 or value>=86400000 or value>extract(epoch from (clock_timestamp()-a.started_at))*1000+2000 then raise exception 'Invalid solve time'; end if;
  bad:=coalesce((replay->>'usedUndo')::boolean,false) or exists(select 1 from jsonb_array_elements(replay->'events') e where (e->>'type'='accept' and e->>'action'='undo') or (e->>'type'='sound' and e->>'kind'='undo'));
  replay:=jsonb_set(replay,'{solver}',(select jsonb_build_object('id',id,'username',username) from public.profiles where id=auth.uid()));
 end if;
 update public.attempts set completed_at=clock_timestamp(),ms=value,dnf=bad,recording=case when bad then null else replay end where id=a.id;
 for n in select unnest(array[1,5,12]) loop
  select count(*) into window_count from (select id from public.attempts where user_id=a.user_id and session_id=a.session_id and started_at<=a.started_at order by started_at desc limit n) w;
  if window_count<n then continue; end if;
  -- Keep every attempt in the window; undo, abandonment and unfinished attempts are DNFs.
  with recent as (select * from public.attempts where user_id=a.user_id and session_id=a.session_id and started_at<=a.started_at order by started_at desc limit n), ranked as (select *,row_number() over(order by dnf,ms nulls last,started_at) rank from recent)
  select case when bool_or(dnf) then null else avg(ms) end into value from ranked where n=1 or rank between 2 and n-1;
  if value is null then continue; end if;
  if exists(select 1 from public.submissions where user_id=a.user_id and metric=case when n=1 then 'single' else 'ao'||n end and status in ('approved','pending') and ms<=value) then continue; end if;
  select jsonb_agg(jsonb_build_object('ms',ms,'dnf',dnf,'recording',recording) order by started_at) into sample from (select * from public.attempts where user_id=a.user_id and session_id=a.session_id and started_at<=a.started_at order by started_at desc limit n) w;
  -- Replace older pending PBs of this metric rather than accumulating recordings.
  delete from public.submissions where user_id=a.user_id and metric=case when n=1 then 'single' else 'ao'||n end and status='pending';
  insert into public.submissions(user_id,metric,ms,evidence) values(a.user_id,case when n=1 then 'single' else 'ao'||n end,value,sample) returning id into candidate;
  results:=results||jsonb_build_array(jsonb_build_object('id',candidate,'metric',case when n=1 then 'single' else 'ao'||n end,'ms',value));
 end loop;
 delete from public.attempts where user_id=a.user_id and id not in (select id from public.attempts where user_id=a.user_id order by started_at desc limit 12);
 perform public.check_recording_quota(0);
 return jsonb_build_object('dnf',bad,'submitted',results);
end; $$;
create function public.leaderboard(kind text default 'single') returns table(id uuid,username text,ms double precision,created_at timestamptz,has_replay boolean) language sql stable security definer set search_path='' as $$
 with best as (select distinct on(s.user_id) s.* from public.submissions s where s.status='approved' and s.metric=kind order by s.user_id,s.ms,s.created_at)
 select b.id,p.username,b.ms,b.created_at,(kind='single' and b.evidence is not null) from best b join public.profiles p on p.id=b.user_id order by b.ms,b.created_at limit 100;
$$;
create function public.public_replay(submission uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not exists(select 1 from public.leaderboard('single') with ordinality l where l.id=submission and l.ordinality<=10) then raise exception 'Only the top 10 single recordings are public'; end if;
 return (select evidence->0->'recording' from public.submissions where id=submission);
end; $$;
create function public.review_queue() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not public.is_admin() then raise exception 'Administrator access required'; end if;
 return coalesce((select jsonb_agg(row_to_json(q)) from (select s.id,p.username,s.metric,s.ms,s.created_at from public.submissions s join public.profiles p on p.id=s.user_id where status='pending' order by s.created_at limit 100) q),'[]');
end; $$;
create function public.review_evidence(submission uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not public.is_admin() then raise exception 'Administrator access required'; end if;
 return (select evidence from public.submissions where id=submission);
end; $$;
create function public.prune_recordings() returns void language plpgsql security definer set search_path='' as $$
begin
 delete from public.short_links where expires_at<=now();
 delete from public.attempts where started_at<now()-interval '2 days';
 delete from public.submissions where status='pending' and created_at<now()-interval '30 days';
 -- Approved PB metadata stays; only current top ten singles retain permanent replay evidence.
 update public.submissions set evidence=null where status<>'pending' and evidence is not null and id not in (select l.id from public.leaderboard('single') with ordinality l where l.ordinality<=10);
end; $$;
create function public.review_submission(submission uuid,approve boolean,note text default '') returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.is_admin() then raise exception 'Administrator access required'; end if;
 update public.submissions set status=case when approve then 'approved' else 'rejected' end,reviewed_at=now(),reviewed_by=auth.uid(),review_note=left(note,500) where id=submission and status='pending';
 if not found then raise exception 'Pending submission not found'; end if;
 perform public.prune_recordings();
end; $$;
-- Fingerprint solve content, not who re-shares it or its display/PB metadata.
-- jsonb gives deterministic object-key ordering for imports and round trips.
create function public.recording_fingerprint(replay jsonb) returns text language sql immutable set search_path='' as $$
 select encode(extensions.digest(jsonb_build_object(
  'format',replay->'format','size',replay->'size','createdAt',replay->'createdAt',
  'completedAt',replay->'completedAt','solveMs',replay->'solveMs',
  'initial',replay->'initial','events',replay->'events'
 )::text,'sha256'),'hex');
$$;
create function public.create_short_link(replay jsonb) returns text language plpgsql security definer set search_path='' as $$
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
 perform public.check_recording_quota(octet_length(replay::text));
 if (select count(*) from public.short_links where user_id=auth.uid())>=20 then raise exception 'Limit: 20 active temporary links per account'; end if;
 if (select count(*) from public.short_links)>=1000 then raise exception 'Temporary link storage is full'; end if;
 result:=left(fingerprint,32);
 insert into public.short_links(id,recording_hash,user_id,recording) values(result,fingerprint,auth.uid(),replay);
 return result;
end; $$;
create function public.get_short_link(code text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare replay jsonb;
begin
 select recording into replay from public.short_links where id=code and expires_at>now();
 if replay is null then raise exception 'This link has expired or does not exist'; end if;return replay;
end; $$;
-- PostgreSQL functions default to PUBLIC execute: revoke explicitly before granting.
revoke execute on all functions in schema public from public,anon,authenticated;
grant execute on function public.is_admin(),public.my_profile(),public.claim_username(text),public.begin_attempt(uuid),public.finish_attempt(uuid,jsonb),public.review_queue(),public.review_evidence(uuid),public.review_submission(uuid,boolean,text),public.create_short_link(jsonb) to authenticated;
grant execute on function public.leaderboard(text),public.public_replay(uuid),public.get_short_link(text) to anon,authenticated;
create extension if not exists pg_cron;
select cron.schedule('ftoers-expiry','17 * * * *',$$select public.prune_recordings()$$);
