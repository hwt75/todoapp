-- The referee's day lookup says which door a commitment-day belonged to.
--
-- **What was wrong.** Story 8.2 made a commitment that asked for the referee's signature
-- unreachable by object_to_day(): his power over that day is sign_off_day(), before midnight, and
-- the 48-hour objection refuses it "That commitment asks for your signature on the day itself, not
-- here." (20260914090000:812-815). referee_day_lookup() was not told. It returns the outcome, the
-- window and whether the day was already objected to, so `objectionIsOffered()` (lib/referee.ts)
-- offered the Object control on every flagged `held` row and the database refused it every time.
-- Recorded in deferred-work.md from the review of Story 8.2, to be closed in 8.4; 8.4 rebuilt the
-- referee's home and left this screen as it was.
--
-- **The fix is a fact, not a verdict.** One more column, `asked_for_signature`, read through
-- requires_referee_approval_as_of() for the day being looked up -- the same door, with the same
-- `is true`, that object_to_day()'s guard reads. The screen mirrors it to decide whether the
-- control renders; object_to_day() remains the judge (AD-1). Two readers of one rule through one
-- door, which is Epic 6 retrospective item 50's whole point.
--
-- **`drop function` + `create`, and the ACL re-issued in this file.** Adding an output column
-- changes the return type, which `create or replace` cannot do. The drop destroys the ACL and
-- this project's default privileges hand EXECUTE on a new `public` function to `anon` -- the exact
-- accident 20260914140000_referee_day_lookup_lost_its_acl.sql repaired after 20260908170000
-- dropped this same function and did not re-grant. Both directions are asserted in
-- supabase/tests/the-day-lookup-knows-which-door.sql and 2-1-roles-and-rls.sql.
--
-- Body otherwise verbatim from 20260908180000:147-189. In particular the `e.commitment_id is null`
-- narrowing that 8-3-the-photograph-reaches-the-referee.sql step 7 asserts is unchanged.

drop function public.referee_day_lookup(uuid);

create function public.referee_day_lookup(p_settlement_id uuid)
returns table (
  commitment_id uuid,
  commitment_name text,
  outcome public.commitment_outcome,
  objection_deadline timestamptz,
  already_objected boolean,
  evidence_paths text[],
  asked_for_signature boolean
)
language sql
security definer
stable
set search_path = ''
as $$
  select sc.commitment_id,
         c.name,
         sc.outcome,
         public.objection_deadline(s.settled_at),
         exists (
           select 1 from public.objection o
            where o.subject = s.subject and o.for_day = s.period
         ),
         coalesce(
           (select array_agg(e.storage_path order by e.created_at, e.id)
              from public.declaration d
              join public.evidence e on e.declaration_id = d.id
             where d.commitment_id = sc.commitment_id
               and d.for_day = s.period
               and d.owner_id = s.subject
               and e.commitment_id is null
               -- Retention: the row survives because commitments_owing() reads it, but the bytes
               -- are gone. Naming the path would put a photo on his screen that cannot load.
               and e.swept_at is null),
           '{}'::text[]
         ),
         -- The flag as it stood on the day looked up, never live: switching it off afterwards
         -- does not reopen the objection door, and object_to_day() reads it exactly this way.
         -- `is true` because the door answers NULL for a commitment with no flag history.
         public.requires_referee_approval_as_of(sc.commitment_id, s.period) is true
    from public.settlement_commitment sc
    join public.settlement s on s.id = sc.settlement_id
    join public.commitment c on c.id = sc.commitment_id
   where sc.settlement_id = p_settlement_id
     and s.kind = 'day'
     and public.role_from_table() = 'referee'
     and s.subject = public.paired_doer_id();
$$;

comment on function public.referee_day_lookup(uuid) is
  'Story 6.7; epic 6 retro item 43; 20261005100000. One row per commitment on one settled day of
  the referee''s paired doer: what the day froze for it, when the 48-hour objection window closes,
  whether the day was already objected to, the claim-parented photographs not yet swept, and
  asked_for_signature -- requires_referee_approval_as_of() for that day, the same door
  object_to_day() reads to refuse a flagged commitment. Facts, not an objectable verdict:
  object_to_day() decides. Returns nothing to a caller who is not the paired referee.';

revoke execute on function public.referee_day_lookup(uuid) from public, anon;
grant execute on function public.referee_day_lookup(uuid) to authenticated;
