-- Story 3.0 — the hour a session may move, and the hour it may not.
--
-- The morning hour has been a real column since Story 2.4's migration: `not null default 7`,
-- range-checked, and carrying a column grant to `authenticated` that
-- `20260819201000_close_role_self_promotion.sql` made meaningful by revoking the table-wide UPDATE
-- sitting behind it. What it never had was a way in — no Settings surface existed, so the blocking
-- morning question arrived at 07:00 for everyone and the grant was never exercised by anything but
-- a retrospective's check file.
--
-- This drives the write that surface makes, and the two ways it must fail:
--
--   * the hour is written to the author's own row and read back by everything that decides when he
--     is asked — the gate, its reminders, and the expiry deadline, which all read one column;
--   * an hour outside 0-23 is refused by the database rather than clamped, because a silently
--     clamped hour is a blocking question arriving at a time he did not choose;
--   * and the same statement still cannot touch `role`, which is the escalation that shipped once.
--
-- The last one is asserted here as well as in `2-1-roles-and-rls.sql` on purpose: this is the story
-- that gives a client a reason to write to `profile` at all, so it is the story that would make a
-- widened grant look reasonable.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/3-0-morning-hour.sql
--
-- One transaction, rolled back at the end. It settles a day, so it needs a database with no live
-- doer account — see supabase/tests/2-7-supersession.sql for that note at length.

begin;

-- The environment's grant, stated rather than assumed, for the reason `2-1-roles-and-rls.sql`
-- gives: on a local stack `authenticated` has SELECT on nothing, and no migration in this
-- repository creates that grant (recorded in deferred-work.md). UPDATE is never granted here —
-- the column grant from the migration is the thing under test.
grant select on table public.profile to authenticated;

do $$
declare
  v_user      uuid := gen_random_uuid();
  v_commit    uuid;
  v_day       date;
  v_hour      integer;
  v_deadline  timestamptz;
  v_after     timestamptz;
  v_role      public.app_role;
  v_refused   boolean;
begin
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day refuses every override '
      '(AD-16). Run against a local or branch database instead.';
  end if;

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_user, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          'retro-3-0-' || v_user::text || '@example.test',
          'not-a-real-password-this-account-never-signs-in',
          now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  select morning_hour into v_hour from public.profile where id = v_user;
  if v_hour <> 7 then
    raise exception using message = format(
      'A new account starts at %s rather than 07:00.', v_hour);
  end if;

  -- -------------------------------------------------------------------------------
  -- 1. A session moves its own hour, through the column grant and nothing else.
  -- -------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated', 'app_role', 'doer')::text, true);
  perform set_config('role', 'authenticated', true);

  update public.profile set morning_hour = 9 where id = v_user;

  -- The same statement, widened by one column, is the escalation that shipped once and was
  -- closed in 20260819201000. This story is the reason a client writes to `profile` at all, so
  -- it is the story that would make a broader grant look reasonable.
  v_refused := false;
  begin
    update public.profile set morning_hour = 9, role = 'referee' where id = v_user;
  exception when insufficient_privilege then
    v_refused := true;
  end;

  perform set_config('role', 'postgres', true);

  select morning_hour, role into v_hour, v_role from public.profile where id = v_user;

  if v_hour <> 9 then
    raise exception using message = format(
      'The hour reads %s after a session set it to 9. The column grant is what makes the '
      'Settings surface possible at all.', v_hour);
  end if;

  if not v_refused or v_role <> 'doer' then
    raise exception using message = format(
      'A session set its own role while setting its morning hour — the profile now reads '
      '`%s`. A grant widened for this story would reopen AD-12 exactly here.', v_role);
  end if;

  raise notice using message = 'Step 1 ok: the hour moved to 09:00 and the role did not move at all.';

  -- -------------------------------------------------------------------------------
  -- 2. An hour that is not an hour is refused, not clamped.
  -- -------------------------------------------------------------------------------
  foreach v_hour in array array[24, -1]
  loop
    v_refused := false;
    begin
      update public.profile set morning_hour = v_hour where id = v_user;
    exception when check_violation then
      v_refused := true;
    end;

    if not v_refused then
      raise exception using message = format(
        'The database accepted %s as a morning hour. Clamping it silently would mean the '
        'blocking question arrives at a time he did not choose, and never says so.', v_hour);
    end if;
  end loop;

  select morning_hour into v_hour from public.profile where id = v_user;
  if v_hour <> 9 then
    raise exception using message = format(
      'A refused write left the hour at %s. Nothing partial may survive.', v_hour);
  end if;

  raise notice using message = 'Step 2 ok: 24 and -1 are both refused, and 09:00 still stands.';

  -- -------------------------------------------------------------------------------
  -- 3. Moving the hour moves the deadline with it — forward, never backward over a day
  --    that has already been judged.
  --
  -- `declaration_deadline` and `enqueue_gate_reminders` both read this one column, so the
  -- question, its reminders and the 48-hour expiry cannot come apart. What must not happen is
  -- a settled day being re-judged against a deadline it was never closed under (AD-5).
  -- -------------------------------------------------------------------------------
  v_day := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 5;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true)
  returning id into v_commit;

  v_deadline := public.declaration_deadline(v_day, 9);

  -- The day closes on the clock, unanswered, under the 09:00 deadline.
  -- Story 6.4: commitments_owing() no longer judges a commitment for a day before it existed.
  -- This fixture creates its commitments moments before judging days that predate them, which is
  -- a state no real account can reach — so it now says when they began. Order-preserving, so
  -- every created_at comparison downstream reads the same way, and idempotent, so a second call
  -- further down this file does not age them twice.
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_day, true);

  if not exists (
    select 1 from public.settlement_current
     where subject = v_user and period = v_day and verdict = 'expired'
  ) then
    raise exception using message = 'Fixture is wrong: the day did not expire.';
  end if;

  -- Now he moves the hour later. The deadline for a *future* day moves with it.
  update public.profile set morning_hour = 20 where id = v_user;
  v_after := public.declaration_deadline(v_day, 20);

  if v_after <= v_deadline then
    raise exception using message = format(
      'Moving the morning hour from 09:00 to 20:00 did not move the deadline: %s then %s. '
      'The gate, its reminders and the expiry all read this column, and they move together '
      'or they disagree about which day is still answerable.', v_deadline, v_after);
  end if;

  -- And the settled day is untouched by any of it.
  perform public.settle_day(v_day, true);

  if (select count(*) from public.settlement_current
       where subject = v_user and period = v_day) <> 1 then
    raise exception using message =
      'The settled day was judged a second time after the hour changed. A verdict is frozen '
      'against the deadline it closed under (AD-5); re-judging it would let the author move '
      'his own past by changing a setting.';
  end if;

  raise notice using message =
    'Step 3 ok: the deadline follows the hour, and the day already closed does not.';

  raise notice using message =
    'PASS. The hour is the author''s to move, the database still decides what an hour is, and '
    'moving it never rewrites a day that has already been judged.';
end $$;

rollback;
