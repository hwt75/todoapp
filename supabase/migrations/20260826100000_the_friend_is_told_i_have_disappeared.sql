-- Story 5.3 — The friend is told I have disappeared (FR-18).
--
-- A Silence episode (Story 5.2) that outlives its own intervention -- the author still has
-- not answered a single Declaration four days after it opened -- stays invisible to the one
-- person who could actually reach out. This story escalates that same episode once, at
-- exactly 4 consecutive quiet days counted from its own started_day, by stamping
-- escalated_at (one more lifecycle milestone on the same row, AD-8/AD-9 -- never a new
-- verdict or table) and enqueuing an email through a new `channel` on the existing outbox
-- rather than a parallel queue.
--
-- Detection stays folded into `enqueue_gate_reminders()` (20260819210000, extended again by
-- 20260826090000) for the same reason Story 5.2 gave: it already loops doer accounts on the
-- morning-slot cadence and already knows the day in question, and a second detector risks
-- disagreeing with it about which day that is. No re-derivation of Silence itself happens
-- here -- the episode staying open (untouched by declaration_satisfies_silence(), 5.2's own
-- trigger) is already proof of continuous silence since started_day.

-- ---------------------------------------------------------------------------------
-- The episode gains one nullable column. Null while unescalated; set once, guarded by
-- `escalated_at is null` on both the read and the update below (mirrors
-- void_expired_appeals()'s own guarded-update, no-raise convention) -- safe under a
-- concurrent second run of the same hourly pass.
-- ---------------------------------------------------------------------------------

alter table public.silence_episode add column escalated_at timestamptz;

comment on column public.silence_episode.escalated_at is
  'FR-18 (Story 5.3): set once an unsatisfied episode reaches 4 consecutive quiet days '
  '(asked_day - started_day >= 3), guarded by escalated_at is null on both the read and the '
  'update. Null while unescalated. Never cleared -- once set, this episode escalates at most '
  'once, even if it later re-opens the routine gate-reminder suppression window again.';


-- ---------------------------------------------------------------------------------
-- The outbox gains a channel. `push` is every row that existed before this story --
-- outbox-worker keeps claiming exactly what it always claimed, unchanged. `email` is new:
-- email-worker (below) is the only thing that ever claims it, over Resend's HTTP API rather
-- than Web Push.
-- ---------------------------------------------------------------------------------

create type public.outbox_channel as enum ('push', 'email');

alter table public.outbox add column channel public.outbox_channel not null default 'push';

comment on column public.outbox.channel is
  'Story 5.3: which worker may claim this row. outbox_claim''s own p_channel filter is the '
  'whole guarantee that outbox-worker (push) and email-worker (email) can never claim each '
  'other''s rows -- not a convention either worker has to remember on its own.';


-- ---------------------------------------------------------------------------------
-- outbox_enqueue gains p_channel, defaulting to 'push' -- every existing call site (settle_day,
-- enqueue_gate_reminders, weekly-quota reminders, focus prompts, ...) keeps enqueuing exactly
-- what it always enqueued, unchanged, without being touched by this migration.
--
-- Adding a parameter changes the function's argument list, so `create or replace` alone would
-- define a second, overloaded function rather than replace this one (Postgres will not let
-- `create or replace` change a function's argument types) -- `drop function` first is this
-- codebase's own established convention for exactly this situation
-- (20260820140000_weekly_quota_is_not_judged_daily.sql's own `commitments_owing()`,
-- 20260819260000_chain.sql's own `day_summary_body()`).
-- ---------------------------------------------------------------------------------

drop function public.outbox_enqueue(uuid, text, jsonb);

/* Called by settlement, inside settlement's own transaction. Returns null when the dedupe
   key has already been seen, which is the point: an effect enqueued twice happens once. */
create function public.outbox_enqueue(
  p_owner uuid,
  p_dedupe_key text,
  p_payload jsonb,
  p_channel public.outbox_channel default 'push'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_id uuid;
begin
  insert into public.outbox (owner_id, dedupe_key, payload, channel)
  values (p_owner, p_dedupe_key, p_payload, p_channel)
  on conflict (dedupe_key) do nothing
  returning id into new_id;

  return new_id;
end;
$$;

revoke execute on function public.outbox_enqueue(uuid, text, jsonb, public.outbox_channel)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- outbox_claim gains p_channel, defaulting to 'push' -- outbox-worker's own call site
-- (`db.rpc('outbox_claim', { p_batch: BATCH })`) is untouched, keeps resolving to the default,
-- and keeps claiming only what it always claimed. Same drop-first convention as above, for the
-- same reason.
-- ---------------------------------------------------------------------------------

drop function public.outbox_claim(integer);

/* Takes a batch of one channel and makes it invisible to any other tick for a minute.

   `for update skip locked` plus a visibility timeout in one statement, never a read
   followed by a write: two ticks overlapping is a normal condition on a schedule, and a
   read-then-write claim sends the same notification twice on the day the first tick runs
   slow. */
create function public.outbox_claim(
  p_batch integer default 10,
  p_channel public.outbox_channel default 'push'
)
returns setof public.outbox
language sql
volatile
security definer
set search_path = ''
as $$
  update public.outbox o
     set attempts = o.attempts + 1,
         claimed_at = now(),
         not_before = now() + interval '1 minute'
   where o.id in (
     select c.id
       from public.outbox c
      where c.status = 'pending'
        and c.not_before <= now()
        and c.channel = p_channel
      order by c.created_at
      for update skip locked
      limit p_batch
   )
  returning o.*;
$$;

revoke execute on function public.outbox_claim(integer, public.outbox_channel)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- Escalation, folded into the existing hourly pass. `create or replace` -- this function's own
-- argument list (none) is unchanged, so unlike the two functions above this really is a
-- replace, exactly the shape 20260826090000 itself used to fold Silence detection in.
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
    select count(*) into outstanding
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

    -- The body states the time it was sent and describes a state as of that time. A push
    -- can arrive minutes late — Story 2.4a's payload rules exist for exactly this, and the
    -- outbox refuses a payload without its own timestamp.
    perform public.outbox_enqueue(
      account.id,
      'gate-' || account.id::text || '-' || asked_day::text || '-' || slot::text,
      jsonb_build_object(
        'title', 'Yesterday',
        'body', outstanding::text
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
  'Hourly (cron "gate-reminders", 20260819210000). Story 5.2 folds Silence-streak detection '
  'into this existing per-account loop: two consecutive quiet asked-days with no active '
  'episode open one and enqueue exactly one push; while an episode stays active, this '
  'account''s routine gate- pushes are skipped entirely, every slot, every morning. Story 5.3 '
  'folds escalation in beside it: once that same episode reaches 4 consecutive quiet days '
  '(asked_day - started_day >= 3) and has not yet been escalated, it is stamped '
  'escalated_at once and one email-channel outbox row is enqueued -- guarded the same '
  'no-raise way void_expired_appeals() guards its own update, so a concurrent second run of '
  'this pass never sends a second escalation email for the same episode.';

-- create or replace does not reset grants, but stated for the reader rather than assumed
-- carried over silently (20260825110000's own convention for the same situation).
revoke execute on function public.enqueue_gate_reminders() from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- The Referee's own read of the escalated-and-unsatisfied episode (FR-18, AD-7). Additive,
-- alongside (not replacing) "silence_episode: read own" -- the doer's own read
-- (20260826090000) is untouched. `escalated_at is not null` is what narrows this to only
-- what the referee is meant to see; `satisfied_at is null` is what clears it the instant any
-- Declaration lands (5.2's own trigger, also untouched by this story) -- the referee-home
-- read below then returns nothing, and no further escalation email ever fires for that same
-- episode again (escalated_at was already set and this migration never clears it).
-- ---------------------------------------------------------------------------------

create policy "silence_episode: referee reads escalated"
  on public.silence_episode
  for select
  to authenticated
  using (
    public.role_from_token() = 'referee'
    and escalated_at is not null
    and satisfied_at is null
  );


-- ---------------------------------------------------------------------------------
-- email-worker's own schedule. Mirrors wake_outbox_worker()/'outbox-worker'
-- (20260819183000) exactly -- same Vault secrets (outbox_worker_key, project_url), same
-- fail-loud-rather-than-silently-do-nothing discipline, same net.http_post shape -- pointed
-- at a different function and a different, hourly cadence: the escalation this drains is a
-- once-per-episode email, not a time-sensitive push, and AD-3 requires this be the worker's
-- own schedule, never triggered by gate-reminders' own run. `:55`, deliberately after
-- gate-reminders' own `:05` slot in the same hour, so an escalation this hour's
-- gate-reminders pass just stamped has already committed before this runs to send it.
-- ---------------------------------------------------------------------------------

create function public.wake_email_worker()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  auth_key text;
  project_url text;
begin
  select decrypted_secret into auth_key
    from vault.decrypted_secrets
   where name = 'outbox_worker_key';

  select decrypted_secret into project_url
    from vault.decrypted_secrets
   where name = 'project_url';

  if auth_key is null or project_url is null then
    raise exception
      'Vault is missing `outbox_worker_key` or `project_url`. The email channel has no '
      'consumer, which looks exactly like a working system. See README, Database and sign-in.';
  end if;

  perform net.http_post(
    url     := project_url || '/functions/v1/email-worker',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || auth_key
               ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 20000
  );
end;
$$;

revoke execute on function public.wake_email_worker() from public, anon, authenticated;

select cron.schedule(
  'email-worker',
  '55 * * * *',
  $$select public.wake_email_worker()$$
);
