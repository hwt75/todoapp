-- Epic 4 retrospective (2026-08-27), action item 2 -- FR-14's "restricted to items dated the
-- claimed day" (epic-4-context.md's own UX section; EXPERIENCE.md: "an old photo proves
-- nothing") had no enforcement anywhere. `appeal_evidence` carried only `id, appeal_id,
-- owner_id, storage_path, created_at` -- no fact about when the evidence was itself captured
-- -- and neither the client (`components/appeal-form.tsx`'s file input) nor any trigger ever
-- checked one. Not recorded in `deferred-work.md` either; this reads as silently dropped
-- rather than knowingly deferred.
--
-- `captured_on` is nullable at the column level (there is no way to backfill a real capture
-- date for any evidence object already in Storage, and this schema follows every other table
-- here in never editing a past migration to force one in) -- the rule is enforced by the
-- trigger below refusing any *new* insert that omits it or names a day other than the
-- appeal's own `for_day`, not by a `not null` constraint that would block on historical rows.

alter table public.appeal_evidence
  add column captured_on date;

comment on column public.appeal_evidence.captured_on is
  'FR-14: the calendar date (Asia/Ho_Chi_Minh) the client read off the evidence file''s own '
  '`lastModified` before upload -- not EXIF, since this codebase has no EXIF-parsing '
  'dependency; a real but accepted limitation (see lib/appeal.ts''s own fileCapturedOn '
  'comment). Nullable for rows that predate this column; appeal_evidence_derive_owner() '
  'refuses any new insert that omits it or names a day other than the parent appeal''s own '
  'for_day.';

create or replace function public.appeal_evidence_derive_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_for_day date;
begin
  select owner_id, for_day into v_owner, v_for_day
    from public.appeal where id = new.appeal_id;

  if not found then
    raise exception 'Evidence does not reference an appeal that exists.';
  end if;

  if new.captured_on is null or new.captured_on <> v_for_day then
    raise exception 'Evidence must be dated the day being appealed.';
  end if;

  new.owner_id := v_owner;
  return new;
end;
$$;

comment on function public.appeal_evidence_derive_owner() is
  'before insert security definer trigger on public.appeal_evidence. Overwrites owner_id '
  'with the referenced appeal''s own owner_id, so a client can never attach evidence it does '
  'not own by sending a different value. FR-14, added 2026-08-27: also refuses any insert '
  'whose captured_on is missing or does not match the appeal''s own for_day -- an old or '
  'unrelated photo is refused server-side even if a client skipped its own check.';
