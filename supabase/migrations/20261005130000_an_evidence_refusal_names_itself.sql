-- An evidence refusal names itself.
--
-- Deferred from epic-6 retro item 42's spec. Every refusal `evidence_derive_owner()` and
-- `evidence_object_must_exist()` raise is a plain P0001, and `components/today.tsx` rendered its
-- message verbatim as the reason a photo was not saved: database English, with a raw ISO date in
-- it, on a screen whose every other sentence lives in `EVIDENCE_COPY`. The entry asked for copy
-- keyed off the failure, not off the message, and nothing on the wire identified the failure except
-- the message.
--
-- So each refusal now carries a stable `hint` -- `evidence:no-parent`, `evidence:day-ended`,
-- `evidence:not-today`, `evidence:wrong-capture-date`, `evidence:no-object` -- which PostgREST
-- returns as the error's `hint` field. The client maps a hint it knows to its own sentence, and a
-- hint it does not know still shows the server's words, so a new refusal is never silent.
--
-- **Messages unchanged, word for word.** Every SQL file that asserts a refusal reads the message
-- with `ilike`, and they pass untouched. Both bodies are otherwise verbatim:
--   evidence_derive_owner()        20260903120000:110-198
--   evidence_object_must_exist()   20260910090000:54-82
-- `create or replace` keeps each function's comment and ACL; the revokes are re-issued anyway.

create or replace function public.evidence_derive_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner   uuid;
  v_for_day date;
  v_today   date;
begin
  if new.appeal_id is not null then
    select owner_id, for_day into v_owner, v_for_day
      from public.appeal where id = new.appeal_id;

    if not found then
      raise exception 'Evidence does not reference an appeal that exists.'
        using hint = 'evidence:no-parent';
    end if;
  elsif new.declaration_id is not null then
    select owner_id, for_day into v_owner, v_for_day
      from public.declaration where id = new.declaration_id;

    if not found then
      raise exception 'Evidence does not reference a claim that exists.'
        using hint = 'evidence:no-parent';
    end if;

    -- Midnight is the deadline, and there is nothing after it (SPEC.md). Enforced here, at
    -- the moment of the upload, rather than left for settlement to discover -- the same call
    -- Story 6.2 made about a late tap, for the same reason: refusing at the moment of the act
    -- is legible, and silently accepting something that will not count is not.
    --
    -- Deliberately NOT applied to an appeal above. An appeal contests a day that has already
    -- closed and lives on its own deadline; binding its evidence to the midnight of the day it
    -- proves would break a path that works today.
    v_today := (now() at time zone 'Asia/Ho_Chi_Minh')::date;

    if v_today > v_for_day then
      raise exception
        'A claim can only be proved on the day it was made. That day (%) has ended.', v_for_day
        using hint = 'evidence:day-ended';
    end if;
  else
    -- Story 6.8. The parent is a commitment and a day, and the day is on this row rather than
    -- on the parent -- a commitment is not a day, so `for_day` is the half it cannot supply.
    select owner_id into v_owner
      from public.commitment where id = new.commitment_id;

    if not found then
      raise exception 'Evidence does not reference a commitment that exists.'
        using hint = 'evidence:no-parent';
    end if;

    v_for_day := new.for_day;

    -- The declaration branch's own midnight rule, reused rather than rewritten: the control is
    -- offered for the whole of the commitment's local day and closes with it, and a day already
    -- ended takes no further evidence. Nothing settles differently either way -- this exists so
    -- the store cannot quietly accumulate a record of days the author never actually kept, which
    -- is the same reason Story 6.2 refuses a late tap instead of filing it.
    --
    -- `<>` rather than the declaration branch's `>`, and the difference is not a preference.
    -- There, `for_day` is derived server-side by `declaration_derive_day()` and can never be in
    -- the future, so `>` is already the whole rule. Here it is a client-sent column, and the
    -- capture-date rule below is no defence against a forward-dated one: `captured_on` comes
    -- from the client too, read off the file's own `lastModified` (lib/evidence.ts), which is
    -- trivially set to any date at all. A day is the day the photo is kept on, both ends.
    v_today := (now() at time zone 'Asia/Ho_Chi_Minh')::date;

    if v_today <> v_for_day then
      raise exception
        'A photo can only be kept on the day it belongs to, and today is not %.', v_for_day
        using hint = 'evidence:not-today';
    end if;
  end if;

  -- FR-14, unchanged since 20260827100000: an old photo proves nothing. `captured_on` is read
  -- from the file's own `lastModified` rather than from EXIF (see lib/evidence.ts), which is a
  -- real and accepted limitation -- enough to refuse an evidently unrelated file, not a
  -- cryptographic proof of when a photo was taken.
  if new.captured_on is null or new.captured_on <> v_for_day then
    raise exception 'Evidence must be dated the day it proves.'
      using hint = 'evidence:wrong-capture-date';
  end if;

  -- Never client-sent. This is the exact fact the bucket's storage.objects policies depend on
  -- (NFR4): access derives from the parent's own owner_id, which only holds if a client cannot
  -- claim a different one. It is also what refuses a foreign parent without any application
  -- check: the derived owner is the parent's, so `evidence: file own`'s `auth.uid() = owner_id`
  -- fails on the way out.
  new.owner_id := v_owner;
  return new;
end;
$$;

revoke execute on function public.evidence_derive_owner() from public, anon, authenticated;

create or replace function public.evidence_object_must_exist()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- A row with no path at all is the NOT NULL constraint's refusal to make, not this trigger's.
  -- A BEFORE ROW trigger runs ahead of every constraint, so without this line an omitted
  -- storage_path would come back as P0001 "no object named  exists" instead of 23502 -- the same
  -- rule-stealing this trigger's own ordering comment exists to avoid.
  if new.storage_path is null then
    return new;
  end if;

  if not exists (
    select 1
      from storage.objects o
     where o.bucket_id = 'appeal-evidence'
       and o.name = new.storage_path
  ) then
    raise exception
      'Evidence must point at a photo that was really uploaded. No object named % exists in the '
      'appeal-evidence bucket.', new.storage_path
      using hint = 'evidence:no-object';
  end if;

  return new;
end;
$$;

revoke execute on function public.evidence_object_must_exist() from public, anon, authenticated;
