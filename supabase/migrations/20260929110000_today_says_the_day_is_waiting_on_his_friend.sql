-- Story 8.6 — Today says the day is waiting on his friend.
--
-- CAP-8: a flagged row with a photograph and no decision says so on the author's Today, and stops
-- saying so once a decision lands or midnight passes. Story 8.4 already answers the same question
-- for the referee. **Two answers to one question is how they come to disagree** -- the shape Epic 6
-- retrospective item 50 names -- so "waiting on the referee" is defined once, here, and both sides
-- read it:
--
--   (i)   commitment_days_waiting_on_referee(owner, day) -- the definition;
--   (ii)  referee_waiting_today() re-created on it, returning exactly what it returned;
--   (iii) waiting_on_my_referee() -- the author's read, the same set for his own account.
--
-- Nothing new is stored. The state is derived from what already exists: a photograph, a flag as of
-- the day, and the absence of a referee_decision row.
--
-- **What is deliberately NOT here.** No change to sign_off_day(), to settlement, to either referee
-- policy, or to what referee_waiting_today() returns -- `8-4-...sql` passes with one assertion
-- moved from "the list names the predicate" to "the list names the definition, which names the
-- predicate", since the call now lives one step down.


-- ---------------------------------------------------------------------------------
-- (i) The definition.
-- ---------------------------------------------------------------------------------

/* Lifted out of referee_waiting_today() (20260929090000:155-165) verbatim, minus the two conjuncts
   that are about *who is asking* -- the role and the pairing -- which stay with each caller,
   because the referee and the author establish them differently.

   Flagged as of the day with a photograph of either parentage is photograph_reaches_the_referee(),
   the one door Story 8.3 built; no decision is the absence of a referee_decision row; an archived
   commitment is excluded because sign_off_day() refuses it outright.

   Revoked from every client role: it takes an owner as an argument, and both its callers are
   `security definer` and establish the owner from the session themselves. */
create function public.commitment_days_waiting_on_referee(p_owner uuid, p_day date)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select c.id
    from public.commitment c
   where c.owner_id = p_owner
     and c.archived_at is null
     and public.photograph_reaches_the_referee(c.id, p_day)
     and not exists (
       select 1 from public.referee_decision r
        where r.subject = c.owner_id
          and r.for_day = p_day
          and r.commitment_id = c.id
     );
$$;

comment on function public.commitment_days_waiting_on_referee(uuid, date) is
  'Story 8.6. The one definition of "waiting on the referee": the commitments of p_owner that are
  flagged as of p_day with a photograph of either parentage (photograph_reaches_the_referee()),
  have no referee_decision for that day, and are not archived. Read by referee_waiting_today() for
  the referee and by waiting_on_my_referee() for the author, so the two can never name different
  rows. Says nothing about who is asking -- each caller establishes that. Revoked from clients.';

revoke execute on function public.commitment_days_waiting_on_referee(uuid, date)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- (ii) The referee's list, on the definition.
--
-- `create or replace`, return columns unchanged, so the grant 20260929090000 made survives. The
-- role and pairing conjuncts stay here; the rest is the join.
-- ---------------------------------------------------------------------------------
create or replace function public.referee_waiting_today()
returns table (
  commitment_id uuid,
  commitment_name text,
  for_day date,
  carries_penalty boolean,
  cadence public.commitment_cadence,
  evidence_paths text[]
)
language sql
security definer
stable
set search_path = ''
as $$
  with today as (
    select (now() at time zone 'Asia/Ho_Chi_Minh')::date as day
  )
  select c.id,
         c.name,
         t.day,
         -- As of the day, never the live column: the same reader sign_off_day() freezes onto the
         -- decision row. coalesce only for the no-history case the 20260827130000 backfill makes
         -- unreachable -- false renders no refuse control, which is the side that costs nothing.
         coalesce(public.carries_penalty_as_of(c.id, t.day), false),
         c.cadence,
         coalesce(
           (select array_agg(p.storage_path order by p.created_at, p.evidence_id)
              from public.commitment_day_photographs(c.id, t.day) p
             -- Retention: a swept row's bytes are gone, and naming the path would put a photo on
             -- his screen that cannot load. referee_day_lookup()'s filter, for its reason.
             where p.swept_at is null),
           '{}'::text[]
         )
    from today t
    cross join lateral public.commitment_days_waiting_on_referee(public.paired_doer_id(), t.day)
      as w(commitment_id)
    join public.commitment c on c.id = w.commitment_id
   where public.role_from_table() = 'referee'
   order by c.name, c.id;
$$;


-- ---------------------------------------------------------------------------------
-- (iii) The author's read.
-- ---------------------------------------------------------------------------------

/* The same set, for the calling account and today. No argument: a caller can ask only about
   himself, and only about now.

   **Empty when no referee is paired to him.** A revoked pairing auto-approves (SPEC constraint),
   so a flagged day with nobody on the other end is not waiting on anyone, and saying it is would
   be telling him to wait for a person who no longer exists.

   **The pairing is asked the way the referee's side asks it.** referee_waiting_today() admits a
   caller only when role_from_table() is 'referee' and paired_doer_id() names this account; the
   mirror of that, from here, is a profile whose referee_of is this account **and** whose role is
   'referee'. Checking referee_of alone would leave one state -- a pairing row whose role has moved
   -- in which the author is told his referee has not looked while his referee is shown nothing,
   which is the disagreement this story's single definition exists to rule out.

   **Returns the day it answered for.** Today stamps the answer with it and discards one stamped
   for another day, so a read sent at 23:59:59 and answered after midnight cannot put yesterday's
   rows on today's screen -- the stamp is the server's day, never the device's.

   No role check on the *caller*. A referee session asking gets his own account's rows, and a referee owns no
   flagged commitments -- commitment_sign_off_needs_a_referee refuses the flag without a pairing
   to the owner. Filtering on role here would be a second rule about who may flag, and that rule
   already has a home.

   Granted to `authenticated`: it is the author's own Today, scoped to auth.uid() with no argument
   to point anywhere else. */
create function public.waiting_on_my_referee()
returns table (commitment_id uuid, for_day date)
language sql
stable
security definer
set search_path = ''
as $$
  with today as (
    select (now() at time zone 'Asia/Ho_Chi_Minh')::date as day
  )
  select w.commitment_id, t.day
    from today t
    cross join lateral public.commitment_days_waiting_on_referee((select auth.uid()), t.day)
      as w(commitment_id)
   where exists (
     select 1 from public.profile p
      where p.referee_of = (select auth.uid())
        and p.role = 'referee'
   );
$$;

comment on function public.waiting_on_my_referee() is
  'Story 8.6, CAP-8. The calling account''s commitments that are waiting on its referee today,
  each with the day the answer is for --
  commitment_days_waiting_on_referee() for auth.uid() and today in Asia/Ho_Chi_Minh, the same set
  the referee''s own list shows. Empty when no referee (by role and pairing, the way
  referee_waiting_today() asks) is paired: a revoked pairing auto-approves,
  so there is nobody to wait on. Read by Today to say, as information and never as a task, that
  his referee has not looked yet and the day holds without him.';

revoke execute on function public.waiting_on_my_referee() from public, anon;
grant execute on function public.waiting_on_my_referee() to authenticated;
