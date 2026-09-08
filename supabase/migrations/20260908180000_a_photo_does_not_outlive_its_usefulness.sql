-- A photo does not outlive its usefulness.
--
-- Requested by the maintainer: photographs were accumulating in `appeal-evidence` with no way out.
-- The existing sweeper (20260907130000) removes only orphans -- objects no `evidence` row points at
-- -- and its own Never boundary refuses to touch an object a row points at, whatever its age. So
-- every photo that had done its job stayed for the life of the project.
--
-- This adds a second pass to the same sweeper: past the retention period, the *bytes* go.
--
-- WHY THE ROW STAYS AND ONLY THE BYTES GO
--
-- This is the whole design, and it is not a matter of taste. `commitments_owing()` and
-- `weekly_held_count()` both read this table to decide an outcome:
--
--   when exists (select 1 from public.evidence e where e.declaration_id = d.id) then d.answer
--
-- A claim answered `held` counts as held only while an evidence row exists; without one, once the
-- day ends it reads `slipped`. And `apply_grace_days()` still rebuilds from live
-- `commitments_owing()` (epic 6 retrospective, A6), so this is not confined to the day being
-- settled -- correcting an old day re-reads it.
--
-- Deleting `evidence` rows would therefore turn held days into slipped days and mint 500,000d
-- penalties nobody earned, and would drop weekly quota counts below their targets. The row is about
-- a hundred bytes and decides money; the photograph is the megabyte and is what was asked to go.
--
-- WHAT EXPIRES
--
-- Every kind: appeal evidence, a claim's proof, and the commitment-day photos Story 6.8 exists to
-- let the author keep. No exemption by parent -- the maintainer was told 6.8 is revoked in
-- substance by this and approved it anyway. `swept_at` is what makes a cleared photo tell itself
-- apart from a broken one, so no surface has to render an absence as a failure.

alter table public.evidence
  add column swept_at timestamptz;

comment on column public.evidence.swept_at is
  'When this photo''s bytes were removed from Storage by the evidence sweeper''s retention pass.
  Null means the object is still there. The row itself is never deleted: commitments_owing() and
  weekly_held_count() read its existence to decide whether a claimed day held, so removing it would
  turn held days into slipped days and mint penalties nobody earned. Stamped only for objects the
  Storage API reported as actually removed -- a row stamped without its bytes gone is a photo the
  product believes it deleted and is still paying to store.';

-- Partial index: the retention pass only ever asks about rows that have not been swept, and past
-- the first sweep those are the minority. Ordering is by `created_at`, which the index carries.
create index evidence_unswept_idx on public.evidence (created_at)
  where swept_at is null;


-- ---------------------------------------------------------------------------------
-- What has outlived the retention period.
-- ---------------------------------------------------------------------------------

/* Returns the row id alongside the path, unlike `orphaned_evidence_objects()` which returns names
   only. The orphan pass has nothing to write back -- an orphan by definition has no row -- whereas
   this pass has to stamp exactly the rows whose bytes went, and matching paths back to ids in the
   worker would be a second place that could get the pairing wrong.

   `created_at`, not `captured_on` or `for_day`: retention is about how long the bytes have been
   stored, which is what costs. A photo filed late for an old day is thirty days old when it has
   been *stored* thirty days.

   Rows already swept are excluded, so a second pass never re-names them and `swept_at` keeps the
   instant of the real removal rather than the last time a job looked at it. */
create function public.expired_evidence_objects(
  p_age interval default interval '30 days',
  p_batch integer default 100
)
returns table (evidence_id uuid, storage_path text)
language sql
stable
security definer
set search_path = ''
as $$
  select e.id, e.storage_path
    from public.evidence e
   where e.swept_at is null
     and e.created_at < now() - p_age
   order by e.created_at
   limit greatest(p_batch, 0);
$$;

comment on function public.expired_evidence_objects(interval, integer) is
  'The photos whose bytes have been stored longer than p_age and have not been swept yet -- every
  kind, appeal and claim and commitment-day alike. Names them only; the deletion belongs to the
  evidence-sweeper Edge Function, because the Storage API is the only path that removes the stored
  bytes rather than just the storage.objects row. Oldest first, capped at p_batch. Revoked from
  every client role: the answer is a list of every account''s storage paths.';

revoke execute on function public.expired_evidence_objects(interval, integer)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- Stamping what actually went.
-- ---------------------------------------------------------------------------------

/* Called by the worker with exactly the ids whose objects the Storage API reported as removed --
   never with everything it asked about. `remove()` can report fewer than were named, and stamping
   the difference would leave the product believing it had deleted photos it is still storing.

   `swept_at is null` in the where clause rather than a blind update: a row stamped by an earlier
   pass keeps that pass's instant, so the column always says when the bytes actually went. */
create function public.mark_evidence_swept(p_ids uuid[])
returns integer
language sql
volatile
security definer
set search_path = ''
as $$
  with stamped as (
    update public.evidence
       set swept_at = now()
     where id = any(p_ids)
       and swept_at is null
    returning 1
  )
  select count(*)::integer from stamped;
$$;

comment on function public.mark_evidence_swept(uuid[]) is
  'Records that these photos'' bytes are gone, for the ids the sweeper actually removed. Returns how
  many rows it stamped, which the worker reports so a persistent gap between named, removed and
  stamped is visible. Never deletes the row -- see the column comment on evidence.swept_at for why
  that would cost money. Revoked from every client role: it writes to every account''s rows.';

revoke execute on function public.mark_evidence_swept(uuid[]) from public, anon, authenticated;
