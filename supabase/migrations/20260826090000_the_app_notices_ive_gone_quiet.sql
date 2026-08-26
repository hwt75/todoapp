-- Story 5.2 — The app notices I have gone quiet (FR-16).
--
-- After two quiet asked-days in a row (zero Declarations answered, both days genuinely owed
-- one), routine notifications stop naming yesterday and start naming the pattern instead: one
-- intervention, delivered once, that states Grace Days remaining and opens the door back in
-- rather than piling a third red prompt on top of two he already walked past.
--
-- Detection lives inside `enqueue_gate_reminders()` itself (20260819210000) rather than a new
-- function or a new cron -- it already loops doer accounts on the morning-slot cadence and
-- already knows the day in question, and a second detector risks disagreeing with it about
-- which day that is. The shape mirrors `supersede_expiries()` (20260819241000): read a source
-- table, re-derive the answer every run, no counter column. `commitments_owing()`
-- (20260819220000) is that source table read, the same one `settle_day()` and
-- `supersede_expiries()` already use.

-- ---------------------------------------------------------------------------------
-- The episode. One row per Silence episode: a due/satisfied-at pair (AD-11) -- the client
-- reads this row rather than the app scheduling or re-scheduling anything.
-- ---------------------------------------------------------------------------------

create table public.silence_episode (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profile (id) on delete cascade,

  -- The earlier of the two quiet asked-days that opened this episode.
  started_day date not null,

  notified_at timestamptz not null default now(),

  -- Null while the episode is open. Set by the trigger below the instant any Declaration is
  -- filed -- never by the client, never by a second pass re-deriving whether it "should" still
  -- be open.
  satisfied_at timestamptz
);

comment on table public.silence_episode is
  'FR-16: one row per Silence episode. started_day is the earlier of the two quiet asked-days '
  'that opened it; notified_at is when the one-shot push was enqueued; satisfied_at (AD-11) is '
  'null while active and set immediately by declaration_satisfies_silence() below on the first '
  'Declaration filed after it opened -- any Declaration, not only one naming started_day.';

-- At most one *active* episode per account -- a satisfied one is history and never blocks a
-- later, separate streak from opening its own new row (the I/O Matrix's own "new episode
-- after satisfaction" row). Also the `on conflict` target `enqueue_gate_reminders()` uses
-- below, mirroring `outbox_enqueue()`'s own dedupe-by-conflict shape rather than a
-- select-then-insert race.
create unique index silence_episode_one_active
  on public.silence_episode (owner_id)
  where satisfied_at is null;

create index silence_episode_owner_idx on public.silence_episode (owner_id);

alter table public.silence_episode enable row level security;

create policy "silence_episode: read own"
  on public.silence_episode for select to authenticated
  using ((select auth.uid()) = owner_id);

-- No insert, update or delete policy. Opening, and ending, an episode is entirely server-side
-- (enqueue_gate_reminders() below and the after-insert trigger below it) -- mirrors
-- settlement's own "one writer" rule (AD-8) for the same reason a client must never decide its
-- own verdict: a client that could open or close its own Silence episode could silence itself
-- out of the one intervention this story exists to deliver.


-- ---------------------------------------------------------------------------------
-- Ends an episode the instant any Declaration is filed. Immediate, not fold-in-delayed like
-- detection itself -- app/page.tsx reads this synchronously (via the row's own satisfied_at)
-- to decide what to render next, and a Declaration answered from inside the intervention's own
-- nested MorningGate must clear it on the very next load, not up to an hour later.
-- ---------------------------------------------------------------------------------

create function public.declaration_satisfies_silence()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.silence_episode
     set satisfied_at = now()
   where owner_id = new.owner_id
     and satisfied_at is null;

  return new;
end;
$$;

comment on function public.declaration_satisfies_silence() is
  'after insert trigger on public.declaration (Story 5.2). Ends the declaring owner''s active '
  'Silence episode, if any, the instant a Declaration lands -- any Declaration, for any '
  'commitment or day, not only one naming the episode''s own started_day. Guarded on '
  'satisfied_at is null, so a second Declaration filed after the episode already closed is a '
  'silent no-op rather than rewriting when it closed.';

create trigger declaration_satisfies_silence
  after insert on public.declaration
  for each row execute function public.declaration_satisfies_silence();

-- Reachable at /rest/v1/rpc otherwise, the exact exposure 20260819121500 closed for
-- handle_new_user. A trigger fires regardless of the EXECUTE grant.
revoke execute on function public.declaration_satisfies_silence() from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- Detection, folded into the existing hourly pass. `create or replace` on the exact function
-- 20260819210000 defined -- migrations are additive, never editing that file itself, the same
-- discipline every prior redefinition in this codebase already follows
-- (20260820102000, 20260820140000, 20260825110000).
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
  'episode open one and enqueue exactly one push (on-conflict dedupe, both on the episode''s '
  'own partial unique index and on the outbox''s own dedupe_key); while an episode stays '
  'active, this account''s routine gate- pushes are skipped entirely, every slot, every '
  'morning.';

-- create or replace does not reset grants, but stated for the reader rather than assumed
-- carried over silently (20260825110000's own convention for the same situation).
revoke execute on function public.enqueue_gate_reminders() from public, anon, authenticated;
