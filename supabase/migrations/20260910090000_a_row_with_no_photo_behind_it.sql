-- A row with no photo behind it.
--
-- Epic 6 retrospective, finding A1 (HIGH). A day is held on the bare existence of an `evidence`
-- row: `commitments_owing()` (20260829090000:324-330) and `weekly_held_count()` (:960-970) both
-- ask only `exists (select 1 from public.evidence ...)`, and the only shape check the row ever
-- faced was the string pattern `storage_path like (parent_id || '/%')` (20260903120000:97-102) --
-- a pattern, never a reference to `storage.objects`.
--
-- So attaching a photo and *claiming* to have attached one were the same act as far as the
-- database was concerned. One `POST /rest/v1/evidence` carrying a made-up path, with no upload at
-- all, settled the day `clean`, kept the chain and avoided the 500,000d penalty. The suite
-- certified it rather than catching it: three fixtures in `6-4-midnight-decides-the-day.sql`
-- planted exactly such a row and asserted `held`.
--
-- The two-part write already happens in the right order everywhere it happens -- object first,
-- row second (`components/today.tsx`, `components/appeal-form.tsx`, and the reason
-- `orphaned_evidence_objects()` exists at all is that the second half can fail after the first
-- succeeded). So the object is there to be found by the time the row is filed, and nothing about
-- the honest path changes. What changes is that the dishonest one now has to put something in the
-- bucket.


-- ---------------------------------------------------------------------------------
-- The gate.
-- ---------------------------------------------------------------------------------

/* ITS OWN TRIGGER, NOT A LINE INSIDE `evidence_derive_owner()`

   The obvious home for this is the trigger that already gates every insert. It is the wrong home.
   Fixtures disable `evidence_derive_owner` to plant rows for days that have ended -- that is how
   two of the three certifying rows in `6-4` were built -- and a rule folded into that function
   would switch off with it. A rule that money depends on must not be disableable by the same
   statement that turns off a convenience.

   INSERT ONLY, AND DELIBERATELY

   `20260908180000` removes the *bytes* of a photo after thirty days and keeps the row, because
   `commitments_owing()` reads the row's existence to decide whether a claimed day held: delete the
   rows and held days become slipped days and mint penalties nobody earned. Every such row is, by
   design, a row with no object behind it. So this rule holds at the moment of filing and never
   again -- no foreign key, no constraint, nothing that re-checks an old row. A foreign key here
   would have the retention sweep delete the evidence of days that were honestly proved.

   The pairing is `bucket_id` plus `name`, exactly as `orphaned_evidence_objects()`
   (20260907130000:47-53) states the same relationship from the other side. Two places deciding
   what "the object behind this row" means, agreeing by construction rather than by comment.

   WHAT THIS DOES NOT DO

   It does not verify a photograph. A caller who uploads any object into a folder he owns and then
   files a row for it still passes -- the bucket's own policies are what make that folder his
   (NFR4). The bar moves from "no upload at all" to "an object you actually put there", which is
   what closes A1, and no further. */
create function public.evidence_object_must_exist()
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
      'appeal-evidence bucket.', new.storage_path;
  end if;

  return new;
end;
$$;

comment on function public.evidence_object_must_exist() is
  'before insert trigger on public.evidence. Refuses a row whose storage_path names no object in '
  'the appeal-evidence bucket -- the reference the table never had, and without which one REST '
  'insert with a fabricated path settled a day clean with no photograph anywhere. Insert only: '
  'the retention sweep (20260908180000) removes the bytes of old photos and keeps their rows, so '
  'a rule that re-checked an old row would delete the proof of honestly held days. Separate from '
  'evidence_derive_owner() on purpose -- fixtures disable that trigger, and this one must survive '
  'that.';

revoke execute on function public.evidence_object_must_exist() from public, anon, authenticated;

-- Fires after `evidence_derive_owner` -- BEFORE ROW triggers run in name order, and `d` sorts
-- before `o`. That ordering is the useful one: a row refused for a wrong capture date or a day
-- that has ended still says so, rather than being turned away for the object it does have.
create trigger evidence_object_must_exist
  before insert on public.evidence
  for each row execute function public.evidence_object_must_exist();
