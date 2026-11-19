create table public.login_limits (key text primary key,window_start timestamptz not null default now(),hits integer not null default 1);
alter table public.login_limits enable row level security;
revoke all on public.login_limits from anon,authenticated;
create function public.allow_username_login(ip_hash text) returns boolean language plpgsql security definer set search_path='' as $$
declare attempts integer;
begin
 delete from public.login_limits where window_start<now()-interval '15 minutes';
 insert into public.login_limits(key) values(ip_hash) on conflict(key) do update set hits=public.login_limits.hits+1 returning hits into attempts;
 return attempts<=20;
end; $$;
revoke all on function public.allow_username_login(text) from public,anon,authenticated;
grant execute on function public.allow_username_login(text) to service_role;
-- Service role access is used only inside the username-login function.
grant select on public.profiles to service_role;
