-- Archived duplicate pending offers retain their result/review metadata, but
-- their recording references follow the same 30-day submitted-evidence limit.
-- Keep this in the merge cleanup function so later review/pruning updates do
-- not accidentally make merge archives permanent recording storage.
create or replace function public.prune_account_merge_requests() returns void language plpgsql security definer set search_path='' as $$
begin
 delete from public.account_merge_requests where completed_at is null and expires_at<now()-interval '1 day' or completed_at<now()-interval '30 days';
 update public.submissions set evidence_refs=null where status='superseded' and evidence_refs is not null and coalesce(submitted_at,created_at)<now()-interval '30 days';
 perform public.collect_recordings();
end; $$;
