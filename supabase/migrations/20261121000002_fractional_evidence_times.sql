-- High-resolution JS durations can lose a few decimal digits when float8 is
-- serialized into JSON evidence. Exact float equality wrongly hid valid results.
-- Allow at most one nanosecond (0.000001 ms) of round-trip error, while still
-- rejecting missing/nonfinite durations, changed times, pauses and undo evidence.
create or replace function public.leaderboard_evidence_available(refs jsonb,kind text) returns boolean language plpgsql stable security definer set search_path='' as $$
declare entry jsonb; object public.recording_objects; expected integer; duration double precision; dnfs integer:=0;
begin
 expected:=case kind when 'single' then 1 when 'ao5' then 5 when 'ao12' then 12 else 0 end;
 if expected=0 or refs is null or jsonb_typeof(refs)<>'array' or jsonb_array_length(refs)<>expected then return false; end if;
 for entry in select * from jsonb_array_elements(refs) loop
  if coalesce((entry->>'dnf')::boolean,false) then dnfs:=dnfs+1;if expected=1 or dnfs>1 then return false; end if;continue; end if;
  duration:=(entry->>'ms')::double precision;
  if duration is null or duration<=0 or duration>=86400000 then return false; end if;
  select * into object from public.recording_objects where hash=entry->>'recording_hash';
  if not found or not object.verified or (object.payload->>'format') is distinct from 'fto-replay-v1' or (object.payload->>'size') is distinct from '3' or (object.payload->>'complete') is distinct from 'true' or jsonb_typeof(object.payload->'events') is distinct from 'array' or ((abs((object.payload->>'solveMs')::double precision-duration)<=0.000001) is not true) or coalesce((object.payload->>'dnf')::boolean,false) or coalesce((object.payload->>'usedUndo')::boolean,false) or coalesce((object.payload->>'usedPause')::boolean,false) or exists(select 1 from jsonb_array_elements(object.payload->'events') e where e->>'type'='pause') then return false; end if;
 end loop;
 return true;
exception when invalid_text_representation or numeric_value_out_of_range then return false;
end; $$;
revoke all on function public.leaderboard_evidence_available(jsonb,text) from public,anon,authenticated;
