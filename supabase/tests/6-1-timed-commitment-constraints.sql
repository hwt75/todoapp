-- Story 6.1 — what a time of day on a commitment may be.
--
-- Five constraints ship in 20260828130000_a_commitment_can_carry_a_time.sql and `npm test`
-- can execute none of them: `lib/commitment.test.ts` exercises a mirror written in TypeScript,
-- which is exactly the arrangement the Epic 2 retrospective found could pass while the SQL was
-- wrong. This file drives each one from the database side.
--
-- The case worth reading twice is step 2. `commitment_window_within_the_day` is written on
-- extracted minutes rather than as `due_time + make_interval(mins => late_window_minutes)`,
-- because Postgres time arithmetic wraps: `time '23:30' + interval '60 minutes'` is `00:30`,
-- and a constraint written the obvious way would accept exactly the case it exists to refuse.
-- Both sides of the boundary are asserted so a future rewrite cannot quietly reintroduce it.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/6-1-timed-commitment-constraints.sql
--
-- One transaction, rolled back at the end. It settles nothing and is safe against any database.

begin;

do $$
declare
  v_user    uuid := gen_random_uuid();
  v_id      uuid;
  v_untimed uuid;
  v_count   integer;
  v_refused boolean;
  v_case    text;
  v_due     time;
  v_window  integer;
  v_kind    public.commitment_kind;
  v_cadence public.commitment_cadence;
  v_minutes integer;
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_user, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          'story-6-1-' || v_user::text || '@example.test',
          'not-a-real-password-this-account-never-signs-in',
          now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  -- -------------------------------------------------------------------------------
  -- 1. What the database accepts.
  --
  -- Including the boundary: 23:30 with a thirty-minute window ends at exactly 1440. The
  -- window is half-open, so its last valid instant is 23:59:59.999 and it is still inside
  -- its own day. `< 1440` here would refuse a legitimate commitment.
  -- -------------------------------------------------------------------------------
  foreach v_case in array array[
    'no time at all',
    'an ordinary evening',
    'the shortest window',
    'the longest window',
    'a window ending at exactly midnight',
    'on a weekly quota'
  ]
  loop
    v_due := case v_case
               when 'no time at all' then null
               when 'the shortest window' then time '06:00'
               when 'the longest window' then time '06:00'
               when 'a window ending at exactly midnight' then time '23:30'
               else time '20:00'
             end;
    v_window := case v_case
                  when 'no time at all' then null
                  when 'the shortest window' then 5
                  when 'the longest window' then 240
                  else 30
                end;

    insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                   weekly_target, week_start_day,
                                   due_time, late_window_minutes)
    values (v_user, gen_random_uuid(), 'Pill', 'do',
            (case v_case when 'on a weekly quota' then 'weekly_quota' else 'daily' end)
              ::public.commitment_cadence,
            case v_case when 'on a weekly quota' then 3 end,
            case v_case when 'on a weekly quota' then 1 end,
            v_due, v_window)
    returning id into v_id;

    if v_id is null then
      raise exception using message = format(
        'The database did not store a commitment described as "%s".', v_case);
    end if;

    if v_case = 'no time at all' then
      v_untimed := v_id;
    end if;
  end loop;

  raise notice using message =
    'Step 1 ok: six well-formed commitments accepted, including a window ending at 1440.';

  -- -------------------------------------------------------------------------------
  -- 2. What the database refuses.
  --
  -- 'one minute past midnight' is the case a wrapping interval would let through: 23:30
  -- plus 31 minutes is 00:01 the next day, and `due_time + interval` would report 00:01 as
  -- less than 24:00 and pass.
  -- -------------------------------------------------------------------------------
  foreach v_case in array array[
    'a time with no window',
    'a window with no time',
    'a window of zero',
    'a window below the floor',
    'a window above the ceiling',
    'an hour past midnight',
    'one minute past midnight',
    'a time with seconds in it',
    'a time on an abstention',
    'a time on an hours quota'
  ]
  loop
    v_kind := case v_case when 'a time on an abstention' then 'abstain' else 'do' end;
    v_cadence := case v_case
                   when 'a time on an hours quota' then 'daily_hours_quota'
                   else 'daily'
                 end;
    v_minutes := case v_case when 'a time on an hours quota' then 180 end;
    v_due := case v_case
               when 'a window with no time' then null
               when 'an hour past midnight' then time '23:30'
               when 'one minute past midnight' then time '23:30'
               when 'a time with seconds in it' then time '20:00:30'
               else time '20:00'
             end;
    v_window := case v_case
                  when 'a time with no window' then null
                  when 'a window of zero' then 0
                  when 'a window below the floor' then 4
                  when 'a window above the ceiling' then 241
                  when 'an hour past midnight' then 60
                  when 'one minute past midnight' then 31
                  else 30
                end;

    v_refused := false;
    begin
      insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                     daily_minutes_target, due_time, late_window_minutes)
      values (v_user, gen_random_uuid(), 'Pill', v_kind, v_cadence,
              v_minutes, v_due, v_window);
    exception when check_violation then
      v_refused := true;
    end;

    if not v_refused then
      raise exception using message = format(
        'The database accepted a commitment described as "%s". Which times are valid is a '
        'constraint, not a thing the form is trusted to remember.', v_case);
    end if;
  end loop;

  raise notice using message =
    'Step 2 ok: ten malformed times were all refused, including 23:30 + 31 minutes -- the '
    'case a wrapping `time + interval` would have accepted.';

  -- -------------------------------------------------------------------------------
  -- 3. An untimed commitment is untouched by this migration.
  --
  -- Nothing backfilled a default into the new columns. A commitment created before Story 6.1
  -- and one created without a time now must be indistinguishable, or every existing row
  -- silently acquired a deadline its author never set.
  -- -------------------------------------------------------------------------------
  select count(*) into v_count
    from public.commitment
   where id = v_untimed
     and due_time is null
     and late_window_minutes is null;
  if v_count <> 1 then
    raise exception using message =
      'A commitment saved without a time came back carrying one. Nothing may backfill a '
      'default into these columns: every row that predates this migration would silently '
      'acquire a deadline its author never set.';
  end if;

  raise notice using message =
    'Step 3 ok: an untimed commitment stays untimed, with both columns null.';
  raise notice using message =
    'PASS. A time and its window arrive together, stay inside their own day, and only land '
    'on a commitment that has a moment to name.';
end $$;

rollback;
