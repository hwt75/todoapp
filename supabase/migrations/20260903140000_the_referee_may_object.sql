-- Story 6.7 — the referee may object.
--
-- A photo holds a timed day by itself (Story 6.4). Nothing let the one person the arrangement
-- exists for say *that photo does not show what you claim it shows*, so the only check on the
-- proof was the author's own honesty — the thing the money was supposed to stand in for.
--
-- **The referee is never sent a queue.** With no referee action at all, every proven day settles
-- held exactly as it does today: nothing in this file runs on a schedule, nothing enqueues
-- anything to him, and no trigger fires on his behalf. He reaches a day by looking it up himself
-- (`referee_day_lookup()`), and a day nobody objects to holds. A design that makes a day depend on
-- him acting is the wrong design whatever else it gets right, so the entire feature is one RPC he
-- may or may not ever call.
--
-- **This is the first correction in the project that moves a day the wrong way.**
-- `supersede_expiries()`, `rule_appeal()` approving and `apply_grace_days()` all move a day toward
-- held, clean, or less money. This one moves a day toward missed, and is the first thing that can
-- create a debt on a day that previously cost nothing. Four guards carry that weight, and none of
-- them is decoration:
--
--   1. **It lands as a Failed Day with an owed Penalty, or it does not land at all.** The story's
--      whole promise is that a Grace Day answers an objection — and `grace_day_validate()`
--      (20260825110000) requires `verdict = 'failed'` **and** `penalty.state = 'owed'`. Every other
--      landing would leave the author a broken chain, no Grace Day, and no appeal either (that path
--      needs `filed_by = 'auto_check'`, which an objection is not). So an objection is refused where
--      the corrected day would read `expired`, where the objected commitment could not carry a
--      penalty that day, and where the day's own penalty is anything but `owed`. The promise is
--      true by construction rather than patched afterwards.
--   2. **The correction freezes the whole day, from the superseded settlement's own rows.** Not a
--      live `commitments_owing()` recompute: the author could otherwise archive the commitment
--      inside the 48-hour window and the correction would simply not contain it — an enforcement
--      mechanism he can switch off is not one. A partial freeze is worse still: it vanishes the day
--      from every commitment's chain rather than breaking one of them, the exact defect
--      `20260820102000_supersession_freezes_the_day.sql` exists to fix, and this is the first
--      correction to feed `chain_current` a `missed` where a `held` stood.
--   3. **One penalty per failed day, in any state (FR-13).** An existing `owed` penalty is carried
--      forward onto the correction with its own state and amount rather than re-minted, so an
--      already-failed day still owes exactly what it owed.
--   4. **He may only object on the account he is paired to.** `role_from_table() = 'referee'` is not
--      scoping: `profile_single_referee` makes the referee global, and `20260824160000:47-53`
--      accepted an analogous unscoped read **explicitly because it was read-only**. This writes, and
--      it mints a 500,000₫ debt.
--
-- **What is reused is `rule_appeal()`'s shape, not the `appeal` table.** `appeal` has no state
-- column at all — its state lives on `penalty.state` — and the day an objection contests has no
-- penalty to park state on. There is also no answer step here: the author chose that the referee
-- decides outright, so there is no deadline of the author's to expire, nothing fires against him
-- while he is quiet, and the collision with Epic 5's Silence episodes disappears rather than being
-- managed. `appeal`, `rule_appeal()`, `void_expired_appeals()` and the appeal deadline are
-- untouched by this file.
--
-- **Two paths this deliberately does not reach into, and what keeps them safe.**
--
--   * `supersede_expiries()` re-derives a day's outcomes from `declaration.answer`, which still
--     reads `held` for an objected claim. It only ever looks at `settlement_current` rows whose
--     verdict is `expired`, and guard 1 means an objection's correction is always `failed` and is
--     never written over an expired day in the first place — so it can never undo one.
--   * `rule_appeal()` approving also recomputes from `commitments_owing()`. An appeal filed
--     *after* an objection, on some other machine-filed miss the same day, and then approved,
--     would restore the objected commitment to `held`. That path needs the referee to both object
--     and then approve, so it is not an ordinary act of the author's — and closing it means
--     changing `rule_appeal()`, which this story's own Ask First forbids. Recorded here rather
--     than left to be rediscovered.
--
-- **Rejected: a browsable list of the author's proven days on the referee's surface.** A list is a
-- queue wearing a different word, and it is exactly the property the lifecycle document
-- (`spec-timed-commitments-with-photo-proof/lifecycle.md`) says keeps an unpaid friend from
-- becoming an approval bottleneck. He objects because he already has a reason to — because he was
-- there, or because the author told him.
--
-- **Rejected: giving the referee the claim's photo.** `20260828150000` deliberately left the
-- bucket's referee policy scoped to appeal evidence, on the grounds that a referee who can see
-- proof of ordinary days but cannot act on it is surveillance nobody asked for, and said Story 6.7
-- gives him the objection and the access together or neither. The objection is what this story
-- owes him; widening `storage.objects` is a separate decision with its own privacy cost, and this
-- file adds no storage policy at all.


-- ---------------------------------------------------------------------------------
-- The account he is paired to.
-- ---------------------------------------------------------------------------------

/* The referee is global — `profile_single_referee` (20260824160000) permits exactly one, on no
   particular account — so `role_from_table() = 'referee'` answers *who is calling* and says nothing
   about *whose day this is*. That was accepted for the read policies in `20260824160000` with the
   reasoning written out at `:47-53`, and the reasoning turns on the exposure being read-only and
   pointing from a stranger's incidental rows toward the referee. `object_to_day()` writes, and what
   it writes is a debt, so it needs the scoping those policies could do without.

   `referee_invite` (20260828120000) is the pairing record: `created_by` is the doer who minted the
   invitation — a check `invite-referee` gates on `is_live_doer` — and `accepted_by` is the profile
   the referee signed up as. That is the direct answer where it exists.

   The fallback is the live doer, for the older `pair-referee` path (Story 4.5), which creates the
   account outright and writes no invitation row. `pair-referee` gates on `is_live_doer` too, so the
   two agree wherever both are present; the coalesce only matters for a referee paired before
   invitations existed.

   `order by accepted_at desc limit 1` rather than a bare `select`: at most one invitation is ever
   accepted per referee in practice, and a function that decides who may be charged money must not
   depend on that being true — a deterministic answer beats an arbitrary one. */
create function public.paired_doer_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select ri.created_by
       from public.referee_invite ri
      where ri.accepted_by = (select auth.uid())
        and ri.accepted_at is not null
      order by ri.accepted_at desc
      limit 1),
    (select p.id from public.profile p where p.role = 'doer' and p.is_live_doer)
  );
$$;

comment on function public.paired_doer_id() is
  'Story 6.7. The doer account the calling referee is paired to: the created_by of the invitation '
  'he accepted (referee_invite, 20260828120000), falling back to the live doer for a referee '
  'paired through pair-referee before invitations existed. Both paths gate on is_live_doer, so the '
  'two agree wherever both exist. Exists because role_from_table() = ''referee'' is not scoping -- '
  'profile_single_referee makes the referee global, and 20260824160000 accepted that unscoped '
  'reach explicitly because it was read-only. object_to_day() writes a debt and cannot.';

revoke execute on function public.paired_doer_id() from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- The window.
-- ---------------------------------------------------------------------------------

/* 48 hours from the superseded settlement's own creation (AD-6). Anchored to `settled_at`, not to
   the day being objected to: a day settled late — a mixed day held open to `D+3` by an untimed
   commitment, or an expiry corrected days afterwards — must still give him the same 48 hours from
   the moment there was something to object to.

   **A correction restamps `settled_at`, and that is knowingly accepted.** A Grace Day the author
   spends writes a fresh settlement, so the day's window reopens. It reopens onto a day whose
   penalty now reads `waived`, which `object_to_day()` refuses outright, so the reopened window
   reaches nothing — guard 1 closes this as a side effect rather than the window rule having to.

   Written with an explicit `at time zone` round trip rather than a bare `settled_at + interval '48
   hours'` for the reason every other deadline in this schema is (`declaration_deadline`,
   `appeal_deadline`, `day_ends_at`): the rule is 48 wall-clock hours in Asia/Ho_Chi_Minh, and
   spelling the zone is what keeps it true if this ever runs somewhere that has a DST rule. The two
   forms are identical for Asia/Ho_Chi_Minh, which has no DST — that is a property of the zone, not
   an argument for leaving the zone unsaid. */
create function public.objection_deadline(p_settled_at timestamptz)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select ((p_settled_at at time zone 'Asia/Ho_Chi_Minh') + interval '48 hours')
         at time zone 'Asia/Ho_Chi_Minh';
$$;

comment on function public.objection_deadline(timestamptz) is
  'When the referee''s 48-hour objection window on one settlement closes (AD-6). Measured from '
  'the settlement''s own settled_at, never from the day it judges -- a day held open by an '
  'untimed commitment, or one reached by a correction days later, still gets the full window '
  'from the moment there was a verdict to object to. Half-open, like every other deadline here: '
  'now() >= objection_deadline(...) is closed.';

revoke execute on function public.objection_deadline(timestamptz) from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- The objection itself.
-- ---------------------------------------------------------------------------------

create table public.objection (
  id uuid primary key default gen_random_uuid(),
  subject uuid not null references public.profile (id) on delete cascade,

  -- Who said it. An objection is the only irreversible, money-creating statement a *person* makes
  -- anywhere in this system, and `profile_single_referee` permits revoking and re-pairing, so
  -- without this the record would say a referee objected and never which one.
  --
  -- `on delete restrict`, unlike `subject`'s cascade: removing the author removes his whole
  -- account and everything about it, but removing the referee must not quietly anonymise
  -- statements he made about somebody else's money. The consequence is real and intended -- his
  -- profile row cannot be deleted while his objections stand. Re-pairing does not need it deleted.
  referee_id uuid not null references public.profile (id) on delete restrict,

  -- The day, and the one commitment on it whose `held` he is contesting. Both stored rather than
  -- derived from `superseded_settlement` at read time: the settlement chain moves on afterwards
  -- (a Grace Day the author spends next writes another correction on top of this one), and the
  -- fact that he objected to *this commitment on this day* must not have to be reconstructed
  -- through a chain that has since grown.
  for_day date not null,
  commitment_id uuid not null references public.commitment (id) on delete cascade,

  -- In his own words. Stored, and shown to the author verbatim -- an objection whose reason is
  -- paraphrased by the app is the app taking a side.
  reason text not null,

  -- The settlement this objection's correction superseded. `on delete restrict`, matching
  -- `settlement.supersedes`: the row this objection acted on is not deletable out from under it.
  superseded_settlement uuid not null references public.settlement (id) on delete restrict,

  created_at timestamptz not null default now(),

  -- He must actually say something, and not without end. Whitespace is not a reason; the upper
  -- bound is a bound on free text that reaches the author's Ledger, not a judgement about how much
  -- he ought to write. object_to_day() checks both itself first, so the referee reads a sentence
  -- rather than a raw 23514 -- this is the guarantee, that is the manners.
  constraint objection_reason_is_said
    check (char_length(btrim(reason)) between 1 and 2000),

  -- AD-15's guarded transition, as a constraint rather than a check-then-act. One objection per
  -- day, first writer wins: a second concurrent call blocks on this index until the first commits
  -- and then finds its own `on conflict do nothing` inserted nothing, which object_to_day() turns
  -- into a refusal rather than a silent no-op. Scoped to the day rather than to the commitment on
  -- purpose -- the correction it writes freezes the *whole* day, so two objections on one day
  -- would be two corrections of the same period, which settlement_once_correction would refuse
  -- anyway, with a constraint-violation message that explains nothing.
  --
  -- This index also serves every read below (`subject, for_day` is exactly how the Ledger and the
  -- lookup both ask), so there is deliberately no second index on the same two columns.
  constraint objection_once_per_day unique (subject, for_day)
);

comment on table public.objection is
  'Story 6.7. The referee''s objection to one settled day: who made it, the day, the commitment '
  'whose held he contests, his reason in his own words, and the settlement his correction '
  'superseded. Append-only and written only by object_to_day() -- there is no insert, update or '
  'delete policy for anyone. An objection is final when he makes it; the author''s recourse is the '
  'one he already has, a Grace Day, which object_to_day() refuses to land him anywhere outside of.';

comment on column public.objection.reason is
  'The referee''s own words. Shown to the author verbatim on the day it names (components/'
  'ledger.tsx) and never paraphrased. Deliberately NOT interpolated into the notification body: '
  'outbox_body_is_sendable (20260820101000) refuses a body containing "currently", "right now" '
  'and friends, so a reason that happened to use one of those words would abort the whole '
  'objection at the outbox insert -- the referee''s sentence must not be able to veto the '
  'objection it belongs to.';

alter table public.objection enable row level security;

-- The author reads the objection against his own day. That is the entire point of storing the
-- reason: he is told, in the referee's words, why a day he thought held does not.
create policy "objection: read own"
  on public.objection for select to authenticated
  using ((select auth.uid()) = subject);

-- No insert, update or delete policy for anyone, referee included. object_to_day() below is
-- `security definer` and is the only writer -- the same arrangement `penalty` has had since
-- 20260819230000, for the same reason: a client that could write one of these could decide a day.
--
-- No referee SELECT policy either. He does not need one: referee_day_lookup() answers "has this
-- day already been objected to" as a boolean about a settlement he named, which is all the
-- surface actually renders, and a policy granting him `select` on this table would hand him every
-- account's objection history -- a feed, which is the thing this story exists not to build.


-- ---------------------------------------------------------------------------------
-- The notification body.
-- ---------------------------------------------------------------------------------

/* Self-dates with the objected day's own weekday, the same way `appeal_ruling_body`
   (20260825090000) does and for the same reason: `push_body_is_sendable` (20260820101000) needs
   either a clock time or a named weekday, and an objection is about a day, not a moment.

   `p_amount` is null when the day already carried its penalty and this objection added no money —
   the sentence then says so plainly instead of naming an amount that did not change hands. It is
   the amount when the objection is what turned a day that cost nothing into a Failed Day.

   The referee's reason is deliberately absent; the column comment on `objection.reason` says why.
   The body points at the Ledger, which is where the reason is shown verbatim. */
create function public.objection_body(p_for_day date, p_amount bigint)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_amount is null then
      'The referee objected: he says that day does not hold. '
        || to_char(p_for_day, 'FMDay') || ', ' || to_char(p_for_day, 'YYYY-MM-DD')
        || ' already cost what it costs, so nothing further is owed. His reason is on that day '
        || 'in your Ledger.'
    else
      'The referee objected: he says that day does not hold. '
        || translate(to_char(p_amount, 'FM999G999G999'), ',', '.') || '₫ for '
        || to_char(p_for_day, 'FMDay') || ', ' || to_char(p_for_day, 'YYYY-MM-DD')
        || ' is owed. His reason is on that day in your Ledger.'
  end;
$$;

comment on function public.objection_body(date, bigint) is
  'The objection notification''s body. Self-dates with the objected day''s own weekday '
  '(push_body_is_sendable has no clock time to reach for here), and names an amount only when '
  'the objection is what made the day cost money -- an already-failed day says so instead. Never '
  'carries the referee''s own reason: a free-text sentence containing "currently" or "right now" '
  'would fail outbox_body_is_sendable and abort the objection itself.';

revoke execute on function public.objection_body(date, bigint) from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- What he can see of one day he named.
-- ---------------------------------------------------------------------------------

/* A `security definer` function rather than an RLS policy on `settlement_commitment`, for the
   reason `referee_missed_commitments()` (20260825100000) already gives and paid for: that table is
   `chain_current`'s own base table, and any RLS grant on it silently reopens a doer-facing surface
   Story 4.5's frozen Intent keeps off-limits to the referee. `supabase/tests/4-5-*.sql` asserts
   that absence and must keep passing unmodified.

   **What this actually grants, stated plainly.** `settlement: referee reads day and week`
   (20260824160000) already gives him every day settlement including clean ones, so naming a day
   costs no new grant — but this adds the commitment *names* and *frozen outcomes* behind that id,
   for every commitment on the day, clean days included. That is strictly more than
   `referee_missed_commitments()` gives, and its narrower `owed`-penalty scoping (`20260825100000:
   129-133`) cannot be copied here: an objection is contested against a `held` outcome on a day that
   usually owes nothing at all, so scoping this to days carrying an owed penalty would answer
   nothing on exactly the days it exists for. The narrowing that *is* available is applied instead —
   one settlement at a time, and only on the account he is paired to (`paired_doer_id()`), which is
   the same boundary `object_to_day()` writes within.

   **One settlement, never a list.** The argument is a single id he already read; there is no
   date-range form, no `= any()` array form, and no way to ask this what days exist. `role_from_
   table() = 'referee'` is a plain row filter rather than an early raise, matching AD-7's own read
   convention and `referee_missed_commitments()`'s shape: a non-referee caller gets zero rows, not
   an error.

   Eligibility is deliberately returned as facts (`outcome`, `objection_deadline`,
   `already_objected`) rather than as one `objectable` boolean. `object_to_day()` below is the sole
   judge (AD-1) and refuses each case in its own words; the client mirrors these three only to
   decide whether the control renders at all, exactly as `lib/ledger.ts`'s own `graceable` mirrors
   `grace_day_validate()`. */
create function public.referee_day_lookup(p_settlement_id uuid)
returns table (
  commitment_id uuid,
  commitment_name text,
  outcome public.commitment_outcome,
  objection_deadline timestamptz,
  already_objected boolean
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
         )
    from public.settlement_commitment sc
    join public.settlement s on s.id = sc.settlement_id
    join public.commitment c on c.id = sc.commitment_id
   where sc.settlement_id = p_settlement_id
     and s.kind = 'day'
     and public.role_from_table() = 'referee'
     and s.subject = public.paired_doer_id();
$$;

comment on function public.referee_day_lookup(uuid) is
  'Story 6.7. What one settled day he already named recorded: each commitment, its name, its '
  'frozen outcome, when the 48-hour objection window closes, and whether the day has already '
  'been objected to. Takes exactly one settlement id -- there is no range form and no way to ask '
  'it what days exist, because a browsable list of the author''s days is a queue in everything '
  'but name -- and answers only for the account he is paired to, the same boundary object_to_day() '
  'writes within. Genuinely wider than referee_missed_commitments(): it names commitments on clean '
  'days too, which is unavoidable, because an objection contests a held outcome on a day that '
  'usually owes nothing. security definer rather than an RLS policy on settlement_commitment: that '
  'table is chain_current''s own base table, and granting the referee select on it would silently '
  'reopen a doer-facing surface (the 20260825100000 incident). role_from_table() = ''referee'' is a '
  'row filter, not a raise -- a non-referee caller reads nothing, never an error (AD-7).';

revoke execute on function public.referee_day_lookup(uuid) from public, anon;
grant execute on function public.referee_day_lookup(uuid) to authenticated;


-- ---------------------------------------------------------------------------------
-- The objection.
-- ---------------------------------------------------------------------------------

/* One transaction: the guard, the correction, the whole day's freeze, exactly one penalty and the
   author's notification. A failure anywhere takes all of them, which is AD-3's reasoning applied
   inward — there is never an objection with no correction, nor a correction with no notification.

   Argument order mirrors `rule_appeal(p_appeal_id, p_approved)`: the row being acted on first.
   `p_settlement_id` is the settlement he read, which is always the *current* one (the client reads
   `settlement_current`) — so a day already corrected is superseded at its correction and never at
   the original, and `settlement_once_correction` can never be asked to fork the chain. A stale id
   is refused below rather than allowed to write a second correction of the same row.

   **Every refusal is in its own words.** There are eleven of them and they are the substance of
   this function, not its preamble: the one thing worse than an objection that should not have
   landed is a refusal the referee cannot act on. */
create function public.object_to_day(
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
  'Story 6.7. The referee''s objection to one commitment''s held on one settled day. '
  'role_from_table() = ''referee'' is checked first, before any row is read; then the reason and '
  'its bound; then the settlement; then paired_doer_id(), because the role check says who is '
  'calling and not whose money this is; then a day corrected since he read it; then a day already '
  'objected to; then the 48-hour window (objection_deadline, from the superseded settlement''s own '
  'settled_at); then an outcome that is not held; then the three parts of the landing guard -- a '
  'penalty in any state but owed, a commitment that carried no penalty that day or is a weekly '
  'quota, and a day that would correct to expired. Each refusal has its own words. The landing '
  'guard exists because grace_day_validate() requires failed + owed: every other landing would '
  'leave the author a broken chain, no Grace Day and no appeal, which is exactly what this story '
  'promised him. The guarded transition is the objection row''s own unique (subject, for_day) -- '
  'first writer wins, the loser is refused rather than silently ignored (AD-15). It then writes a '
  'correction superseding the settlement he named, freezing the WHOLE day by copying the '
  'superseded settlement''s own frozen rows with the objected commitment forced to missed (never a '
  'live commitments_owing() recompute, which the author could defeat by archiving the commitment), '
  'carries an existing owed penalty forward or mints exactly one, and enqueues one push to the '
  'author (AD-3). No queue, no notification and no obligation ever reaches the referee from this '
  'feature: with no call at all, every proven day settles held exactly as before.';

-- Directly callable by an authenticated referee session, the same shape rule_appeal() and
-- mark_penalty_collected() already use: the function itself is the privilege boundary, reached
-- over /rest/v1/rpc rather than fronted by an Edge Function or a trigger.
revoke execute on function public.object_to_day(uuid, uuid, text) from public, anon;
grant execute on function public.object_to_day(uuid, uuid, text) to authenticated;
