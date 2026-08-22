-- Story 3.1 — where a session's minutes land, and the four things a session may not be.
--
-- The whole design of the focus timer is that nothing runs. A session is a start instant and a
-- stop instant, written as one row when he stops, and every number that matters is derived from
-- those two instants by the database (AD-1). That moves the entire risk of the story into this
-- file: if the day is derived wrong, or the flooring happens in the wrong place, or the trigger
-- lets a session point at the wrong commitment, nothing on the screen would say so — a wrong
-- total still looks like a number.
--
-- The four rules under test, in the order they can bite:
--
--   * a session belongs wholly to the day it *started* (AD-14), so 23:50 → 00:20 is thirty
--     minutes on the start day and is never split. Under a flat penalty that is the difference
--     between a Failed Day and a clean one;
--   * minutes are floored **once, at the day** — flooring per session would let three
--     twenty-minute sittings bank 59 minutes of an hour;
--   * a session may only be banked against a Put hours in commitment the same account owns;
--   * and a stop that does not follow its start is refused rather than clamped.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/3-1-focus-session.sql
--
-- One transaction, rolled back at the end. It settles nothing, but it carries the live-doer
-- guard anyway: this is the first file that writes *observations* rather than fixtures for a
-- decision, and an observation written into the author's own project would be minutes he did
-- not work, sitting in a total the product asks him to trust.

begin;

-- The environment's grants, stated rather than assumed, for the reason `2-1-roles-and-rls.sql`
-- gives at length: on a local stack `authenticated` has SELECT on nothing, and no migration in
-- this repository creates those grants (recorded in deferred-work.md). SELECT and INSERT only —
-- there is no update or delete policy to test, because there is deliberately none to have.
grant select on table public.profile to authenticated;
grant select, insert on table public.focus_session to authenticated;
grant select on table public.focus_day_minutes to authenticated;

do $$
declare
  v_user     uuid := gen_random_uuid();   -- the author
  v_other    uuid := gen_random_uuid();   -- somebody else with an account
  v_hours    uuid;                        -- his Put hours in commitment
  v_daily    uuid;                        -- an ordinary daily commitment of his
  v_foreign  uuid;                        -- an hours quota belonging to the other account
  v_day      date;
  v_for_day  date;
  v_minutes  integer;
  v_seconds  bigint;
  v_count    integer;
  v_refused  boolean;
  v_message  text;
  v_offset   interval;
begin
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so a focus session written here would be minutes '
      'he did not work. Run against a local or branch database instead.';
  end if;

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'retro-3-1-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_user, v_other]) as t(id);

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 daily_minutes_target)
  values (v_user, gen_random_uuid(), 'Company work', 'open_ended', 'daily_hours_quota', 180)
  returning id into v_hours;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence)
  values (v_user, gen_random_uuid(), 'TryHackMe', 'do', 'daily')
  returning id into v_daily;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 daily_minutes_target)
  values (v_other, gen_random_uuid(), 'Somebody else''s hours', 'open_ended',
          'daily_hours_quota', 60)
  returning id into v_foreign;

  -- A day far enough back that nothing else in a shared fixture collides with it, and stated as
  -- a local date so the instants below can be written as local wall-clock times.
  v_day := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 10;

  -- -------------------------------------------------------------------------------
  -- 1. A session lands wholly on the day it started (AD-14).
  --
  -- 23:50 to 00:20. Thirty minutes, on the start day, never split. The client sends two
  -- instants and no date at all; this is the whole of AD-6 in one row.
  -- -------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated', 'app_role', 'doer')::text, true);
  perform set_config('role', 'authenticated', true);

  insert into public.focus_session (owner_id, commitment_id, idempotency_key,
                                    started_at, stopped_at)
  values (v_user, v_hours, gen_random_uuid(),
          (v_day + time '23:50') at time zone 'Asia/Ho_Chi_Minh',
          (v_day + 1 + time '00:20') at time zone 'Asia/Ho_Chi_Minh');

  perform set_config('role', 'postgres', true);

  select f.for_day, f.duration_seconds
    into v_for_day, v_seconds
    from public.focus_session f
   where f.commitment_id = v_hours;

  if v_for_day <> v_day then
    raise exception using message = format(
      'A session from 23:50 to 00:20 landed on %s rather than on %s, the day it started. '
      'AD-14 puts an event wholly on the day containing its start instant, and under a flat '
      'penalty splitting it is the difference between a Failed Day and a clean one.',
      v_for_day, v_day);
  end if;

  if v_seconds <> 1800 then
    raise exception using message = format(
      'The session measured %s seconds rather than 1800. The duration is the database''s to '
      'compute (AD-1); a client that could send it could send anything.', v_seconds);
  end if;

  raise notice using message =
    'Step 1 ok: thirty minutes across midnight, wholly on the day it started.';

  -- -------------------------------------------------------------------------------
  -- 2. Minutes are floored once, at the day — never per session.
  --
  -- Three sittings of 20:20, 20:20 and 20:20 are 61 minutes exactly. Floored per session they
  -- would bank 60 and quietly lose a minute; floored per day they bank 61. The day's total is
  -- what the quota is judged against, so it is the number that has to be right.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);

  insert into public.focus_session (owner_id, commitment_id, idempotency_key,
                                    started_at, stopped_at)
  select v_user, v_hours, gen_random_uuid(),
         (v_day + 1 + make_interval(hours => h)) at time zone 'Asia/Ho_Chi_Minh',
         (v_day + 1 + make_interval(hours => h, mins => 20, secs => 20))
           at time zone 'Asia/Ho_Chi_Minh'
    from unnest(array[9, 11, 14]) as t(h);

  select m.minutes, m.seconds
    into v_minutes, v_seconds
    from public.focus_day_minutes m
   where m.commitment_id = v_hours and m.for_day = v_day + 1;

  perform set_config('role', 'postgres', true);

  if v_seconds <> 3660 then
    raise exception using message = format(
      'The day summed to %s seconds rather than 3660.', v_seconds);
  end if;

  if v_minutes <> 61 then
    raise exception using message = format(
      'Three sittings of 20 minutes 20 seconds banked %s minutes rather than 61. Flooring each '
      'session instead of the day discards up to 59 seconds a session, silently.', v_minutes);
  end if;

  -- And the midnight session is on its own day, not folded into this one.
  select m.minutes into v_minutes
    from public.focus_day_minutes m
   where m.commitment_id = v_hours and m.for_day = v_day;

  if v_minutes <> 30 then
    raise exception using message = format(
      'The start day reads %s minutes rather than 30. Two days'' sessions have run together.',
      v_minutes);
  end if;

  raise notice using message =
    'Step 2 ok: 20:20 three times is 61 minutes, and the days stay apart.';

  -- -------------------------------------------------------------------------------
  -- 3. A session may only be banked against a Put hours in commitment.
  --
  -- A daily commitment is settled by his word each morning. Minutes banked against it would be
  -- a second, softer record of a thing the declaration already answers — and the two could
  -- disagree, which is the failure this product can least afford.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);

  v_refused := false;
  begin
    insert into public.focus_session (owner_id, commitment_id, idempotency_key,
                                      started_at, stopped_at)
    values (v_user, v_daily, gen_random_uuid(),
            (v_day + time '09:00') at time zone 'Asia/Ho_Chi_Minh',
            (v_day + time '09:30') at time zone 'Asia/Ho_Chi_Minh');
  exception when raise_exception then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused then
    raise exception using message =
      'A focus session was banked against a daily commitment. FR-2 settles that one on his '
      'word, and a second measurement of it is a second answer that can disagree.';
  end if;

  if v_message not like '%daily%' then
    raise exception using message = format(
      'The refusal did not name the cadence it refused: "%s". A message that does not say what '
      'was wrong is a message the screen cannot pass on.', v_message);
  end if;

  raise notice using message =
    'Step 3 ok: a daily commitment is refused, and the refusal names the cadence.';

  -- -------------------------------------------------------------------------------
  -- 4. And only against a commitment the same account owns.
  --
  -- The insert policy constrains `owner_id` and nothing else, so RLS alone would accept a row
  -- owned by the caller that points at somebody else's commitment — banking his minutes into
  -- another account's day.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);

  v_refused := false;
  begin
    insert into public.focus_session (owner_id, commitment_id, idempotency_key,
                                      started_at, stopped_at)
    values (v_user, v_foreign, gen_random_uuid(),
            (v_day + time '09:00') at time zone 'Asia/Ho_Chi_Minh',
            (v_day + time '09:30') at time zone 'Asia/Ho_Chi_Minh');
  exception when raise_exception then
    v_refused := true;
  end;

  -- The mirror image: writing into the other account outright, which the policy refuses.
  v_count := 0;
  begin
    insert into public.focus_session (owner_id, commitment_id, idempotency_key,
                                      started_at, stopped_at)
    values (v_other, v_foreign, gen_random_uuid(),
            (v_day + time '09:00') at time zone 'Asia/Ho_Chi_Minh',
            (v_day + time '09:30') at time zone 'Asia/Ho_Chi_Minh');
  exception when insufficient_privilege then
    v_count := 1;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused then
    raise exception using message =
      'A session owned by one account was banked against another account''s commitment. The '
      'trigger is the only thing checking that, because the insert policy only sees owner_id.';
  end if;

  if v_count <> 1 then
    raise exception using message =
      'A session was inserted into another account outright. `with check` on the insert policy '
      'is the only thing standing between two accounts.';
  end if;

  raise notice using message = 'Step 4 ok: neither cross-account route is open.';

  -- -------------------------------------------------------------------------------
  -- 5. A stop that does not follow its start is refused, not clamped.
  --
  -- The device's clock is the only clock this story has. When it moves backwards mid-session
  -- the honest answer is a refusal the screen can show, not a zero-length session recorded as
  -- though it happened — spec 3-0 D1 settled that a value the database quietly changes is
  -- worse than one it refuses.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);

  -- Its own variable. `v_message` still holds the `sqlerrm` step 3 captured, and a loop that
  -- reuses it would be asserting against whatever the last refusal happened to say.
  foreach v_offset in array array[interval '00:30', interval '00:00']
  loop
    v_refused := false;
    begin
      insert into public.focus_session (owner_id, commitment_id, idempotency_key,
                                        started_at, stopped_at)
      values (v_user, v_hours, gen_random_uuid(),
              (v_day + time '09:00') at time zone 'Asia/Ho_Chi_Minh',
              (v_day + time '09:00' - v_offset) at time zone 'Asia/Ho_Chi_Minh');
    exception when check_violation then
      v_refused := true;
    end;

    if not v_refused then
      raise exception using message = format(
        'A session that stopped %s before it started was accepted.', v_offset);
    end if;
  end loop;

  perform set_config('role', 'postgres', true);

  raise notice using message =
    'Step 5 ok: a backwards clock and a zero-length session are both refused.';

  -- -------------------------------------------------------------------------------
  -- 6. The same key twice is one session.
  --
  -- AD-4: the key is minted when *start* is tapped and reused by every retry. A stop banked
  -- without a network and flushed twice must produce one row, and the second attempt must be a
  -- unique violation the client can recognise as success arriving out of order — 23505, which
  -- `lib/declaration-submit.ts` classifies as `duplicate`.
  -- -------------------------------------------------------------------------------
  declare
    v_key uuid := gen_random_uuid();
    v_state text;
  begin
    perform set_config('role', 'authenticated', true);

    insert into public.focus_session (owner_id, commitment_id, idempotency_key,
                                      started_at, stopped_at)
    values (v_user, v_hours, v_key,
            (v_day + 2 + time '09:00') at time zone 'Asia/Ho_Chi_Minh',
            (v_day + 2 + time '09:50') at time zone 'Asia/Ho_Chi_Minh');

    v_state := '';
    begin
      insert into public.focus_session (owner_id, commitment_id, idempotency_key,
                                        started_at, stopped_at)
      values (v_user, v_hours, v_key,
              (v_day + 2 + time '09:00') at time zone 'Asia/Ho_Chi_Minh',
              (v_day + 2 + time '09:50') at time zone 'Asia/Ho_Chi_Minh');
    exception when unique_violation then
      v_state := sqlstate;
    end;

    perform set_config('role', 'postgres', true);

    if v_state <> '23505' then
      raise exception using message = format(
        'A replayed flush produced sqlstate "%s" rather than 23505. The client reads that code '
        'to tell an already-delivered session from a failure, and retries anything else.',
        v_state);
    end if;

    select count(*) into v_count
      from public.focus_session f where f.idempotency_key = v_key;

    if v_count <> 1 then
      raise exception using message = format(
        'Flushing the same key twice produced %s sessions.', v_count);
    end if;
  end;

  raise notice using message = 'Step 6 ok: the same key twice is one session.';

  -- -------------------------------------------------------------------------------
  -- 7. One account never reads another's sessions.
  --
  -- Filtered to zero rows rather than refused, for the reason `2-1-roles-and-rls.sql` gives: a
  -- refusal confirms the row is there.
  -- -------------------------------------------------------------------------------
  insert into public.focus_session (owner_id, commitment_id, idempotency_key,
                                    started_at, stopped_at)
  values (v_other, v_foreign, gen_random_uuid(),
          (v_day + time '09:00') at time zone 'Asia/Ho_Chi_Minh',
          (v_day + time '10:00') at time zone 'Asia/Ho_Chi_Minh');

  perform set_config('role', 'authenticated', true);
  select count(*) into v_count from public.focus_session f where f.owner_id = v_other;
  select count(*) into v_minutes from public.focus_day_minutes m where m.owner_id = v_other;
  perform set_config('role', 'postgres', true);

  if v_count <> 0 or v_minutes <> 0 then
    raise exception using message = format(
      'A session read %s of another account''s sessions and %s of its daily totals. '
      '`focus_day_minutes` is `security_invoker` precisely so it cannot become the way around '
      'the policy on the table beneath it.', v_count, v_minutes);
  end if;

  raise notice using message =
    'Step 7 ok: another account''s sessions and totals are both invisible.';

  -- -------------------------------------------------------------------------------
  -- 8. The schema enforces AD-1 and AD-6, not merely the client that happens to write.
  --
  -- Every other step here drives the same path the app drives. This one drives the path the app
  -- deliberately does *not*: a caller that sends a day of its own, and one that sends a duration
  -- of its own. Both are one line away in any future client, and the reason they are refused has
  -- to live in the database — a rule kept only by the component that currently exists is a rule
  -- that lasts until the next component.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);

  -- A client-sent day is overwritten rather than honoured. The trigger runs `before insert` and
  -- assigns unconditionally, so what arrives is irrelevant.
  insert into public.focus_session (owner_id, commitment_id, idempotency_key,
                                    started_at, stopped_at, for_day)
  values (v_user, v_hours, gen_random_uuid(),
          (v_day + 3 + time '09:00') at time zone 'Asia/Ho_Chi_Minh',
          (v_day + 3 + time '09:30') at time zone 'Asia/Ho_Chi_Minh',
          v_day - 400);

  v_refused := false;
  begin
    insert into public.focus_session (owner_id, commitment_id, idempotency_key,
                                      started_at, stopped_at, duration_seconds)
    values (v_user, v_hours, gen_random_uuid(),
            (v_day + 4 + time '09:00') at time zone 'Asia/Ho_Chi_Minh',
            (v_day + 4 + time '09:30') at time zone 'Asia/Ho_Chi_Minh',
            99999);
  exception when generated_always then
    v_refused := true;
  end;

  perform set_config('role', 'postgres', true);

  select f.for_day into v_for_day
    from public.focus_session f
   where f.started_at = (v_day + 3 + time '09:00') at time zone 'Asia/Ho_Chi_Minh';

  if v_for_day <> v_day + 3 then
    raise exception using message = format(
      'A client sent for_day and the database kept it: the row reads %s. AD-6 gives the server '
      'that job, and a client that can choose the day can move minutes onto a day it likes '
      'better.', v_for_day);
  end if;

  if not v_refused then
    raise exception using message =
      'A client sent duration_seconds and was not refused. The length of a session is derived '
      'from its two instants (AD-1); a client that can send it can bank three hours it did not '
      'work without the instants ever disagreeing.';
  end if;

  raise notice using message =
    'Step 8 ok: a sent day is overwritten and a sent duration is refused.';

  raise notice using message =
    'PASS. A session lands on the day it started, the day floors its own minutes exactly once, '
    'and nothing may bank time against a commitment it does not own or a cadence that is '
    'settled by his word.';
end $$;

rollback;
