-- Story 6.6 — the reminder lands inside the window.
--
-- The mechanism is `outbox.not_before`: an hourly pass at `:50` queues a row *ahead* of the hour
-- carrying the instant its window opens, and the every-minute outbox worker — untouched by this
-- story — delivers it when that instant arrives. What has to be proved here is that the instant
-- is right, that the row is cancelled the moment the facts it was built from change, and that the
-- claim predicate really does hold it back until then.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/6-6-the-reminder-lands-inside-the-window.sql
--
-- One transaction, rolled back at the end. It settles nothing, moves no money and is safe
-- against any database.
--
-- **Three things this file exists to pin, because three review loops failed to.**
--
--   1. *The production path.* Every write the app really makes — the commitment insert, the
--      edit, the archive, the claim — runs as `authenticated`, through the same
--      `set_config('request.jwt.claims', ...)` idiom `6-5` uses. Loop 3 wrote every fixture as
--      `postgres`, the trigger functions' own owner; a reviewer then dropped `security definer`
--      from the chokepoint and both trigger functions and every file stayed green while a
--      commitment inserted as `authenticated` queued nothing — the permission error went into a
--      `when others then null` and vanished.
--   2. *The tomorrow branch.* Asserted behaviourally, by passing the chokepoint's own `p_now`
--      late enough in the local day that tomorrow's window falls inside the lookahead. Never by
--      reading `pg_proc.prosrc`: loop 3 did that, and a reviewer defeated it in one edit by
--      replacing `today + 1` with `case when true then today else today + 1 end`.
--   3. *Both halves of the cancel guard.* A row a live worker holds survives, and so does one
--      already `sent` — deleting a sent row frees the dedupe key that enforces one reminder per
--      commitment-day and destroys the record that the push went out.
--
-- **No assertion here may depend on the hour the suite runs, and the file must never `raise`
-- because of the wall clock** — every file runs on every push under `ON_ERROR_STOP=1`, so a
-- refused precondition is a red build, not a skip. Two habits make that true. `now()` is the
-- transaction's own timestamp and therefore frozen for the whole file, so every fixture derived
-- from it agrees with every other. And every assertion is keyed on the date its own fixture
-- actually resolved to (`v_fix_day`), never on an assumed "today": loop 2 went red between 23:40
-- and midnight because a fixture six minutes ahead had already rolled onto tomorrow.

begin;

-- The table privileges the client path below depends on, asserted rather than re-issued.
--
-- Granting them here would be the same defect class as loop 3's `postgres` fixtures: this file's
-- headline claim is that the writes the app really makes queue and cancel their own rows, and a
-- `grant ... to authenticated` at the top would paper over a production revoke and keep the file
-- green while the feature was dead for every real commitment. `select` on `commitment` is in the
-- list because `declaration_derive_day()` is invoker-rights on purpose (20260828140000) and
-- because `insert ... returning` reads back what it wrote.
do $$
declare
  v_priv text;
begin
  foreach v_priv in array array['select', 'insert', 'update'] loop
    if not has_table_privilege('authenticated', 'public.commitment', v_priv) then
      raise exception using message = format(
        '`authenticated` cannot %s public.commitment. This file proves the client write path; '
        'without the privilege it would prove nothing, and re-granting it here would hide '
        'exactly the production breakage it exists to catch.', upper(v_priv));
    end if;
  end loop;

  if not has_table_privilege('authenticated', 'public.declaration', 'insert') then
    raise exception using message =
      '`authenticated` cannot INSERT public.declaration — the claim is one of the four writes '
      'this file drives through the real client path.';
  end if;

  raise notice using message =
    'Precondition ok: `authenticated` already holds the table privileges the client path needs; '
    'nothing is granted by this file.';
end $$;

do $$
declare
  v_a  uuid := gen_random_uuid();  -- the account nearly everything hangs off
  v_b  uuid := gen_random_uuid();  -- a second account, to prove owner_id is not assumed
  v_c  uuid := gen_random_uuid();  -- the account with an open Silence episode

  v_daily        uuid;  -- the routine case: timed, daily, unclaimed
  v_quota        uuid;  -- weekly_quota: reminded, but its copy may not claim the day fails
  v_claimed      uuid;  -- already declared for the fixture day
  v_untimed      uuid;  -- no due_time at all; the morning gate still owns it
  v_archived     uuid;  -- timed and archived
  v_poison       uuid;  -- a name that defeats push_body_is_sendable
  v_claimtest    uuid;  -- the row outbox_claim() is driven against
  v_theirs       uuid;  -- v_b's own
  v_silent       uuid;  -- v_c's own, behind an open Silence episode
  v_edge         uuid;  -- the lookahead's four edge assertions
  v_midnight     uuid;  -- due 00:30, reachable only through the tomorrow branch
  v_created      uuid;  -- created as `authenticated`, mid-window
  v_widened      uuid;  -- only its late_window_minutes changes
  v_cleared      uuid;  -- its due_time is set back to null
  v_moved        uuid;  -- its due_time changed part-way through today
  v_claim_cancel uuid;  -- claimed after its row was already queued

  v_now   timestamptz := now();
  v_today date        := (now() at time zone 'Asia/Ho_Chi_Minh')::date;

  -- The fixture window: a whole minute a few minutes ahead of the real local clock, so the
  -- chokepoint's `[p_now, p_now + 90 minutes)` bound genuinely admits it at any hour.
  --
  -- The one adjustment is not about the assertions but about `commitment_window_within_the_day`
  -- (20260828130000): a 30-minute window opening at 23:45 would cross midnight and the INSERT
  -- would be refused by a check constraint — a red build caused by the clock, which this file
  -- may never produce. So a fixture landing in the last hour of the local day is taken from the
  -- start of the next one instead. That keeps it between 6 and 72 minutes ahead of `now()`,
  -- inside the lookahead either way.
  v_fix_at    timestamptz;
  v_fix_local timestamp;
  v_fix_day   date;
  v_fix_due   time;
  v_fix_shuts text;
  v_wide_shuts text;

  v_key       text;
  v_count     integer;
  v_when      timestamptz;
  v_body      text;
  v_title     text;
  v_sent_at   text;
  v_owner     uuid;
  v_channel   public.outbox_channel;
  v_ok        boolean;
  v_instant   timestamptz;
  v_pass_now  timestamptz;
  v_case      text;
  v_acct      uuid;
begin
  -- -------------------------------------------------------------------------------
  -- 0. Fixtures.
  -- -------------------------------------------------------------------------------
  v_fix_at := date_trunc('minute', v_now) + interval '6 minutes';
  v_fix_local := v_fix_at at time zone 'Asia/Ho_Chi_Minh';
  if v_fix_local::time > time '22:59' then
    v_fix_local := (v_fix_local::date + 1)::timestamp + interval '6 minutes';
    v_fix_at := v_fix_local at time zone 'Asia/Ho_Chi_Minh';
  end if;
  v_fix_day := v_fix_local::date;
  v_fix_due := v_fix_local::time;
  v_fix_shuts := to_char(v_fix_local + interval '30 minutes', 'HH24:MI');

  foreach v_case in array array['a', 'b', 'c']
  loop
    v_acct := case v_case when 'a' then v_a when 'b' then v_b else v_c end;
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data)
    values (v_acct, '00000000-0000-0000-0000-000000000000',
            'authenticated', 'authenticated',
            'story-6-6-' || v_case || '-' || gen_random_uuid()::text || '@example.test',
            'not-a-real-password-this-account-never-signs-in',
            now(), now(), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);
  end loop;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Thuoc', 'do', 'daily', v_fix_due, 30)
  returning id into v_daily;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 weekly_target, week_start_day, due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Swim', 'do', 'weekly_quota', 3, 1, v_fix_due, 30)
  returning id into v_quota;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Stretch', 'do', 'daily', v_fix_due, 30)
  returning id into v_claimed;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence)
  values (v_a, gen_random_uuid(), 'Gym', 'do', 'daily')
  returning id into v_untimed;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes, archived_at)
  values (v_a, gen_random_uuid(), 'Old pill', 'do', 'daily', v_fix_due, 30, now())
  returning id into v_archived;

  -- The same poisoned-name fixture `3-2` and `3-5` already carry: "right now" is one of the four
  -- phrases push_body_is_sendable refuses, and a commitment name is freeform text the author
  -- typed, so it can contain one by accident.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Read right now', 'do', 'daily', v_fix_due, 30)
  returning id into v_poison;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Walk', 'do', 'daily', v_fix_due, 30)
  returning id into v_claimtest;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Stand up', 'do', 'daily', time '08:00', 30)
  returning id into v_edge;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Night pill', 'do', 'daily', time '00:30', 30)
  returning id into v_midnight;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_b, gen_random_uuid(), 'Their pill', 'do', 'daily', v_fix_due, 30)
  returning id into v_theirs;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_c, gen_random_uuid(), 'Quiet pill', 'do', 'daily', v_fix_due, 30)
  returning id into v_silent;

  -- v_claimed is answered for the fixture day, through the real client path: the window is the
  -- fixture's own, and `declaration_derive_day()` refuses a tap outside it.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_a, v_claimed, gen_random_uuid(), 'held', v_fix_at);

  perform set_config('role', 'postgres', true);

  raise notice using message = format(
    'Fixture ok: the window opens at %s on %s (%s), shuts at %s.',
    to_char(v_fix_due, 'HH24:MI'), v_fix_day, v_fix_at, v_fix_shuts);

  -- -------------------------------------------------------------------------------
  -- 1. The hourly pass.
  --
  -- The queue is cleared first so this step reads what the *pass* did rather than what the
  -- INSERT triggers above already did — those get their own unconditional step further down.
  -- -------------------------------------------------------------------------------
  delete from public.outbox where dedupe_key like 'due-%';

  perform public.enqueue_due_time_reminders();

  v_key := 'due-' || v_daily::text || '-' || v_fix_day::text;

  select count(*) into v_count from public.outbox where dedupe_key = v_key;
  if v_count <> 1 then
    raise exception using message = format(
      'The pass left %s row(s) at `%s` for a timed, unclaimed commitment whose window opens in '
      'minutes. One reminder per commitment-day is the whole contract.', v_count, v_key);
  end if;

  select not_before, owner_id, channel, status::text,
         payload ->> 'body', payload ->> 'title', payload ->> 'sent_at'
    into v_when, v_owner, v_channel, v_case, v_body, v_title, v_sent_at
    from public.outbox where dedupe_key = v_key;

  if v_when is distinct from v_fix_at then
    raise exception using message = format(
      'The row''s not_before reads %s; the window opens at %s. `not_before` is the entire '
      'mechanism — the worker delivers at that instant and no earlier.', v_when, v_fix_at);
  end if;

  if v_owner is distinct from v_a then
    raise exception using message = format(
      'The row is owned by %s rather than the commitment''s own owner %s.', v_owner, v_a);
  end if;

  if v_channel is distinct from 'push' then
    raise exception using message = format(
      'The row is on the `%s` channel. Only outbox-worker delivers a reminder; email-worker '
      'claims a different channel entirely.', v_channel);
  end if;

  if v_case <> 'pending' then
    raise exception using message = format('A freshly queued row reads `%s`.', v_case);
  end if;

  if v_title is distinct from to_char(v_fix_due, 'HH24:MI') then
    raise exception using message = format(
      'The title reads "%s", expected the window''s opening time "%s".',
      v_title, to_char(v_fix_due, 'HH24:MI'));
  end if;

  if v_body not like 'Thuoc %' or v_body not like '%' || v_fix_shuts || '%'
     or v_body not like '%the day fails.' then
    raise exception using message = format(
      'The daily body reads "%s". It must name the commitment, the hour the window shuts (%s), '
      'and — for a daily cadence only — what a missing photo costs.', v_body, v_fix_shuts);
  end if;

  -- The payload rule exists because a push is read at a time the sender cannot know
  -- (20260820101000). A row queued now and delivered in an hour that dated itself "now" would be
  -- lying by an hour about the one thing that rule is for.
  if v_sent_at is distinct from to_char(v_fix_at at time zone 'utc',
                                        'YYYY-MM-DD"T"HH24:MI:SS"Z"') then
    raise exception using message = format(
      'The payload dates itself %s; it is delivered at %s. sent_at is the delivery instant, '
      'never the queue time.', v_sent_at, v_fix_at);
  end if;

  -- A weekly_quota day is judged at week close and cannot fail for a missing photo (FR-2), so
  -- the daily sentence would be a lie about money.
  select payload ->> 'body' into v_body
    from public.outbox
   where dedupe_key = 'due-' || v_quota::text || '-' || v_fix_day::text;

  if v_body is null then
    raise exception using message =
      'A timed weekly_quota commitment was not reminded at all. It has a window like any other; '
      'only what a missed one costs is different.';
  end if;

  if v_body like '%the day fails%' then
    raise exception using message = format(
      'The weekly_quota body reads "%s". Its day cannot fail for a missing photo — settle_week() '
      'judges it at week close — so this push names a cost the day will never carry.', v_body);
  end if;

  if v_body not like '%' || v_fix_shuts || '%' then
    raise exception using message = format(
      'The weekly_quota body "%s" does not name the hour the window shuts, which is what makes '
      'it pass push_body_is_sendable and is the useful half of it.', v_body);
  end if;

  select count(*) into v_count from public.outbox
   where dedupe_key like 'due-' || v_claimed::text || '-%';
  if v_count <> 0 then
    raise exception using message = format(
      'A commitment already declared for its own day enqueued %s row(s). The claim is the answer; '
      'reminding him to do what he has already said he did is the second notification this story '
      'forbids.', v_count);
  end if;

  select count(*) into v_count from public.outbox
   where dedupe_key like 'due-' || v_untimed::text || '-%';
  if v_count <> 0 then
    raise exception using message = format(
      'An untimed commitment enqueued %s row(s). It has no window; the morning gate still owns '
      'it.', v_count);
  end if;

  select count(*) into v_count from public.outbox
   where dedupe_key like 'due-' || v_archived::text || '-%';
  if v_count <> 0 then
    raise exception using message = format(
      'An archived commitment enqueued %s row(s) — a push for something the author has already '
      'deleted.', v_count);
  end if;

  select count(*) into v_count from public.outbox
   where dedupe_key like 'due-' || v_poison::text || '-%';
  if v_count <> 0 then
    raise exception using message = format(
      'A commitment whose name defeats push_body_is_sendable enqueued %s row(s).', v_count);
  end if;

  -- And it did not take the pass down with it: the benign row above was queued in the same run.
  -- Story 3.2's review found what an unhandled exception in an enqueue pass does — it unwinds
  -- the whole function and rolls back every row already queued, for every account before it.
  select count(*) into v_count from public.outbox where dedupe_key = v_key;
  if v_count <> 1 then
    raise exception using message =
      'The poisoned commitment took the rest of the pass with it. A refusal must be a `return '
      'false`, never an exception.';
  end if;

  select owner_id into v_owner from public.outbox
   where dedupe_key = 'due-' || v_theirs::text || '-' || v_fix_day::text;
  if v_owner is distinct from v_b then
    raise exception using message = format(
      'The second account''s reminder is owned by %s, expected %s.', v_owner, v_b);
  end if;

  raise notice using message =
    'Step 1 ok: the pass queues one deferred row per timed, unclaimed commitment, at the instant '
    'its own window opens, on the push channel and against its own owner; a weekly_quota body '
    'names no failed day; a claimed, an untimed, an archived and a poisoned commitment queue '
    'nothing, and the poisoned one harms no other row.';

  -- -------------------------------------------------------------------------------
  -- 2. A retried pass is a no-op. `:50` overlapping a ninety-minute lookahead is deliberate.
  -- -------------------------------------------------------------------------------
  perform public.enqueue_due_time_reminders();

  select count(*) into v_count from public.outbox where dedupe_key = v_key;
  if v_count <> 1 then
    raise exception using message = format(
      'A second pass over the same hour left %s row(s) at `%s`. The unique dedupe key is what '
      'makes ninety minutes of overlap against an hourly run free.', v_count, v_key);
  end if;

  raise notice using message = 'Step 2 ok: a repeated pass enqueues nothing new.';

  -- -------------------------------------------------------------------------------
  -- 3. An open Silence episode does not suppress this reminder.
  --
  -- `5-2` pins the opposite behaviour for the routine gate- push, which the intervention
  -- replaces. This one is not routine: an author who has gone quiet is exactly the one whose
  -- timed day is about to cost him money.
  -- -------------------------------------------------------------------------------
  insert into public.silence_episode (owner_id, started_day, notified_at)
  values (v_c, v_today - 2, now());

  delete from public.outbox where dedupe_key like 'due-' || v_silent::text || '-%';

  perform public.enqueue_due_time_reminders();

  select count(*) into v_count from public.outbox
   where dedupe_key = 'due-' || v_silent::text || '-' || v_fix_day::text;
  if v_count <> 1 then
    raise exception using message = format(
      'An account with an open Silence episode got %s reminder(s) for a window opening in '
      'minutes. Suppression exists for the routine morning gate; this one costs money tonight.',
      v_count);
  end if;

  raise notice using message =
    'Step 3 ok: an account with an open, unsatisfied Silence episode is still reminded of its '
    'own window. (`5-2:155` is what pins the opposite for the routine gate push; this step does '
    'not run that pass.)';

  -- -------------------------------------------------------------------------------
  -- 4. The mechanism itself: outbox_claim() holds the row back until its instant arrives.
  --
  -- Asserted by calling the claim rather than inferred from the column, because the column is
  -- only meaningful through that predicate. The fixture moves — its `not_before` is pulled into
  -- the past the way the passage of time would — never the clock.
  -- -------------------------------------------------------------------------------
  v_key := 'due-' || v_claimtest::text || '-' || v_fix_day::text;

  select count(*) into v_count from public.outbox where dedupe_key = v_key;
  if v_count <> 1 then
    raise exception using message = format(
      'Expected one queued row at `%s` before driving the claim, found %s.', v_key, v_count);
  end if;

  select count(*) into v_count
    from public.outbox_claim(50) o where o.dedupe_key = v_key;
  if v_count <> 0 then
    raise exception using message =
      'outbox_claim() handed out a reminder whose window has not opened yet. The push would '
      'land before the hour it names, which is the same defect as landing after it.';
  end if;

  update public.outbox set not_before = now() - interval '1 second' where dedupe_key = v_key;

  select count(*) into v_count
    from public.outbox_claim(50) o where o.dedupe_key = v_key;
  if v_count <> 1 then
    raise exception using message =
      'outbox_claim() did not return the reminder once its instant had passed. Nothing else '
      'delivers it; the row would sit in the queue forever.';
  end if;

  raise notice using message =
    'Step 4 ok: the claim refuses the row before its instant and takes it after.';

  -- -------------------------------------------------------------------------------
  -- 5. Both edges of the ninety-minute lookahead, half-open `[p_now, p_now + 90 minutes)`.
  --
  -- Driven through the chokepoint's own `p_now` on days far enough out that nothing else in this
  -- file touches those keys. Narrowing or widening the bound turns each pair red.
  -- -------------------------------------------------------------------------------
  v_instant := public.due_time_instant(v_today + 5, time '08:00');
  v_ok := public.enqueue_due_time_reminder(v_edge, v_today + 5, v_instant);
  if not v_ok then
    raise exception using message =
      'A window opening at exactly this instant was refused. The lower edge is inclusive: the '
      'reminder is meant to land as the window opens, not one tick later.';
  end if;

  v_instant := public.due_time_instant(v_today + 6, time '08:00');
  v_ok := public.enqueue_due_time_reminder(v_edge, v_today + 6, v_instant + interval '1 second');
  if v_ok then
    raise exception using message =
      'A window that opened a second ago was still queued. A reminder arriving at minute four of '
      'a five-minute window is technically inside it and practically useless.';
  end if;
  select count(*) into v_count from public.outbox
   where dedupe_key = 'due-' || v_edge::text || '-' || (v_today + 6)::text;
  if v_count <> 0 then
    raise exception using message = format(
      'The refusal returned false but left %s row(s) behind.', v_count);
  end if;

  v_instant := public.due_time_instant(v_today + 7, time '08:00');
  v_ok := public.enqueue_due_time_reminder(v_edge, v_today + 7, v_instant - interval '90 minutes');
  if v_ok then
    raise exception using message =
      'A window exactly ninety minutes out was queued. The upper edge is exclusive, and it is '
      'what keeps a trigger from queueing a window half a day ahead that then outlives every '
      'fact it was built from.';
  end if;

  v_instant := public.due_time_instant(v_today + 8, time '08:00');
  v_ok := public.enqueue_due_time_reminder(
            v_edge, v_today + 8, v_instant - interval '90 minutes' + interval '1 second');
  if not v_ok then
    raise exception using message =
      'A window one second inside the ninety-minute lookahead was refused. Narrowed, the pass '
      'stops reaching the windows its own hourly cadence exists to cover.';
  end if;

  raise notice using message =
    'Step 5 ok: the lookahead admits [p_now, p_now + 90 minutes) and nothing either side of it.';

  -- -------------------------------------------------------------------------------
  -- 6. The tomorrow branch, asserted behaviourally at any hour.
  --
  -- A `due_time` of 00:10 is unreachable from the run before it unless both days are resolved:
  -- the 23:50 run resolves the previous local day, and by the time the date rolls over the window
  -- has opened. `p_now` is pinned to 23:30 local so tomorrow's 00:30 window is sixty minutes out
  -- — inside the lookahead — while today's, twenty-three hours behind, is not. Deleting the
  -- second date, or short-circuiting it while leaving the text in place, turns this red.
  --
  -- **Both entry points, because they are two callers of one function and the trigger reads the
  -- real clock.** `offer_due_time_reminders()` is where the second date is written and where
  -- `commitment_due_time_written()` gets it from — pinned directly here, so a mutation to it goes
  -- red at any hour rather than only during the hour when tomorrow's earliest window happens to
  -- be near. The pass is then driven over the same fixture to prove it comes through the same
  -- door.
  --
  -- **The queue is cleared for this commitment first, and that is not tidiness.** Between 00:00
  -- and 00:30 local, step 1's pass legitimately queues today's 00:30 row and the absence
  -- assertion below would raise on a correct implementation; after about 23:00 the fixture's own
  -- INSERT trigger has already queued tomorrow's, and the presence assertion would pass even with
  -- the second date deleted. Clearing first is what makes both directions mean something at every
  -- hour.
  --
  -- **The expected instant is built independently.** Asserting against `due_time_instant()` would
  -- compare the chokepoint's conversion with itself, and a wrong time zone would satisfy both
  -- sides — so the literal local timestamp is assembled here the way `6-5:37` assembles its own.
  -- -------------------------------------------------------------------------------
  v_instant := ((v_today + 1)::text || ' 00:30')::timestamp at time zone 'Asia/Ho_Chi_Minh';
  v_pass_now := v_instant - interval '60 minutes';

  delete from public.outbox where dedupe_key like 'due-' || v_midnight::text || '-%';

  if public.offer_due_time_reminders(v_midnight, v_pass_now) <> 1 then
    raise exception using message =
      'Offering the 00:30 commitment at 23:30 local queued a number of rows other than one. '
      'Exactly one of the two days it names — tomorrow — is inside the lookahead.';
  end if;

  select count(*), min(not_before) into v_count, v_when from public.outbox
   where dedupe_key = 'due-' || v_midnight::text || '-' || (v_today + 1)::text;
  if v_count <> 1 then
    raise exception using message = format(
      'The offer left %s row(s) for tomorrow''s 00:30 window when made at 23:30 local. Without '
      'the second date this time is reachable by nothing at all — not by the pass, and not by '
      'the trigger on a commitment created at 23:51.', v_count);
  end if;
  if v_when is distinct from v_instant then
    raise exception using message = format(
      'Tomorrow''s reminder is due %s; 00:30 tomorrow in Asia/Ho_Chi_Minh is %s.',
      v_when, v_instant);
  end if;

  select count(*) into v_count from public.outbox
   where dedupe_key = 'due-' || v_midnight::text || '-' || v_today::text;
  if v_count <> 0 then
    raise exception using message = format(
      'The same offer also queued %s row(s) for *today''s* 00:30 window, twenty-three hours in '
      'the past. The second date must be tomorrow, not today again.', v_count);
  end if;

  -- And the pass reaches it through that same door.
  delete from public.outbox where dedupe_key like 'due-' || v_midnight::text || '-%';

  perform public.enqueue_due_time_reminders(v_pass_now);

  select count(*) into v_count from public.outbox
   where dedupe_key = 'due-' || v_midnight::text || '-' || (v_today + 1)::text;
  if v_count <> 1 then
    raise exception using message = format(
      'The hourly pass left %s row(s) for tomorrow''s 00:30 window. It must offer the same two '
      'days the trigger does, from the same function.', v_count);
  end if;

  raise notice using message =
    'Step 6 ok: today and tomorrow are resolved by one function both callers use, and at 23:30 '
    'local only tomorrow''s 00:30 window is inside the lookahead.';

  -- -------------------------------------------------------------------------------
  -- 7. The INSERT arm, through the path the app actually takes.
  --
  -- A commitment created at 20:15 carrying a 20:40 window is one the 19:50 pass could not have
  -- seen and the 20:50 pass would reach after it opened. Its own creation entry is the one
  -- `due_time_as_of()` excepts, so it genuinely owns that window.
  --
  -- Written as `authenticated`. That is what makes the assertion mean anything: with
  -- `security definer` dropped from the trigger function or the chokepoint, the write below
  -- succeeds, the permission error disappears into a `when others` handler, and no row is queued.
  -- -------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Vitamin', 'do', 'daily', v_fix_due, 30)
  returning id into v_created;

  perform set_config('role', 'postgres', true);

  v_key := 'due-' || v_created::text || '-' || v_fix_day::text;

  select count(*) into v_count from public.outbox where dedupe_key = v_key;
  if v_count <> 1 then
    raise exception using message = format(
      'A commitment inserted as `authenticated` carrying a window minutes away queued %s row(s). '
      'The write itself is the only thing that can reach that window in time — and if this is '
      'zero while a `postgres` insert works, the privilege chain is dead and the error was '
      'swallowed.', v_count);
  end if;

  select not_before, owner_id into v_when, v_owner from public.outbox where dedupe_key = v_key;
  if v_when is distinct from v_fix_at or v_owner is distinct from v_a then
    raise exception using message = format(
      'The trigger''s own row is due %s for owner %s; expected %s and %s.',
      v_when, v_owner, v_fix_at, v_a);
  end if;

  raise notice using message =
    'Step 7 ok: a commitment created through the client path queues its own window.';

  -- -------------------------------------------------------------------------------
  -- 8. The UPDATE arm cancels, and re-offers. A rename is the case that proves both halves.
  --
  -- A rename writes no `commitment_due_time_change` row, so today is still perfectly governed —
  -- cancelling without re-offering would lose the reminder outright whenever the window opens
  -- before the next `:50` pass. And because `outbox_enqueue` is `on conflict do nothing`, the
  -- body can only carry the new name if the old row was actually deleted first.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  update public.commitment set name = 'Vitamin D' where id = v_created;
  perform set_config('role', 'postgres', true);

  select count(*), min(payload ->> 'body') into v_count, v_body
    from public.outbox where dedupe_key = v_key;

  if v_count <> 1 then
    raise exception using message = format(
      'After a rename the queue holds %s row(s) at `%s`, expected 1. A rename leaves today '
      'governed; deleting without re-offering costs the author the reminder entirely.',
      v_count, v_key);
  end if;

  if v_body not like 'Vitamin D %' then
    raise exception using message = format(
      'The queued body still reads "%s". `outbox_enqueue` is `on conflict do nothing`, so the '
      'new name can only appear if the stale row was deleted first — this is the delete half of '
      'the UPDATE arm.', v_body);
  end if;

  raise notice using message =
    'Step 8 ok: an edit deletes the stale row and re-offers the day, and the body follows.';

  -- -------------------------------------------------------------------------------
  -- 8b. A cadence change rewrites the queued body.
  --
  -- The body's second sentence is built from `cadence`, so a `daily -> weekly_quota` change
  -- leaves a queued push asserting a failed day the week will never charge. That is why `cadence`
  -- is in the UPDATE trigger's own column list; drop it from there and this row keeps saying the
  -- day fails.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  update public.commitment
     set cadence = 'weekly_quota', weekly_target = 3, week_start_day = 1
   where id = v_created;
  perform set_config('role', 'postgres', true);

  select count(*), min(payload ->> 'body') into v_count, v_body
    from public.outbox where dedupe_key = v_key;

  if v_count <> 1 then
    raise exception using message = format(
      'After a cadence change the queue holds %s row(s) at `%s`, expected 1.', v_count, v_key);
  end if;

  if v_body like '%the day fails%' then
    raise exception using message = format(
      'The queued body still reads "%s" after the commitment became a weekly quota. Its day is '
      'judged at week close and cannot fail for a missing photo, so this push now names a cost '
      'the week will never charge.', v_body);
  end if;

  raise notice using message =
    'Step 8b ok: a cadence change rewrites the sentence that names what a missed day costs.';

  -- -------------------------------------------------------------------------------
  -- 8c. Widening the window alone rewrites the hour the body names.
  --
  -- `late_window_minutes` is the one column in the trigger's list that nothing else here touches:
  -- rename covers `name`, 8b covers `cadence`, 9 covers `archived_at`, 10 covers `due_time`. Drop
  -- it from `after update of` and from the `when` clause and, without this step, nothing turns
  -- red — while the author gets a push telling him the window shuts half an hour before it does.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Insulin', 'do', 'daily', v_fix_due, 30)
  returning id into v_widened;
  perform set_config('role', 'postgres', true);

  v_key := 'due-' || v_widened::text || '-' || v_fix_day::text;

  select payload ->> 'body' into v_body from public.outbox where dedupe_key = v_key;
  if v_body is null or v_body not like '%' || v_fix_shuts || '%' then
    raise exception using message = format(
      'Expected a queued body naming a window shutting at %s before widening it, read "%s".',
      v_fix_shuts, coalesce(v_body, 'no row at all'));
  end if;

  v_wide_shuts := to_char(v_fix_local + interval '60 minutes', 'HH24:MI');

  perform set_config('role', 'authenticated', true);
  update public.commitment set late_window_minutes = 60 where id = v_widened;
  perform set_config('role', 'postgres', true);

  select count(*), min(payload ->> 'body') into v_count, v_body
    from public.outbox where dedupe_key = v_key;

  if v_count <> 1 then
    raise exception using message = format(
      'After widening the window the queue holds %s row(s) at `%s`, expected 1.', v_count, v_key);
  end if;

  if v_body not like '%' || v_wide_shuts || '%' then
    raise exception using message = format(
      'The queued body still reads "%s" after the window was widened to shut at %s. The push '
      'would tell the author he has half an hour less than he does.', v_body, v_wide_shuts);
  end if;

  raise notice using message =
    'Step 8c ok: widening late_window_minutes alone rewrites the hour the body names.';

  -- -------------------------------------------------------------------------------
  -- 8d. Clearing the time takes the reminder with it.
  --
  -- The case the trigger's `when` clause cannot be written as `new.due_time is not null` for:
  -- guarded that way, the write that switches a commitment back to untimed never fires the
  -- trigger and its queued reminder goes out for a window that no longer exists. Nothing else in
  -- this file sets `due_time` to null, so nothing else catches that mutation.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Eye drops', 'do', 'daily', v_fix_due, 30)
  returning id into v_cleared;
  perform set_config('role', 'postgres', true);

  v_key := 'due-' || v_cleared::text || '-' || v_fix_day::text;

  select count(*) into v_count from public.outbox where dedupe_key = v_key;
  if v_count <> 1 then
    raise exception using message = format(
      'Expected one queued row at `%s` before clearing the time, found %s.', v_key, v_count);
  end if;

  perform set_config('role', 'authenticated', true);
  update public.commitment
     set due_time = null, late_window_minutes = null
   where id = v_cleared;
  perform set_config('role', 'postgres', true);

  select count(*) into v_count from public.outbox where dedupe_key = v_key;
  if v_count <> 0 then
    raise exception using message = format(
      'Clearing the time left %s queued row(s) at `%s`. The commitment is untimed now — the '
      'morning gate owns it, there is no window to announce, and the push would name one.',
      v_count, v_key);
  end if;

  raise notice using message =
    'Step 8d ok: switching a commitment back to untimed cancels its queued reminder.';

  -- -------------------------------------------------------------------------------
  -- 9. An archive cancels and does not re-offer.
  -- -------------------------------------------------------------------------------
  v_key := 'due-' || v_created::text || '-' || v_fix_day::text;

  perform set_config('role', 'authenticated', true);
  update public.commitment set archived_at = now() where id = v_created;
  perform set_config('role', 'postgres', true);

  select count(*) into v_count from public.outbox where dedupe_key = v_key;
  if v_count <> 0 then
    raise exception using message = format(
      'After an archive %s row(s) survive at `%s` — a push for a commitment the author has just '
      'deleted.', v_count, v_key);
  end if;

  raise notice using message = 'Step 9 ok: archiving takes the queued reminder with it.';

  -- -------------------------------------------------------------------------------
  -- 10. A due_time changed part-way through a day makes that day untimed, and the chokepoint
  --     refuses it — the copy would otherwise announce a cost the day cannot carry.
  --
  -- `p_now` is pinned a minute before the *new* window opens, so the lookahead admits it and the
  -- only possible reason for a refusal is `due_time_as_of()` returning null. Non-vacuous at every
  -- hour, and independent of which local date the file's own fixture resolved to.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Evening pill', 'do', 'daily', time '20:40', 30)
  returning id into v_moved;

  update public.commitment set due_time = time '22:00' where id = v_moved;

  perform set_config('role', 'postgres', true);

  if public.due_time_as_of(v_moved, v_today) is not null then
    raise exception using message =
      'due_time_as_of() still reports a governing time for a day whose due_time was written '
      'part-way through it. Story 6.4 froze the opposite; this file depends on it.';
  end if;

  v_instant := public.due_time_instant(v_today, time '22:00');
  v_ok := public.enqueue_due_time_reminder(v_moved, v_today, v_instant - interval '1 minute');
  if v_ok then
    raise exception using message =
      'A day judged untimed by due_time_as_of() was still reminded. That day falls back to the '
      'morning gate and cannot fail for a missing photo, so the push would name a cost the day '
      'will never incur.';
  end if;

  select count(*) into v_count from public.outbox
   where dedupe_key = 'due-' || v_moved::text || '-' || v_today::text;
  if v_count <> 0 then
    raise exception using message = format(
      'A commitment whose time moved mid-day holds %s queued row(s) for today.', v_count);
  end if;

  raise notice using message =
    'Step 10 ok: a time written part-way through a day is not reminded for that day, and the '
    'edit left nothing standing.';

  -- -------------------------------------------------------------------------------
  -- 11. A claim filed after the row was queued cancels it — and only the day it names.
  --
  -- The chokepoint already refuses a day carrying a declaration; deferral is what lets a row
  -- outlive that rule, and this is the commonest way it happens: he claims at 20:00 for a window
  -- that opens at 20:30. Cancelling both days would be wrong in both directions — a claim filed
  -- for today at 23:56 would delete a queued 00:10 reminder for tomorrow that nothing could
  -- re-queue in time.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Drops', 'do', 'daily', v_fix_due, 30)
  returning id into v_claim_cancel;
  perform set_config('role', 'postgres', true);

  -- The next day's row, queued through the chokepoint so both days are genuinely standing.
  v_instant := public.due_time_instant(v_fix_day + 1, v_fix_due);
  if not public.enqueue_due_time_reminder(v_claim_cancel, v_fix_day + 1, v_instant) then
    raise exception using message =
      'Could not queue the following day''s reminder, which this step needs standing to prove '
      'the declaration trigger leaves it alone.';
  end if;

  select count(*) into v_count from public.outbox
   where dedupe_key = 'due-' || v_claim_cancel::text || '-' || v_fix_day::text;
  if v_count <> 1 then
    raise exception using message = format(
      'Expected the fixture day''s reminder standing before the claim, found %s.', v_count);
  end if;

  perform set_config('role', 'authenticated', true);
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_a, v_claim_cancel, gen_random_uuid(), 'held', v_fix_at);
  perform set_config('role', 'postgres', true);

  select count(*) into v_count from public.outbox
   where dedupe_key = 'due-' || v_claim_cancel::text || '-' || v_fix_day::text;
  if v_count <> 0 then
    raise exception using message = format(
      'A claim filed for the day left %s queued reminder(s) for it. He has already answered; the '
      'push would arrive telling him to do what he has done.', v_count);
  end if;

  select count(*) into v_count from public.outbox
   where dedupe_key = 'due-' || v_claim_cancel::text || '-' || (v_fix_day + 1)::text;
  if v_count <> 1 then
    raise exception using message = format(
      'The claim also removed the *next* day''s reminder (%s row(s) left). A declaration cancels '
      'the day it names and no other — a claim filed late tonight must not cost him tomorrow''s '
      'window.', v_count);
  end if;

  raise notice using message =
    'Step 11 ok: a filed claim cancels its own day''s reminder and leaves the next day''s alone.';

  -- -------------------------------------------------------------------------------
  -- 12. Both halves of the cancel guard.
  --
  -- A row a live worker is holding is spared — it was claimed in step 4, and `outbox_claim()`
  -- leaves it `pending` with `not_before` a minute out. A row already `sent` is spared too:
  -- deleting it would free the dedupe key that enforces one reminder per commitment-day and
  -- destroy the record that the push went out.
  -- -------------------------------------------------------------------------------
  v_key := 'due-' || v_claimtest::text || '-' || v_fix_day::text;

  perform public.cancel_due_time_reminders(v_claimtest, v_fix_day);

  select count(*) into v_count from public.outbox where dedupe_key = v_key;
  if v_count <> 1 then
    raise exception using message =
      'The cancel deleted a row a live worker is holding. Its visibility timeout has not expired '
      '— the send may already be in flight — and the outbox would lose all record of it.';
  end if;

  v_key := 'due-' || v_quota::text || '-' || v_fix_day::text;
  update public.outbox set status = 'sent', sent_at = now() where dedupe_key = v_key;

  perform public.cancel_due_time_reminders(v_quota, v_fix_day);

  select count(*) into v_count from public.outbox where dedupe_key = v_key;
  if v_count <> 1 then
    raise exception using message =
      'The cancel deleted a row that had already been sent. That frees the dedupe key holding '
      'one reminder per commitment-day, and destroys the evidence the push went out.';
  end if;

  -- And it still reaches the row it is meant to: a plain pending, unheld one.
  v_key := 'due-' || v_daily::text || '-' || v_fix_day::text;
  perform public.cancel_due_time_reminders(v_daily, v_fix_day);

  select count(*) into v_count from public.outbox where dedupe_key = v_key;
  if v_count <> 0 then
    raise exception using message = format(
      'The cancel left %s pending, unheld row(s) standing. Guarded that tightly it cancels '
      'nothing at all.', v_count);
  end if;

  raise notice using message =
    'Step 12 ok: the cancel spares a held row and a sent one, and still takes a plain pending '
    'one.';

  -- -------------------------------------------------------------------------------
  -- 13. Every function on this path runs with its owner's rights.
  --
  -- Step 7 pins the two commitment trigger functions behaviourally, which is the mutation that
  -- actually escaped loop 3: written as `authenticated`, a commitment insert queues nothing
  -- without `security definer`, and the permission error disappears into the same handler that
  -- keeps this from ever failing the author's write.
  --
  -- The other three cannot be pinned that way, and saying why is better than leaving them
  -- unstated: every caller they have is itself `security definer`, so today they inherit
  -- `postgres` either way and the first caller that is not one would find them broken. Read from
  -- the catalog rather than from `pg_proc.prosrc` — an invariant stated, not a substring that
  -- any edit keeping the text would survive.
  -- -------------------------------------------------------------------------------
  foreach v_case in array array[
    'public.enqueue_due_time_reminder(uuid, date, timestamptz)',
    'public.offer_due_time_reminders(uuid, timestamptz)',
    'public.enqueue_due_time_reminders(timestamptz)',
    'public.cancel_due_time_reminders(uuid, date)',
    'public.commitment_due_time_written()',
    'public.declaration_cancels_due_time_reminder()'
  ]
  loop
    select p.prosecdef into v_ok from pg_proc p where p.oid = v_case::regprocedure;
    if not v_ok then
      raise exception using message = format(
        '`%s` is not `security definer`. It reads commitments across accounts and writes the '
        'outbox, neither of which any client role may do — and every failure on this path is '
        'swallowed by a handler that exists so a reminder can never fail the author''s own '
        'write, so it would go dead in silence.', v_case);
    end if;
  end loop;

  raise notice using message =
    'Step 13 ok: every function on this path is security definer.';

  raise notice using message =
    'PASS. A timed window is reminded at the instant it opens and never before; a claimed, '
    'untimed, archived or unsendable commitment is not; the author''s own writes queue and '
    'cancel their own rows; and a Silence episode does not suppress any of it.';
end $$;

-- ---------------------------------------------------------------------------------
-- The wiring between the pass and the clock.
--
-- Nothing else in this repo reads `cron.job`, so every other pipeline's schedule is prose. Here
-- it is the whole outcome of the story: dropping the `cron.schedule` call leaves `db reset` and
-- every other file green while no reminder is ever enqueued in production.
-- ---------------------------------------------------------------------------------
do $$
declare
  v_schedule text;
  v_command  text;
  v_active   boolean;
begin
  select schedule, command, active into v_schedule, v_command, v_active
    from cron.job where jobname = 'due-time-reminders';

  if v_schedule is null then
    raise exception using message =
      'No `due-time-reminders` job exists. Every function this story adds is unreachable without '
      'it, and the suite would still be green.';
  end if;

  if v_schedule <> '50 * * * *' then
    raise exception using message = format(
      'The job runs on `%s`. `:00 :05 :15 :25 :35 :45 :55` are taken; `:50` is the free minute, '
      'and moving it onto a taken one puts two passes on the same tick.', v_schedule);
  end if;

  -- Name and schedule alone are not the wiring. A job pointed at a different function, or one
  -- pointed at the right function and switched off, keeps both and delivers nothing.
  if v_command not like '%enqueue_due_time_reminders()%' then
    raise exception using message = format(
      'The job runs `%s`. Right name, right minute, wrong function — nothing would ever be '
      'enqueued and every other assertion in this file would still pass.', v_command);
  end if;

  if not v_active then
    raise exception using message =
      'The `due-time-reminders` job exists on the right minute with the right command and is '
      'deactivated. pg_cron simply skips it, silently, forever.';
  end if;

  raise notice using message =
    'Step 14 ok: `due-time-reminders` is active, hourly at `:50`, and calls the pass.';
end $$;

rollback;
