-- Manually entered IDs are claims, not proof of ownership. Verified identity
-- comes exclusively from Supabase Auth's custom:wca OAuth identity.
alter table public.profiles add column wca_id text check(wca_id ~ '^[0-9]{4}[A-Z]{4}[0-9]{2}$');
create function public.profile_wca(owner uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
  'wca_connected',i.id is not null,
  'wca_id',case when i.id is not null then case when i.identity_data->'custom_claims'->>'wca_id' ~ '^[0-9]{4}[A-Z]{4}[0-9]{2}$' then i.identity_data->'custom_claims'->>'wca_id' end else p.wca_id end,
  'wca_verified',coalesce(i.id is not null and i.identity_data->'custom_claims'->>'wca_id' ~ '^[0-9]{4}[A-Z]{4}[0-9]{2}$',false),
  'wca_name',case when i.id is not null then coalesce(i.identity_data->>'full_name',i.identity_data->>'name') end)
 from public.profiles p left join lateral (
  select id,identity_data from auth.identities where user_id=p.id and provider='custom:wca' order by created_at desc limit 1
 ) i on true where p.id=owner;
$$;
revoke all on function public.profile_wca(uuid) from public,anon,authenticated;
create or replace function public.my_profile() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',p.id,'username',p.username,'admin',public.is_admin())||public.profile_wca(p.id) from public.profiles p where p.id=auth.uid();
$$;
create function public.set_wca_id(wca_id text default null) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 perform 1 from public.profiles where id=auth.uid() for update;
 if not found then raise exception 'Choose a username first'; end if;
 if exists(select 1 from auth.identities where user_id=auth.uid() and provider='custom:wca') then raise exception 'Your connected WCA account determines your WCA ID'; end if;
 wca_id:=nullif(upper(trim(wca_id)),'');
 if wca_id is not null and wca_id !~ '^[0-9]{4}[A-Z]{4}[0-9]{2}$' then raise exception 'Use a WCA ID such as 2024ASHR02, or leave it empty'; end if;
 update public.profiles p set wca_id=set_wca_id.wca_id where p.id=auth.uid();
 return public.my_profile();
end; $$;
create function public.claim_profile(name text,wca_id text default null) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform public.claim_username(name);
 if exists(select 1 from auth.identities where user_id=auth.uid() and provider='custom:wca') then return public.my_profile();end if;
 return public.set_wca_id(wca_id);
end; $$;
create function public.leaderboard_profiles(kind text default 'single') returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(l)||public.profile_wca(s.user_id) order by l.ms,l.created_at),'[]'::jsonb)
 from public.leaderboard(kind) l join public.submissions s on s.id=l.id;
$$;
revoke all on function public.set_wca_id(text),public.claim_profile(text,text),public.leaderboard_profiles(text) from public,anon,authenticated;
grant execute on function public.set_wca_id(text),public.claim_profile(text,text) to authenticated;
grant execute on function public.leaderboard_profiles(text) to anon,authenticated;
