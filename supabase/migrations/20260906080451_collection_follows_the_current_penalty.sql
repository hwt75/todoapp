-- Epic 6 retrospective item 36 -- collection follows the Penalty whose settlement still stands.
--
-- object_to_day() and mark_penalty_collected() can both move the same day's money. They now take
-- the same per-account transaction advisory lock before either reads mutable state used for that
-- decision. Collection also treats a Penalty as collectible only while its own settlement remains
-- the leaf of the append-only correction chain.

create or replace function public.mark_penalty_collected(p_penalty_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_exists boolean;
  v_settlement uuid;
  v_owner uuid;
  v_for_day date;
begin
  if public.role_from_table() is distinct from 'referee' then
    raise exception 'Only the referee may mark a Penalty collected.';
  end if;

  select s.id, s.subject, s.period into v_settlement, v_owner, v_for_day
    from public.penalty p
    join public.settlement s on s.id = p.settlement_id
   where p.id = p_penalty_id;

  v_exists := found;

  if not v_exists then
    raise exception 'No such penalty.';
  end if;

  -- The fix this migration adds: the same lock, same key, grace_day_validate() and
  -- appeal_hold_penalty() already take -- held for the rest of this transaction, so a
  -- concurrent grace_day insert for this same account now genuinely waits behind whichever
  -- transaction got here first, instead of both reading the other's uncommitted state as
  -- absent and both proceeding.
  perform pg_advisory_xact_lock(hashtext(v_owner::text));

  -- The lookup above exists only to find the account lock. Once the lock is ours, re-read the
  -- Penalty and its settlement before using either to move money. object_to_day() takes this same
  -- lock before it can append a correction, so whichever call arrived second now sees the first
  -- call's committed state rather than acting on its unlocked snapshot.
  select s.id, s.subject, s.period into v_settlement, v_owner, v_for_day
    from public.penalty p
    join public.settlement s on s.id = p.settlement_id
   where p.id = p_penalty_id;

  if not found then
    raise exception 'No such penalty.';
  end if;

  if exists (
    select 1 from public.settlement c where c.supersedes = v_settlement
  ) then
    raise exception
      'That penalty is no longer the current Penalty for this day. Refresh the Ledger and '
      'collect the current Penalty.';
  end if;

  -- Story 5.1 (2026-08-25 independent review): the same "a grace_day row for this day
  -- means it is already spoken for" guard appeal_hold_penalty() already enforces. Now
  -- actually race-safe against a concurrent grace_day insert, not only sequentially safe.
  if exists (
    select 1 from public.grace_day g
     where g.owner_id = v_owner and g.for_day = v_for_day
  ) then
    raise exception
      'A Grace Day has already been spent on this day. It cannot also be collected.';
  end if;

  -- Story 5.4: collected_at stamped in the same guarded update as the state transition --
  -- one write, so a penalty can never read state = 'collected' with collected_at still null.
  update public.penalty p
     set state = 'collected', collected_at = now()
   where p.id = p_penalty_id
     and p.state = 'owed'
     and not exists (
       select 1 from public.settlement c where c.supersedes = p.settlement_id
     );

  if not found then
    if exists (
      select 1
        from public.penalty p
       where p.id = p_penalty_id
         and exists (
           select 1 from public.settlement c where c.supersedes = p.settlement_id
         )
    ) then
      raise exception
        'That penalty is no longer the current Penalty for this day. Refresh the Ledger and '
        'collect the current Penalty.';
    end if;

    raise exception
      'This penalty has already been resolved -- collected already, or no longer owed.';
  end if;
end;
$$;

comment on function public.mark_penalty_collected(uuid) is
  'FR-21; Epic 6 retrospective item 36. Checks role_from_table() = ''referee'' first, resolves '
  'the target account only to take the per-account transaction advisory lock, then re-reads the '
  'Penalty and every mutable fact used to collect it. A Penalty whose settlement has a successor '
  'is historical and is refused with a refresh/current-Penalty message, even when that copied '
  'historical row still says owed. Grace Day exclusion remains under the same lock. The final '
  'owed -> collected update repeats the no-successor predicate defensively, stamps collected_at '
  'atomically, and preserves the existing refusal for repeat or otherwise resolved collection.';

revoke execute on function public.mark_penalty_collected(uuid) from public, anon;
grant execute on function public.mark_penalty_collected(uuid) to authenticated;


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
  'Story 6.7; Epic 6 retrospective item 36. Checks role_from_table() = ''referee'' first and '
  'validates the paired account before taking that account''s transaction advisory lock. Under '
  'the lock it re-reads the settlement, currentness, frozen outcomes, Penalty and every mutable '
  'fact used to write money, serializing objections with mark_penalty_collected(). The existing '
  'eligibility, 48-hour, one-objection, failed+owed landing, whole-day freeze, one-Penalty, '
  'notification, security-definer and empty-search-path behavior remains unchanged.';

-- Directly callable by an authenticated referee session, the same shape rule_appeal() and
-- mark_penalty_collected() already use: the function itself is the privilege boundary, reached
-- over /rest/v1/rpc rather than fronted by an Edge Function or a trigger.
revoke execute on function public.object_to_day(uuid, uuid, text) from public, anon;
grant execute on function public.object_to_day(uuid, uuid, text) to authenticated;
