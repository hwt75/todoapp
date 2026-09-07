-- Story 6.2 — which day a declaration belongs to.
--
-- `declaration_derive_day()` decides that for **every** declaration in the product, timed or
-- not, and it cannot fail visibly: a wrong branch writes a `for_day` off by one, the row looks
-- entirely normal, and every reader downstream -- settlement, chains, penalties, the ledger --
-- is wrong about a day it will never be told about. That is why this file exists and why it
-- asserts the untimed derivation as hard as the new one.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/6-2-a-claim-lands-on-the-day-it-was-made.sql
--
-- One transaction, rolled back at the end. It settles nothing and is safe against any
-- database.
--
-- The window checks run as `authenticated`, not as `postgres`, on purpose: the rule applies
-- only to a client-originated statement, and running these as the superuser would exercise
-- the machine branch while appearing to exercise the doer's.

begin;

grant select on table public.profile, public.commitment, public.declaration to authenticated;
grant insert on table public.declaration to authenticated;

do $$
declare
  v_a         uuid := gen_random_uuid();
  v_b         uuid := gen_random_uuid();
  v_untimed   uuid;
  v_timed     uuid;
  v_theirs    uuid;
  v_day       date := date '2026-08-10';
  v_for_day   date;
  v_filed_by  public.declaration_filed_by;
  v_refused   boolean;
  v_case      text;
  v_at        timestamptz;
  -- Story 6.2, reopened by Epic 6 retrospective item 38: a queued claim is flushed long after
  -- the tap, so every value that judges it has to be the one that was in force at the tap.
  v_cleared   uuid;
  v_midday    uuid;
  v_widened   uuid;
  v_unlogged  uuid;
  v_today     date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_message   text;
begin
  foreach v_case in array array['a', 'b']
  loop
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data)
    values (case v_case when 'a' then v_a else v_b end,
            '00000000-0000-0000-0000-000000000000',
            'authenticated', 'authenticated',
            'story-6-2-' || v_case || '-' || gen_random_uuid()::text || '@example.test',
            'not-a-real-password-this-account-never-signs-in',
            now(), now(), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);
  end loop;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence)
  values (v_a, gen_random_uuid(), 'Gym', 'do', 'daily')
  returning id into v_untimed;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Pill', 'do', 'daily', time '20:00', 30)
  returning id into v_timed;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_b, gen_random_uuid(), 'Their pill', 'do', 'daily', time '20:00', 30)
  returning id into v_theirs;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a, 'role', 'authenticated')::text, true);

  -- -------------------------------------------------------------------------------
  -- 1. An untimed commitment still answers for yesterday.
  --
  -- First, because it is the thing this story must not break. Every commitment in the
  -- product today is one of these, and the morning question means nothing if the answer
  -- lands on the wrong day.
  -- -------------------------------------------------------------------------------
  v_at := (v_day + 1 || ' 07:30')::timestamp at time zone 'Asia/Ho_Chi_Minh';

  perform set_config('role', 'authenticated', true);
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_a, v_untimed, gen_random_uuid(), 'held', v_at);
  perform set_config('role', 'postgres', true);

  select for_day, filed_by into v_for_day, v_filed_by
    from public.declaration where commitment_id = v_untimed;

  if v_for_day <> v_day then
    raise exception using message = format(
      'A morning answer given at 07:30 on %s was filed for %s. It answers for %s -- the '
      'subtraction that makes that true has to survive this story.', v_day + 1, v_for_day, v_day);
  end if;

  if v_filed_by <> 'doer' then
    raise exception using message =
      'A client-originated declaration was not forced to filed_by = doer.';
  end if;

  raise notice using message =
    'Step 1 ok: an untimed commitment still answers for yesterday, filed_by forced to doer.';

  -- -------------------------------------------------------------------------------
  -- 2. A timed commitment is claimed on its own day.
  -- -------------------------------------------------------------------------------
  v_at := (v_day || ' 20:14')::timestamp at time zone 'Asia/Ho_Chi_Minh';

  perform set_config('role', 'authenticated', true);
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_a, v_timed, gen_random_uuid(), 'held', v_at);
  perform set_config('role', 'postgres', true);

  select for_day into v_for_day
    from public.declaration where commitment_id = v_timed;

  if v_for_day <> v_day then
    raise exception using message = format(
      'A claim tapped at 20:14 on %s was filed for %s. A timed commitment is answered on '
      'its own day, at the moment the thing is done.', v_day, v_for_day);
  end if;

  raise notice using message =
    'Step 2 ok: a claim tapped inside the window lands on the day it was tapped.';

  -- -------------------------------------------------------------------------------
  -- 3. Both edges of the window, and both sides of it.
  --
  -- Half-open: the instant it opens counts, the instant it closes does not. Each case gets
  -- its own day, because one commitment may carry only one declaration per day.
  -- -------------------------------------------------------------------------------
  foreach v_case in array array[
    'the first instant',
    'the last instant',
    'the closing instant',
    'a minute late',
    'before it opens'
  ]
  loop
    v_at := ((v_day - 10 - (case v_case
                              when 'the first instant' then 0
                              when 'the last instant' then 1
                              when 'the closing instant' then 2
                              when 'a minute late' then 3
                              else 4
                            end))
             || ' ' || (case v_case
                          when 'the first instant' then '20:00:00'
                          when 'the last instant' then '20:29:59'
                          when 'the closing instant' then '20:30:00'
                          when 'a minute late' then '20:31:00'
                          else '06:00:00'
                        end))::timestamp at time zone 'Asia/Ho_Chi_Minh';

    v_refused := false;
    perform set_config('role', 'authenticated', true);
    begin
      insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
      values (v_a, v_timed, gen_random_uuid(), 'held', v_at);
    exception when raise_exception then
      v_refused := true;
    end;
    perform set_config('role', 'postgres', true);

    if v_case in ('the first instant', 'the last instant') and v_refused then
      raise exception using message = format(
        'A claim tapped at "%s" of its window was refused. The window is half-open: it '
        'opens at 20:00 and closes at 20:30, and both of those are inside it.', v_case);
    end if;

    if v_case in ('the closing instant', 'a minute late', 'before it opens') and not v_refused then
      raise exception using message = format(
        'A claim tapped "%s" was accepted. Recording it instead of refusing it costs the '
        'author two days, not one -- the derivation would name the next day and spend its '
        'only declaration on a claim made before its window opened.', v_case);
    end if;
  end loop;

  raise notice using message =
    'Step 3 ok: 20:00:00 and 20:29:59 accepted; 20:30:00, 20:31 and 06:00 refused.';

  -- -------------------------------------------------------------------------------
  -- 4. A claim made offline is dated by the tap, not by the flush (AD-6).
  --
  -- The author taps in a basement at 20:14 and the row arrives the next morning. The day it
  -- belongs to is the day he tapped, or an answer given honestly counts against him.
  -- -------------------------------------------------------------------------------
  v_at := (v_day - 20 || ' 20:14')::timestamp at time zone 'Asia/Ho_Chi_Minh';

  perform set_config('role', 'authenticated', true);
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_a, v_timed, gen_random_uuid(), 'held', v_at);
  perform set_config('role', 'postgres', true);

  select for_day into v_for_day
    from public.declaration
   where commitment_id = v_timed and answered_at = v_at;

  if v_for_day <> v_day - 20 then
    raise exception using message = format(
      'A claim tapped on %s and flushed later was filed for %s. The instant stored is the '
      'instant he tapped (AD-6), and the day follows the tap.', v_day - 20, v_for_day);
  end if;

  raise notice using message =
    'Step 4 ok: a claim flushed late is still dated by the tap that made it.';

  -- -------------------------------------------------------------------------------
  -- 5. A declaration cannot name a commitment the caller does not own.
  --
  -- Pre-existing and not caused by this story: `declaration`'s insert policy checks
  -- `auth.uid() = owner_id` and the caller's role, and never that `commitment_id` belongs to
  -- that owner. The trigger now reads the commitment as the caller, so RLS answers it.
  -- -------------------------------------------------------------------------------
  v_at := (v_day - 30 || ' 20:14')::timestamp at time zone 'Asia/Ho_Chi_Minh';

  v_refused := false;
  perform set_config('role', 'authenticated', true);
  begin
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
    values (v_a, v_theirs, gen_random_uuid(), 'held', v_at);
  exception when others then
    v_refused := true;
  end;
  perform set_config('role', 'postgres', true);

  if not v_refused then
    raise exception using message =
      'One account filed a declaration against another account''s commitment. The trigger '
      'reads the commitment as the caller precisely so RLS refuses this.';
  end if;

  raise notice using message =
    'Step 5 ok: a declaration naming another account''s commitment is refused.';

  -- -------------------------------------------------------------------------------
  -- 6. A machine-filed row keeps the previous-day derivation, even on a timed commitment.
  --
  -- Documented behaviour rather than a happy accident: settlement does not know about
  -- `due_time` until Story 6.4, so giving a machine-filed row a same-day meaning here would
  -- be inventing behaviour for a judge that has not been written. This asserts the choice so
  -- that changing it in 6.4 is a deliberate act with a failing test, not a silent drift.
  -- -------------------------------------------------------------------------------
  v_at := (v_day - 40 || ' 03:00')::timestamp at time zone 'Asia/Ho_Chi_Minh';

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer,
                                  answered_at, filed_by)
  values (v_a, v_timed, gen_random_uuid(), 'slipped', v_at, 'auto_check');

  select for_day, filed_by into v_for_day, v_filed_by
    from public.declaration
   where commitment_id = v_timed and answered_at = v_at;

  if v_for_day <> v_day - 41 then
    raise exception using message = format(
      'A machine-filed row on a timed commitment was filed for %s rather than %s. Story 6.2 '
      'leaves the machine branch alone on purpose; if 6.4 changes it, change this too.',
      v_for_day, v_day - 41);
  end if;

  if v_filed_by <> 'auto_check' then
    raise exception using message =
      'A security-definer caller''s explicit filed_by was overwritten. Only a client-'
      'originated statement is forced back to doer.';
  end if;

  raise notice using message =
    'Step 6 ok: a machine-filed row keeps the previous-day derivation and its own filed_by.';

  -- ===============================================================================
  -- Epic 6 retrospective item 38 — a queued claim is judged by what was in force when
  -- it was tapped.
  --
  -- Everything above flushes within the same settings. A claim tapped in a basement can
  -- arrive days later, and until now the trigger asked the *live* commitment what it meant:
  -- clear the time from another device and a same-day claim silently answered the previous
  -- day instead, spending that day's one allowed declaration on a day nobody spoke about and
  -- leaving the day actually claimed to fail at close.
  -- ===============================================================================

  -- -------------------------------------------------------------------------------
  -- 7. The time cleared on a later day does not re-point a claim already tapped.
  --
  -- The whole point of the fix. `due_time_as_of()` is what settlement has judged days by
  -- since Story 6.4; the derivation now asks the same door, so a settings edit made after a
  -- day ended cannot change what a tap inside it meant.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Cleared later', 'do', 'daily', time '20:00', 30)
  returning id into v_cleared;

  -- The commitment is old; only its log stamps matter, and they are what the reader orders by.
  update public.commitment_due_time_change
     set changed_at = (v_day - 60 || ' 08:00')::timestamp at time zone 'Asia/Ho_Chi_Minh'
   where commitment_id = v_cleared;

  -- Today, from another device: the commitment stops being timed at all.
  update public.commitment
     set due_time = null, late_window_minutes = null
   where id = v_cleared;

  v_at := (v_day - 50 || ' 20:14')::timestamp at time zone 'Asia/Ho_Chi_Minh';

  perform set_config('role', 'authenticated', true);
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer,
                                  answered_at, claimed_timed)
  values (v_a, v_cleared, gen_random_uuid(), 'held', v_at, true);
  perform set_config('role', 'postgres', true);

  select for_day into v_for_day
    from public.declaration where commitment_id = v_cleared and answered_at = v_at;

  if v_for_day is distinct from v_day - 50 then
    raise exception using message = format(
      'A claim tapped on %s and flushed after the time was cleared today was filed for %s. '
      'Reading the live column here is what let another device re-point a tap that had '
      'already happened.', v_day - 50, coalesce(v_for_day::text, 'nothing at all'));
  end if;

  -- And the window that judged it is the one that governed that day, not the null the live
  -- row now carries -- otherwise every hour of that day would be inside the window.
  v_at := (v_day - 51 || ' 20:45')::timestamp at time zone 'Asia/Ho_Chi_Minh';

  v_refused := false;
  perform set_config('role', 'authenticated', true);
  begin
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer,
                                    answered_at, claimed_timed)
    values (v_a, v_cleared, gen_random_uuid(), 'held', v_at, true);
  exception when raise_exception then
    v_refused := true;
  end;
  perform set_config('role', 'postgres', true);

  if not v_refused then
    raise exception using message =
      'A claim tapped 45 minutes past a 30-minute window was accepted, because the live row '
      'no longer carries a window at all. A null late_window_minutes makes the comparison '
      'null and every hour of the day looks open.';
  end if;

  raise notice using message =
    'Step 7 ok: clearing the time today leaves an earlier day''s claim on its own day, still '
    'judged by the window that governed it.';

  -- -------------------------------------------------------------------------------
  -- 8. The time cleared during the tap's own day is refused, not silently re-pointed.
  --
  -- `due_time_as_of()` calls that day untimed -- nothing governed the whole of it -- so
  -- settlement will ask about it in the next morning's question. Recording a same-day claim
  -- there would make the derivation the only writer disagreeing with the judge.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Cleared mid-day', 'do', 'daily', time '20:00', 30)
  returning id into v_midday;

  update public.commitment
     set due_time = null, late_window_minutes = null
   where id = v_midday;

  v_at := (v_today || ' 20:14')::timestamp at time zone 'Asia/Ho_Chi_Minh';

  v_refused := false;
  perform set_config('role', 'authenticated', true);
  begin
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer,
                                    answered_at, claimed_timed)
    values (v_a, v_midday, gen_random_uuid(), 'held', v_at, true);
  exception when raise_exception then
    v_refused := true;
  end;
  perform set_config('role', 'postgres', true);

  if not v_refused then
    raise exception using message =
      'A claim tapped on a day whose time was cleared part-way through was accepted. That day '
      'is judged untimed, so this either lands on the previous day -- answering a day nobody '
      'spoke about -- or contradicts the judge.';
  end if;

  if exists (select 1 from public.declaration where commitment_id = v_midday) then
    raise exception using message =
      'A refused claim left a row behind. A refusal has to record nothing at all.';
  end if;

  raise notice using message =
    'Step 8 ok: a claim for a day whose time moved part-way through is refused, and nothing '
    'is recorded.';

  -- -------------------------------------------------------------------------------
  -- 9. The remembered mode is checked, and its absence is not a "no".
  --
  -- The client sends what it believed when the author tapped. It is never trusted as a value
  -- -- a lie can only produce a refusal or agree with the log -- and an item queued by an
  -- older client carries nothing, which must derive exactly as it always did rather than
  -- read as "untimed".
  -- -------------------------------------------------------------------------------
  v_at := (v_day - 55 || ' 20:14')::timestamp at time zone 'Asia/Ho_Chi_Minh';

  v_refused := false;
  perform set_config('role', 'authenticated', true);
  begin
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer,
                                    answered_at, claimed_timed)
    values (v_a, v_timed, gen_random_uuid(), 'held', v_at, false);
  exception when raise_exception then
    v_refused := true;
  end;
  perform set_config('role', 'postgres', true);

  if not v_refused then
    raise exception using message =
      'A morning answer was accepted against a day that carried a window all the way through. '
      'The gate never asks about a timed commitment, so this is a stale queued item, and '
      'filing it would answer the day before the one it was tapped on.';
  end if;

  v_at := (v_day - 56 || ' 20:14')::timestamp at time zone 'Asia/Ho_Chi_Minh';

  perform set_config('role', 'authenticated', true);
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_a, v_timed, gen_random_uuid(), 'held', v_at);
  perform set_config('role', 'postgres', true);

  select for_day into v_for_day
    from public.declaration where commitment_id = v_timed and answered_at = v_at;

  if v_for_day is distinct from v_day - 56 then
    raise exception using message = format(
      'A claim carrying no remembered mode was filed for %s rather than %s. Absent must mean '
      '"not asserted" and derive as before, never "untimed" -- every item queued before this '
      'shipped carries nothing.', coalesce(v_for_day::text, 'nothing at all'), v_day - 56);
  end if;

  raise notice using message =
    'Step 9 ok: a mismatched remembered mode is refused, and an absent one still derives.';

  -- -------------------------------------------------------------------------------
  -- 10. The window that judges a tap is the one in force at the tap.
  --
  -- Not the live value, which the author may have widened since, and not the value in force
  -- when the day began, which would refuse an online tap the app had just shown as open.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Widened', 'do', 'daily', time '20:00', 30)
  returning id into v_widened;

  update public.commitment_due_time_change
     set changed_at = (v_day - 60 || ' 08:00')::timestamp at time zone 'Asia/Ho_Chi_Minh'
   where commitment_id = v_widened;

  update public.commitment set late_window_minutes = 60 where id = v_widened;

  update public.commitment_due_time_change
     set changed_at = (v_day - 3 || ' 12:00')::timestamp at time zone 'Asia/Ho_Chi_Minh'
   where commitment_id = v_widened and late_window_minutes = 60;

  -- Before the widening: 20:45 is 45 minutes past a 30-minute window.
  v_at := (v_day - 10 || ' 20:45')::timestamp at time zone 'Asia/Ho_Chi_Minh';

  v_refused := false;
  perform set_config('role', 'authenticated', true);
  begin
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer,
                                    answered_at, claimed_timed)
    values (v_a, v_widened, gen_random_uuid(), 'held', v_at, true);
  exception when raise_exception then
    v_refused := true;
  end;
  perform set_config('role', 'postgres', true);

  if not v_refused then
    raise exception using message =
      'A claim tapped at 20:45 under a 30-minute window was accepted because the window has '
      'since been widened to 60. Widening it today cannot retroactively make a day''s late '
      'claim punctual.';
  end if;

  -- After the widening: the same wall-clock instant is inside the window the app showed.
  v_at := (v_day - 2 || ' 20:45')::timestamp at time zone 'Asia/Ho_Chi_Minh';

  perform set_config('role', 'authenticated', true);
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer,
                                  answered_at, claimed_timed)
  values (v_a, v_widened, gen_random_uuid(), 'held', v_at, true);
  perform set_config('role', 'postgres', true);

  select for_day into v_for_day
    from public.declaration where commitment_id = v_widened and answered_at = v_at;

  if v_for_day is distinct from v_day - 2 then
    raise exception using message = format(
      'A claim tapped at 20:45 after the window was widened to 60 minutes was filed for %s. '
      'The window in force at the tap is the one the author was shown.',
      coalesce(v_for_day::text, 'nothing at all'));
  end if;

  -- And the day the window length itself changed is still a timed day. Only the *time*
  -- moving part-way through a day makes that day untimed (Story 6.4); a window edit must not
  -- quietly re-judge the day it was made on.
  v_at := (v_day - 3 || ' 20:14')::timestamp at time zone 'Asia/Ho_Chi_Minh';

  perform set_config('role', 'authenticated', true);
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer,
                                  answered_at, claimed_timed)
  values (v_a, v_widened, gen_random_uuid(), 'held', v_at, true);
  perform set_config('role', 'postgres', true);

  select for_day into v_for_day
    from public.declaration where commitment_id = v_widened and answered_at = v_at;

  if v_for_day is distinct from v_day - 3 then
    raise exception using message = format(
      'The day the window length was changed on was filed for %s rather than %s. Logging the '
      'window must not widen due_time_as_of()''s "changed part-way through" rule, or a '
      'settings edit would re-judge days settlement has already closed.',
      coalesce(v_for_day::text, 'nothing at all'), v_day - 3);
  end if;

  raise notice using message =
    'Step 10 ok: the window in force at the tap judges it, and a window edit does not make '
    'its own day untimed.';

  -- -------------------------------------------------------------------------------
  -- 11. A governing time whose window was never recorded is refused, and says so.
  --
  -- Only reachable through history written before the window was logged. The honest answer is
  -- that the day cannot be judged, not a guess -- and a null window silently accepts every
  -- hour, which is the one outcome that moves money for nothing.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Unlogged window', 'do', 'daily', time '20:00', 30)
  returning id into v_unlogged;

  update public.commitment_due_time_change
     set changed_at = (v_day - 60 || ' 08:00')::timestamp at time zone 'Asia/Ho_Chi_Minh',
         late_window_minutes = null
   where commitment_id = v_unlogged;

  v_at := (v_day - 45 || ' 20:14')::timestamp at time zone 'Asia/Ho_Chi_Minh';

  v_refused := false;
  v_message := null;
  perform set_config('role', 'authenticated', true);
  begin
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer,
                                    answered_at, claimed_timed)
    values (v_a, v_unlogged, gen_random_uuid(), 'held', v_at, true);
  exception when raise_exception then
    v_refused := true;
    v_message := sqlerrm;
  end;
  perform set_config('role', 'postgres', true);

  if not v_refused then
    raise exception using message =
      'A claim on a day whose window was never recorded was accepted. With no window the '
      'comparison is null and every hour of the day reads as inside it.';
  end if;

  if v_message not ilike '%recorded%' then
    raise exception using message = format(
      'The refusal said "%s". It has to say the window for that day was never recorded, or '
      'the author reads it as his own mistake.', v_message);
  end if;

  raise notice using message =
    'Step 11 ok: a day whose window was never recorded is refused in words that name why.';

  raise notice using message =
    'PASS. Untimed answers for yesterday, a claim lands on the day it was tapped, the window '
    'is half-open and enforced, and no account can declare against another''s commitment. A '
    'queued claim is judged by the time and the window that were in force when it was tapped: '
    'a later settings edit cannot re-point it, a change during its own day refuses it rather '
    'than answering the wrong day, the remembered mode is checked but never trusted, and an '
    'unrecorded window is a refusal rather than an open door.';
end $$;

rollback;
