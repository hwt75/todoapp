-- Every surface asks the day the same question.
--
-- A regression this repository introduced on 2026-09-07 and shipped to the live project the same
-- day. `20260907100000` (Epic 6 retrospective item 38) moved `declaration_derive_day()` onto
-- `due_time_as_of()`, so a claim queued offline keeps the meaning it had when it was tapped. On the
-- day a due time is switched on, that door reports the day untimed, and the derivation therefore
-- *refuses* a same-day claim and tells the author to answer in the next morning's question instead.
--
-- Three surfaces decide whether to ask, and all three were left reading the live
-- `commitment.due_time`: `enqueue_gate_reminders()` (the morning push), `timed_claim_today` (the
-- Claim control), and the client's own gate. So nothing asked. The author could not claim the day
-- and was never asked about it, and `settle_day()` counted the resulting silence as `expired` with
-- a penalty minted and the chain broken -- money taken for a question that was never put.
--
-- The invariant that made the live read correct was written down twice, here at the gate and again
-- on `timed_claim_today`, both saying "declaration_derive_day() reads the live value too". Item 38
-- falsified that sentence without either comment being opened. Both are corrected below rather than
-- left to be re-read as true.
--
-- This changes no settled day: it changes which days are *asked about*, and a day already answered
-- or already settled is filtered out by the clauses that were always there.


-- ---------------------------------------------------------------------------------
-- The morning question.
-- ---------------------------------------------------------------------------------

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
  per account. Reads due_time_as_of() rather than the live due_time (2026-09-07): a day no time
  governed is the morning question''s to ask about, which is exactly what declaration_derive_day()
  tells the author when it refuses a claim on such a day. While this read was live, that refusal
  pointed at a question nobody asked and the day settled as silence with a penalty.';

revoke execute on function public.enqueue_gate_reminders() from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- The Claim control.
-- ---------------------------------------------------------------------------------

/* Same correction, same reason. The view decided what Today may offer from the live column, so on
   the day a time was switched on it rendered a Claim that `declaration_derive_day()` refuses every
   time. A control that cannot succeed is worse than no control: it spends the author's attention
   and then tells him he was wrong to use it.

   Columns are unchanged, so this is a `create or replace` rather than a drop -- nothing downstream
   has to be recreated. */
create or replace view public.timed_claim_today
with (security_invoker = true)
as
with today as (
  select (now() at time zone 'Asia/Ho_Chi_Minh')::date as d
)
select c.owner_id,
       c.id as commitment_id,
       -- What a photo attaches to. Without it a reload strands a claim made earlier today: the
       -- id lives only in the component state the claim returned, so the author who claimed at
       -- 20:31 and closed the app had no way back to the upload control at 20:40, and the day
       -- failed at midnight for a photo he was never offered a second chance to attach.
       d.id as declaration_id,
       -- The existence of an evidence row *is* acceptance -- the capture-date rule and the
       -- frozen-day refusal both live in `evidence_derive_owner()` (20260828150000), so a row
       -- that exists is a row that passed them.
       (d.id is not null and exists (
          select 1 from public.evidence e where e.declaration_id = d.id
        )) as proven
  from public.commitment c
  cross join today t
  left join public.declaration d
         on d.commitment_id = c.id
        and d.for_day = t.d
 where public.due_time_as_of(c.id, t.d) is not null
   and c.archived_at is null;

comment on view public.timed_claim_today is
  'Story 6.5: for every open timed commitment of the caller, whether today has been claimed
  (declaration_id, also what a photo attaches to) and whether a photo has landed on that claim
  (proven). Facts only -- never a verdict, which stays with commitments_owing() and settle_day().
  Reads due_time_as_of() rather than the live due_time (2026-09-07). It read the live value until
  then, on the stated grounds that declaration_derive_day() judged a tap against the same live
  value; item 38 moved that derivation onto the door and left this behind, so on the day a time was
  switched on the view offered a Claim the server refused every time. security_invoker, so RLS on
  commitment, declaration and evidence is what scopes it -- never a client-side tally of raw rows
  (AD-8).';


-- ---------------------------------------------------------------------------------
-- The same fact, for the client's own gate.
-- ---------------------------------------------------------------------------------

/* `lib/use-gate.ts` decides what the morning question asks about, from a plain `commitment` select,
   and `isAskedNextMorning()` read `due_time` straight off that row. It is the third live reader and
   the load-bearing one: the push above is a reminder, but this is the surface that actually puts
   the question on screen, so while it disagreed with the door the day stayed unanswerable even
   with the push fixed.

   A view rather than an RPC, because the client already reads its commitments this way and the
   answer is one column keyed by commitment. The day is fixed rather than a parameter for the same
   reason `timed_claim_today` fixes its own: `dayInQuestion()` is always the previous local day,
   independent of the morning hour (`lib/declaration.ts`), so there is exactly one day to answer
   about and a view can name it. */
create view public.morning_question_day
with (security_invoker = true)
as
with asked as (
  select ((now() at time zone 'Asia/Ho_Chi_Minh')::date - 1) as d
)
select c.owner_id,
       c.id as commitment_id,
       a.d  as for_day,
       -- Null means the morning question owns this day. Non-null means a window did, and the day
       -- was decided at its own midnight.
       public.due_time_as_of(c.id, a.d) as governing_due_time
  from public.commitment c
  cross join asked a;

comment on view public.morning_question_day is
  'For each of the caller''s commitments, the due_time that governed the day the morning question is
  about -- the previous local day, which dayInQuestion() names independently of the morning hour.
  Null means no time governed that day, so it is the morning question''s to ask about; non-null
  means it was decided at its own midnight. Exists so the client gate reads the same door
  enqueue_gate_reminders() and settle_day() read, instead of the live column it read until
  2026-09-07. Carries no filtering of its own -- archived, cadence and already-answered stay with
  commitmentsOwing(), which was always where they lived. security_invoker, so RLS scopes it.';
