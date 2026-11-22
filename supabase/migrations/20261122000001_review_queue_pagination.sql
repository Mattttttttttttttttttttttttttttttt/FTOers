-- Filter before limiting: held cases cannot starve the active review queue.
create index if not exists submissions_review_page_idx on public.submissions
  (status, (coalesce(submitted_at,created_at)),created_at,id)
  where status in ('pending','investigating');
create function public.review_queue_page(review_state text default 'active', category text default 'all', after_cursor jsonb default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not public.is_admin() then raise exception 'Administrator access required'; end if;
 if review_state not in ('active','held','all') or category not in ('all','single','ao5','ao12') then raise exception 'Invalid review filter'; end if;
 with filtered as (
  select s.id,p.username,s.metric,s.ms,s.status,s.created_at,s.submitted_at,s.investigation_note,s.investigation_at,
    coalesce(s.submitted_at,s.created_at) as sort_at
  from public.submissions s join public.profiles p on p.id=s.user_id
  where s.status in ('pending','investigating')
    and (review_state='all' or s.status=case when review_state='held' then 'investigating' else 'pending' end)
    and (category='all' or s.metric=category)
 ), page as (
  select * from filtered where after_cursor is null or (sort_at,created_at,id) >
    ((after_cursor->>'sort_at')::timestamptz,(after_cursor->>'created_at')::timestamptz,(after_cursor->>'id')::uuid)
  order by sort_at,created_at,id limit 26
 ), numbered as (select *,row_number() over(order by sort_at,created_at,id) as n from page)
 select jsonb_build_object(
   'rows',coalesce((select jsonb_agg(to_jsonb(q)-'n'-'sort_at' order by n) from numbered q where n<=25),'[]'::jsonb),
   'has_more',(select count(*)>25 from numbered),
   'next_cursor',(select jsonb_build_object('sort_at',sort_at,'created_at',created_at,'id',id) from numbered where n=25),
   'counts',jsonb_build_object('pending',(select count(*) from public.submissions where status='pending'),
                             'held',(select count(*) from public.submissions where status='investigating')))
 into result;
 return result;
end; $$;
revoke all on function public.review_queue_page(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.review_queue_page(text,text,jsonb) to authenticated;
