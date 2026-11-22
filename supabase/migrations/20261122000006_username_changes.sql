-- Rename the canonical profile; login identities and historical recordings keep
-- their stable IDs. The existing lower(username) unique index handles races.
create function public.rename_username(name text) returns jsonb language plpgsql security definer set search_path='' as $$
declare owner uuid:=public.account_uid();
begin
 if owner is null then raise exception 'Sign in again to change your username';end if;
 name:=trim(name);
 if name is null or name !~ '^[A-Za-z0-9_]{3,24}$' then raise exception 'Use 3–24 letters, numbers or underscores';end if;
 perform 1 from public.profiles where id=owner for update;
 if not found then raise exception 'Choose a username first';end if;
 update public.profiles p set username=name where p.id=owner;
 return public.my_profile();
exception when unique_violation then raise exception 'Username already taken';
end; $$;
revoke all on function public.rename_username(text) from public,anon,authenticated;
grant execute on function public.rename_username(text) to authenticated;
