-- Epic 5 retrospective (2026-08-26), action item 2 — restoring a feature this epic silently
-- dropped, not adding a new one.
--
-- Story 2.9 (`20260819261000_gate_names_the_chain.sql`) made the routine gate-reminder push
-- name the chain at stake -- "Day N is waiting." -- whenever exactly one commitment was
-- outstanding and its chain was actually running. When Story 5.2 folded Silence-streak
-- detection into this same function (`20260826090000`), its own `create or replace` was
-- branched off a version of the body that predates Story 2.9: `lone_commitment`, `lone_chain`
-- and `stake` never made it into the new declare block or the new outbox body, and Story 5.3's
-- own subsequent replacement (`20260826100000`) inherited the same gap. This migration is the
-- third `create or replace` of this function and changes nothing else about it -- every line
-- Stories 5.2 and 5.3 added (Silence-streak detection, escalation, the routine push itself) is
-- carried forward untouched; only the `lone_commitment`/`lone_chain`/`stake` block Story 2.9
-- originally added is reinstated, in the same place in the routine-push section it always
-- occupied.

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
    -- Story 2.9, restored: `array_agg(...)[1]`, not `min(c.id)` -- Postgres has no `min` for
    -- uuid. The aggregated id is only meaningful when `outstanding = 1`; with more than one
    -- it is an arbitrary row and the stake block below must never use it.
    select count(*), (array_agg(c.id))[1] into outstanding, lone_commitment
      from public.commitment c
     where c.owner_id = account.id
       and c.cadence <> 'daily_hours_quota'
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
  'Hourly (cron "gate-reminders", 20260819210000). Story 2.9 names the chain at stake ("Day N '
  'is waiting.") when exactly one commitment is outstanding and its chain is running -- '
  'restored 2026-08-26 after Stories 5.2/5.3''s own replacements silently dropped it. Story 5.2 '
  'folds Silence-streak detection into this same per-account loop: two consecutive quiet '
  'asked-days with no active episode open one and enqueue exactly one push; while an episode '
  'stays active, this account''s routine gate- pushes are skipped entirely, every slot, every '
  'morning. Story 5.3 folds escalation in beside it: once that same episode reaches 4 '
  'consecutive quiet days (asked_day - started_day >= 3) and has not yet been escalated, it is '
  'stamped escalated_at once and one email-channel outbox row is enqueued -- guarded the same '
  'no-raise way void_expired_appeals() guards its own update, so a concurrent second run of '
  'this pass never sends a second escalation email for the same episode.';

-- create or replace does not reset grants, but stated for the reader rather than assumed
-- carried over silently (20260825110000's own convention for the same situation).
revoke execute on function public.enqueue_gate_reminders() from public, anon, authenticated;
