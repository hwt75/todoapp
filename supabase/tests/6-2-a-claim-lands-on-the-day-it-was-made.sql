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
  raise notice using message =
    'PASS. Untimed answers for yesterday, a claim lands on the day it was tapped, the window '
    'is half-open and enforced, and no account can declare against another''s commitment.';
end $$;

rollback;
