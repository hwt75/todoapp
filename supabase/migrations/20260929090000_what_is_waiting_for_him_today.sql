-- Story 8.4 — What is waiting for him today.
--
-- Stories 8.2 and 8.3 let the referee decide a flagged commitment-day and open the photograph
-- behind it, but nothing showed him which days those are: `sign_off_day()` had no caller. This
-- adds the one read that names them, for the section Story 8.4 puts on his home screen.
--
-- **Two things, in this order.**
--
--   (i)  The parentage union leaves photograph_reaches_the_referee() for a helper of its own, and
--        the predicate is re-created on top of it, deciding exactly what it decided before. The
--        list needs the photographs' *paths*, and the predicate only answers *whether* -- so
--        without this the list would have to spell out the union a second time, which is the
--        shape Epic 6 retrospective item 50 names and `8-3-...sql` step 7 exists to catch.
--  (ii)  referee_waiting_today(), gated by the predicate, in the shape referee_day_lookup()
--        established.
--
-- **What is deliberately NOT here.** No change to `sign_off_day()` (its text is untouched, and it
-- reaches the helper only through the predicate it already calls), to either referee policy, to
-- `referee_day_lookup()` -- which still excludes commitment-day photographs, and `8-3-...sql` step 7
-- still says so -- or to settlement. No notification of anyone: telling the author is Story 8.5,
-- and the referee is never nudged at all (SPEC non-goal).


-- ---------------------------------------------------------------------------------
-- (i) Which photographs belong to one commitment-day, said once.
-- ---------------------------------------------------------------------------------

/* The union Story 8.3 wrote into photograph_reaches_the_referee(), moved rather than copied. Both
   parentages, because which one proves a day depends on whether the commitment carries a
   due_time: Story 6.3's claim-parented photograph if it does, Story 6.8's commitment-day
   photograph if it does not (20260903120000:51-53).

   Returns rows rather than a boolean so that the predicate can ask `exists` of it and the list can
   ask for paths, and neither has to know how the two parentages are joined.

   **`swept_at` is returned, never filtered.** The predicate does not filter it (Story 8.3 decided
   that and says why at 20260914120000:100-106) and the list does, as referee_day_lookup() does. A
   helper that filtered would silently change the predicate's decision, and the three callers of
   the predicate -- both referee policies and sign_off_day() -- would all move at once.

   Revoked from every client role, unlike the predicate. Nothing calls it except the two
   `security definer` functions below, which run as their owner, so a client grant would buy
   nothing and expose an RPC that lists storage paths for any commitment uuid it is handed. */
create function public.commitment_day_photographs(p_commitment_id uuid, p_for_day date)
returns table (
  evidence_id uuid,
  storage_path text,
  swept_at timestamptz,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  -- Story 6.8's commitment-day record, for a commitment carrying no due_time.
  select e.id, e.storage_path, e.swept_at, e.created_at
    from public.evidence e
   where e.commitment_id = p_commitment_id and e.for_day = p_for_day
  union all
  -- Story 6.3's claim-parented proof, for one that does.
  select e.id, e.storage_path, e.swept_at, e.created_at
    from public.evidence e
    join public.declaration d on d.id = e.declaration_id
   where d.commitment_id = p_commitment_id and d.for_day = p_for_day;
$$;

comment on function public.commitment_day_photographs(uuid, date) is
  'Story 8.4. Every evidence row that belongs to one commitment-day, of either parentage -- the one
  place the union of Story 6.8''s commitment-day record and Story 6.3''s claim-parented proof is
  written. Says nothing about who may see them: photograph_reaches_the_referee() asks that, and
  asks it of this. swept_at is returned and never filtered, so the predicate decides exactly what
  it did before this function existed. Revoked from every client role -- its only callers are
  security definer.';

revoke execute on function public.commitment_day_photographs(uuid, date)
  from public, anon, authenticated;


/* The predicate, re-created on the helper. `create or replace`, so the grant Story 8.3 gave it and
   both policies that call it stand untouched. The decision is identical: `exists` over a `union
   all` of the two queries is true exactly when either of the two `exists` it replaces was. */
create or replace function public.photograph_reaches_the_referee(p_commitment_id uuid, p_for_day date)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.requires_referee_approval_as_of(p_commitment_id, p_for_day) is true
     and exists (
       select 1 from public.commitment_day_photographs(p_commitment_id, p_for_day)
     );
$$;


-- ---------------------------------------------------------------------------------
-- (ii) What is waiting for him today.
-- ---------------------------------------------------------------------------------

/* The shape referee_day_lookup() established (20260908180000:147-189): `security definer`,
   `role_from_table() = 'referee'` and `paired_doer_id()` as filters, so a caller who should not
   have it gets zero rows rather than an error (AD-7's read convention). Never an RLS grant on
   `referee_decision`, `settlement_commitment` or the flag's log -- granting the referee `select`
   on settlement rows is the 20260825100000 incident.

   **Today only, resolved here.** The day is `now()` in `Asia/Ho_Chi_Minh` (AD-6) and is handed
   back as `for_day`, so the screen passes the server's own date to sign_off_day() and never
   derives one. No argument: a list that took a day would be a history.

   **The row gate is the one door.** photograph_reaches_the_referee() decides "flagged as of today
   and proved with a photograph", which is also what sign_off_day() and both referee policies ask.
   A row listed here is one he can open and decide; a row he could decide but not see, or see but
   not decide, is the disagreement the single predicate exists to prevent.

   **Facts, not a verdict.** `carries_penalty` and `cadence` are returned so the screen can decide
   whether a refuse control renders at all, the way objectionIsOffered() mirrors
   referee_day_lookup()'s facts. A `refusable` column would be a second copy of sign_off_day()'s
   landing guards, and sign_off_day() stays the only judge of them.

   Excluded, beyond the gate: a commitment-day already decided either way (it is no longer waiting,
   and the list is not a history), and an archived commitment (sign_off_day() refuses it outright).
   A settled day needs no clause: today is never settled before it ends. */
create function public.referee_waiting_today()
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
    from public.commitment c
    cross join today t
   where public.role_from_table() = 'referee'
     and c.owner_id = public.paired_doer_id()
     and c.archived_at is null
     and public.photograph_reaches_the_referee(c.id, t.day)
     and not exists (
       select 1 from public.referee_decision r
        where r.subject = c.owner_id
          and r.for_day = t.day
          and r.commitment_id = c.id
     )
   order by c.name, c.id;
$$;

comment on function public.referee_waiting_today() is
  'Story 8.4, CAP-6. The flagged commitment-days of the caller''s paired doer, for today in
  Asia/Ho_Chi_Minh, that have a photograph and no referee decision -- gated by
  photograph_reaches_the_referee(), the one expression of that rule. Returns the day itself so the
  client never derives one, the photographs'' paths (swept rows excluded) for signing in one call,
  and carries_penalty/cadence as facts the screen mirrors to decide whether a refuse control
  renders. sign_off_day() stays the sole judge. No other day, no other account, no history, no
  count: a non-referee or unpaired caller gets zero rows, never an error.';

-- Explicit, both halves. referee_day_lookup() lost exactly this to a drop-and-create
-- (20260914140000), and this project's default privileges grant EXECUTE on a new `public`
-- function to `anon`.
revoke execute on function public.referee_waiting_today() from public, anon;
grant execute on function public.referee_waiting_today() to authenticated;
