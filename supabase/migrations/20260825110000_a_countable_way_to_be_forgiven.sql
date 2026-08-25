-- Story 5.1 — A countable way to be forgiven (FR-17).
--
-- A Failed Day has had no way out that does not require lying about it: the author could
-- only watch a Penalty stand, or contest a machine's call he never actually disputed. This
-- gives him a limited, honest allowance instead: 2 Grace Days per calendar month
-- (confirmed with the human; non-carrying), each of which voids one Failed Day's Penalty
-- and restores that day's chain.
--
-- The shape deliberately does NOT mirror Story 4.6's `rule_appeal()`, which writes its own
-- correction synchronously. `grace_day` is a plain append-only event table (AD-9) --
-- one row per `(owner_id, for_day)` -- validated synchronously by a `before insert` trigger
-- (mirroring `appeal_hold_penalty()`'s own shape, for immediate client feedback: eligible
-- day, still owed, allowance remaining), but the actual correction -- `penalty.state ->
-- 'waived'`, the corrective `settlement`, the chain-restoring `settlement_commitment`
-- freeze -- is folded in later by `apply_grace_days()`, called from `settle_due_days()`'s
-- own hourly pass alongside `supersede_expiries()`. Settlement stays the only writer of
-- derived state (AD-8) -- the whole reason this story exists rather than adding a second
-- synchronous corrector next to `rule_appeal()`'s (a prior review found exactly that shape
-- of bug: two independent correctors of the same chain disagreeing with each other).
--
-- Unlike `voided` (Story 4.6), which structurally never reaches `penalty_current` (a won
-- appeal's correction only carries its own penalty when a *different* miss the same day
-- still owes one), `waived` must: the Ledger row has to read `Waived`, not `Clean`, so the
-- author can tell a day he chose to forgive apart from a day that simply held. So
-- `apply_grace_days()` inserts a second penalty row, on the corrective settlement itself,
-- already `waived` -- never `owed` even for an instant -- alongside marking the original
-- (now superseded) penalty `waived` too, for the trace.

-- ---------------------------------------------------------------------------------
-- The allowance, named once. `grace_day_validate()`'s own insert-time count and
-- `grace_allowance_remaining`'s own arithmetic both read this rather than each carrying
-- their own literal `2` -- the two are guaranteed to agree by construction rather than by
-- two authors remembering to update both.
-- ---------------------------------------------------------------------------------

create function public.grace_days_per_month()
returns integer
language sql
immutable
set search_path = ''
as $$ select 2 $$;

comment on function public.grace_days_per_month() is
  'FR-17 [confirmed with the human before drafting]: 2 Grace Days per calendar month, '
  'non-carrying -- unused ones do not roll into the next month. Named once so '
  'grace_day_validate()''s own insert-time check and grace_allowance_remaining''s own count '
  'cannot drift apart.';

-- Revoked from `public`/`anon` (the default grant), granted to `authenticated`: unlike
-- `penalty_amount_dong()` (fully closed, called only from inside security definer bodies),
-- `grace_allowance_remaining` below is a plain `security_invoker` view, so its own query --
-- including this call -- runs under the caller's real privileges once an actual account
-- reads it (mirrors `week_days_remaining()`'s identical reasoning, 20260820130000). Without
-- the grant every read of that view would fail "permission denied for function
-- grace_days_per_month" rather than an RLS-empty result, which is the wrong way for this to
-- be unreachable.
revoke execute on function public.grace_days_per_month() from public, anon;
grant execute on function public.grace_days_per_month() to authenticated;


-- ---------------------------------------------------------------------------------
-- `penalty_state` gains the value this story makes reachable. Isolated in its own
-- statement, referenced only from inside a plpgsql function body below (deferred to when
-- that body actually runs, in a later transaction) -- mirroring every prior story's own
-- addition to this enum (`20260824130000`, `20260825090000`, `20260825100000`).
-- ---------------------------------------------------------------------------------

alter type public.penalty_state add value if not exists 'waived';

comment on type public.penalty_state is
  'owed (2.6); held, dropped (4.4, an Appeal in flight or timed out in the author''s favour); '
  'voided (4.6, an Appeal the referee approved -- distinct from dropped, which nobody ruled '
  'on); collected (4.7, the referee''s own mark_penalty_collected() -- the only way a debt is '
  'ever discharged); waived (5.1, a Grace Day spent on this day -- a different fact than '
  'voided: nobody ruled the machine wrong, the day itself is forgiven, and unlike voided this '
  'one has to stay visible on the Ledger as `Waived`).';


-- ---------------------------------------------------------------------------------
-- The event itself. Append-only (AD-9): no update, no delete, no unspend.
-- ---------------------------------------------------------------------------------

create table public.grace_day (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profile (id) on delete cascade,

  -- The already-settled day being forgiven, read off a Day summary or a Ledger row --
  -- client-supplied the same way `appeal.for_day` is (an appeal/a grace day both name an
  -- already-settled day rather than describing an event that just happened).
  for_day date not null,

  created_at timestamptz not null default now(),

  -- Null until `apply_grace_days()` folds this row in. The scheduled pass's own marker that
  -- it has already looked at this row, not a client-visible status -- there is no polling
  -- surface for it (Never boundary: no new notification).
  processed_at timestamptz,

  -- The whole allowance-tracking mechanism in one constraint: the same day can never be
  -- graced twice, ever (not merely "while unprocessed" -- this is unconditional, matching
  -- "no unspend/undo once inserted"). It also closes the double-insert race the I/O Matrix
  -- names: two rapid inserts for the same day before either is processed, the second always
  -- loses to this index rather than a plain guarded update.
  constraint grace_day_once_per_day unique (owner_id, for_day)
);

comment on table public.grace_day is
  'One row per Grace Day spent (AD-9, append-only). Validated synchronously on insert '
  '(grace_day_validate trigger, below) for immediate feedback; the actual correction -- '
  'penalty.state -> waived, a corrective settlement, the chain-restoring freeze -- is folded '
  'in later by apply_grace_days(), called from settle_due_days()''s own hourly pass, so '
  'settlement remains the only writer of derived state (AD-8).';

create index grace_day_owner_idx on public.grace_day (owner_id);

-- Read every unprocessed row in insertion order -- apply_grace_days()'s own scan below.
create index grace_day_unprocessed_idx on public.grace_day (created_at) where processed_at is null;


-- ---------------------------------------------------------------------------------
-- The eligibility check, synchronous, in one `before insert security definer` trigger --
-- mirrors `appeal_hold_penalty()`'s exact shape (20260824150000): read the settlement that
-- is genuinely current (nothing supersedes it, `settlement_current`'s own definition,
-- inlined rather than adding a view dependency inside a security definer trigger, for the
-- identical reason that migration gives), require `verdict = 'failed'`, require the day's
-- own Penalty to still read `owed` (excludes `held` -- an Appeal in flight -- and
-- `collected`, per this story's own AC), and require fewer than
-- `grace_days_per_month()` grace_day rows already this calendar month
-- (Asia/Ho_Chi_Minh, AD-6). Any failure raises a clear, specific message -- this is a live,
-- client-triggered action and needs synchronous feedback, unlike apply_grace_days() below.
-- ---------------------------------------------------------------------------------

create function public.grace_day_validate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_settlement record;
  v_penalty record;
  v_used integer;
begin
  -- Serializes concurrent inserts for the *same* account before the monthly count below is
  -- ever read. Without this, two concurrent inserts for two *different* for_day values on
  -- the same account can both read v_used under ordinary READ COMMITTED isolation before
  -- either commits, both pass, and the account ends up with more than
  -- grace_days_per_month() spent in a month -- grace_day_once_per_day only ever prevents a
  -- double-spend on the *same* day, never this. Held for the rest of the transaction
  -- (xact, not session) and released automatically on commit or rollback; a second
  -- concurrent insert for the same account simply waits its turn rather than racing.
  -- hashtext() collapses the uuid to a bigint key advisory locks take; a hash collision
  -- with some other lock taken under a different key elsewhere in this schema would only
  -- ever cost extra, harmless waiting, never a wrong count -- and nothing else in this
  -- schema takes an advisory lock at all.
  perform pg_advisory_xact_lock(hashtext(new.owner_id::text));

  select s.* into v_settlement
    from public.settlement s
   where s.subject = new.owner_id
     and s.period = new.for_day
     and s.kind = 'day'
     and not exists (select 1 from public.settlement c where c.supersedes = s.id);

  if not found or v_settlement.verdict <> 'failed' then
    raise exception
      'No Failed Day on record for %. A Grace Day only applies to a day that closed on an '
      'admitted or machine-filed miss, never one that closed on silence (expired) or one '
      'that already held clean.', new.for_day;
  end if;

  select p.* into v_penalty
    from public.penalty p
   where p.settlement_id = v_settlement.id;

  if not found or v_penalty.state <> 'owed' then
    raise exception
      'This day''s Penalty is not eligible for a Grace Day -- it is %, not owed.',
      coalesce(v_penalty.state::text, 'missing');
  end if;

  select count(*) into v_used
    from public.grace_day g
   where g.owner_id = new.owner_id
     and date_trunc('month', g.created_at at time zone 'Asia/Ho_Chi_Minh')
         = date_trunc('month', now() at time zone 'Asia/Ho_Chi_Minh');

  if v_used >= public.grace_days_per_month() then
    raise exception
      'Both Grace Days for this month have already been spent. They do not carry over.';
  end if;

  return new;
end;
$$;

comment on function public.grace_day_validate() is
  'before insert security definer trigger on public.grace_day. Takes a per-account advisory '
  'lock first, before counting this month''s spend -- serializes concurrent inserts for '
  'different for_day values on the same account, which grace_day_once_per_day alone does '
  'not (that constraint only stops a double-spend on the *same* day). Mirrors '
  'appeal_hold_penalty()''s own shape: reads the day''s genuinely current settlement '
  '(nothing supersedes it), requires verdict = failed, requires the linked Penalty to still '
  'read owed, and requires fewer than grace_days_per_month() grace_day rows already this '
  'calendar month (Asia/Ho_Chi_Minh). Any failure raises a specific message -- this is a '
  'live, client-triggered action and needs synchronous feedback. Never writes penalty, '
  'settlement or settlement_commitment itself -- that is apply_grace_days()''s job alone '
  '(AD-8).';

create trigger grace_day_validate
  before insert on public.grace_day
  for each row execute function public.grace_day_validate();

-- Reachable at /rest/v1/rpc otherwise, the exact exposure 20260819121500 closed for
-- handle_new_user. A trigger fires regardless of the EXECUTE grant.
revoke execute on function public.grace_day_validate() from public, anon, authenticated;

alter table public.grace_day enable row level security;

create policy "grace_day: read own"
  on public.grace_day for select to authenticated
  using ((select auth.uid()) = owner_id);

create policy "grace_day: file own"
  on public.grace_day for insert to authenticated
  with check ((select auth.uid()) = owner_id and public.role_from_table() = 'doer');

-- No update and no delete policy. Append-only (AD-9): no unspend, no undo, once a row lands.


-- ---------------------------------------------------------------------------------
-- Grace Days and Appeals are mutually exclusive on the same day, at the database level.
--
-- Without this, a Grace Day could be silently wasted: the doer spends one (the day is
-- machine-filed-missed and still owed), then -- before the next `:15` fold-in --
-- `appeal_hold_penalty()` fires for the same day (his own appeal, or a fresh auto-check
-- retry), moving the Penalty to `held`. `apply_grace_days()` then finds it no longer
-- `owed`, silently no-ops (its own Never boundary: a lost race is not an error) and marks
-- `processed_at` anyway -- the Grace Day is consumed (append-only, no unspend) and nothing
-- was actually forgiven, the exact allowance FR-17 promises spent for nothing.
--
-- `appeal_hold_penalty()` is redefined here (`create or replace`, never editing
-- `20260824150000_an_appeal_reads_the_day_that_stands.sql` itself -- migrations are
-- additive, the same discipline `20260820102000_supersession_freezes_the_day.sql` and this
-- migration's own earlier `settle_due_days()` redefinition already follow) with one added
-- guard: refused outright if a `grace_day` row already exists for this `(owner_id,
-- for_day)`, whether or not it has been folded in yet -- existence alone means the day is
-- already spoken for by the other mechanism. The reverse direction is already covered by
-- `grace_day_validate()` itself: a `held` Penalty (an appeal in flight) never reads
-- `owed`, so a Grace Day can never be spent on a day already under open appeal.
-- ---------------------------------------------------------------------------------

create or replace function public.appeal_hold_penalty()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_carries boolean;
  v_filed_by public.declaration_filed_by;
  v_settlement_id uuid;
  v_outcome public.commitment_outcome;
  v_penalty record;
begin
  select owner_id, carries_penalty into v_owner, v_carries
    from public.commitment where id = new.commitment_id;

  if not found or v_owner <> new.owner_id then
    raise exception 'Appeal commitment does not belong to the appealing account.';
  end if;

  if not v_carries then
    raise exception 'Only a Penalty-carrying commitment can be appealed.';
  end if;

  -- Story 5.1: the two mechanisms cannot both claim the same day. Checked here, before the
  -- eligibility reads below, so the message names the actual reason rather than a
  -- downstream symptom of it.
  if exists (
    select 1 from public.grace_day g
     where g.owner_id = new.owner_id and g.for_day = new.for_day
  ) then
    raise exception
      'A Grace Day has already been spent on this day. It cannot also be appealed.';
  end if;

  select sc.settlement_id, sc.outcome into v_settlement_id, v_outcome
    from public.settlement_commitment sc
    join public.settlement s on s.id = sc.settlement_id
   where sc.commitment_id = new.commitment_id and s.period = new.for_day
     and s.kind = 'day' and s.subject = new.owner_id and s.verdict = 'failed'
     and not exists (select 1 from public.settlement c where c.supersedes = s.id);

  if not found or v_outcome <> 'missed' then
    raise exception 'No machine miss on record for this commitment/day.';
  end if;

  select filed_by into v_filed_by from public.declaration
   where commitment_id = new.commitment_id and for_day = new.for_day;

  if v_filed_by is distinct from 'auto_check' then
    raise exception 'Only a machine-filed miss can be appealed.';
  end if;

  select id, state into v_penalty from public.penalty where settlement_id = v_settlement_id;

  if not found or v_penalty.state <> 'owed' then
    raise exception 'This day''s Penalty is not appealable.';
  end if;

  new.settlement_id := v_settlement_id;
  new.penalty_id := v_penalty.id;
  new.deadline := public.appeal_deadline(now());

  -- Guarded even here, on the row this trigger just proved is `owed`: belt-and-suspenders
  -- against a second appeal attempt racing this one for the same penalty through a
  -- different (commitment_id, for_day) pair on a Failed Day with more than one Penalty-
  -- carrying miss. `appeal_one_per_commitment_day` stops a literal duplicate; this guard is
  -- what stops two *different* eligible misses on the same day from both trying to hold the
  -- one Penalty FR-13 gives that day.
  update public.penalty set state = 'held' where id = v_penalty.id and state = 'owed';

  if not found then
    raise exception 'This day''s Penalty was claimed by another appeal first.';
  end if;

  return new;
end;
$$;

comment on function public.appeal_hold_penalty() is
  'before insert security definer trigger on public.appeal. Validates ownership, that no '
  'Grace Day already claims this day (Story 5.1 -- the two mechanisms are mutually '
  'exclusive, whether or not the Grace Day has been folded in yet), that the day''s CURRENT '
  '(un-superseded) settlement reads verdict = failed with a missed outcome for this '
  'commitment, that the day''s own declaration was filed by the machine (not the author), '
  'and that the linked Penalty is still owed -- then derives '
  'settlement_id/penalty_id/deadline and holds the Penalty, atomically. Any failure raises; '
  'there is no silent no-op insert.';

-- Reachable at /rest/v1/rpc otherwise, the exact exposure 20260819121500 closed for
-- handle_new_user. A trigger fires regardless of the EXECUTE grant -- re-stated here since
-- `create or replace function` does not touch grants, but stated for the reader rather than
-- assumed carried over silently.
revoke execute on function public.appeal_hold_penalty() from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- The remaining allowance. `security_invoker`, mirroring `weekly_quota_progress`'s own
-- shape (20260820130000) -- a calendar month's count instead of an ISO week's. No
-- client-side tally of raw grace_day rows anywhere else (AD-8's own convention, stated
-- verbatim in weekly_quota_progress's own comment): this view is the one source.
-- ---------------------------------------------------------------------------------

create view public.grace_allowance_remaining
with (security_invoker = true)
as
select p.id as owner_id,
       public.grace_days_per_month() - coalesce(used.count, 0)::integer as remaining
  from public.profile p
  left join lateral (
    select count(*)::integer as count
      from public.grace_day g
     where g.owner_id = p.id
       and date_trunc('month', g.created_at at time zone 'Asia/Ho_Chi_Minh')
           = date_trunc('month', now() at time zone 'Asia/Ho_Chi_Minh')
  ) used on true
 where p.role = 'doer';

comment on view public.grace_allowance_remaining is
  'grace_days_per_month() minus how many grace_day rows this account has this calendar '
  'month (Asia/Ho_Chi_Minh, AD-6) -- non-carrying, so last month''s unused ones never add in. '
  'The one source the Day summary, a Ledger row and Settings all read (AD-8) -- never a '
  'client-side tally of raw grace_day rows.';


-- ---------------------------------------------------------------------------------
-- The fold-in. Mirrors `supersede_expiries()`'s own "read-only-source-table, fold in by
-- the next pass" shape exactly (20260819241000) -- no dedicated inbox/queue mechanism, a
-- plain source table read by the scheduled pass, the norm everywhere else in this codebase.
--
-- Re-guards `state = 'owed'` in the transition's own where clause, `void_expired_appeals()`'s
-- own convention (20260824140000): there is no synchronous caller left to raise to by the
-- time this runs, so a lost race (the Penalty left `owed` some other way between insert and
-- fold-in -- should not happen given the Never boundary grace_day_validate() already
-- enforces at insert time, guarded here anyway) is a silent no-op, not an error.
-- ---------------------------------------------------------------------------------

create function public.apply_grace_days()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  grace_row record;
  v_settlement_id uuid;
  v_settlement_verdict public.day_verdict;
  v_penalty record;
  v_correction uuid;
  processed integer := 0;
begin
  for grace_row in
    select * from public.grace_day where processed_at is null order by created_at
  loop
    select s.id, s.verdict into v_settlement_id, v_settlement_verdict
      from public.settlement s
     where s.subject = grace_row.owner_id
       and s.period = grace_row.for_day
       and s.kind = 'day'
       and not exists (select 1 from public.settlement c where c.supersedes = s.id);

    if found and v_settlement_verdict = 'failed' then
      update public.penalty
         set state = 'waived'
       where settlement_id = v_settlement_id
         and state = 'owed'
      returning * into v_penalty;

      if found then
        -- The corrective settlement: the whole day is forgiven, never partially -- verdict
        -- clean, missed_count 0, supersedes the original (AD-9: the original row is never
        -- touched beyond its own penalty's state; the ledger folds the chain).
        insert into public.settlement (subject, period, kind, verdict, missed_count, supersedes)
        values (grace_row.owner_id, grace_row.for_day, 'day', 'clean', 0, v_settlement_id)
        returning id into v_correction;

        -- Every commitment that day freezes as held -- mirroring rule_appeal()'s own
        -- chain-restoration fix (20260820102000_supersession_freezes_the_day.sql's bug
        -- class): a correction with no frozen outcomes vanishes the whole day from every
        -- commitment's chain, not only the one that actually missed. A Grace Day forgives
        -- the day whole, so every commitment reads held, not only the ones that held on
        -- their own.
        insert into public.settlement_commitment (settlement_id, subject, commitment_id, outcome)
        select v_correction, grace_row.owner_id, o.commitment_id, 'held'::public.commitment_outcome
          from public.commitments_owing(grace_row.owner_id, grace_row.for_day) o;

        -- The correction carries its own penalty, already waived -- never owed even for an
        -- instant -- so penalty_current (which follows settlement_current) actually shows
        -- it, and the Ledger reads Waived rather than Clean. Unlike a won appeal's
        -- correction (which only inserts a new penalty when a different miss the same day
        -- still owes one), this one always does: the whole point is that the forgiveness
        -- itself stays visible, not merely that the day no longer costs money.
        insert into public.penalty (subject, settlement_id, amount_dong, state)
        values (grace_row.owner_id, v_correction, v_penalty.amount_dong, 'waived');

        processed := processed + 1;
      end if;
    end if;

    update public.grace_day set processed_at = now() where id = grace_row.id;
  end loop;

  return processed;
end;
$$;

comment on function public.apply_grace_days() is
  'Folds in every unprocessed grace_day row: re-guards state = ''owed'' in the transition''s '
  'own where clause (void_expired_appeals()''s convention -- no synchronous caller left to '
  'raise to), then on success waives the Penalty, inserts a corrective clean settlement '
  '(supersedes the original, missed_count 0), freezes every commitment that day as held '
  '(mirroring rule_appeal()''s own chain-restoration fix), and inserts the correction''s own '
  'already-waived penalty so the Ledger reads Waived rather than Clean. A lost race (the '
  'Penalty left owed some other way before this ran) is a silent no-op -- processed_at is '
  'still set, nothing else changes. Called from settle_due_days() alongside '
  'supersede_expiries(), never a separate schedule and never a synchronously-callable RPC '
  '(AD-8: settlement remains the only writer of derived state).';

revoke execute on function public.apply_grace_days() from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- Wired into the existing hourly pass, alongside supersede_expiries() -- same schedule
-- (20260819221000_settlement_schedule.sql's own `settle-days` cron, `:15`), never a
-- dedicated one.
-- ---------------------------------------------------------------------------------

create or replace function public.settle_due_days()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  today date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  day_to_settle date;
  settled integer := 0;
begin
  perform set_config('app.settlement_invocation', 'schedule', true);

  for day_to_settle in
    select generate_series(today - 5, today - 1, interval '1 day')::date
  loop
    settled := settled + public.settle_day(day_to_settle);
  end loop;

  settled := settled + public.supersede_expiries();
  settled := settled + public.apply_grace_days();

  return settled;
end;
$$;

revoke execute on function public.settle_due_days() from public, anon, authenticated;
