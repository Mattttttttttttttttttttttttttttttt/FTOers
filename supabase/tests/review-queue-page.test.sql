begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();
insert into auth.users(id,email,email_confirmed_at)
 select ('10000000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'solver'||i||'@example.invalid',now() from generate_series(1,132) i;
insert into public.profiles(id,username) select id,'Solver'||row_number() over(order by id) from auth.users;
insert into auth.users(id,email,email_confirmed_at) values('33333333-3333-4333-8333-333333333333','abid.ibn.ashraf@gmail.com',now());
insert into public.profiles(id,username) values('33333333-3333-4333-8333-333333333333','Owner');
insert into public.submissions(user_id,metric,ms,status,submitted_at,created_at)
 select id,'single',10000,case when row_number() over(order by id)<=105 then 'investigating' else 'pending' end,
 now()-interval '1 day',now()-interval '1 day' from public.profiles where username<>'Owner';
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',true);
select throws_ok($$select public.review_queue_page()$$,'P0001','Administrator access required','Solvers cannot read review pages');
select set_config('request.jwt.claim.sub','33333333-3333-4333-8333-333333333333',true);
create temp table pages as select public.review_queue_page() as first;
select is(jsonb_array_length(first->'rows'),25,'Active rows are filtered before the 25-row limit, despite 105 older held cases') from pages;
select is((first->'counts'->>'held')::int,105,'Counts include all held cases, not just the loaded page') from pages;
select is((first->>'has_more')::boolean,true,'A full page advertises its successor') from pages;
create temp table second as select public.review_queue_page('active','all',first->'next_cursor') as page from pages;
select is(jsonb_array_length(page->'rows'),2,'Keyset cursor handles tied timestamps without missing results') from second;
select is((page->>'has_more')::boolean,false,'The final page disables Next') from second;
select is((select count(distinct r->>'id')::int from (select jsonb_array_elements(first->'rows') r from pages union all select jsonb_array_elements(page->'rows') from second) q),27,'Pagination does not repeat IDs');
select is(jsonb_array_length(public.review_queue_page('held','all')->'rows'),25,'Held cases remain independently accessible');
select is(jsonb_array_length(public.review_queue_page('all','ao5')->'rows'),0,'Category filtering happens on the server');
set local role anon;
select throws_ok($$select public.review_queue_page()$$,'42501',null,'Anonymous callers cannot read private review metadata');
select * from finish();
rollback;
