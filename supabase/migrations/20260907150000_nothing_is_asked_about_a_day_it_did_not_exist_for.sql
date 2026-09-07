-- Nothing is asked about a day it did not exist for.
--
-- Found by using the product rather than by reading it: on the live project, creating the first
-- commitment on a fresh account immediately blocked the whole app behind "Did <name> hold on
-- <yesterday>?" -- a day before the commitment existed. Answering it files a declaration the judge
-- does not believe in; not answering it leaves the app saying "Nothing else is here until this is
-- answered."
--
-- `commitments_owing()` has refused to judge a commitment for a day that predates it since
-- 20260824090000, and states the rule as
-- `(c.created_at at time zone 'Asia/Ho_Chi_Minh')::date <= p_day` (20260829090000:348). Neither
-- *asking* surface copied it: this function counted the commitment, and the client's own
-- `commitmentsOwing()` mirror -- which is what actually puts the question on screen -- filtered
-- only on cadence, due time, already-answered and archived.
--
-- This is the same shape as the two repairs before it: one rule, several readers, and the copy
-- that decides what the author sees is the one missing a clause. The client half ships alongside.

create or replace function public.enqueue_gate_reminders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  account record;
  local_now timestamp;
  local_hour integer;
  asked_day date;
  slot integer;
  outstanding integer;
  enqueued integer := 0;

  -- Story 2.9, restored 2026-08-26: named only when exactly one commitment is outstanding
  -- and its chain is actually running (see the stake computation below for both conditions).
  lone_commitment uuid;
  lone_chain integer;
  stake text;

  -- Story 5.2: Silence-streak detection. Re-derived every run, no counter column (matches
  -- supersede_expiries()/apply_grace_days()'s own convention) -- reset per account below so a
  -- stale value from a previous loop iteration can never leak into this one's decision.
  owing_total integer;
  owing_answered integer;
  quiet_yesterday boolean;
  quiet_day_before boolean;
  earlier_quiet_day date;
  new_episode_id uuid;

  -- Story 5.3: escalation. Read fresh every pass, independent of whether the block above
  -- opened a new episode this pass or found one already open from days ago.
  escalating_id uuid;
  escalating_started_day date;
  escalating_updated integer;
  escalating_elapsed integer;
begin
  local_now := now() at time zone 'Asia/Ho_Chi_Minh';
  local_hour := extract(hour from local_now)::integer;
  asked_day := local_now::date - 1;

  for account in
    select p.id, p.morning_hour from public.profile p where p.role = 'doer'
  loop
    -- Before the hour he agreed to, there is nothing to ask, and no day is old enough yet to
    -- judge quiet against.
    continue when local_hour < account.morning_hour;

    -- -----------------------------------------------------------------------------
    -- Silence-streak detection. A day is quiet when the account had commitments owing
    -- (commitments_owing(), the same read settle_day()/supersede_expiries() already use) and
    -- zero of them carry a declaration. Two consecutive quiet asked-days (asked_day and the
    -- one before it) with no active episode open one.
    -- -----------------------------------------------------------------------------
    new_episode_id := null;

    select count(*), count(o.answer) into owing_total, owing_answered
      from public.commitments_owing(account.id, asked_day) o;
    quiet_yesterday := owing_total > 0 and owing_answered = 0;

    select count(*), count(o.answer) into owing_total, owing_answered
      from public.commitments_owing(account.id, asked_day - 1) o;
    quiet_day_before := owing_total > 0 and owing_answered = 0;

    if quiet_yesterday and quiet_day_before then
      earlier_quiet_day := asked_day - 1;

      -- `on conflict (owner_id) where satisfied_at is null do nothing` targets
      -- silence_episode_one_active directly, mirroring outbox_enqueue()'s own
      -- dedupe-by-conflict shape: a second detection before the next asked-day advances (this
      -- same hour, or four hours later) is a no-op rather than a second row or a raised
      -- exception racing settlement's own writers.
      insert into public.silence_episode (owner_id, started_day, notified_at)
      values (account.id, earlier_quiet_day, now())
      on conflict (owner_id) where satisfied_at is null do nothing
      returning id into new_episode_id;

      if new_episode_id is not null then
        -- Self-dated like every other push this pass sends (Story 1.2's own rule, restated on
        -- gate-reminders' own body above) -- a push can arrive minutes late, and the intervention
        -- states its own account of "as of" rather than implying it is describing right now.
        perform public.outbox_enqueue(
          account.id,
          'silence-' || account.id::text || '-' || earlier_quiet_day::text,
          jsonb_build_object(
            'title', 'Two quiet days',
            'body', 'Two quiet days. This is the part where it usually ends. It doesn''t '
                    'have to. Open the app for what to do today, as of '
                    || to_char(local_now, 'HH24:MI') || '.',
            'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
          )
        );
      end if;
    end if;

    -- -----------------------------------------------------------------------------
    -- Story 5.3: escalate the active, unescalated episode (if any) once it reaches 4
    -- consecutive quiet days, counted from its own started_day. Guarded on
    -- `escalated_at is null` on both this read and the update below, so a concurrent second
    -- run of this same pass finds either nothing left to update (the update's own `where`
    -- matches zero rows) or nothing left to read (a prior run already stamped it) -- either
    -- way, no second email. No re-derivation of Silence itself: the episode being active
    -- (satisfied_at is null) already proves continuous silence since started_day, exactly the
    -- way 5.2's own detection above already established it.
    --
    -- The update's own `where` also repeats `satisfied_at is null`, not only
    -- `escalated_at is null`: a Declaration can land (declaration_satisfies_silence(), 5.2's
    -- own trigger) in the gap between this SELECT and the UPDATE below -- a different session
    -- entirely, since this whole function runs one account's iteration inside its own
    -- statement boundaries, not one enclosing transaction across the full account loop.
    -- Without this second guard, that race would still stamp escalated_at and send an email
    -- for an episode that was satisfied moments before, contradicting "any Declaration
    -- answered... cancels further escalation".
    -- -----------------------------------------------------------------------------
    escalating_id := null;

    select id, started_day into escalating_id, escalating_started_day
      from public.silence_episode
     where owner_id = account.id
       and satisfied_at is null
       and escalated_at is null;

    if escalating_id is not null and asked_day - escalating_started_day >= 3 then
      update public.silence_episode
         set escalated_at = now()
       where id = escalating_id
         and escalated_at is null
         and satisfied_at is null;

      get diagnostics escalating_updated = row_count;

      if escalating_updated > 0 then
        escalating_elapsed := asked_day - escalating_started_day + 1;

        -- Email, not push: a new `channel` on the same outbox (AD-3), never a parallel
        -- queue. The referee's own address is resolved server-side by email-worker, at send
        -- time, from auth.users -- never carried in this payload, and never the row's own
        -- owner_id (the doer, kept here only for FK/cascade/audit consistency with every
        -- other outbox row -- Design Notes). The body states the actual elapsed day count,
        -- never a hardcoded "four", and is self-dating like every other body this pass
        -- builds (push_body_is_sendable requires it) -- names only the day count, no amount,
        -- no missed commitment, per FR-18.
        perform public.outbox_enqueue(
          account.id,
          'silence-escalate-' || account.id::text || '-' || escalating_started_day::text,
          jsonb_build_object(
            'title', 'He has gone quiet',
            'body', 'He hasn''t opened this in ' || escalating_elapsed::text
                    || ' days. Nothing needs deciding — but he''d probably rather hear '
                    || 'from you than from the app, as of ' || to_char(local_now, 'HH24:MI')
                    || '.',
            'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
          ),
          'email'
        );
      end if;
    end if;

    -- While an owner has an active episode, routine gate-reminder pushes are skipped entirely
    -- -- every slot, every morning, not only the morning the episode opened above. The
    -- intervention replaces them; it never adds to them. The day-summary push is untouched --
    -- it is a different function (20260819250000) this pass never calls.
    continue when exists (
      select 1 from public.silence_episode s
       where s.owner_id = account.id and s.satisfied_at is null
    );

    slot := local_hour - account.morning_hour;
    continue when slot >= public.gate_reminder_slots();

    -- A commitment owes an answer when its cadence is settled by his word, it was not
    -- already archived before the day in question, and nothing has been filed for it.
    -- `daily_hours_quota` is excluded: FR-2 judges it against measured minutes, not a
    -- statement, and asking would invite a softer second answer.
    --
    -- Story 6.4: a commitment carrying a `due_time` is excluded for a related reason. Its
    -- question was asked and answered inside its own window and decided at midnight; asking
    -- again the next morning would offer a second, softer answer to a day already judged --
    -- and `declaration_derive_day()` would file that answer against today rather than
    -- yesterday, so it could not even reach the day being asked about.
    --
    -- The **same door settlement reads**, `due_time_as_of()`. This line read the live column
    -- until 2026-09-07, and the reasoning was sound while it held: what is worth *asking* is
    -- what the author can actually answer, and `declaration_derive_day()` read the live value
    -- too, so a commitment timed this morning could only be claimed today.
    --
    -- `20260907100000` (retrospective item 38) moved the derivation onto the door and left this
    -- line behind, falsifying exactly that sentence. On the day a time is switched on the door
    -- calls the day untimed, the derivation refuses a same-day claim and names this question as
    -- the way to answer -- and this filter then skipped it, so nothing asked at all. The day
    -- settled as silence, with a penalty, for a question that was never put. Both sides read the
    -- same value now.
    --
    -- Story 2.9, restored: `array_agg(...)[1]`, not `min(c.id)` -- Postgres has no `min` for
    -- uuid. The aggregated id is only meaningful when `outstanding = 1`; with more than one
    -- it is an arbitrary row and the stake block below must never use it.
    select count(*), (array_agg(c.id))[1] into outstanding, lone_commitment
      from public.commitment c
     where c.owner_id = account.id
       and c.cadence <> 'daily_hours_quota'
       -- The door, not the live column. What is worth *asking* and what is *true* about a day
       -- are settled by the same value now, which is the only arrangement in which the comment
       -- above is true.
       and public.due_time_as_of(c.id, asked_day) is null
       -- It has to have existed on the day being asked about. `commitments_owing()` has carried
       -- this rule since 20260824090000 and states it exactly this way (20260829090000:348); this
       -- surface never copied it, so a commitment created today was counted as owing an answer
       -- for yesterday. The judge returns nothing for that day, so the question could not be
       -- answered into anything -- and the client gate, missing the same clause, blocked the whole
       -- app behind it the first time anyone added a commitment.
       and (c.created_at at time zone 'Asia/Ho_Chi_Minh')::date <= asked_day
       and (c.archived_at is null
            or (c.archived_at at time zone 'Asia/Ho_Chi_Minh')::date > asked_day)
       and not exists (
         select 1 from public.declaration d
          where d.commitment_id = c.id and d.for_day = asked_day
       );

    continue when outstanding = 0;

    -- Story 2.9, restored: names the chain at stake, never the money -- and only when exactly
    -- one commitment is being asked about (no honest composite of several different chains
    -- exists) and only when that chain is actually running (a chain at zero has nothing
    -- waiting).
    stake := '';
    if outstanding = 1 then
      select ch.current_days into lone_chain
        from public.chain_current ch
       where ch.commitment_id = lone_commitment;

      if coalesce(lone_chain, 0) > 0 then
        stake := 'Day ' || lone_chain::text || ' is waiting. ';
      end if;
    end if;

    -- The body states the time it was sent and describes a state as of that time. A push
    -- can arrive minutes late — Story 2.4a's payload rules exist for exactly this, and the
    -- outbox refuses a payload without its own timestamp.
    perform public.outbox_enqueue(
      account.id,
      'gate-' || account.id::text || '-' || asked_day::text || '-' || slot::text,
      jsonb_build_object(
        'title', 'Yesterday',
        'body', stake
                || outstanding::text
                || case when outstanding = 1 then ' commitment is' else ' commitments are' end
                || ' unanswered for ' || asked_day::text
                || ', as of ' || to_char(local_now, 'HH24:MI') || '.',
        'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      )
    );

    enqueued := enqueued + 1;
  end loop;

  return enqueued;
end;
$$;
comment on function public.enqueue_gate_reminders() is
  'Raises the morning question for every account that owes an answer for yesterday, once per day
  per account. Asks only about commitments the judge would ask about: due_time_as_of() decides
  whether a time governed the day (2026-09-07), and created_at decides whether the commitment
  existed on it -- the rule commitments_owing() has carried since 20260824090000 and this surface
  did not copy until now.';

revoke execute on function public.enqueue_gate_reminders() from public, anon, authenticated;
