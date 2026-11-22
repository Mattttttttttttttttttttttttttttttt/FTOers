-- The merge release was approved before older engineering migrations. A later
-- full/--include-all release must run this final pass after those definitions
-- are installed, so their raw Auth IDs cannot split a merged profile again.
-- Leave this migration pending until those older updates are released.
do $$ declare f record; definition text; begin
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prokind='f' and p.proname not in ('account_uid','root_account','my_profile')
 loop
  definition:=pg_get_functiondef(f.oid);
  if definition like '%auth.uid()%' then execute replace(definition,'auth.uid()','public.account_uid()'); end if;
 end loop;
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='inspect_leaderboard_recovery'
 loop
  definition:=pg_get_functiondef(f.oid);
  definition:=replace(definition,$needle$id::text=payload->'solver'->>'id'$needle$,'id=public.recording_solver_owner(payload)');
  definition:=replace(definition,$needle$payload->'solver'->>'id'<>owner::text$needle$,'public.recording_solver_owner(payload) is distinct from owner');
  execute definition;
 end loop;
end $$;
