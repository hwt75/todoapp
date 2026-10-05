-- The settler takes the account lock, and every correction writer reads under it.
--
-- Two backlog items, one key. hwt75 picked both on 2026-10-05:
--
-- 1. `settle_day()` was the only writer of money-relevant state that did not take the per-account
--    advisory lock `pg_advisory_xact_lock(hashtext(owner_id::text))`. grace_day_validate(),
--    appeal_hold_penalty(), mark_penalty_collected() and object_to_day() all take it. The race it
--    left open is recorded in deferred-work.md (review of Story 8.2, 2026-09-14): settle_day()
--    reads commitments_owing() in five separate statements under READ COMMITTED, so a referee's
--    refusal committing between the counts and the frozen-outcome write produced a settlement
--    reading `clean` with no Penalty beside a frozen `missed`. No correction path can repair that
--    shape.
--
--    The settler taking the key does not close that race by itself, because sign_off_day() took no
--    key -- Story 8.2's decision 3. **hwt75 reversed decision 3 on 2026-10-05**: both take the key,
--    so a refusal either commits before the settler reads anything or meets the settled check after
--    the settler commits. scripts/test-sign-off-race.mjs is updated in the same change to assert
--    the new wait.
--
--    supersede_expiries() takes it too. Its race with mark_penalty_collected() is the other
--    deferred-work.md entry (code review of epic-6 retro item 36), and serialization alone does not
--    close it: a collector that wins the key still leaves an expired day with a collected Penalty
--    for the pass to rewrite. So under the key the pass also re-asks whether the row is still
--    current, and leaves alone a day whose Penalty is no longer owed.
--
-- 2. `apply_grace_days()` was the last correction writer that rebuilt a day from live
--    commitments_owing() rather than from the settlement it corrects (Epic 6 retrospective item 44,
--    finding A6). It now copies the frozen rows, and it takes the key as well.
--
-- Every function is reproduced verbatim from its live definition with only the edits its own
-- comments name:
--   settle_day()          20260914090000:1040-1231
--   supersede_expiries()  20260914090000:1267-1377
--   sign_off_day()        20260929100000:147-393
--   apply_grace_days()    20260825110000:391-458
--
-- **Lock order.** Every function here takes the account key before any row lock and before the
-- commitment-day key 20260907110000 introduced. No function takes two account keys except
-- settle_day(), which loops over accounts and takes them one at a time in that loop, and no other
-- function waits on a second account's key while holding one. That order admits no cycle.
-- `create or replace` keeps each function's ACL; the revokes are re-issued anyway, as the two
-- migrations before this one did.

-- ---------------------------------------------------------------------------------
-- (i) The settler.
-- ---------------------------------------------------------------------------------

/* One change: the account key, taken at the top of each account's iteration and held until the
   scheduled transaction ends. Every read of commitments_owing() in that iteration -- the counts,
   the Auto-check gate, the deadline gate, the frozen outcomes, the summary -- is then made with no
   other writer of that account's money-relevant state in flight. A writer that got the key first
   has committed before the first read. A writer that arrives later waits, and then meets a settled
   day: sign_off_day() refuses it, grace_day_validate() reads the new settlement, and the collector
   reads its Penalty.

   Taken for every doer account, including one that turns out to owe nothing that day. Taking it
   only after `continue when total = 0` would leave that first count outside the key, and the cost
   of the alternative is one uncontended lock per account per hour. */
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

    -- The per-account key, before the first read of commitments_owing() below. See the note
    -- above this function: every later read in this iteration is made under it.
    perform pg_advisory_xact_lock(hashtext(account.id::text));

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

revoke execute on function public.settle_day(date, boolean) from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- (ii) The expiry correction.
-- ---------------------------------------------------------------------------------

/* The key per expired row, then two re-reads under it: is the row still the end of its chain,
   and is its Penalty, if any, still owed. Nothing after them moves. */
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
    -- The per-account key, before anything about this row is read again. The loop's own read
    -- above was made without it, so two things are re-asked under it.
    perform pg_advisory_xact_lock(hashtext(expired_row.subject::text));

    -- Still the end of its chain. Another pass, or any correction writer that got the key first,
    -- may have superseded this row while this one waited; a second correction of the same row
    -- would fork the chain into two current settlements for one day.
    continue when exists (
      select 1 from public.settlement c where c.supersedes = expired_row.id
    );

    -- Its Penalty still owed, if it has one. A silent day mints a Penalty, and the referee may
    -- already have collected it. Rewriting that day now would retire the collected Penalty from
    -- `penalty_current` and, for an admitted slip, mint an owed one beside it -- the
    -- collected-history-plus-owed-replacement shape deferred-work.md recorded against this
    -- function. Money that has changed hands is not rewritten by a pass: the expiry stands, the
    -- same refusal object_to_day() makes for a Penalty in any state but owed.
    continue when exists (
      select 1 from public.penalty p
       where p.settlement_id = expired_row.id and p.state <> 'owed'
    );

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

revoke execute on function public.supersede_expiries() from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- (iii) The referee's decision, taking the key.
-- ---------------------------------------------------------------------------------

create or replace function public.sign_off_day(
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
  v_decision uuid;
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

  -- The per-account key, taken here and not earlier: after the pairing check, so an unscoped
  -- caller never holds another account's key (object_to_day()'s rule at 20260906080451:181-184),
  -- and after the argument and window refusals, which read nothing that can change under him.
  -- Everything below it -- the settled check, the decided check, the frozen facts, the insert --
  -- is read and written under it.
  --
  -- **This reverses Story 8.2's decision 3**, on hwt75's decision of 2026-10-05. That decision
  -- held that a write which moves no money had no reason to hold the account key. It does have
  -- one: `now()` is transaction-start time, so a decision begun at 23:59:59.9 commits after
  -- midnight and could land while `settle_day()` was running -- between its counts and its
  -- frozen-outcome write -- leaving a settlement reading `clean` beside a frozen `missed`, a
  -- broken chain with nothing for a Grace Day to attach to. The settled check below narrowed that
  -- window and could not close it, because it was check-then-act against a writer that took no
  -- key. Now both take the same one, so exactly one of two things happens: this decision commits
  -- before the settler reads anything, or the settler commits first and the check below refuses.
  -- The cost decision 3 named -- a referee briefly in the way of the author's Grace Day -- is the
  -- length of this function's transaction.
  perform pg_advisory_xact_lock(hashtext(v_paired::text));

  -- The midnight race, closed by the key above. A referee deciding a day the cron already settled
  -- is told so in a sentence rather than given a silent no-op.
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
  -- read as no photograph.
  --
  -- Story 8.3 moved that union into photograph_reaches_the_referee() and put both referee
  -- policies on it, so the question this guard asks and the question the policies answer are now
  -- one expression rather than three. This function's own comment asked for exactly that --
  -- *"Story 8.4's list must ask this same question; the two must not be able to disagree"* -- and
  -- leaving it here as a second copy is how they would have. **Identical in what it decides:**
  -- the flag half of the predicate was established `is true` above, so what is left of it here is
  -- the union, unchanged.
  if not p_approved
     and not public.photograph_reaches_the_referee(p_commitment_id, p_for_day) then
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

  -- AD-15's guarded transition. Two concurrent decisions on one commitment-day no longer reach
  -- here together -- the second waits on the account key above and then meets the decided check
  -- -- but the unique constraint is still the guarantee, and `on conflict do nothing` plus the
  -- raise below is what holds if anything ever writes this table without the key.
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
  -- Story 8.5: the id is the outbox dedupe key below, the same reason object_to_day() keeps its
  -- own. A race loser's `on conflict do nothing` returns no row, so `FOUND` is false and it raises
  -- before it can reach the enqueue -- exactly one push per refusal, by the unique constraint.
  on conflict (subject, for_day, commitment_id) do nothing
  returning id into v_decision;

  if not found then
    raise exception 'That day has already been decided, and a decision is final.';
  end if;

  -- Story 8.5, CAP-7. The author is told, in the refusal's own transaction (AD-3) and on the push
  -- channel -- if this enqueue fails, the refusal does not land. An approval changes nothing and
  -- says nothing; a silence has no transaction to say it in.
  --
  -- refusal_payload() is what keeps someone's wording from aborting this: the commitment name
  -- rides in the title and the reason in `quote`, neither of which outbox_body_is_sendable reads,
  -- and the body it does read is built from the app's words and the date alone.
  if not p_approved then
    perform public.outbox_enqueue(
      v_paired,
      'refusal-' || v_decision::text,
      public.refusal_payload(v_commitment.name, p_for_day, v_reason)
    );
  end if;
end;
$$;

comment on function public.sign_off_day(uuid, date, boolean, text) is
  'Story 8.2; Story 8.3; Story 8.5. The referee''s decision on one flagged commitment-day of the
  doer he is paired to, before that day closes. Checks role_from_table() = ''referee'' as its first
  statement, then the reason, then the pairing -- above any read of the author''s, so there is no
  commitment-id oracle. Reads the flag only through requires_referee_approval_as_of(), never live,
  and the photograph through photograph_reaches_the_referee(). Refuses outside the local day, on a
  day already settled, on a commitment that is archived or already decided, and -- for a refusal
  only -- on one carrying no penalty that day, on either quota cadence, and on a commitment-day
  with no photograph. Freezes carries_penalty and cadence onto the row. Takes the per-account
  advisory lock settle_day() takes (20261005090000, reversing Story 8.2 decision 3), after the
  pairing and window checks and before the settled and decided checks, so a decision and the
  settlement of its day are serialised; the unique constraint plus `on conflict do nothing`
  remains the guarantee against a second row. A refusal enqueues exactly one push to the author,
  keyed refusal-<decision id>, built by refusal_payload(); an approval enqueues nothing.';

revoke execute on function public.sign_off_day(uuid, date, boolean, text) from public, anon;
grant execute on function public.sign_off_day(uuid, date, boolean, text) to authenticated;


-- ---------------------------------------------------------------------------------
-- (iv) The Grace Day fold-in, from the frozen rows.
-- ---------------------------------------------------------------------------------

create or replace function public.apply_grace_days()
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
    -- The per-account key, the same one grace_day_validate() took when this row was filed.
    -- Everything below reads the day's current settlement and its Penalty and then writes a
    -- correction of both, so it is read under the key every other writer of that state takes.
    perform pg_advisory_xact_lock(hashtext(grace_row.owner_id::text));

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

        -- Every commitment the forgiven settlement froze, and only those, now reads held. A
        -- Grace Day forgives the day whole -- the outcome is still the literal 'held' for every
        -- row -- but WHICH commitments the day had is the settlement's frozen fact, never a new
        -- reading of commitments_owing(). Live state cannot reproduce it: a commitment archived
        -- with a backdated instant, or one whose cadence has since become daily_hours_quota,
        -- drops out of a live reading and its chain loses the day the Grace Day was spent to
        -- keep. rule_appeal() (20260907090000) and object_to_day() copy frozen rows for the same
        -- reason; this was the last correction writer that did not.
        insert into public.settlement_commitment (settlement_id, subject, commitment_id, outcome)
        select v_correction, sc.subject, sc.commitment_id, 'held'::public.commitment_outcome
          from public.settlement_commitment sc
         where sc.settlement_id = v_settlement_id;

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
  'Folds in every unprocessed grace_day row, each under its account''s advisory lock: re-guards '
  'state = ''owed'' in the transition''s own where clause (void_expired_appeals()''s convention -- '
  'no synchronous caller left to raise to), then on success waives the Penalty, inserts a '
  'corrective clean settlement (supersedes the original, missed_count 0), freezes every '
  'commitment the superseded settlement froze as held -- copied from its settlement_commitment '
  'rows, never rebuilt from commitments_owing() (Epic 6 retrospective item 44) -- and inserts the '
  'correction''s own already-waived penalty so the Ledger reads Waived rather than Clean. A lost '
  'race (the Penalty left owed some other way before this ran) is a silent no-op -- processed_at '
  'is still set, nothing else changes. Called from settle_due_days() alongside '
  'supersede_expiries(), never a separate schedule and never a synchronously-callable RPC '
  '(AD-8: settlement remains the only writer of derived state).';

revoke execute on function public.apply_grace_days() from public, anon, authenticated;
