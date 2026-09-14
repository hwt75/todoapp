-- Story 8.1 — a commitment can ask for the referee's signature.
--
-- The author wants his friend's signature on some days and not others, and there is nowhere to
-- say which. This is the column that says it, and nothing more: **nothing reads the flag yet.**
-- No settlement change, no commitments_owing() clause, no decision table, no referee surface, no
-- notification, and object_to_day() is untouched. Story 8.2 is what makes it decide anything.
--
-- **Why the log ships in this migration rather than in 8.2.** The flag decides money, and a rule
-- that decides money is never read live: a switch flipped today must not rewrite what yesterday
-- meant. `carries_penalty_as_of()` (20260827130000) and `due_time_as_of()` (20260829090000,
-- repaired 20260907120000) are the two precedents, and the Epic 6 retrospective's item 50 is what
-- happens when a rule is read live by some callers and historically by others -- three defects in
-- one day, all of them that one shape. So the column, its append-only log and its one reader land
-- together, before the first caller exists, and every later reader goes through the one door.
--
-- **The answer 20260903120000 asked for.** `commitment.requires_photo`'s own comment ends: "If a
-- later story ever makes a missing photo cost anything, this column needs the log before that
-- story ships." This epic does not make a missing photo cost anything. The referee's waiting list
-- (Story 8.4) will only ever name commitment-days that already have a photograph, and a flagged
-- day with no photograph and no decision settles exactly as it does today -- silence approves, and
-- a missing photo is a day the referee is never asked about rather than a day he refuses. So
-- `requires_photo` still decides nothing, still needs no log, and 20260903120000 is not edited.
--
-- **No pre-flight check before the three constraints.** 20260829090000:1002 raises loudly before
-- adding `commitment_time_not_with_auto_check`, because rows carrying both already existed. That
-- cannot happen here: the column is new and defaults false, so every pre-existing row satisfies
-- all three constraints by construction. Adding the check would be theatre.


-- ---------------------------------------------------------------------------------
-- The flag, on the commitment.
-- ---------------------------------------------------------------------------------

alter table public.commitment
  add column requires_referee_approval boolean not null default false;

comment on column public.commitment.requires_referee_approval is
  'Story 8.1: whether this commitment asks the author''s paired referee to sign its day off. '
  'Unlike requires_photo beside it, this one decides money -- from Story 8.2 a refusal filed '
  'before midnight fails the day inside the day''s own settlement -- which is why it carries '
  'commitment_requires_referee_approval_change and requires_referee_approval_as_of() and '
  'requires_photo does not. Nothing reads it in this migration. A missing photo still costs '
  'nothing even with this on: the referee is only ever shown commitment-days that already have '
  'one, so a flagged day with no photograph is a day he is never asked about, not a day he '
  'refuses -- which is the answer to 20260903120000''s own closing sentence. Read it only '
  'through requires_referee_approval_as_of(); never live.';

-- Three refusals that stop the flag meaning nothing. The fourth -- that a referee is actually
-- paired -- cannot be a CHECK, because a check cannot query `profile`; it is the trigger further
-- down. All four are mirrored in `lib/commitment.ts` so the form can refuse a bad draft without a
-- round trip, exactly as the cadence-target rules are.

-- Deliberately narrower than `commitment_time_needs_a_moment` (20260828130000:83) and sharing no
-- predicate with it or with `commitment_auto_check_not_on_abstain`. Those two exclude an
-- abstention and an hours quota for unrelated reasons -- one asks whether a *moment* exists, the
-- other whether a *sensor* does. This asks something narrower than either: a signature is a
-- statement that a thing was done, so only `do` has anything for a referee to sign. `abstain` is
-- a thing not done and `open_ended` is hours banked rather than an act witnessed. A shared
-- predicate would couple three rules that will not change together.
alter table public.commitment
  add constraint commitment_sign_off_needs_a_do
    check (not requires_referee_approval or kind = 'do');

-- A machine already answers for a commitment carrying an Auto-check, and two answers to one
-- question is how they come to disagree. The same reasoning `commitment_time_not_with_auto_check`
-- (20260829090000:1023) made for a photo-settled day, one step further out.
alter table public.commitment
  add constraint commitment_sign_off_not_with_auto_check
    check (not requires_referee_approval or auto_check_kind is null);

-- A sign-off with nothing to look at is a referee guessing.
alter table public.commitment
  add constraint commitment_sign_off_implies_photo
    check (not requires_referee_approval or requires_photo);


-- ---------------------------------------------------------------------------------
-- The log. The shape 20260827130000 established, copied deliberately.
-- ---------------------------------------------------------------------------------

create table public.commitment_requires_referee_approval_change (
  id uuid primary key default gen_random_uuid(),
  commitment_id uuid not null references public.commitment (id) on delete cascade,
  requires_referee_approval boolean not null,
  -- `clock_timestamp()`, not `now()`, following commitment_due_time_change (20260829090000:147)
  -- rather than commitment_carries_penalty_change, whose shape the rest of this table copies.
  -- Two entries written inside one transaction carry the identical `now()`, and the log stops
  -- being orderable -- which is the only thing it is for. The reader's own
  -- `order by changed_at desc limit 1` would then break the tie arbitrarily, on a column that
  -- decides money. carries_penalty_change uses `now()` because it predates that observation, not
  -- because ties are safe there; this is the one place its shape was superseded.
  changed_at timestamptz not null default clock_timestamp()
);

comment on table public.commitment_requires_referee_approval_change is
  'Append-only history of every value commitment.requires_referee_approval has ever held, logged
  by commitment_log_requires_referee_approval_change() below. Never read directly by application
  code -- requires_referee_approval_as_of() is the one door. The same shape, and for the same
  reason, as commitment_carries_penalty_change (20260827130000): a fact that decides money is
  frozen when it is established, never re-derived afterwards.';

create index commitment_requires_referee_approval_change_lookup_idx
  on public.commitment_requires_referee_approval_change (commitment_id, changed_at desc);

alter table public.commitment_requires_referee_approval_change enable row level security;

-- An explicit deny rather than an absent policy, for the reason
-- commitment_carries_penalty_change gives: RLS with no policy already denies, but silence reads
-- as an oversight and this reads as a decision. The revoke below is what actually keeps the table
-- out of the API; this is the second lock. AD-7.
create policy "commitment_requires_referee_approval_change: no client may touch this"
  on public.commitment_requires_referee_approval_change for all to authenticated, anon
  using (false)
  with check (false);

revoke all on table public.commitment_requires_referee_approval_change
  from public, anon, authenticated;

create function public.commitment_log_requires_referee_approval_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.commitment_requires_referee_approval_change
    (commitment_id, requires_referee_approval)
  values (new.id, new.requires_referee_approval);

  return new;
end;
$$;

comment on function public.commitment_log_requires_referee_approval_change() is
  'Logs every value requires_referee_approval has ever held -- the initial one at row creation,
  and every change after. Fires only when the value actually changes (the trigger''s own WHEN
  clause on the update path), never once per unrelated update: an author renaming a commitment
  must not leave an entry that reads as a decision he made about his referee.';

revoke execute on function public.commitment_log_requires_referee_approval_change()
  from public, anon, authenticated;

create trigger commitment_log_requires_referee_approval_change_on_insert
  after insert on public.commitment
  for each row
  execute function public.commitment_log_requires_referee_approval_change();

create trigger commitment_log_requires_referee_approval_change_on_update
  after update of requires_referee_approval on public.commitment
  for each row
  when (old.requires_referee_approval is distinct from new.requires_referee_approval)
  execute function public.commitment_log_requires_referee_approval_change();

-- Backfill: one row per existing commitment, stamped at its own created_at with its current
-- (and only possible) value, false. Without it the reader's second branch has nothing to
-- extrapolate from and every pre-existing commitment answers NULL for every day before this
-- migration ran -- which is how a boolean that decides money becomes three-valued.
insert into public.commitment_requires_referee_approval_change
  (commitment_id, requires_referee_approval, changed_at)
select id, requires_referee_approval, created_at
  from public.commitment;


-- ---------------------------------------------------------------------------------
-- The one door. Two branches, not three.
-- ---------------------------------------------------------------------------------

/* The reader takes the first half of `due_time_as_of()`'s shape and refuses the second half.

   `carries_penalty_as_of()` reads the value at the instant the day *closed*, because a cost is
   settled when a day ends. `due_time_as_of()` reads the value at the day's *start* and also
   judges the day untimed if the time moved during it, because a window is a question about the
   whole day. This takes the day-start read and drops the mid-day veto, for one reason: the veto
   is a hole here. A refusal lands at 21:00; the author switches the flag off at 22:00; under a
   mid-day veto the day is judged unflagged and the refusal he just earned evaporates. Under a
   day-start read with no veto it stands -- and a flag switched *on* mid-day governs nothing until
   tomorrow, which is the SPEC's own "turning the flag on reaches forward only" written as SQL.

   An existence test rather than a `coalesce`, exactly as `late_window_at()` (20260907100000) and
   the `due_time_as_of()` repair (20260907120000) are written. The column is `not null`, so the
   two shapes agree today; the existence test is what stops a later nullable column reintroducing
   the defect that repair exists for -- a coalesce cannot tell "no entry applies" from "the entry
   that applies says null". */
create function public.requires_referee_approval_as_of(p_commitment_id uuid, p_day date)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with history as (
    select ch.requires_referee_approval, ch.changed_at
      from public.commitment_requires_referee_approval_change ch
     where ch.commitment_id = p_commitment_id
  )
  select case
           -- An entry was in force when the day began: its value governed the whole of p_day,
           -- and nothing done later in the day or after it can move that.
           when exists (
             select 1
               from history h
              where h.changed_at < public.day_begins_at(p_day)
           ) then (
             select h.requires_referee_approval
               from history h
              where h.changed_at < public.day_begins_at(p_day)
              order by h.changed_at desc
              limit 1
           )

           -- p_day is at or before the commitment's own creation: extrapolate the earliest known
           -- value backward, the same fallback carries_penalty_as_of() and due_time_as_of() both
           -- make and for the same reason -- a fixed historical fact, not a live read.
           else (
             select h.requires_referee_approval
               from history h
              order by h.changed_at asc
              limit 1
           )
         end;
$$;

comment on function public.requires_referee_approval_as_of(uuid, date) is
  'Whether p_commitment_id asked for its referee''s sign-off through the whole of p_day -- the
  value in force at the instant p_day began (Asia/Ho_Chi_Minh, AD-6). The one door to
  commitment_requires_referee_approval_change; nothing reads that table directly. Two branches
  rather than due_time_as_of()''s three, deliberately: there is no mid-day veto here. A flag
  switched off at 22:00 cannot un-earn a refusal filed at 21:00, and a flag switched on mid-day
  governs nothing until tomorrow -- the SPEC''s "turning the flag on reaches forward only", as
  SQL. For a day at or before the commitment''s own creation, falls back to the earliest logged
  value. NULL only if p_commitment_id has no history at all, which the backfill and the insert
  trigger together make unreachable for any commitment this schema ever created.

  The boundary is strict and falls toward the second branch: an entry stamped at exactly
  day_begins_at(p_day) did NOT govern p_day, because `changed_at < day_begins_at(p_day)` excludes
  it. An entry landing on the stroke of midnight is a change made during the day it opens, and a
  change made during a day never governs that day here -- the same direction the mid-day rule
  above points in, said once for the one instant where it is decidable either way.';

-- Revoked from authenticated, matching carries_penalty_as_of(). Story 8.6 is the first client
-- reader and must choose then between a grant and a `security_invoker` view -- the
-- `morning_question_day` precedent. `components/ledger.tsx:156`'s live read is what happens when
-- neither is done.
revoke execute on function public.requires_referee_approval_as_of(uuid, date)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- The fourth refusal, which cannot be a CHECK.
-- ---------------------------------------------------------------------------------

/* A check constraint cannot query `profile`, so "it cannot be set with no referee paired" is a
   trigger, and it fires only when the flag is *written*.

   That is the whole rule. A pairing revoked afterwards does not retroactively refuse anything and
   no trigger re-checks it, because the SPEC is explicit that a revoked pairing simply
   auto-approves -- which is Story 8.2's silence, not an error the author has to clear before he
   can rename his own commitment.

   `security definer` because the doer cannot see the row it reads: `referee_of` is set on the
   *referee's* profile row pointing at the doer (20260907160000:29), and `profile: read own` stops
   a doer seeing any row but his own. */
create function public.commitment_sign_off_needs_a_referee()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.profile p where p.referee_of = new.owner_id
  ) then
    raise exception
      'This commitment asks for a referee''s signature, but no referee is paired to this '
      'account. Pair one in Settings first.';
  end if;

  return new;
end;
$$;

comment on function public.commitment_sign_off_needs_a_referee() is
  'before insert/update trigger on public.commitment. Refuses a row that turns
  requires_referee_approval on while no profile carries referee_of = the commitment''s owner --
  the fourth refusal of Story 8.1, and the one a CHECK constraint cannot make because a check
  cannot query another table. Write-time only: nothing re-checks an already-flagged commitment,
  so a pairing revoked later leaves flagged days to auto-approve rather than making the row
  unsaveable. security definer because profile.referee_of lives on the referee''s row and
  "profile: read own" hides it from the doer.';

revoke execute on function public.commitment_sign_off_needs_a_referee()
  from public, anon, authenticated;

create trigger commitment_sign_off_needs_a_referee_on_insert
  before insert on public.commitment
  for each row
  when (new.requires_referee_approval)
  execute function public.commitment_sign_off_needs_a_referee();

-- `is distinct from` rather than `new.requires_referee_approval` alone: the client's save writes
-- every column by name on every edit, so an author editing an already-flagged commitment would
-- otherwise be re-checked against a pairing the rule above says is not his to keep.
create trigger commitment_sign_off_needs_a_referee_on_update
  before update of requires_referee_approval on public.commitment
  for each row
  when (new.requires_referee_approval
        and old.requires_referee_approval is distinct from new.requires_referee_approval)
  execute function public.commitment_sign_off_needs_a_referee();


-- ---------------------------------------------------------------------------------
-- What the form has to ask, because it cannot read the answer itself.
-- ---------------------------------------------------------------------------------

/* The client mirror of the four refusals has no read to reuse for this one. `paired_doer_id()` is
   revoked from `authenticated` and answers the *referee's* question anyway ("which doer am I
   paired to"), and `profile: read own` stops a doer seeing the row where `referee_of` points at
   him. So the doer gets his own boolean: the mirror of `paired_doer_id()`, asked from the other
   side, returning nothing about the referee but whether one exists.

   Granted to `authenticated`, unlike `paired_doer_id()`: it is a single boolean about the
   caller's own account, derived from the caller's own auth.uid() with no argument to point
   elsewhere, and it opens nothing -- the trigger above is what actually enforces the rule, and
   this only stops the form spending a round trip to be told so. */
create function public.has_paired_referee()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profile p where p.referee_of = (select auth.uid())
  );
$$;

comment on function public.has_paired_referee() is
  'Whether the calling account has a referee paired to it -- true when some profile carries
  referee_of = auth.uid(). The mirror of paired_doer_id(), asked by the doer instead of the
  referee. security definer because profile.referee_of lives on the referee''s row, which
  "profile: read own" hides from the doer. Granted to authenticated so the commitment form can
  disable the sign-off control and say where to pair one, rather than offering a checkbox whose
  save the database will refuse; it reveals nothing about who the referee is. Never an
  authorization decision -- commitment_sign_off_needs_a_referee() is.';

revoke execute on function public.has_paired_referee() from public, anon;
grant execute on function public.has_paired_referee() to authenticated;
