-- Account aliases preserve each Supabase login. App ownership resolves to one
-- canonical profile; auth.users/identities are never moved, edited or deleted.
create table public.account_members (
 auth_user_id uuid primary key references auth.users on delete cascade,
 profile_id uuid not null references public.profiles on delete cascade,
 merged_at timestamptz not null default clock_timestamp()
);
create index account_members_profile on public.account_members(profile_id);
create table public.merge_blocked_sessions (
 session_id uuid primary key,
 auth_user_id uuid not null references auth.users on delete cascade,
 created_at timestamptz not null default clock_timestamp()
);
create table public.account_merge_requests (
 id uuid primary key default gen_random_uuid(), actor uuid not null references auth.users on delete cascade,
 primary_identity uuid not null references auth.users on delete cascade,
 secondary_identity uuid not null references auth.users on delete cascade,
 primary_profile uuid not null references auth.users on delete cascade,
 secondary_profile uuid not null references auth.users on delete cascade,
 preview jsonb not null, created_at timestamptz not null default clock_timestamp(),
 expires_at timestamptz not null default clock_timestamp()+interval '5 minutes',
 completed_at timestamptz, result jsonb
);
create index account_merge_requests_actor on public.account_merge_requests(actor,created_at);
alter table public.account_members enable row level security;
alter table public.merge_blocked_sessions enable row level security;
alter table public.account_merge_requests enable row level security;
revoke all on public.account_members,public.merge_blocked_sessions,public.account_merge_requests from public,anon,authenticated;
create trigger account_members_storage_guard before insert or update on public.account_members for each row execute function public.guard_database_write();
create trigger merge_sessions_storage_guard before insert or update on public.merge_blocked_sessions for each row execute function public.guard_database_write();
create trigger merge_requests_storage_guard before insert or update on public.account_merge_requests for each row execute function public.guard_database_write();

create function public.root_account(identity_id uuid) returns uuid language sql stable security definer set search_path='' as $$
 select coalesce((select profile_id from public.account_members where auth_user_id=identity_id),identity_id);
$$;
create function public.account_uid() returns uuid language plpgsql stable security definer set search_path='' as $$
declare identity_id uuid:=auth.uid(); claims jsonb:=coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb; current_session uuid;
begin
 if identity_id is null then return null; end if;
 if exists(select 1 from public.account_members where auth_user_id=identity_id) then
  begin current_session:=(claims->>'session_id')::uuid; exception when invalid_text_representation then return null; end;
  if current_session is null or not exists(select 1 from auth.sessions s where s.id=current_session and s.user_id=identity_id) or exists(select 1 from public.merge_blocked_sessions b where b.session_id=current_session) then return null; end if;
 end if;
 return public.root_account(identity_id);
end; $$;
-- Resolve every existing app RPC at the authorization boundary. Preserve each
-- function's grants and security properties. Do not modify Supabase Auth itself.
do $$ declare f record; definition text; begin
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prokind='f' and p.proname not in ('account_uid','root_account')
 loop
  definition:=pg_get_functiondef(f.oid);
  if definition like '%auth.uid()%' then execute replace(definition,'auth.uid()','public.account_uid()'); end if;
 end loop;
end $$;

-- Family lookups start from the indexed membership table, not a per-row
-- resolver over the whole Auth users/identities tables.
create function public.account_login_ids(owner uuid) returns table(id uuid) language sql stable security definer set search_path='' as $$
 select owner union select auth_user_id from public.account_members where profile_id=owner;
$$;
create or replace function public.profile_wca(owner uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('wca_connected',i.id is not null,
 'wca_id',case when i.id is not null then case when i.identity_data->'custom_claims'->>'wca_id' ~ '^[0-9]{4}[A-Z]{4}[0-9]{2}$' then i.identity_data->'custom_claims'->>'wca_id' end else p.wca_id end,
 'wca_verified',coalesce(i.id is not null and i.identity_data->'custom_claims'->>'wca_id' ~ '^[0-9]{4}[A-Z]{4}[0-9]{2}$',false),
 'wca_name',case when i.id is not null then coalesce(i.identity_data->>'full_name',i.identity_data->>'name') end)
 from public.profiles p left join lateral (
  select id,identity_data from auth.identities where user_id in(select id from public.account_login_ids(owner)) and provider='custom:wca' order by created_at desc limit 1
 ) i on true where p.id=owner;
$$;
create function public.account_logins(owner uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('provider',i.provider,'email',case when u.email_confirmed_at is not null then u.email end) order by i.provider,u.id),'[]')
 from auth.identities i join auth.users u on u.id=i.user_id where i.user_id in(select id from public.account_login_ids(owner));
$$;
create or replace function public.my_profile() returns jsonb language sql stable security definer set search_path='' as $$
 select case when auth.uid() is not null and public.account_uid() is null then '{"reauth_required":true}'::jsonb else (
 select jsonb_build_object('id',p.id,'username',p.username,'admin',public.is_admin(),'logins',public.account_logins(p.id))||public.profile_wca(p.id)
 from public.profiles p where p.id=public.account_uid()) end;
$$;
create or replace function public.set_wca_id(wca_id text default null) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if public.account_uid() is null then raise exception 'Sign in again to update your profile'; end if;
 perform 1 from public.profiles where id=public.account_uid() for update;
 if not found then raise exception 'Choose a username first'; end if;
 if (public.profile_wca(public.account_uid())->>'wca_connected')::boolean then raise exception 'Your connected WCA account determines your WCA ID'; end if;
 wca_id:=nullif(upper(trim(wca_id)),'');
 if wca_id is not null and wca_id !~ '^[0-9]{4}[A-Z]{4}[0-9]{2}$' then raise exception 'Use a WCA ID such as 2024ASHR02, or leave it empty'; end if;
 update public.profiles p set wca_id=set_wca_id.wca_id where p.id=public.account_uid();return public.my_profile();
end; $$;
create function public.merge_features() returns jsonb language sql stable as $$select '{"version":1}'::jsonb$$;

-- Keep trusted legacy recording attribution/hash intact while recognizing its
-- original solver UUID as a member of the merged profile.
create function public.recording_solver_owner(payload jsonb) returns uuid language plpgsql stable security definer set search_path='' as $$
begin return public.root_account((payload->'solver'->>'id')::uuid); exception when invalid_text_representation then return null; end; $$;
do $$ declare f record; definition text; begin
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='inspect_leaderboard_recovery'
 loop
  definition:=pg_get_functiondef(f.oid);
  definition:=replace(definition,$needle$id::text=payload->'solver'->>'id'$needle$,'id=public.recording_solver_owner(payload)');
  definition:=replace(definition,$needle$payload->'solver'->>'id'<>owner::text$needle$,'public.recording_solver_owner(payload) is distinct from owner');
  execute definition;
 end loop;
end $$;

create function public.account_merge_summary(owner uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',owner,'username',(select username from public.profiles where id=owner),'logins',public.account_logins(owner),
 'submissions',(select count(*) from public.submissions where user_id=owner and status<>'draft'),
 'approved',(select count(*) from public.submissions where user_id=owner and status='approved'),
 'pending',(select count(*) from public.submissions where user_id=owner and status='pending'),
 'held',(select count(*) from public.submissions where user_id=owner and status='investigating'),
 'links',(select count(*) from public.short_links where user_id=owner),
 'attempts',(select count(*) from public.attempts where user_id=owner),
 'notifications',(select count(*) from public.submission_notifications where user_id=owner),
 'usage_today',coalesce((select bytes from public.short_link_daily_usage where user_id=owner and day=(clock_timestamp() at time zone 'UTC')::date),0))||coalesce(public.profile_wca(owner),'{"wca_connected":false,"wca_id":null,"wca_verified":false}'::jsonb);
$$;
create function public.prepare_account_merge(actor uuid,primary_identity uuid,secondary_identity uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare a uuid:=public.root_account(primary_identity);b uuid:=public.root_account(secondary_identity); snapshot jsonb;ticket uuid;
begin
 if actor is null or public.root_account(actor) is distinct from a then raise exception 'Verify the account you are currently using';end if;
 if a is null or b is null or a=b then raise exception 'These sign-ins already use the same FTOers profile';end if;
 if not exists(select 1 from auth.users where id=secondary_identity) or not exists(select 1 from public.profiles where id=a) then raise exception 'Account unavailable';end if;
 if (select count(*) from auth.identities where user_id in(select id from public.account_login_ids(a) union select id from public.account_login_ids(b)) and provider='custom:wca')>1 then raise exception 'These profiles use different WCA accounts. Contact Abid before merging them';end if;
 if (select count(*) from public.account_merge_requests where prepare_account_merge.actor=account_merge_requests.actor and created_at>now()-interval '1 hour')>=10 then raise exception 'Too many merge previews. Try again later';end if;
 snapshot:=jsonb_build_object('primary',public.account_merge_summary(a),'secondary',public.account_merge_summary(b));
 insert into public.account_merge_requests(actor,primary_identity,secondary_identity,primary_profile,secondary_profile,preview)
 values(actor,primary_identity,secondary_identity,a,b,snapshot) returning id into ticket;
 return snapshot||jsonb_build_object('ticket',ticket,'expires_in',300);
end; $$;
-- Superseded pending offers are archived, never converted to an administrator
-- rejection. Reviewed/rejected/held records and their notes remain untouched.
alter table public.submissions drop constraint submissions_status_check;
alter table public.submissions add constraint submissions_status_check check(status in('draft','pending','investigating','approved','rejected','superseded'));
create function public.complete_account_merge(actor uuid,primary_identity uuid,secondary_identity uuid,ticket uuid,keep text) returns jsonb language plpgsql security definer set search_path='' as $$
declare request public.account_merge_requests;dest uuid;source uuid;members uuid[];snapshot jsonb;used integer;today date:=(clock_timestamp() at time zone 'UTC')::date;had_admin boolean;outcome jsonb;
begin
 perform pg_catalog.pg_advisory_xact_lock(83192812);
 select * into request from public.account_merge_requests where id=ticket for update;
 if request.id is null or request.actor is distinct from actor or request.primary_identity is distinct from primary_identity or request.secondary_identity is distinct from secondary_identity then raise exception 'Merge verification is missing. Start again';end if;
 if request.completed_at is not null then return request.result;end if;
 if request.expires_at<clock_timestamp() then raise exception 'Merge preview expired. Verify both accounts again';end if;
 if keep not in('primary','secondary') then raise exception 'Choose the profile to keep';end if;
 if public.root_account(primary_identity) is distinct from request.primary_profile or public.root_account(secondary_identity) is distinct from request.secondary_profile or public.root_account(actor) is distinct from request.primary_profile then raise exception 'Account membership changed. Start again';end if;
 dest:=case when keep='primary' then request.primary_profile else request.secondary_profile end;
 source:=case when keep='primary' then request.secondary_profile else request.primary_profile end;
 perform 1 from public.profiles where id in(dest,source) order by id for update;
 if not exists(select 1 from public.profiles where id=dest) then raise exception 'Choose the existing profile with a username';end if;
 snapshot:=jsonb_build_object('primary',public.account_merge_summary(request.primary_profile),'secondary',public.account_merge_summary(request.secondary_profile));
 if snapshot is distinct from request.preview then raise exception 'Account data changed. Review a new merge preview';end if;
 select array_agg(id) into members from (select id from public.account_login_ids(dest) union select id from public.account_login_ids(source)) family;
 if (select count(*) from auth.identities where user_id=any(members) and provider='custom:wca')>1 then raise exception 'Different WCA accounts cannot be merged automatically';end if;
 select exists(select 1 from public.admins where user_id=any(members)) or exists(select 1 from auth.users where id=any(members) and email_confirmed_at is not null and lower(email)='abid.ibn.ashraf@gmail.com') into had_admin;
 -- Block every existing session, including the two verification sessions. A
 -- fresh sign-in gets a new session UUID. Refreshing an old token cannot gain
 -- access to the other profile after a merge.
 insert into public.merge_blocked_sessions(session_id,auth_user_id) select id,user_id from auth.sessions where user_id=any(members) on conflict do nothing;
 -- Old retired names remain reserved and available for legacy username login.
 insert into public.account_members(auth_user_id,profile_id) select unnest(members),dest on conflict(auth_user_id) do update set profile_id=excluded.profile_id,merged_at=clock_timestamp();
 if had_admin then insert into public.admins(user_id) values(dest) on conflict do nothing;end if;
 update public.profiles set wca_id=coalesce(wca_id,(select p.wca_id from public.profiles p where p.id=source)) where id=dest;
 update public.attempts set user_id=dest,session_id=gen_random_uuid() where user_id in(dest,source);
 update public.submissions set user_id=dest where user_id=source;
 delete from public.submissions where user_id=dest and status='draft';
 with ranked as (select id,row_number() over(partition by metric order by coalesce(submitted_at,created_at) desc,created_at desc,id desc) n from public.submissions where user_id=dest and status='pending')
 update public.submissions s set status='superseded' from ranked r where s.id=r.id and r.n>1;
 update public.short_links set user_id=dest where user_id=source;
 update public.submission_notifications set user_id=dest where user_id=source;
 select least(500000,coalesce(sum(bytes) filter(where day=today),0))::integer into used from public.short_link_daily_usage where user_id in(dest,source);
 delete from public.short_link_daily_usage where user_id in(dest,source);
 insert into public.short_link_daily_usage(user_id,day,bytes) values(dest,today,used);
 outcome:=jsonb_build_object('profile_id',dest,'username',(select username from public.profiles where id=dest),'sign_in_again',true);
 update public.account_merge_requests set completed_at=clock_timestamp(),result=outcome where id=ticket;
 return outcome;
end; $$;
create function public.prune_account_merge_requests() returns void language sql security definer set search_path='' as $$
 delete from public.account_merge_requests where completed_at is null and expires_at<now()-interval '1 day' or completed_at<now()-interval '30 days';
$$;
select cron.schedule('ftoers-merge-request-cleanup','37 * * * *','select public.prune_account_merge_requests()');
revoke all on function public.account_login_ids(uuid),public.root_account(uuid),public.account_logins(uuid),public.recording_solver_owner(jsonb),public.account_merge_summary(uuid),public.prepare_account_merge(uuid,uuid,uuid),public.complete_account_merge(uuid,uuid,uuid,uuid,text),public.prune_account_merge_requests(),public.account_uid(),public.merge_features() from public,anon,authenticated;
grant execute on function public.prepare_account_merge(uuid,uuid,uuid),public.complete_account_merge(uuid,uuid,uuid,uuid,text) to service_role;
grant execute on function public.account_uid(),public.merge_features() to anon,authenticated;
-- Username/password login still resolves when the chosen profile originally had
-- only WCA OAuth and the password identity belongs to its merged member.
create function public.username_login_email(name text) returns text language sql stable security definer set search_path='' as $$
 select u.email from public.profiles p join auth.users u on u.id in(select id from public.account_login_ids(public.root_account(p.id)))
 where lower(p.username)=lower(name) and u.email is not null and u.email<>''
 order by exists(select 1 from auth.identities i where i.user_id=u.id and i.provider='email') desc,(u.id=p.id) desc,u.id limit 1;
$$;
revoke all on function public.username_login_email(text) from public,anon,authenticated;
grant execute on function public.username_login_email(text) to service_role;
