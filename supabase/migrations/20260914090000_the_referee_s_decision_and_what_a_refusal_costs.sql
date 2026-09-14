-- Story 8.2 — the referee's decision, and what a refusal costs.
--
-- Story 8.1 put `requires_referee_approval` on the commitment and deliberately left nothing
-- reading it. This is the story that makes it decide money, and it does so at a cost the 48-hour
-- objection path never could: **inside the day's own settlement**. No supersession, no correction,
-- no voided-and-reminted penalty, and no day held open waiting for a person.
--
-- Six parts, in this order:
--
--   (i)   `public.referee_decision` -- the decision itself, append-only, with the two
--         money-relevant facts of the moment frozen onto it.
--   (ii)  `public.sign_off_day()` -- the one thing a referee session may call.
--   (iii) `public.commitments_owing()` -- drop and re-create, one new output column, `refused`.
--   (iv)  `public.object_to_day()` -- one added guard: a flagged commitment is unreachable here.
--   (v)   `public.settle_day()` -- one derived `effective_answer`, and nothing else moved.
--   (vi)  `public.supersede_expiries()` -- the other reader that decides what a commitment did,
--         through the same door, in the same change (Epic 6 retrospective item 50).
--
-- **Silence approves, and this migration is written so that the pre-existing SQL suite proves it.**
-- With no decision row every expression below collapses to exactly what it computed yesterday:
-- `refused` is false, the two coalesces read their live arguments, and `effective_answer()` is the
-- identity on `answer`. That is the point of the shape, and every pre-existing file under
-- `supabase/tests/` passing unmodified is the proof.


-- ---------------------------------------------------------------------------------
-- (i) The decision.
-- ---------------------------------------------------------------------------------

/* Its own table, not `public.objection`. That one is bound to `superseded_settlement` and has no
   meaning before a settlement exists, and there is no settlement before midnight. What it keeps
   from `objection` (20260903140000:174-256) is the care, not the columns: `referee_id` with `on
   delete restrict`, the reason stored verbatim, and the day and the commitment stored rather than
   derived from a chain that moves on afterwards.

   `objection_deadline()` (20260903140000:150-158) is deliberately NOT the shape reused for the
   window. It is a function of `settled_at`, and there is no `settled_at` before midnight -- this
   decision's window is the local day itself, `day_begins_at()` to `day_ends_at()`. */
create table public.referee_decision (
  id uuid primary key default gen_random_uuid(),
  subject uuid not null references public.profile (id) on delete cascade,

  -- Who said it. The same reasoning `objection.referee_id` carries at 20260903140000:178-186, and
  -- it applies harder here: a refusal is the only statement a *person* makes that costs the author
  -- money inside a day that has not closed yet. `on delete restrict`, unlike `subject`'s cascade:
  -- removing the author removes his whole account, but removing the referee must not quietly
  -- anonymise a statement he made about somebody else's money. His profile row cannot be deleted
  -- while his decisions stand, and re-pairing does not need it deleted.
  referee_id uuid not null references public.profile (id) on delete restrict,

  -- The day and the commitment, both stored rather than derived. There is nothing to derive them
  -- from: a decision is written before the day has a settlement at all.
  for_day date not null,
  commitment_id uuid not null references public.commitment (id) on delete cascade,

  -- What he said. Silence approves, so an approval changes no outcome and exists only as a record
  -- that he looked; the entire force of the mechanism is `false`.
  approved boolean not null,

  -- In his own words, and never paraphrased by the app. Nullable, unlike `objection.reason`,
  -- because an approval has nothing to explain -- see `referee_decision_says_why` below.
  reason text,

  -- ---------------------------------------------------------------------------------
  -- The two facts the refusal was made in, frozen at decision time.
  --
  -- `commitment: edit own` (20260819150000:97-102) lets the author change `archived_at`,
  -- `carries_penalty` and `cadence` freely, all day. Three of those edits, made between a refusal
  -- at 21:00 and midnight, each used to void it outright:
  --
  --   * `carries_penalty` off -- `carries_penalty_as_of()` cuts at `(p_day + 1)` midnight, the
  --     day's **end** (20260827130000:109), so a read at 21:00 predicts nothing about settlement;
  --   * cadence to `weekly_quota` -- settle_day()'s `admitted` count excludes it;
  --   * cadence to `daily_hours_quota` -- `commitments_owing()` excludes it from the day entirely.
  --
  -- So the refusal records the world it was made in and `commitments_owing()` prefers these over
  -- the live columns. The same shape Epic 4 retrospective item 27 used on
  -- `file_auto_check_result()`. Archiving is handled at the other end -- `sign_off_day()` refuses
  -- an archived commitment outright -- because a row written against a commitment the author had
  -- already retired should never exist in the first place.
  -- ---------------------------------------------------------------------------------
  carries_penalty boolean not null,
  cadence public.commitment_cadence not null,

  -- `now()`, not `clock_timestamp()`. The `_change` log tables need the latter because several
  -- rows land in one transaction and the log stops being orderable if they tie; the unique
  -- constraint below permits exactly one row per commitment-day, so there is nothing to order.
  created_at timestamptz not null default now(),

  -- A refusal must say why, and an approval must not. Both halves matter: the first is the whole
  -- content of CAP-3, and the second stops a "reason" being attached to a decision that changes
  -- nothing and then rendered to the author as though something had. `sign_off_day()` checks both
  -- itself first, so the referee reads a sentence rather than a raw 23514 -- this is the
  -- guarantee, that is the manners.
  constraint referee_decision_says_why
    check (
      case
        when approved then reason is null
        -- Both bounds, and on both forms. `btrim` is what makes "1" mean *something said*;
        -- the raw `char_length` is what makes 2000 a real bound, because otherwise an
        -- arbitrarily large value padded with whitespace trims down to 2000 and passes the
        -- constraint this comment calls the guarantee. sign_off_day() btrims before it writes,
        -- but it is not the only thing that can reach this table -- `postgres` is, and so is
        -- whatever writes here next.
        else reason is not null
             and char_length(btrim(reason)) between 1 and 2000
             and char_length(reason) <= 2000
      end
    ),

  -- AD-15's guarded transition, as a constraint rather than a check-then-act.
  --
  -- **This is where it departs from `objection_once_per_day` (20260903140000:223).** That one is
  -- scoped to `(subject, for_day)` because the correction it writes freezes the *whole* day, so
  -- two objections on one day would be two corrections of one period. Nothing here writes a
  -- correction: a decision lands on one commitment inside a day that has not closed, and the
  -- referee may legitimately sign off two flagged commitments on the same day. So the key carries
  -- the commitment too.
  --
  -- The index leads with `(subject, for_day)`, which is exactly how `commitments_owing()`'s
  -- lateral asks it, so there is deliberately no second index -- `objection`'s own :221-222 makes
  -- the same argument.
  --
  -- `referee_id` and `commitment_id` are therefore left unindexed, and that was considered
  -- rather than overlooked. An unindexed FK makes the *parent's* delete scan this table:
  -- `referee_id` is `on delete restrict` and a referee profile is never deleted while his
  -- decisions stand, and `commitment_id` cascades from a row the schema archives rather than
  -- deletes (20260819150000:37-40). `objection` made exactly this call for exactly these two
  -- columns; matching it is worth more than two indexes nothing reads, because the next person
  -- comparing the two tables should find one decision, not two.
  constraint referee_decision_once_per_commitment_day
    unique (subject, for_day, commitment_id)
);

comment on table public.referee_decision is
  'Story 8.2. The referee''s decision on one flagged commitment on one day of his paired doer''s, '
  'written before that day closes: who said it, the day, the commitment, whether he approved, his '
  'reason in his own words when he did not, and the two money-relevant facts frozen as they stood '
  'when he said it. Append-only and written only by sign_off_day() -- there is no insert, update '
  'or delete policy for anyone, referee included, and there is no withdrawal. Silence approves: '
  'with no row here every settlement path behaves exactly as it does for an unflagged commitment.';

comment on column public.referee_decision.reason is
  'The referee''s own words, shown to the author verbatim (Story 8.5) and never paraphrased. Null '
  'exactly when approved, by referee_decision_says_why.';

comment on column public.referee_decision.carries_penalty is
  'carries_penalty_as_of(commitment_id, for_day) at the instant the decision was written. '
  'commitments_owing() prefers this over a live read for a refused commitment-day, so turning the '
  'money off at 22:00 cannot decide what a refusal at 21:00 meant. Not a live read and not a '
  'prediction -- carries_penalty_as_of() cuts at the day''s END (20260827130000:109), so at 21:00 '
  'it reports the value in force at 21:00 and nothing more, which is precisely why it has to be '
  'stored rather than re-asked.';

comment on column public.referee_decision.cadence is
  'commitment.cadence at the instant the decision was written. commitments_owing() prefers this '
  'over the live column for a refused commitment-day -- in its select list AND in both of its '
  'where-clause cadence predicates, because moving a refused commitment to daily_hours_quota '
  'otherwise dropped it out of the day altogether.';

alter table public.referee_decision enable row level security;

-- The author reads the decision on his own day. That is the entire point of storing the reason:
-- he is told, in the referee's words, why a day he thought held does not. Story 8.5 is what
-- actually tells him; this is what it will read.
create policy "referee_decision: read own"
  on public.referee_decision for select to authenticated
  using ((select auth.uid()) = subject);

-- No insert, update or delete policy for anyone, referee included. sign_off_day() below is
-- `security definer` and is the only writer -- the same arrangement `objection` and `penalty` have
-- had since 20260903140000 and 20260819230000, for the same reason: a client that could write one
-- of these could decide a day.
--
-- No referee SELECT policy either, and deliberately not. Granting the referee `select` on
-- `settlement_commitment` was a real incident in this repository (20260825100000:21-33) -- it was
-- also a grant on `chain_current`, a `security_invoker` view over it. He reads what is waiting for
-- him through a `security definer` function in Story 8.4, never through a policy here.


-- ---------------------------------------------------------------------------------
-- (ii) The one thing a referee session may call.
-- ---------------------------------------------------------------------------------

/* The write-RPC shape `rule_appeal()` (20260825090000:88-149) established, minus the one thing it
   ends with: **there is no `outbox_enqueue` call here.** Telling the author is Story 8.5, split
   out on purpose.

   No advisory lock, unlike `object_to_day()` (20260906080451:185). That function takes the
   per-account key because it reads Penalty state and currentness and then moves money. This one
   writes a single row and moves nothing; its only contention is two decisions on one
   commitment-day, which `referee_decision_once_per_commitment_day` plus `on conflict do nothing`
   serialises -- `object_to_day()`'s own race-loser idiom at :341-351. Holding the author's
   serialization key for a write that decides nothing at write time would put a referee in the way
   of the author's Grace Day for no gain.

   `is not true` / `is distinct from`, never `not` / `<>`, throughout.
   `requires_referee_approval_as_of()` returns NULL for a commitment with no log rows at all, and
   `if not f(...) then raise` never raises on NULL -- the refusal would silently not happen for
   exactly the caller it exists to catch. The same hazard the role gate already guards
   (20260825090000:105-109), one function along. */
create function public.sign_off_day(
  p_commitment_id uuid,
  p_for_day date,
  p_approved boolean,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_paired uuid;
  v_commitment record;
  v_carries_penalty boolean;
  v_reason text;
begin
  -- First statement, before any row is read -- the I/O Matrix's own "Not the referee" row.
  -- `is distinct from`, not `<>`: a plain `<>` against a NULL role evaluates NULL, and
  -- `if NULL then raise` never raises (20260825090000:105-109).
  if public.role_from_table() is distinct from 'referee' then
    raise exception 'Only the referee may sign off a day.';
  end if;

  -- Same NULL hazard, same fix, and checked before anything is read for the same reason the role
  -- is: `if not p_approved then` treats a NULL argument as false and would fall straight through
  -- into the refusal branch for a call that named no decision at all.
  if p_approved is null then
    raise exception 'p_approved must not be null. Say whether you approve or refuse.';
  end if;

  if p_commitment_id is null or p_for_day is null then
    raise exception 'A decision names one commitment and one day. Both are required.';
  end if;

  -- He must say why, and not without end -- `referee_decision_says_why` is the real guarantee,
  -- this is what turns it into a sentence he can act on. Both directions: an approval carrying a
  -- reason is refused with words rather than a raw 23514.
  if not p_approved then
    if p_reason is null or btrim(p_reason) = '' then
      raise exception 'A refusal has to say why. Give a reason.';
    end if;

    if char_length(btrim(p_reason)) > 2000 then
      raise exception
        'That reason is % characters. Say it in 2000 or fewer -- he reads it on the day it names.',
        char_length(btrim(p_reason));
    end if;
  elsif btrim(coalesce(p_reason, '')) <> '' then
    raise exception
      'An approval carries no reason -- it changes nothing, so there is nothing to explain. '
      'His silence would have approved the day anyway. If you meant to refuse, say so.';
  end if;

  v_reason := case when p_approved then null else btrim(p_reason) end;

  -- Establish the caller before reading anything of the author's. The pairing check belongs above
  -- the commitment lookup, not below it: a referee who could tell 'No such commitment.' from
  -- 'That commitment belongs to an account you are not paired to.' would have a commitment-id
  -- oracle across every account. `object_to_day()` orders itself this way and says why at
  -- 20260906080451:181-184. So the lookup is *scoped* to the paired account and the two cases
  -- share one sentence.
  v_paired := public.paired_doer_id();

  if v_paired is null then
    raise exception 'That commitment belongs to an account you are not paired to.';
  end if;

  select c.* into v_commitment
    from public.commitment c
   where c.id = p_commitment_id and c.owner_id = v_paired;

  if not found then
    raise exception 'That commitment belongs to an account you are not paired to.';
  end if;

  -- The flag, read **only** through requires_referee_approval_as_of() and never live -- the one
  -- door, in both of this story's readers (Epic 6 retrospective item 50). `is not true`, because
  -- the door answers NULL for a commitment with no history and `not NULL` fails open.
  if public.requires_referee_approval_as_of(p_commitment_id, p_for_day) is not true then
    raise exception 'That commitment did not ask for your signature on that day.';
  end if;

  -- The window. Half-open at both ends, matching every other deadline in this schema: a signature
  -- at exactly midnight is late, and one at exactly the day's first instant is in time.
  if now() >= public.day_ends_at(p_for_day) then
    raise exception 'That day has closed. A signature lands before midnight or not at all.';
  end if;

  if now() < public.day_begins_at(p_for_day) then
    raise exception 'That day has not started yet.';
  end if;

  -- The midnight race, narrowed. `now()` is transaction-start time, so a decision begun at
  -- 23:59:59.9 commits after midnight and can land while `settle_day()` is running -- and
  -- `settle_day()` reads `commitments_owing()` in five separate statements under READ COMMITTED
  -- (20260829090000:449, 464, 473, 509, 520), with the counts and the penalty insert before the
  -- frozen-outcome write. A refusal committing between those two produces a settlement reading
  -- `clean` with no penalty beside a frozen `missed`: a broken chain with nothing for a Grace Day
  -- to attach to, which `grace_day_validate()` refuses on both of its conditions at once.
  --
  -- This is check-then-act and does not eliminate that window; it takes it from the whole of
  -- settle_day()'s run down to the instant between this read and the insert below, and it turns
  -- the common case -- a referee deciding a day the cron already settled -- from a silent no-op
  -- into a sentence. **The real closure is the per-account advisory lock that every other writer
  -- of money-relevant state already takes and `settle_day()` alone does not**; giving it one
  -- changes the most load-bearing function in the schema for a reason that predates this epic, so
  -- it is its own story and is recorded in `deferred-work.md` with this finding as its evidence.
  if exists (
    select 1 from public.settlement s
     where s.subject = v_paired and s.period = p_for_day and s.kind = 'day'
  ) then
    raise exception
      'That day has already been settled, so a decision now would arrive too late to be read.';
  end if;

  -- Already decided, and this is checked **above** the refusal-only guards below, not beside the
  -- insert. A decision is final, and a repeat has to read as the guarded transition it is -- in
  -- the same words the race-loser gets -- whatever has happened to the commitment since. Ordered
  -- below it, a referee who refused at 21:00 and double-tapped after the author turned the money
  -- off at 22:00 was told "That commitment carried no penalty on that day": the wrong sentence,
  -- and one that tells him something about the author's edits that is none of his business.
  --
  -- The unique constraint is still the actual guarantee -- a check-then-act read cannot make one
  -- on its own -- and the raise beside the insert is what catches the race this read cannot.
  if exists (
    select 1 from public.referee_decision r
     where r.subject = v_paired and r.for_day = p_for_day
       and r.commitment_id = p_commitment_id
  ) then
    raise exception 'That day has already been decided, and a decision is final.';
  end if;

  -- Read once, here, and frozen onto the row below. Never re-read at settlement.
  v_carries_penalty := public.carries_penalty_as_of(p_commitment_id, p_for_day);

  -- ---------------------------------------------------------------------------------
  -- The landing guards, and only two of `object_to_day()`'s four survive the move before
  -- midnight. It lands as a day that a Grace Day can still reach, or it does not land.
  --
  -- Guard (a) -- a penalty in any state but `owed` (20260906080451:266-286) -- cannot apply:
  -- `penalty` is keyed by `settlement_id`, and a day that has not closed has no settlement and
  -- therefore no penalty. Guard (c) -- the `unanswered > 0` would-land-`expired` refusal
  -- (:307-333) -- cannot apply either: it counts the frozen rows of the settlement being
  -- superseded, and at refusal time there are none. What survives is exactly the pair that is a
  -- fact about the *commitment* rather than about a settlement.
  --
  -- All of these are refusal-only. An approval changes no outcome, so it can break nothing, and
  -- refusing one would be the mechanism nagging about a decision that costs nothing.
  -- ---------------------------------------------------------------------------------

  if not p_approved and v_carries_penalty is not true then
    raise exception
      'That commitment carried no penalty on that day, so refusing it would cost him nothing '
      'and break his chain with no Grace Day able to reach it.';
  end if;

  if not p_approved and v_commitment.cadence = 'weekly_quota' then
    raise exception
      'That is a Weekly Quota commitment. Its money is decided at week close and never by one '
      'day, so refusing it would break his chain with no Grace Day able to reach it.';
  end if;

  -- The third, which `object_to_day()` never needed: an hours quota is judged by measured minutes
  -- and `commitments_owing()` has excluded it outright since
  -- 20260820140000_weekly_quota_is_not_judged_daily.sql. Without this the RPC would report success
  -- for a decision the settlement arm can never read -- half-closing Story 8.1's own deferred
  -- entry, which left the flag settable on `do` + `daily_hours_quota` and inert.
  if not p_approved and v_commitment.cadence = 'daily_hours_quota' then
    raise exception
      'That commitment is measured in minutes over the day, never held or missed on one day, so '
      'there is no day here to refuse. Its hours decide it.';
  end if;

  -- A refusal needs something to have been refused. CAP-6 keeps photograph-less days off the
  -- referee's list, but a condition living only in Story 8.4's query is not enforced -- AD-1 says
  -- the server is the sole judge. **Both parentages count** (20260903120000:51-53): a commitment
  -- carrying a due_time proves itself with the claim-parented photograph of Story 6.3, one
  -- without with the commitment-day photograph of Story 6.8, and the union is what is asked here
  -- rather than a branch on due_time -- so a photograph the author really attached can never be
  -- read as no photograph. Story 8.4's list must ask this same question; the two must not be able
  -- to disagree.
  if not p_approved
     and not exists (
       select 1 from public.evidence e
        where e.commitment_id = p_commitment_id and e.for_day = p_for_day
     )
     and not exists (
       select 1 from public.evidence e
         join public.declaration d on d.id = e.declaration_id
        where d.commitment_id = p_commitment_id and d.for_day = p_for_day
     ) then
    raise exception
      'There is no photograph on that day yet, so there is nothing to refuse.';
  end if;

  -- Archived, and this is the other half of the freeze above. Iteration 2 of this story's review
  -- froze the facts onto the row and gave `commitments_owing()` an archived-filter exception, but
  -- that exception has no time ordering: a commitment archived at 08:00 could be refused at 21:00
  -- and pulled back into a day the author had already retired it from. The exception stays as it
  -- is; the ordering is enforced here, by refusing to write the decision at all. Two narrow rules,
  -- each true on its own, rather than one timestamp comparison whose correctness depends on
  -- reading both.
  if v_commitment.archived_at is not null then
    raise exception 'That commitment is archived, so its days are no longer being judged.';
  end if;

  -- AD-15's guarded transition, and the only thing standing between two concurrent decisions --
  -- the read above serializes nothing, and two calls that both pass it arrive here. The second
  -- blocks on the unique index until the first commits, then finds its own `on conflict do
  -- nothing` inserted nothing. `object_to_day()`'s own idiom at 20260906080451:341-351.
  --
  -- `coalesce(..., false)` on the frozen money flag: carries_penalty_as_of() answers NULL only
  -- for a commitment with no log history at all, which the 20260827130000 backfill makes
  -- unreachable, and the column is `not null`. A refusal never reaches this line with anything
  -- but true -- the guard above refused it -- so the coalesce only ever decides what an
  -- *approval* records, and an approval's frozen facts are never read by anything.
  insert into public.referee_decision
    (subject, referee_id, for_day, commitment_id, approved, reason, carries_penalty, cadence)
  values (v_paired, (select auth.uid()), p_for_day, p_commitment_id, p_approved, v_reason,
          coalesce(v_carries_penalty, false), v_commitment.cadence)
  -- No `returning`: `FOUND` is set by the INSERT itself, and there is nothing here that wants
  -- the id. object_to_day() keeps its own because it builds an outbox dedupe key from it; this
  -- function deliberately enqueues nothing, so a handle on the row would be a variable written
  -- and never read. Story 8.5 adds the telling, and will add the `returning` with it.
  on conflict (subject, for_day, commitment_id) do nothing;

  if not found then
    raise exception 'That day has already been decided, and a decision is final.';
  end if;
end;
$$;

comment on function public.sign_off_day(uuid, date, boolean, text) is
  'Story 8.2. The referee''s decision on one flagged commitment-day of the doer he is paired to, '
  'before that day closes. Checks role_from_table() = ''referee'' as its first statement, then the '
  'reason, then the pairing -- above any read of the author''s, so there is no commitment-id '
  'oracle. Reads the flag only through requires_referee_approval_as_of(), never live. Refuses '
  'outside the local day, on a day already settled, on a commitment that is archived or already '
  'decided, and -- for a refusal only -- on one carrying no penalty that day, on either quota '
  'cadence, and on a commitment-day with no photograph of either parentage. Freezes '
  'carries_penalty and cadence onto the row so three edits `commitment: edit own` permits before '
  'midnight cannot void a refusal already made. Takes no advisory lock: it moves no money, and '
  'the unique constraint plus `on conflict do nothing` is what serialises two decisions on one '
  'commitment-day. Enqueues nothing -- telling the author is Story 8.5.';

-- Directly callable by an authenticated referee session, the same shape rule_appeal(),
-- mark_penalty_collected() and object_to_day() already use: the function itself is the privilege
-- boundary, reached over /rest/v1/rpc rather than fronted by an Edge Function or a trigger.
revoke execute on function public.sign_off_day(uuid, date, boolean, text) from public, anon;
grant execute on function public.sign_off_day(uuid, date, boolean, text) to authenticated;


-- ---------------------------------------------------------------------------------
-- The derived answer, written once so its four readers cannot drift apart.
-- ---------------------------------------------------------------------------------

/* A refusal is **not** written into `answer`. That column means what the *author* said, and three
   readers outside settlement depend on it meaning exactly that: `count(o.answer)` is how the
   Story 5.2 silence intervention decides he has gone quiet (20260826090000:156,
   20260826130000:74) and how `commitment_answer_rate_for_month()` computes SM-6
   (20260826110000:321). Synthesising `'slipped'` into it would let a third party's write make the
   author look present on a day he said nothing on.

   So `commitments_owing()` carries `refused` as its own column, and this is the one place the two
   are combined. Frozen decision 4 is what compels it: a refusal must count as *answered*, so the
   day lands `failed` rather than `expired` -- `expired` being the one verdict a Grace Day cannot
   reach. Expressed once rather than as four separate conditions inside `settle_day()`, so the
   four cannot drift into disagreeing about what a refusal means -- which is the exact defect
   shape Epic 6 retrospective item 50 named. */
/* **`set search_path = ''` is kept, and it was decided on a measurement rather than on the
   convention.** PostgreSQL will not inline a SQL function carrying a `proconfig`, so this is a
   real per-row call rather than a folded-away CASE -- and the body references only its two
   arguments and one schema-qualified type, so the SET resolves nothing and could be dropped
   without changing what the function can mean.

   Measured on the local stack, 2026-09-14, 1,000,000 evaluations: with the SET, 1.34s; without
   it (inlined), 0.038s; a bare CASE, 0.034s. So the SET costs ~1.3us per call, and the inlinable
   form is indistinguishable from writing the CASE out by hand.

   Then measured in context, which is what actually decides it: 20 commitments, 200 passes of
   `commitments_owing()` with and without the five aggregate terms this function serves -- 0.347s
   against 0.340s, a difference below the run-to-run noise. `commitments_owing()` calls
   `carries_penalty_as_of()` and `due_time_as_of()` once per row, each an index lookup into a log
   table, and those dominate this by orders of magnitude. At settlement's real shape -- tens of
   commitments, once a day -- the SET costs a fraction of a millisecond per account.

   So it stays: all 82 functions in this schema carry it, `2-1-roles-and-rls.sql` treats an empty
   search_path as the house rule, and being the single exception is a permanent cost to every
   future reader in exchange for a saving that does not measure. **What would reverse this:** a
   caller that evaluates it per row at a scale `commitments_owing()` does not -- a report
   cross-joining it over a month, or a settlement path that grows to thousands of commitments per
   account. Drop the SET then, and nothing else: the body is already fully qualified. */
create function public.effective_answer(
  p_refused boolean,
  p_answer public.declaration_answer
)
returns public.declaration_answer
language sql
immutable
set search_path = ''
as $$
  select case
           when p_refused then 'slipped'::public.declaration_answer
           else p_answer
         end;
$$;

comment on function public.effective_answer(boolean, public.declaration_answer) is
  'What one commitment-day counts as when settlement judges it: the author''s own answer, unless '
  'the referee refused that day, in which case `slipped` regardless of what the author said or '
  'did not say. Story 8.2. The only combiner of commitments_owing()''s `refused` and `answer` '
  'columns -- settle_day() reads this and never the two separately, so its deadline gate, its '
  'counts, its frozen outcomes and its summary cannot come to disagree about a refusal. The '
  'identity on `answer` whenever `refused` is false, which is what makes every pre-existing '
  'settlement test pass unmodified.';

revoke execute on function public.effective_answer(boolean, public.declaration_answer)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- (iii) The owing query, and the one thing it learns.
-- ---------------------------------------------------------------------------------

/* Reproduced verbatim from its live definition (20260829090000:308-360) with exactly the
   additions Design Notes name: the `refused` output column, the `left join lateral`, and every
   read of `cadence` and `carries_penalty` moved onto the frozen value -- the two `where`
   predicates included. Diff it against that block; nothing else moved.

   **`drop function` and `create`, not `create or replace`.** A `returns table` signature cannot be
   changed in place. The drop destroys the ACL and a bare `create` in `public` hands EXECUTE
   straight back to PUBLIC, `anon` included -- the hazard 20260903090000:43-47 records for
   `outbox_enqueue`. The `revoke` below is re-issued for that reason, and
   `supabase/tests/2-1-roles-and-rls.sql:480` already asserts it and is what would catch a miss.

   With no decision row `rd` is NULL throughout, `refused` is false, both coalesces read their
   live arguments, the archived exception is inert and both `where` predicates are the expressions
   they were yesterday. That is what makes every pre-existing test pass unmodified. */
drop function public.commitments_owing(uuid, date);

create function public.commitments_owing(p_owner uuid, p_day date)
returns table (
  refused boolean,
  commitment_id uuid,
  carries_penalty boolean,
  answer public.declaration_answer,
  cadence public.commitment_cadence,
  due_time time
)
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(rd.hit, false),
         c.id,
         coalesce(rd.carries_penalty, public.carries_penalty_as_of(c.id, p_day)),
         case
           when t.due_time is null then d.answer
           when d.answer is distinct from 'held' then d.answer
           when exists (
             select 1 from public.evidence e where e.declaration_id = d.id
           ) then d.answer
           when now() >= public.day_ends_at(p_day) then 'slipped'::public.declaration_answer
           else null
         end,
         coalesce(rd.cadence, c.cadence),
         t.due_time
    from public.commitment c
    cross join lateral (select public.due_time_as_of(c.id, p_day) as due_time) t
    left join public.declaration d
           on d.commitment_id = c.id and d.for_day = p_day
    -- The refusal, and the world it was made in. One `left join lateral` serving all four uses
    -- below: the `refused` column itself, the frozen money flag, the frozen cadence, and the one
    -- narrow archived exception.
    --
    -- **The flag read goes inside the lateral, not beside it in a conjunction.** Putting it in
    -- the lateral's own `where` evaluates it once per decision row rather than once per
    -- commitment per day, and it matters: `settle_day()` calls this five times per account per
    -- day and `commitment_answer_rate_for_month()` cross-joins it over a whole month
    -- (20260826110000:321-323). Written as a conjunction beside `rd.approved is false` it would
    -- have rested on `AND` operand order, which is not contractual in PostgreSQL -- a hope, not a
    -- structure.
    --
    -- `is true`, never bare: requires_referee_approval_as_of() answers NULL for a commitment with
    -- no log history, and a NULL predicate would drop the row rather than fail open here -- but
    -- the door is written the same way in both of this story's readers so neither can be read as
    -- the other's opposite.
    --
    -- The unique index leads with `(subject, for_day)`, which is exactly how this asks it.
    -- `hit` is a marker column and it is not decoration. Iteration 3 of this story's review
    -- caught the alternative: `rd.* is not null` tests "every column of the row is non-null",
    -- not "a row matched", and it is correct here only because both frozen columns happen to be
    -- `NOT NULL` today. The moment a later story surfaces `reason` or `created_at` through this
    -- lateral -- Story 8.5 needs the reason -- `refused` would silently read false for every
    -- refusal in the schema, and so would the archived exception below, which asks the same
    -- question. A constant column cannot be made null by anything added beside it.
    left join lateral (
      select true as hit, r.carries_penalty, r.cadence
        from public.referee_decision r
       where r.subject = p_owner and r.for_day = p_day and r.commitment_id = c.id
         and not r.approved
         and public.requires_referee_approval_as_of(c.id, p_day) is true
    ) rd on true
   where c.owner_id = p_owner
     and coalesce(rd.cadence, c.cadence) <> 'daily_hours_quota'
     -- Nothing is judged for a day it did not exist on. The same guard resolve_auto_checks()
     -- (20260824090000) and settle_week() (20260820150000) already carry, arriving here late:
     -- while every deadline was D+3 a brand-new commitment already cost two of the five days
     -- settle_due_days() sweeps, and with midnight it would cost all five.
     --
     -- Every fixture under supabase/tests/ had to learn to say when its commitments began --
     -- eighteen of them created a commitment moments before judging days that predate it, which
     -- is a state no real account can be in.
     and (c.created_at at time zone 'Asia/Ho_Chi_Minh')::date <= p_day
     and (c.archived_at is null
          or (c.archived_at at time zone 'Asia/Ho_Chi_Minh')::date > p_day
          -- One narrow exception, and the only reason this clause moves at all: a commitment the
          -- author archives *after* a refusal must not drop out of the day the refusal named.
          -- `object_to_day()` names this exact attack at 20260906080451:365-370 and defeats it by
          -- copying frozen rows; this path has no frozen rows to copy. The ordering -- that the
          -- commitment was not already archived when the referee decided -- is enforced at the
          -- other end, by sign_off_day() refusing an archived commitment outright.
          or rd.hit is true)
     -- A Weekly Quota is judged at week close, and not doing it on a Tuesday is the shape of the
     -- commitment rather than a silence. While the morning gate asked about it daily there was an
     -- answer every day and the day had something to say; a timed one is not asked (the gate
     -- exclusion below), so an unclaimed day would sit here unanswered and settle the whole day
     -- `expired` -- no summary, a broken chain, and Story 5.2's intervention firing at an author
     -- who is on target for the week. A day it *was* claimed on still appears, held or slipped,
     -- because there is something to say about that one. weekly_held_count() remains the only
     -- thing that judges the quota itself.
     and not (coalesce(rd.cadence, c.cadence) = 'weekly_quota' and t.due_time is not null and d.id is null);
$$;

comment on function public.commitments_owing(uuid, date) is
  'Every commitment p_owner owes an answer for on p_day, whether it was penalty-carrying AS OF
  THAT DAY (carries_penalty_as_of(), Epic 4 retrospective A1 fix, 2026-08-27), and what it
  actually did. Excludes daily_hours_quota (FR-2, judged by measured minutes) and a commitment
  archived on or before p_day, a commitment created after p_day, and a timed weekly_quota
  commitment on a day it was not claimed. cadence is read by settle_day/settle_week to exclude
  weekly_quota from the two counts that turn a miss into money; due_time is the value that governed
  p_day (due_time_as_of(), never the live column) and is read by the same callers to know which
  deadline this row is judged against (commitment_deadline()). Story 6.4: on a commitment that
  carried a due_time through p_day, a claim of held is reported as held only once evidence exists
  for it, and as slipped once the day it was made has ended without any -- the photo is what holds
  a timed day, not the tap. A commitment with no declaration at all still reports null, unchanged:
  that is what Silence detection and the answer-rate measures count.

  Story 8.2 adds `refused`: true exactly when the referee refused this commitment on this day AND
  the commitment asked for his signature as of that day (requires_referee_approval_as_of(), the
  one door, never a live read). `answer` is untouched and still means what the AUTHOR said --
  the silence intervention and commitment_answer_rate_for_month() both count it and neither may be
  made to see a third party''s write as the author being present. settle_day() combines the two
  through effective_answer(). For a refused commitment-day, carries_penalty and cadence are read
  from the decision row rather than live, and the archived filter keeps the row: three edits
  `commitment: edit own` permits between a refusal and midnight each used to void it outright.
  With no decision row every one of those expressions is exactly what it was before this story.';

revoke execute on function public.commitments_owing(uuid, date) from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- (iv) The 48-hour objection, with one door closed.
-- ---------------------------------------------------------------------------------

/* Reproduced verbatim from its live definition (20260906080451:117-428) with exactly one guard
   added. Not from the 6.7 file, which has neither the advisory lock nor the under-lock re-read.
   Diff it against that block; nothing else in those 300 lines moved -- not the lock, not the
   landing guards, not the whole-day freeze, not the penalty carry-forward, not the notification. */
create or replace function public.object_to_day(
  p_settlement_id uuid,
  p_commitment_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_settlement record;
  v_penalty record;
  v_outcome public.commitment_outcome;
  v_cadence public.commitment_cadence;
  v_paired uuid;
  v_admitted integer;
  v_unanswered integer;
  v_correction uuid;
  v_objection uuid;
begin
  -- First statement, before any row is read -- the I/O Matrix's own "Not the referee" row:
  -- refused before any row is read, role check first, then RLS. `is distinct from`, not `<>`,
  -- for the reason rule_appeal() spells out at 20260825090000:105: a plain `<>` against a NULL
  -- role evaluates NULL, and `if NULL then raise` never raises -- the refusal would silently not
  -- happen for the one caller a role check exists to catch.
  if public.role_from_table() is distinct from 'referee' then
    raise exception 'Only the referee may object to a day.';
  end if;

  -- He must give a reason, and it is bounded. Both checked before anything is read, for the same
  -- reason the role is: a malformed call should not get as far as reading the author's day.
  -- `objection_reason_is_said` is the real guarantee; these two are what turn it into a sentence
  -- he can act on instead of a raw 23514 rendered verbatim on his screen.
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'An objection has to say why. Give a reason.';
  end if;

  if char_length(btrim(p_reason)) > 2000 then
    raise exception
      'That reason is % characters. Say it in 2000 or fewer -- he reads it on the day it names.',
      char_length(btrim(p_reason));
  end if;

  select * into v_settlement
    from public.settlement where id = p_settlement_id and kind = 'day';

  if not found then
    raise exception 'No such settled day.';
  end if;

  -- The account he is paired to, and only that one. The role check above says who is calling; it
  -- says nothing about whose money this is, and this function mints a debt.
  v_paired := public.paired_doer_id();

  if v_paired is null then
    raise exception
      'You are not paired to an account, so there is no day here that is yours to question.';
  end if;

  if v_settlement.subject <> v_paired then
    raise exception 'That day belongs to an account you are not paired to.';
  end if;

  -- The role and paired-account checks deliberately stay before the lock: an unscoped caller must
  -- not be allowed to hold another account's serialization key. Once scope is established, take
  -- the same per-account transaction advisory lock as mark_penalty_collected() before reading
  -- currentness, Penalty state, or any other mutable fact that decides whether money moves.
  perform pg_advisory_xact_lock(hashtext(v_settlement.subject::text));

  -- The pre-lock lookup existed only to validate account scope. Re-read the settlement under the
  -- lock before the correction uses its subject, period, deadline, currentness, or frozen rows.
  select * into v_settlement
    from public.settlement where id = p_settlement_id and kind = 'day';

  if not found then
    raise exception 'No such settled day.';
  end if;

  -- The day moved on between his reading it and his objecting -- a Grace Day the author spent, an
  -- appeal ruled, an expiry corrected, or another objection. Refused rather than superseded a
  -- second time: settlement_once_correction allows at most one correction per original, so this
  -- is the difference between a clear sentence and a duplicate-key error.
  if exists (select 1 from public.settlement c where c.supersedes = p_settlement_id) then
    raise exception
      'That day has already been resolved -- something has corrected it since you read it. '
      'Look it up again.';
  end if;

  -- Already objected to, checked here rather than left to the insert below. The unique index is
  -- still the actual guarantee -- a check-then-act read cannot make one on its own, exactly as
  -- `profile_single_referee` (20260824160000) says of `pair-referee`'s own early check. This is
  -- what makes the *reachable* case read as the guarded transition it is: without it, a second
  -- objection aimed at the correction the first one wrote falls through to the outcome check
  -- below and is told there is no `held` to contest, which is true and answers the wrong
  -- question. A day is objected to once; that is the sentence he should get.
  if exists (
    select 1 from public.objection o
     where o.subject = v_settlement.subject and o.for_day = v_settlement.period
  ) then
    raise exception 'That day has already been objected to. It is already resolved.';
  end if;

  -- The window. Half-open, matching every other deadline in this schema: an objection at exactly
  -- 48 hours is late.
  if now() >= public.objection_deadline(v_settlement.settled_at) then
    raise exception
      'That day settled more than 48 hours ago. The window has closed and the day stands.';
  end if;

  -- There has to be a `held` to contest, and it is read from the frozen row rather than from
  -- today's declarations. A commitment the day already recorded as missed or unanswered has
  -- nothing for an objection to overturn, and forcing it to `missed` again would write a
  -- correction identical to the row it supersedes -- money and chain unchanged, one more link in
  -- the chain, and a notification about nothing.
  select sc.outcome into v_outcome
    from public.settlement_commitment sc
   where sc.settlement_id = p_settlement_id and sc.commitment_id = p_commitment_id;

  if not found then
    raise exception 'That commitment was not part of that day.';
  end if;

  -- Two mechanisms for one job is how they come to disagree, so a flagged commitment is
  -- unreachable from here -- enforced in SQL rather than left to convention, which is what
  -- Epic 8's SPEC asks for. The referee's power over a flagged commitment is sign_off_day(),
  -- before midnight, and the 48-hour objection stays exactly what it was for every unflagged one.
  --
  -- Read through requires_referee_approval_as_of(), never live and never as of today: the flag as
  -- it stood on the day being objected to is what decides which door that day belonged to, so
  -- switching it off afterwards does not reopen this one. `is true` rather than a bare call --
  -- the door answers NULL for a commitment with no log history, and `if NULL then raise` never
  -- raises, which would fail open into exactly the path this guard exists to close.
  --
  -- Placed after the frozen-row lookup above and before the outcome check below, deliberately:
  -- after, so the commitment is known to be part of a day of the account he is paired to and this
  -- sentence cannot be used to probe the flag on some other account's commitment id; before, so a
  -- flagged commitment gets this sentence whatever its outcome reads, rather than being told
  -- there is no `held` to contest on a day his own refusal already froze `missed`.
  if public.requires_referee_approval_as_of(p_commitment_id, v_settlement.period) is true then
    raise exception
      'That commitment asks for your signature on the day itself, not here.';
  end if;

  if v_outcome <> 'held' then
    raise exception
      'That day already reads % for that commitment, not held. There is nothing to object to.',
      v_outcome;
  end if;

  -- ---------------------------------------------------------------------------------
  -- Guard 1, in three parts: it lands as a Failed Day with an owed Penalty, or not at all.
  --
  -- `grace_day_validate()` (20260825110000) requires `verdict = 'failed'` AND `state = 'owed'`
  -- before it will accept a Grace Day. An objection landing anywhere else leaves the author a
  -- broken chain and nothing to answer it with -- not a Grace Day, and not an appeal either, which
  -- needs `filed_by = 'auto_check'` and is not what an objection is. So rather than land him there
  -- and call the promise true, the objection is refused.
  -- ---------------------------------------------------------------------------------

  -- (a) The day's own penalty, if it has one. Read once, here, and used again below to carry a
  --     surviving one forward. `collected` is terminal -- nothing in this schema transitions out
  --     of it -- and superseding its settlement would drop money that has actually changed hands
  --     out of `penalty_current`. `held` is refused for a reason of its own: `appeal.penalty_id`
  --     points at that exact row, and `void_expired_appeals()` (20260824140000) updates only the
  --     row the appeal points at, so superseding it would strand an in-flight appeal on an
  --     invisible penalty that could never drop. Every other non-`owed` state is already resolved
  --     and a Grace Day cannot reach it.
  select * into v_penalty from public.penalty where settlement_id = p_settlement_id;

  if found and v_penalty.state <> 'owed' then
    raise exception '%', case v_penalty.state
      when 'collected' then
        'That day''s penalty has already been collected. One day is charged once, so it cannot '
        || 'be objected to now.'
      when 'waived' then
        'He has already spent a Grace Day on that day. Objecting now would break his chain and '
        || 'leave him nothing to answer it with.'
      when 'held' then
        'That day''s penalty is on hold under an open appeal. Rule on the appeal first -- '
        || 'objecting now would strand it.'
      when 'dropped' then
        'That day''s penalty was dropped when its appeal timed out. It is resolved, and objecting '
        || 'now would leave him no way to answer.'
      when 'voided' then
        'That day''s penalty was voided by your own ruling. It is resolved, and objecting now '
        || 'would leave him no way to answer.'
      else
        'That day''s penalty is no longer owed, so a Grace Day could not answer an objection to it.'
    end;
  end if;

  -- (b) The objected commitment has to be able to cost money that day, or the correction lands
  --     `clean` with no penalty: a broken chain and nothing to spend a Grace Day on.
  --     `carries_penalty_as_of()` (20260827130000), never the live column -- what a miss cost is
  --     settled when the day ended, and turning the money off today must not decide what an
  --     objection to last Tuesday means.
  if not public.carries_penalty_as_of(p_commitment_id, v_settlement.period) then
    raise exception
      'That commitment carried no penalty on that day, so an objection would cost him nothing '
      'and break his chain with no Grace Day able to reach it.';
  end if;

  select c.cadence into v_cadence from public.commitment c where c.id = p_commitment_id;

  if v_cadence = 'weekly_quota' then
    raise exception
      'That is a Weekly Quota commitment. Its money is decided at week close and never by one '
      'day, so an objection would break his chain with no Grace Day able to reach it.';
  end if;

  -- (c) The day must not land `expired`. settle_day() reads `expired` whenever any commitment was
  --     owed an answer and gave none, which is exactly a frozen `unanswered` outcome -- and
  --     `grace_day_validate()` refuses an expired day, so an objection that produced one would
  --     again leave him nothing. This is also what keeps `supersede_expiries()` off an objection
  --     forever: it only ever loops over `settlement_current` rows reading `expired`, and no
  --     correction written here can be one.
  --
  --     Counted in the same pass as `admitted`, from the superseded settlement's own frozen rows
  --     (see the freeze below for why never a live recompute). `admitted` mirrors settle_day()'s
  --     own filter verbatim -- `carries_penalty and cadence <> 'weekly_quota'` -- with the objected
  --     commitment added to it, which is the whole content of the objection.
  select count(*) filter (
           where public.carries_penalty_as_of(sc.commitment_id, v_settlement.period)
             and c.cadence <> 'weekly_quota'
             and (sc.outcome = 'missed' or sc.commitment_id = p_commitment_id)
         ),
         count(*) filter (where sc.outcome = 'unanswered')
    into v_admitted, v_unanswered
    from public.settlement_commitment sc
    join public.commitment c on c.id = sc.commitment_id
   where sc.settlement_id = p_settlement_id;

  if v_unanswered > 0 then
    raise exception
      'That day closed on the clock with % commitment(s) he never answered, so correcting it '
      'would leave it expired -- and a Grace Day cannot reach an expired day.', v_unanswered;
  end if;

  -- AD-15's guarded transition, and the only thing standing between two concurrent objections --
  -- the read above serializes nothing, and two calls that both pass it arrive here. The second
  -- blocks on the unique index until the first commits, then finds its own `on conflict do
  -- nothing` inserted nothing. Everything below runs solely for the call that actually won it;
  -- the loser is told the day is already resolved rather than silently doing nothing, in the same
  -- words the read above uses so a race and a repeat read identically to him.
  insert into public.objection
    (subject, referee_id, for_day, commitment_id, reason, superseded_settlement)
  values (v_settlement.subject, (select auth.uid()), v_settlement.period, p_commitment_id,
          btrim(p_reason), p_settlement_id)
  on conflict (subject, for_day) do nothing
  returning id into v_objection;

  if not found then
    raise exception
      'That day has already been objected to. It is already resolved.';
  end if;

  -- `failed`, written as the constant it provably is rather than as a `case` whose other arms are
  -- unreachable and therefore untestable: (c) has ruled out `expired`, and (b) guarantees the
  -- objected commitment is counted in `v_admitted`, so `v_admitted >= 1` and the day cannot read
  -- `clean`. `missed_count` is `v_admitted` alone for the same reason -- settle_day() writes
  -- `admitted + silent`, and the silent term is zero by (c).
  insert into public.settlement (subject, period, kind, verdict, missed_count, supersedes)
  values (v_settlement.subject, v_settlement.period, 'day', 'failed', v_admitted, p_settlement_id)
  returning id into v_correction;

  -- What each commitment did, frozen against the correction -- the **whole** day, and copied from
  -- the superseded settlement's own frozen rows rather than recomputed.
  --
  -- **Never `commitments_owing()`.** That function reads today's commitments: a commitment the
  -- author archives inside the 48-hour window drops out of it, so the correction would simply not
  -- contain the row the objection is about, and archiving would defeat an objection outright. An
  -- enforcement mechanism the person being enforced against can switch off is not one. The frozen
  -- rows are also the only honest source -- they are what the day actually recorded, which is the
  -- thing being corrected.
  --
  -- **And never only the objected commitment.** 20260820102000 exists because a correction with no
  -- frozen outcomes vanishes the day from every commitment's chain rather than breaking one of
  -- them; a correction carrying only the objected row does the same thing to all the others.
  --
  -- One arm added to the copy: the objected commitment reads `missed` regardless of what its own
  -- declaration and photo say, because that is the entire content of the objection.
  insert into public.settlement_commitment (settlement_id, subject, commitment_id, outcome)
  select v_correction, v_settlement.subject, sc.commitment_id,
         case
           when sc.commitment_id = p_commitment_id then 'missed'::public.commitment_outcome
           else sc.outcome
         end
    from public.settlement_commitment sc
   where sc.settlement_id = p_settlement_id;

  -- The money. FR-13: one penalty per failed day, in every state.
  --
  --   * The day already carried one -> carry it forward unchanged, state and amount, onto the
  --     correction. Not a second charge: `penalty_current` follows the chain, so exactly one row
  --     is ever live for the day, and the original stays in the table as history the same way
  --     every other correction path leaves it. Guard 1(a) means the state carried is always
  --     `owed`; it is copied rather than written as a literal so the day the enum grows another
  --     state this reads what the row said rather than what this line assumed.
  --   * The day carried none -> mint it, at the ordinary Failed Day amount. Guard 1(b) guarantees
  --     the day now owes one, so there is no third branch: an objection either carries a penalty
  --     forward or creates exactly one, never neither.
  --
  -- Either way the result is an ordinary Failed Day penalty: the Ledger shows it, apply_grace_days()
  -- waives it, and nothing anywhere special-cases it.
  if v_penalty.id is not null then
    insert into public.penalty (subject, settlement_id, amount_dong, state)
    values (v_settlement.subject, v_correction, v_penalty.amount_dong, v_penalty.state);
  else
    insert into public.penalty (subject, settlement_id, amount_dong)
    values (v_settlement.subject, v_correction, public.penalty_amount_dong());
  end if;

  -- The author is told, in the same transaction as the correction (AD-3), on the push channel.
  -- Keyed by the objection's own id, which the unique constraint above makes once-per-day -- a
  -- race loser never reaches this statement at all, having already raised.
  --
  -- The amount is named only when this objection is what made the day cost money. An
  -- already-failed day's penalty did not move, and a notification naming an amount for it would
  -- read as a second charge.
  perform public.outbox_enqueue(
    v_settlement.subject,
    'objection-' || v_objection::text,
    jsonb_build_object(
      'title', 'The referee objected',
      'body', public.objection_body(
                v_settlement.period,
                case when v_penalty.id is null then public.penalty_amount_dong() end),
      'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    )
  );
end;
$$;

comment on function public.object_to_day(uuid, uuid, text) is
  'Story 6.7; Epic 6 retrospective item 36; Story 8.2. Checks role_from_table() = ''referee'' first '
  'and validates the paired account before taking that account''s transaction advisory lock. Under '
  'the lock it re-reads the settlement, currentness, frozen outcomes, Penalty and every mutable '
  'fact used to write money, serializing objections with mark_penalty_collected(). The existing '
  'eligibility, 48-hour, one-objection, failed+owed landing, whole-day freeze, one-Penalty, '
  'notification, security-definer and empty-search-path behavior remains unchanged. Story 8.2 adds '
  'one refusal: a commitment that asked for the referee''s signature on the day being objected to '
  '(requires_referee_approval_as_of(), as of that day and never live) is unreachable from here -- '
  'its door is sign_off_day(), before midnight. Two mechanisms for one job is how they come to '
  'disagree, and the SPEC asks for this in the database rather than by convention.';

-- Unchanged from 20260906080451:439-442, re-issued because `create or replace` preserves the ACL
-- and this is a replace, not a drop: stated rather than silently relied on.
revoke execute on function public.object_to_day(uuid, uuid, text) from public, anon;
grant execute on function public.object_to_day(uuid, uuid, text) to authenticated;


-- ---------------------------------------------------------------------------------
-- (v) Settlement, reading the derived answer.
-- ---------------------------------------------------------------------------------

/* Reproduced verbatim from its live definition (20260829090000:397-556) with one change and one
   reason for it: frozen decision 4 requires a refusal to count as answered, so the day lands
   `failed` rather than `expired` and a Grace Day can still reach it. That behaviour cannot come
   from `answer` -- three non-settlement readers depend on `answer` meaning what the author said --
   so it comes from `refused`, combined once by effective_answer() and read in four places: the
   counts, the deadline gate, the frozen outcomes and the summary.

   Nothing else moves. In particular commitment_deadline(), day_ends_at() and day_begins_at() are
   untouched, the AD-13 Auto-check gate is left verbatim (see its own note below), and the deadline
   gate's rule is the same rule -- a day is held while any commitment still owes an answer that
   could still arrive; a refused commitment no longer owes one. */
create or replace function public.settle_day(p_day date, p_override boolean default false)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  invocation text := coalesce(current_setting('app.settlement_invocation', true), '');
  account record;
  total integer;
  answered integer;
  admitted integer;
  silent integer;
  held integer;
  survivor_id uuid;
  survivor text;
  survivor_chain integer;
  suggestion text;
  verdict public.day_verdict;
  inserted integer;
  new_settlement uuid;
  settled integer := 0;
begin
  if current_user in ('anon', 'authenticated') then
    raise exception 'settle_day is never callable from the application (AD-2)';
  end if;

  if invocation <> 'schedule' and not p_override then
    raise exception
      'settle_day ran outside its schedule with no override. Pass p_override => true, '
      'which is refused for the live doer account (AD-16).';
  end if;

  for account in
    select p.id, p.is_live_doer, p.morning_hour from public.profile p where p.role = 'doer'
  loop
    if p_override and account.is_live_doer then
      raise exception
        'settle_day refuses an override against the live doer account (AD-16). '
        'Only the schedule may settle it.';
    end if;

    -- Story 8.2: every read of what a commitment did goes through effective_answer(), which is
    -- the identity on o.answer for every day nobody refused. A refusal counts as *answered* --
    -- frozen decision 4 -- so the day lands `failed` rather than `expired`, which is the one
    -- verdict a Grace Day cannot reach; and it must reach `admitted` and `silent` through the
    -- same expression, or a refused commitment the author never answered would be counted once in
    -- each and charge missed_count twice for one commitment.
    select count(*),
           count(public.effective_answer(o.refused, o.answer)),
           count(*) filter (
             where o.carries_penalty
               and public.effective_answer(o.refused, o.answer) = 'slipped'
               and o.cadence <> 'weekly_quota'
           ),
           count(*) filter (
             where o.carries_penalty
               and public.effective_answer(o.refused, o.answer) is null
               and o.cadence <> 'weekly_quota'
           ),
           count(*) filter (where public.effective_answer(o.refused, o.answer) = 'held')
      into total, answered, admitted, silent, held
      from public.commitments_owing(account.id, p_day) o;

    continue when total = 0;

    -- AD-13: a day cannot settle while any of its owed, unanswered, Auto-check-linked
    -- commitments still has a pending check for it — bounded by auto_check_pending's own
    -- 96-hour grace window rather than held open indefinitely. Checked ahead of the deadline
    -- gate on purpose: an expired-but-Auto-check-pending day must still block, which is
    -- exactly the race Story 4.2 closed. Excludes weekly_quota the same way admitted/silent
    -- above do: a Weekly Quota commitment's own Auto-check protection is settle_week's guard,
    -- not this one — commitments_owing() does not exclude weekly_quota from its result set
    -- (only daily_hours_quota is excluded), so without this filter a stuck weekly-quota check
    -- would delay the whole day's settlement, notification and penalty freeze for every other,
    -- unrelated commitment on the account — a collateral cost that story never asked for.
    continue when exists (
      select 1 from public.commitments_owing(account.id, p_day) o
       -- Story 8.2, and this one is a sixth way the author could have voided a refusal.
       --
       -- An earlier draft left this read on `o.answer` and argued it was equivalent, because
       -- `commitment_sign_off_not_with_auto_check` (20260911090000:68-70) forbids a flagged
       -- commitment from carrying an Auto-check. **That is a CHECK on the live row, and
       -- `commitment: edit own` is unrestricted.** Refused at 21:00; the flag switched off at
       -- 22:00, which does not un-refuse the day because the lateral reads the `_as_of()` door;
       -- an Auto-check attached at 22:01, which the CHECK now permits. auto_check_pending() then
       -- reads true -- there is no declaration, because an untimed commitment's author is not
       -- asked until the next morning -- and this gate holds the **whole account's** day for up
       -- to 96 hours. That is "no day is ever held open waiting for a person" defeated by the
       -- person being enforced against, and 20260824100000:40-47 records this same 96-hour class
       -- as a bug caught in review once before.
       where public.effective_answer(o.refused, o.answer) is null
         and o.cadence <> 'weekly_quota'
         and public.auto_check_pending(o.commitment_id, p_day)
    );

    -- The deadline, per commitment (Story 6.4). Hold the day while any single commitment still
    -- owes an answer that its own clock would still accept. An untimed commitment's clock is
    -- the account's morning hour on p_day + 3; a timed one's ran out at midnight.
    continue when exists (
      select 1 from public.commitments_owing(account.id, p_day) o
       -- Story 8.2: a refused commitment owes no further answer. An untimed one's own deadline is
       -- the next morning, so without this the day would hold past midnight waiting for an author
       -- whose day the referee has already decided.
       where public.effective_answer(o.refused, o.answer) is null
         and now() < public.commitment_deadline(p_day, account.morning_hour, o.due_time)
    );

    verdict := case
      when answered < total then 'expired'
      when admitted > 0 then 'failed'
      else 'clean'
    end;

    insert into public.settlement (subject, period, kind, verdict, missed_count)
    values (account.id, p_day, 'day', verdict, admitted + silent)
    on conflict (subject, period, kind) where supersedes is null do nothing
    returning id into new_settlement;

    get diagnostics inserted = row_count;
    settled := settled + inserted;

    continue when new_settlement is null;

    if (admitted + silent) > 0 then
      insert into public.penalty (subject, settlement_id, amount_dong)
      values (account.id, new_settlement, public.penalty_amount_dong());
    end if;

    -- What each commitment did, frozen. This happens for an expired day too, and that is
    -- the point of `unanswered` being its own outcome: the chain has to break on silence,
    -- and the history has to say *why* it broke rather than filing it as a miss.
    insert into public.settlement_commitment (settlement_id, subject, commitment_id, outcome)
    select new_settlement, account.id, o.commitment_id,
           -- Story 8.2: the same derived answer the counts above read, so the verdict and the
           -- frozen rows cannot disagree about a refusal. A refused day freezes `missed`
           -- whatever the author said or did not say.
           case public.effective_answer(o.refused, o.answer)
             when 'held' then 'held'
             when 'slipped' then 'missed'
             else 'unanswered'
           end::public.commitment_outcome
      from public.commitments_owing(account.id, p_day) o;

    -- No summary for a day that expired. The data is there and it is tempting, but a
    -- message saying "one of five today, start with X tomorrow" about a day he never
    -- answered is the product pretending it knows how his day went. It knows he did not say.
    continue when verdict = 'expired';

    -- One commitment that held, and one to start with tomorrow. Deliberately single values
    -- rather than lists: two suggestions is a to-do list, and a list of misses is the thing
    -- this message exists to replace.
    select c.id, c.name into survivor_id, survivor
      from public.commitments_owing(account.id, p_day) o
      join public.commitment c on c.id = o.commitment_id
     -- Story 8.2: read through the same expression as `held` above, or the summary could name a
     -- refused commitment as the one that held on a day counting zero held.
     where public.effective_answer(o.refused, o.answer) = 'held'
     order by c.created_at
     limit 1;

    select c.name into suggestion
      from public.commitments_owing(account.id, p_day) o
      join public.commitment c on c.id = o.commitment_id
     order by (public.effective_answer(o.refused, o.answer) = 'slipped') desc, c.created_at
     limit 1;

    continue when suggestion is null;

    -- Read after the outcomes above are written, so the number includes the day being
    -- summarised: "day 12" means it has now held twelve days, not eleven and counting.
    select ch.current_days into survivor_chain
      from public.chain_current ch
     where ch.commitment_id = survivor_id;

    perform public.outbox_enqueue(
      account.id,
      'summary-' || account.id::text || '-' || p_day::text,
      jsonb_build_object(
        'title', 'Today',
        'body', public.day_summary_body(
                  held, total, p_day,
                  case when (admitted + silent) > 0 then public.penalty_amount_dong() end,
                  survivor, suggestion, survivor_chain),
        'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      )
    );
  end loop;

  return settled;
end;
$$;

-- Unchanged from 20260829090000:558, re-issued for the same reason object_to_day()'s pair is:
-- `create or replace` preserves the ACL, and saying so is cheaper than the next reader checking.
revoke execute on function public.settle_day(date, boolean) from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- (vi) The expiry correction, reading the same derived answer.
-- ---------------------------------------------------------------------------------

/* Reproduced verbatim from its live definition (20260829090000:578-656). The other reader of
   `commitments_owing()` that decides what a commitment DID from its answer, and it carries
   settle_day()'s own two shapes: the `admitted` filter at `:607` and the frozen-outcome mapping
   at `:636`. A correction it writes for an expired day would otherwise restore a refused
   commitment to `held`, mint no penalty for it, and repair the chain the refusal broke.

   **`apply_grace_days()` reads `commitments_owing()` too and is deliberately NOT routed through
   `effective_answer()`.** It writes `'held'` for every commitment on the day as a literal
   (20260825110000:436-438) and reads no answer at all, so there is nothing here to move. That is
   not an oversight in either direction: a Grace Day forgives the day **whole**, which is the only
   shape that does not vanish the day from every other commitment's chain, and CAP-5 says a Grace
   Day still reaches a refused day. So spending one on a refused day repairs the chain the refusal
   broke and waives the penalty -- intended, and pinned in Step 9 of this story's test file so it
   cannot drift into either reading by accident.

   **This function and `settle_day()` have shared a defect once already.** `deferred-work.md`'s
   Story 3.3 entry records `supersede_expiries()` carrying the identical `weekly_quota` bug and
   being fixed in the same pass. Leaving it behind here is the shape both that entry and Epic 6
   retrospective item 50 exist to stop: when a rule gains a one-door abstraction, every reader
   moves through it in the same change, not in the next story.

   Three reads move, not two -- see the note on `timely` inside. Nothing else does: the per-row
   deadline, the `continue` rule, the correction's own verdict arithmetic and its penalty are all
   exactly what they were. With no decision row `o.refused` is false throughout, `effective_answer()`
   is the identity on `answer`, and every expression is the one it was before this story. */
create or replace function public.supersede_expiries()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  expired_row record;
  morning integer;
  total integer;
  timely integer;
  admitted integer;
  correction uuid;
  corrected integer := 0;
begin
  for expired_row in
    select s.* from public.settlement_current s where s.verdict = 'expired'
  loop
    select p.morning_hour into morning from public.profile p where p.id = expired_row.subject;

    -- Story 8.2. Three reads move onto the referee's decision, and the third is a judgement call
    -- the first two force.
    --
    -- `timely` is the one that is not obvious. It asks "did this commitment's answer arrive
    -- before its own deadline", and it asks it of the *declaration*, which a refused commitment
    -- may not have at all -- an untimed one is refused against a photograph on a day the author
    -- is not asked about until the next morning (frozen decision 4). Left as it was, a single
    -- refusal makes `timely < total` true forever, the `continue` below fires on every pass, and
    -- the day stays `expired`. That is not a no-op: the author's own answer to some *other*
    -- commitment, given in time and merely delivered late, is thrown away because his friend
    -- refused a different one -- and `expired` is the one verdict `grace_day_validate()`
    -- (20260825110000:165-170) refuses outright, so he is left with a broken chain and nothing to
    -- answer it with. That is precisely the state this story's landing guards exist to prevent,
    -- reached through the back door.
    --
    -- A refusal is always in time by construction: sign_off_day() refuses at day_ends_at(), and
    -- every commitment_deadline() is at or after that instant -- day_ends_at() for a timed
    -- commitment, the D+3 morning for an untimed one. So `o.refused` IS timeliness here; there is
    -- no instant to compare because the comparison is already decided.
    --
    -- settle_day()'s `answered` counts a refusal (through effective_answer()) and this function's
    -- `timely` did not: two readers of one rule disagreeing about whether a commitment has an
    -- answer, which is the shape Epic 6 retrospective item 50 names and the reason every reader
    -- moves through the one door in the same change.
    select count(*),
           count(*) filter (
             where o.refused
                or (d.id is not null
                    and d.answered_at
                          < public.commitment_deadline(expired_row.period, morning, o.due_time))
           ),
           count(*) filter (
             where (o.refused
                    or d.answered_at
                         < public.commitment_deadline(expired_row.period, morning, o.due_time))
               and public.effective_answer(o.refused, o.answer) = 'slipped'
               and o.carries_penalty
               and o.cadence <> 'weekly_quota'
           )
      into total, timely, admitted
      from public.commitments_owing(expired_row.subject, expired_row.period) o
      left join public.declaration d
             on d.commitment_id = o.commitment_id and d.for_day = expired_row.period;

    -- Still short an answer, or an answer that was genuinely late. The expiry stands and
    -- the remedy is a Grace Day, not a rewrite.
    continue when timely < total;

    insert into public.settlement (subject, period, kind, verdict, missed_count, supersedes)
    values (
      expired_row.subject,
      expired_row.period,
      expired_row.kind,
      (case when admitted > 0 then 'failed' else 'clean' end)::public.day_verdict,
      admitted,
      expired_row.id
    )
    returning id into correction;

    -- What each commitment did, frozen against the correction — the half that was
    -- missing. Every answer here is timely by the `continue` above, so the `else` arm is
    -- unreachable rather than lenient; it is written the same way `settle_day` writes it
    -- so the two cannot drift into disagreeing about what an outcome means.
    insert into public.settlement_commitment (settlement_id, subject, commitment_id, outcome)
    select correction, expired_row.subject, o.commitment_id,
           -- Story 8.2, and the same expression the counts above read. Without it a correction
           -- restores a refused commitment to `held`, its penalty is not minted, and the chain
           -- the refusal broke is repaired -- the author's friend having refused the day for
           -- nothing. The `else` arm stays unreachable for the reason above it says: every row
           -- here is either refused, and maps to `missed`, or carries a timely declaration.
           case public.effective_answer(o.refused, o.answer)
             when 'held' then 'held'
             when 'slipped' then 'missed'
             else 'unanswered'
           end::public.commitment_outcome
      from public.commitments_owing(expired_row.subject, expired_row.period) o;

    -- The correction carries its own penalty if he did admit a slip. The original's
    -- penalty stays in the table as history and stops counting, because `penalty_current`
    -- follows the chain.
    if admitted > 0 then
      insert into public.penalty (subject, settlement_id, amount_dong)
      values (expired_row.subject, correction, public.penalty_amount_dong());
    end if;

    corrected := corrected + 1;
  end loop;

  return corrected;
end;
$$;

-- Unchanged from 20260829090000:658, re-issued for the same reason its two neighbours are:
-- `create or replace` preserves the ACL, and saying so is cheaper than the next reader checking.
revoke execute on function public.supersede_expiries() from public, anon, authenticated;
