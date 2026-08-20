-- Story 2.4a — the outbox refuses a sentence that cannot be read late.
--
-- Story 1.2 paid for the rule: a push arrived minutes late after the phone rejoined Wi-Fi.
-- Late, not lost — but it means a body is read at a time the sender cannot know, so it must
-- never describe the present, and it must date itself well enough that a copy left on the
-- lock screen can be told from a new one.
--
-- The rule was written in `lib/outbox.ts` and **nothing ever called it**: bodies are built in
-- SQL and the only database guard was `payload ? 'sent_at'`, which checks that a key exists
-- and says nothing about what the sentence claims (Epic 2 retrospective, A7/T3). It now lives
-- in `public.push_body_is_sendable` as a check constraint on the outbox
-- (`20260820101000_outbox_body_rule_where_it_runs.sql`), which is the only place it can
-- refuse anything.
--
-- A rule that refuses is only worth having if it refuses the wrong thing and passes the right
-- one, so this file asserts both halves — and the right one is not a literal typed here but
-- the output of the functions that actually build the bodies.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/2-4a-outbox-body-rule.sql
--
-- One transaction, rolled back at the end.

begin;

do $$
declare
  v_user       uuid := gen_random_uuid();
  v_commitment uuid;
  v_body       text;
  v_hour       integer;
  v_queued     integer;
  v_count      integer;
  v_refused    boolean;
begin
  -- -------------------------------------------------------------------------------
  -- 1. What the rule refuses.
  -- -------------------------------------------------------------------------------
  if public.push_body_is_sendable('') then
    raise exception using message = 'An empty body is sendable, and it should not be.';
  end if;

  if public.push_body_is_sendable(null) then
    raise exception using message =
      'A missing body reads as sendable. `payload ->> ''body''` is null when the key is '
      'absent, so null has to fail or the constraint passes everything shaped wrongly.';
  end if;

  if public.push_body_is_sendable('You have not answered yet right now.') then
    raise exception using message =
      'A body saying "right now" is sendable. By the time it is read, now may be a '
      'different day — the exact failure Story 1.2 observed.';
  end if;

  if public.push_body_is_sendable('Yesterday is still unanswered.') then
    raise exception using message =
      'A body carrying neither a time nor a named day is sendable, so a notification left '
      'on the lock screen cannot be told from a new one.';
  end if;

  raise notice using message =
    'Step 1 ok: empty, absent, present-tense and undated bodies are all refused.';

  -- -------------------------------------------------------------------------------
  -- 2. What it must not refuse — asked of the function that writes the sentence,
  --    not of a literal copied into this file.
  -- -------------------------------------------------------------------------------
  v_body := public.day_summary_body(4, 5, date '2026-08-18', 500000::bigint,
                                    'TryHackMe', 'No fap', 12);

  if not public.push_body_is_sendable(v_body) then
    raise exception using message = format(
      'The evening summary is refused by the rule guarding the queue it goes into: "%s". '
      'One of the two is wrong and the message is the one the author reads.', v_body);
  end if;

  raise notice using message = format('Step 2 ok: the summary passes — "%s"', v_body);

  -- -------------------------------------------------------------------------------
  -- 3. The constraint, not just the function. A body that describes the present must be
  --    unable to reach the queue at all, through the door everything actually uses.
  -- -------------------------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_user, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          'retro-2-4a-' || v_user::text || '@example.test',
          'not-a-real-password-this-account-never-signs-in',
          now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  v_refused := false;
  begin
    perform public.outbox_enqueue(
      v_user, 'body-rule-' || v_user::text,
      jsonb_build_object(
        'title', 'Yesterday',
        'body', 'Two commitments are unanswered currently.',
        'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')));
  exception when check_violation then
    v_refused := true;
  end;

  if not v_refused then
    raise exception using message =
      'outbox_enqueue accepted a body describing the present. The constraint is on the '
      'table the function inserts into, so this is the enqueue path itself failing open.';
  end if;

  raise notice using message =
    'Step 3 ok: outbox_enqueue refuses a present-tense body with a check violation.';

  -- -------------------------------------------------------------------------------
  -- 4. And the real morning-gate path still gets through.
  --
  -- The risk of adding a guard late is that it refuses something the product already
  -- sends — quietly, inside a cron run at 07:30, where nobody is watching. So the gate is
  -- driven for real: the account's morning hour is set to this hour, which puts it in slot
  -- 0, and `enqueue_gate_reminders` builds its own body the way it does every morning.
  -- -------------------------------------------------------------------------------
  v_hour := extract(hour from now() at time zone 'Asia/Ho_Chi_Minh')::integer;
  update public.profile set morning_hour = v_hour, role = 'doer' where id = v_user;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty)
  values (v_user, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true)
  returning id into v_commitment;

  v_queued := public.enqueue_gate_reminders();

  select count(*) into v_count from public.outbox where owner_id = v_user;
  if v_count <> 1 then
    raise exception using message = format(
      'The gate queued %s reminders for this account, expected 1. If the constraint '
      'refused the body, the morning question stops being asked at all.', v_count);
  end if;

  select payload ->> 'body' into v_body from public.outbox where owner_id = v_user;
  raise notice using message = format(
    'Step 4 ok: the gate queued its reminder (%s across all accounts) — "%s"',
    v_queued, v_body);

  raise notice using message =
    'PASS. The body rule refuses what it was written to refuse and passes both sentences '
    'the product actually sends.';
end $$;

rollback;
