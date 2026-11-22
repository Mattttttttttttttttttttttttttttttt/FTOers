-- Decimal bytes: 500 kB/account/UTC day, 100 MB unique replay payloads,
-- and a 350 MB database write stop with headroom below the Free plan's 500 MB.
-- Limits apply to app writes; Supabase-managed Auth/WAL and future schemas
-- require monitoring too. No application quota can cap those external writers.
create table public.short_link_daily_usage (
 user_id uuid primary key references public.profiles on delete cascade,
 day date not null,
 bytes integer not null check(bytes between 0 and 500000)
);
alter table public.short_link_daily_usage enable row level security;
revoke all on public.short_link_daily_usage from public,anon,authenticated;
-- Charge links already created today when upgrading, without deleting old links.
insert into public.short_link_daily_usage(user_id,day,bytes)
 select l.user_id,(clock_timestamp() at time zone 'UTC')::date,
 least(500000,sum(octet_length(o.payload::text)))::integer
 from public.short_links l join public.recording_objects o on o.hash=l.recording_hash
 where l.created_at>=date_trunc('day',clock_timestamp() at time zone 'UTC') at time zone 'UTC'
 group by l.user_id;

create function public.database_storage_bytes() returns bigint language sql volatile security definer set search_path='' as $$
 select pg_catalog.pg_database_size(pg_catalog.current_database());
$$;
create function public.check_database_capacity(incoming bigint default 0) returns void language plpgsql security definer set search_path='' as $$
begin
 -- A conservative reserve for the incoming tuple, indexes/TOAST, and page allocation.
 if public.database_storage_bytes()+greatest(coalesce(incoming,0),0)*3+1000000>350000000 then
  raise exception 'Database storage is nearly full. New saves are paused; existing recordings are still accessible.';
 end if;
end; $$;
create function public.guard_database_write() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='UPDATE' and pg_catalog.pg_column_size(new)<pg_catalog.pg_column_size(old) then return new; end if;
 perform public.check_database_capacity(pg_catalog.pg_column_size(new));return new;
end; $$;
-- Catch metadata growth as well as large payloads. DELETE/cleanup stays available.
create trigger profiles_storage_guard before insert or update on public.profiles for each row execute function public.guard_database_write();
create trigger attempts_storage_guard before insert or update on public.attempts for each row execute function public.guard_database_write();
create trigger submissions_storage_guard before insert or update on public.submissions for each row execute function public.guard_database_write();
create trigger short_links_storage_guard before insert or update on public.short_links for each row execute function public.guard_database_write();
create trigger recording_objects_storage_guard before insert or update on public.recording_objects for each row execute function public.guard_database_write();
create trigger daily_usage_storage_guard before insert or update on public.short_link_daily_usage for each row execute function public.guard_database_write();
create trigger login_limits_storage_guard before insert or update on public.login_limits for each row execute function public.guard_database_write();

create or replace function public.check_recording_quota(incoming bigint) returns void language plpgsql security definer set search_path='' as $$
declare used bigint;
begin
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 select coalesce(sum(octet_length(payload::text)),0) into used from public.recording_objects;
 if used+greatest(coalesce(incoming,0),0)>100000000 then raise exception 'Recording storage is temporarily full'; end if;
 perform public.check_database_capacity(incoming);
end; $$;
create or replace function public.create_short_link(replay jsonb) returns text language plpgsql security definer set search_path='' as $$
declare result text; fingerprint text; incoming integer; used integer; today date;
begin
 if auth.uid() is null then raise exception 'Sign in to create a temporary link'; end if;
 if (replay->>'format') is distinct from 'fto-replay-v1' or (replay->>'size') is distinct from '3' or (replay->>'complete') is distinct from 'true' or octet_length(replay::text)>2000000 then raise exception 'Only complete 3×3 recordings up to 2 MB can use short links'; end if;
 perform 1 from public.profiles where id=auth.uid() for update;
 if not found then raise exception 'Choose a username first'; end if;
 -- Serialize same-account and cross-account uploads using the existing lock order.
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 fingerprint:=public.recording_fingerprint(replay);
 select id into result from public.short_links where recording_hash=fingerprint and expires_at>now();
 -- Reading/reusing an active link is free, even when quotas are full. Its expiry stays fixed.
 if result is not null then return result; end if;
 incoming:=octet_length(replay::text);
 today:=(clock_timestamp() at time zone 'UTC')::date;
 select case when day=today then bytes else 0 end into used from public.short_link_daily_usage where user_id=auth.uid();
 if coalesce(used,0)+incoming>500000 then
  raise exception 'Daily short-link limit reached (500 kB per account). Resets at 00:00 UTC. You can still copy the full link, text or JSON.';
 end if;
 delete from public.short_links where expires_at<=now();
 perform public.collect_recordings();
 if (select count(*) from public.short_links where user_id=auth.uid())>=20 then raise exception 'Limit: 20 active temporary links per account'; end if;
 if (select count(*) from public.short_links)>=1000 then raise exception 'Temporary link storage is full'; end if;
 result:=left(fingerprint,32);
 fingerprint:=public.store_recording(replay,false);
 insert into public.short_links(id,recording_hash,user_id) values(result,fingerprint,auth.uid());
 -- Same transaction as the link: failures consume no quota; deleting/expiring a
 -- link does not refund today's usage. One bounded row per account, not an upload log.
 insert into public.short_link_daily_usage(user_id,day,bytes) values(auth.uid(),today,incoming)
 on conflict(user_id) do update set day=excluded.day,bytes=coalesce(used,0)+excluded.bytes;
 return result;
end; $$;
create function public.storage_status() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not public.is_admin() and current_setting('request.jwt.claim.role',true) is distinct from 'service_role' and (coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb->>'role') is distinct from 'service_role' then raise exception 'Administrator access required'; end if;
 return jsonb_build_object('database_bytes',public.database_storage_bytes(),'database_write_stop_bytes',350000000,
 'recording_payload_bytes',(select coalesce(sum(octet_length(payload::text)),0) from public.recording_objects),
 'recording_payload_limit_bytes',100000000,'daily_short_link_limit_bytes',500000);
end; $$;
revoke all on function public.database_storage_bytes(),public.check_database_capacity(bigint),public.guard_database_write(),public.storage_status() from public,anon,authenticated;
grant execute on function public.storage_status() to authenticated,service_role;
-- CREATE OR REPLACE keeps the existing authenticated-only short-link RPC grant.
