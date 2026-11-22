-- Private in-app decision notifications: bounded to 50/account and 90 days.
create table public.submission_notifications (
 id bigint generated always as identity primary key,
 user_id uuid not null references public.profiles on delete cascade,
 submission_id uuid unique references public.submissions on delete set null,
 metric text not null check(metric in ('single','ao5','ao12')),
 ms double precision not null,
 decision text not null check(decision in ('approved','rejected')),
 note text not null default '' check(length(note)<=500),
 created_at timestamptz not null default clock_timestamp(),
 read_at timestamptz
);
create index submission_notifications_owner on public.submission_notifications(user_id,created_at desc,id desc);
alter table public.submission_notifications enable row level security;
revoke all on public.submission_notifications from public,anon,authenticated;
create trigger notifications_storage_guard before insert or update on public.submission_notifications for each row execute function public.guard_database_write();
insert into public.submission_notifications(user_id,submission_id,metric,ms,decision,note,created_at)
 -- Historical review notes were not labelled as messages to the solver.
 select user_id,id,metric,ms,status,'',reviewed_at from (
 select s.*,row_number() over(partition by user_id order by reviewed_at desc,id) rank from public.submissions s where status in ('approved','rejected') and reviewed_at>now()-interval '90 days'
 ) recent where rank<=50;
create function public.my_submission_notifications() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(row_to_json(n) order by n.created_at desc,n.id desc),'[]') from (
 select id,metric,ms,decision,note,created_at,read_at from public.submission_notifications where user_id=auth.uid() and created_at>now()-interval '90 days' order by created_at desc,id desc limit 50
 ) n;
$$;
create function public.mark_submission_notifications_read(ids bigint[]) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in to read notifications'; end if;
 if coalesce(cardinality(ids),0)>50 then raise exception 'Select at most 50 notifications'; end if;
 update public.submission_notifications set read_at=clock_timestamp() where user_id=auth.uid() and id=any(ids) and read_at is null;
end; $$;
create function public.prune_submission_notifications() returns void language sql security definer set search_path='' as $$
 delete from public.submission_notifications where created_at<now()-interval '90 days';
 delete from public.submission_notifications n using (
 select id,row_number() over(partition by user_id order by created_at desc,id desc) rank from public.submission_notifications
 ) ranked where n.id=ranked.id and ranked.rank>50;
$$;
alter function public.prune_recordings() rename to prune_recording_data;
create function public.prune_recordings() returns void language plpgsql security definer set search_path='' as $$
begin
 perform public.prune_recording_data();
 perform public.prune_submission_notifications();
end; $$;
create or replace function public.review_submission(submission uuid,approve boolean,note text default '') returns void language plpgsql security definer set search_path='' as $$
declare reviewed public.submissions;
begin
 if not public.is_admin() then raise exception 'Administrator access required'; end if;
 perform pg_catalog.pg_advisory_xact_lock(83192811);
 update public.submissions set status=case when approve then 'approved' else 'rejected' end,reviewed_at=clock_timestamp(),reviewed_by=auth.uid(),review_note=left(coalesce(note,''),500) where id=submission and status='pending' returning * into reviewed;
 if not found then raise exception 'Pending submission not found'; end if;
 insert into public.submission_notifications(user_id,submission_id,metric,ms,decision,note,created_at) values(reviewed.user_id,reviewed.id,reviewed.metric,reviewed.ms,reviewed.status,reviewed.review_note,reviewed.reviewed_at);
 perform public.prune_recordings();
end; $$;
revoke all on function public.my_submission_notifications(),public.mark_submission_notifications_read(bigint[]),public.prune_submission_notifications(),public.prune_recording_data(),public.prune_recordings() from public,anon,authenticated;
grant execute on function public.my_submission_notifications(),public.mark_submission_notifications_read(bigint[]) to authenticated;
